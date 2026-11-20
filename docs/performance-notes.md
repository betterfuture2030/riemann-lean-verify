# Performance notes

For anyone running the build on their own machine. All measurements were taken on 2026-11-20 on one machine: a 10-core Mac (4 performance and 6 efficiency cores) with 24 GB of memory, building onto an external drive, with Lean `v4.33.1`. They describe the first few percent of the build, which is the easy part. Section 5 explains why that matters.

## 1. Summary

| Question | Short answer | Basis |
|---|---|---|
| What limits throughput first? | Memory, not CPU | Tuning tables, section 3 |
| How much memory per parallel job? | Plan for about 2 GB per job plus about 8 GB | Rule of thumb fitted to one machine: 8 jobs was best on 24 GB |
| Best setting found | 8 jobs: about 3,230 modules per hour, once other applications were closed | Measured |
| Same machine with other applications holding memory | 5 jobs: about 2,330 modules per hour; 7 jobs collapsed to about 910 | Measured |
| Cost of a shallow module | About 11 CPU-seconds, of which about 6 (about 55 percent) is importing Mathlib | Derived from the measured rate and a measured import-only compile, on macOS |
| Disk written per module | About 0.8 MB of compiled output plus a JSON file of 6.4 MB or more | Measured over the first 10,300 modules |
| Disk for the whole build | About 1.4 TB as Lake writes it, of which about 90 percent is regenerable JSON; allow 1.5 TB | Projection, section 4 |
| Can the early rate be extrapolated? | No. It gives a floor of about 54 hours. Later modules import far more | Section 5 |
| Biggest risk on a small machine | The last few files import all 175,186 others | Section 7; not yet observed |

## 2. Memory and the number of jobs

Every module in the tree imports Mathlib, directly or indirectly. Each compiler process therefore begins by memory-mapping the compiled files of Mathlib and the libraries beneath it: 8,690 modules, of which Mathlib's own occupy 5.9 GB on disk. Mapped files are shared between processes through the operating system's page cache, so this is paid once in memory, but it has to stay resident for the build to run at speed. On top of it each process needs private memory for its own work.

A snapshot of the running build on 2026-11-20 showed compiler processes with resident sizes from about 0.1 GB (just started) to about 5.6 GB. Most of the larger figure is the shared Mathlib mapping, so resident size per process overstates what an extra job costs. The private share was not measured separately.

A working rule consistent with these measurements is:

> jobs = the smaller of (number of cores) and ((memory in GB − 8) ÷ 2)

That gives 8 jobs on a 24 GB machine. It is fitted to the one machine measured and should be treated as a starting point. Set `RH_JOBS` in `config.env` to choose the number yourself; leaving it empty lets the scripts choose.

Signs that the job count is too high for the memory available:

- throughput falls as jobs are added;
- system CPU time rises towards half of the total, or the machine shows idle time while jobs are queued. Both suggest that time is going into paging rather than compiling.

Closing other applications mattered more than any setting. Compare the 5-job rows of the two tables below with the 8-job row.

## 3. The tuning tables

Each row is one run of the build at a fixed cap on parallel jobs, measured over a window of five to six minutes after a 100-second warm-up. "Modules" is the number of compiled files that appeared during the window. The CPU columns are a single sample taken at the end of the window, so they are noisy. Failures are the cumulative count of failed modules in all logs.

**First run: other applications were holding memory.**

| Jobs | Modules | Seconds | Modules per hour | CPU user % | CPU system % | CPU idle % | Failures |
|---|---|---|---|---|---|---|---|
| 3 | 150 | 382 | 1,414 | 58.7 | 31.2 | 10.1 | 0 |
| 4 | 210 | 383 | 1,974 | 68.3 | 27.2 | 4.5 | 0 |
| 5 | 248 | 383 | 2,331 | 34.3 | 41.5 | 24.2 | 0 |
| 6 | 183 | 383 | 1,720 | 67.6 | 31.4 | 1.3 | 0 |
| 7 | 97 | 382 | 914 | 23.4 | 37.7 | 38.9 | 0 |

**Second run: after freeing memory.**

| Jobs | Modules | Seconds | Modules per hour | CPU user % | CPU system % | CPU idle % | Failures |
|---|---|---|---|---|---|---|---|
| 5 | 172 | 301 | 2,057 | 62.9 | 15.0 | 22.9 | 0 |
| 6 | 226 | 301 | 2,703 | 79.6 | 20.4 | 0.0 | 0 |
| 7 | 239 | 301 | 2,858 | 42.8 | 45.1 | 12.7 | 0 |
| 8 | 271 | 302 | 3,230 | 74.2 | 25.7 | 0.6 | 0 |
| 9 | 232 | 302 | 2,766 | 64.5 | 35.2 | 0.4 | 0 |
| 10 | 247 | 302 | 2,944 | 51.8 | 48.2 | 0.0 | 0 |

How to read them:

- In the first run, going from 5 to 7 jobs cut throughput by more than half, with 39 percent of the CPU idle. That is the signature of memory pressure.
- In the second run the same machine sustained 8 jobs. At 10 jobs, system time was nearly half of all CPU time and throughput was lower.
- The windows are short and each one compiled different modules. Differences of ten percent between neighbouring rows are within the noise; note that 5 jobs measured 2,331 in one run and 2,057 in the other. The tables support "8 is about right for this machine and 5 is right when memory is tight". They do not support finer conclusions.

In these runs the cap was applied by limiting the worker threads of the `lake build` process (`LEAN_NUM_THREADS`). The raw tables are in [`../records/`](../records/).

## 4. Disk

Measured on 2026-11-20 over the first 10,300 compiled modules:

| File per module | Where Lake puts it | Mean size | Total so far | Regenerable? |
|---|---|---|---|---|
| `.olean` (the compiled module) | `.lake/build/lib/lean` | 0.72 MB (median 0.40 MB, largest 69 MB) | 7.4 GB | No: this is the output. Rebuilding it means recompiling |
| `.ilean`, `.trace`, hash files | same | 0.04 MB together | 0.4 GB | No |
| `.c` and its hash | `.lake/build/ir` | under 0.01 MB | 0.1 GB | No |
| `.setup.json` | `.lake/build/ir` | 6.47 MB (largest 8.4 MB) | 66.7 GB | Yes |

So about 90 percent of what the build writes is the per-module JSON file.

**Why the JSON is regenerable.** Before compiling a module, Lake writes a setup file that tells the compiler where to find the compiled form of every module in that module's import closure, together with the options to use. It is an input to the compiler invocation, derived entirely from the import graph, the options and the paths on disk. It contains no result of compilation. For a module that imports only Mathlib it has 8,690 entries and is 6.43 MB. Each further imported project module adds about 250 bytes; the largest so far had 16,431 entries.

The kernel replay reads `.olean` files only. Deleting setup files once the build has finished therefore loses nothing that the checks need. Whether Lake treats a module as out of date when its setup file is missing, and so rebuilds it, has not been tested here; do not delete them while a build is still going unless you have checked.

**Projection for the whole tree.** With a mean of about 2,950 imported project modules per module (section 5), the mean setup file is about 7.2 MB, so the JSON totals about 1.26 TB. If the remaining modules are the same size on average as the first 10,300, compiled output adds about 0.13 TB. Mathlib's own compiled files are 5.9 GB. That is about 1.4 TB in total, or about 150 GB without the setup files. Allow 1.5 TB. Both figures are projections from the first six percent of the build.

## 5. Why early throughput cannot be extrapolated

Lake compiles in dependency order. The modules it reaches first are the ones that import few other project modules. They are the cheapest in the tree, for a simple reason: before a compiler process can do anything, it has to load the compiled form of everything its module imports.

**Sizes of import closures**, counting project modules only, from the import graph of the source:

| Statistic | Project modules imported, directly or indirectly |
|---|---|
| Modules that import no project module at all | 5,927 of 175,187 |
| 10th percentile | 5 |
| 25th percentile | 51 |
| Median | 606 |
| 75th percentile | 3,330 |
| 90th percentile | 8,388 |
| 95th percentile | 10,094 |
| 99th percentile | 21,794 |
| Largest in the sample | 49,768 |
| Mean | about 2,950 (4,000-module random sample; a separate 1,500-module sample gave 2,670) |

The percentiles are from a random sample of 1,500 modules. A few modules at the very end import nearly everything:

| Module | Project modules in its import closure |
|---|---|
| The file that assembles the final statement (`…/ThirdPlaceSeries/EveryCharacterOfLiteratureOfVWin`) | 151,285 |
| `…/CharacterBoxes/MainConclusion` | 175,173 |
| `Supplements.Kernels.MainTheorems` | 175,178 |
| `Supplements.Kernels.MainTheoremsAll` | 175,184 |
| `Main` | 175,186 |

**Depth.** The longest chain of imports is 203 modules long. However many cores are available, those 203 have to be compiled one after another.

| Length of the longest import chain ending at a module, counting the module itself | Modules |
|---|---|
| 1 to 20 | 53,083 |
| 21 to 40 | 33,534 |
| 41 to 60 | 32,019 |
| 61 to 80 | 19,018 |
| 81 to 100 | 22,744 |
| 101 to 120 | 10,658 |
| 121 to 140 | 3,268 |
| 141 to 160 | 726 |
| 161 to 220 | 137 |

**What this does to cost.** A module that imports only Mathlib loads 8,690 files, about 5.9 GB. Project `.olean` files have averaged 0.72 MB so far, which is of the same order as Mathlib's. Assuming that average holds for the rest of the tree:

| Module | Files to load | Approximate size mapped |
|---|---|---|
| Imports only Mathlib | 8,690 | 5.9 GB |
| Mean module (2,950 project imports) | 11,640 | 8 GB |
| 95th percentile (10,094) | 18,780 | 13 GB |
| 99th percentile (21,794) | 30,480 | 22 GB |
| `Main` (175,186) | 183,880 | about 130 GB |

Since importing Mathlib alone is already about 55 percent of the cost of a shallow module, the import cost of a typical later module is likely to be larger than anything measured so far. How much larger in time is not known. It depends on how much of the mapped data a module actually touches, and nothing measured yet reaches those modules.

**The fit that failed.** An attempt was made to fit wall time per module against closure size using the first 1,228 timed modules. The largest closure among them was 837. The fitted slope was slightly negative, which would project a negative build time. The sample simply contains no information about deep modules. This is recorded as a warning against doing the same thing with better-looking numbers.

## 6. Expected duration

| Estimate | Value | Status |
|---|---|---|
| Floor on the measured machine: 175,187 modules at the best shallow rate of 3,230 per hour | 54 hours | Arithmetic on a measured rate. A lower bound, not a forecast |
| Same, at the rate achieved with memory tight (2,330 per hour) | 75 hours | Arithmetic on a measured rate |
| With a penalty for deeper modules of 1.1 to 2.0 times, as assumed in desk reviews | 60 to 110 hours | Assumed range. No measurement supports either end |
| Kernel replay of every module afterwards | Not known. In a 24-module sample each replay took 14 to 28 seconds of wall time (median 16), about 2 seconds of user and 11 of system CPU time, one process per module, while the build was also running | Measured on shallow modules only |

"Days on a laptop" is the accurate summary. The replay is not a small addition: per module, on these shallow modules, it costs about as much CPU time as compiling did, because it too has to load the import closure.

The build can be stopped and restarted. Lake keeps finished modules. The tuning runs allowed 100 seconds after each restart for Lake to start up before measuring; that start-up time is likely to grow as the number of finished modules grows.

## 7. The final files on a machine with little memory

This risk has not been observed, because the build has not reached these files. It follows from the numbers in section 5.

- The last handful of modules each map about 130 GB of compiled files in a single process. A 24 GB machine cannot hold that in memory. Mapped files can be dropped from memory and read again from disk, so this is not automatically fatal, but every access that misses becomes a disk read.
- The compiler's private memory for a module also grows with the size of its import closure. By how much is not measured. A desk estimate by one reviewer, scaling from Mathlib, was 20 to 35 GB for a final file. If that is right, a 24 GB machine will swap heavily or fail on them.
- Well before the end, the top one percent of modules map more than 20 GB each. Eight of those cannot be resident at once on 24 GB.

What to do about it:

- Lower the job count as the build approaches the end. One or two jobs for the last few thousand modules is a reasonable precaution on a small machine; it has not been tried here.
- If the final files fail for lack of memory on a small machine, that is a statement about the machine. It is not a failed proof check. Record it as such and finish those files on a machine with more memory.
- On Linux, two limits are worth raising before starting: the per-process limit on open files (the Mac run used 65,536), and the per-process limit on memory mappings, `vm.max_map_count`, whose usual default of 65,530 is below the roughly 184,000 files a final module maps. The second point comes from a desk review and has not been tested here.

## 8. Other practical points

- Keep the machine awake. The Mac run was wrapped in `caffeinate`.
- No module had failed in any of the logs on 2026-11-20, so how a failure behaves at this scale has not been observed here.
- The tree's `lakefile.toml` raises `maxHeartbeats` to 4,000,000 and the compiler's thread stack size. Individual files raise the heartbeat limit further. Some single modules will take a long time; that is expected and is not a hang.
- If you measure anything on a different machine, especially on deeper modules or on Linux, the numbers would be a useful addition to [`../records/`](../records/).
