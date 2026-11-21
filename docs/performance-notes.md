# Performance notes

For anyone running the build on their own machine. Sections 1 to 8 were measured on 2026-11-20 on one machine: a 10-core Mac (4 performance and 6 efficiency cores) with 24 GB of memory, building onto an external drive, with Lean `v4.33.1`. They describe the first few percent of the build, which is the easy part. Section 5 explains why that matters. Section 9 adds what a 32-vCPU Linux machine measured later the same day, on modules up to much larger import closures; where it answers a question that an earlier section leaves open, the earlier section says so. Section 10 corrects what sections 6 and 9 first said about the cost of the kernel replay.

## 1. Summary

| Question | Short answer | Basis |
|---|---|---|
| What limits throughput first? | Memory, not CPU | Tuning tables, section 3 |
| How much memory per parallel job? | Plan for about 2 GB per job plus about 8 GB | Rule of thumb fitted to one machine: 8 jobs was best on 24 GB |
| Best setting found | 8 jobs: about 3,230 modules per hour, once other applications were closed | Measured |
| Same machine with other applications holding memory | 5 jobs: about 2,330 modules per hour; 7 jobs collapsed to about 910 | Measured |
| Cost of a shallow module | About 11 CPU-seconds, of which about 6 (about 55 percent) is importing Mathlib | Derived from the measured rate and a measured import-only compile, on macOS |
| Disk written per module | About 0.8 MB of compiled output plus a JSON file of 6.4 MB or more | Measured over the first 10,300 modules |
| Disk for the whole build | About 1.4 TB as Lake writes it, of which about 90 percent is regenerable JSON; allow 1.5 TB. About 150 GB if the JSON is removed as modules finish; allow 200 GB | Projection, section 4 |
| Can the early rate be extrapolated? | No. It gives a floor of about 54 hours. Later modules import far more | Section 5 |
| Biggest risk on a small machine | The last few files import all 175,186 others | Section 7; not yet observed |

## 2. Memory and the number of jobs

Every module in the tree imports Mathlib, directly or indirectly. Each compiler process therefore begins by memory-mapping the compiled files of Mathlib and the libraries beneath it: 8,690 modules, of which Mathlib's own occupy 5.9 GB on disk. (A later count on a running process found about 8,650 of those mapped, plus 1,801 modules of Lean's own library that this figure leaves out: 10,452 library modules in all. See section 7.) Mapped files are shared between processes through the operating system's page cache, so this is paid once in memory, but it has to stay resident for the build to run at speed. On top of it each process needs private memory for its own work.

A snapshot of the running build on 2026-11-20 showed compiler processes with resident sizes from about 0.1 GB (just started) to about 5.6 GB. Most of the larger figure is the shared Mathlib mapping, so resident size per process overstates what an extra job costs. The private share was not measured separately here. It was later, on Linux: a median of 0.5 GB per process (section 9).

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

The kernel replay reads `.olean` files only. Deleting setup files once the build has finished therefore loses nothing that the checks need.

**Deleting them during a build.** Lake decides what is up to date from the `.trace` and hash files beside the compiled output. A test on 2026-11-20 with the same Lake version (5.0.0) on a five-module project found that it does not look at the setup file of a module that is already built: after the setup files were deleted, a second `lake build` recompiled nothing and left every `.olean` byte-for-byte unchanged, modules importing the pruned ones compiled normally, and `leanchecker` passed on all of them. The compiler reads a module's setup file once, when it starts on that module; Lake writes the setup file first and the `.trace` file last.

[`../scripts/prune_setup_files.sh`](../scripts/prune_setup_files.sh) uses that ordering: it reports, and with `--delete` removes, the setup file of every module whose `.trace` is newer than its setup file. Run without `--delete` on the real build at 23,991 setup files, it found 156.1 GB, of which 154.2 GB belonged to finished modules ([`../records/mac-build/progress-20261120-2001.txt`](../records/mac-build/progress-20261120-2001.txt)). The same was then confirmed on the real tree, on Linux: in two cloud rehearsals the setup files of 641 and 644 finished modules were deleted, the build tool was restarted, and none of those modules was recompiled ([`../records/cloud/full-rehearsals/`](../records/cloud/full-rehearsals/)). It has not been run with `--delete` on a Mac, so the first time you do there, check that the next `lake build` prints no "Built" line for a module that was already compiled.

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

"Files to load" here counts modules, and leaves out the 1,801 modules of Lean's own library. Each library module is mapped as five files and each project module as about one; section 7 has the measured counts.

Since importing Mathlib alone is already about 55 percent of the cost of a shallow module, the import cost of a typical later module is likely to be larger than anything measured so far. How much larger in time was not known when this was written. It has since been measured on Linux for closures up to 17,860 and is small: see section 9.

**The fit that failed.** An attempt was made to fit wall time per module against closure size using the first 1,228 timed modules. The largest closure among them was 837. The fitted slope was slightly negative, which would project a negative build time. The sample simply contains no information about deep modules. This is recorded as a warning against doing the same thing with better-looking numbers.

## 6. Expected duration

| Estimate | Value | Status |
|---|---|---|
| Floor on the measured machine: 175,187 modules at the best shallow rate of 3,230 per hour | 54 hours | Arithmetic on a measured rate. A lower bound, not a forecast |
| Same, at the rate achieved with memory tight (2,330 per hour) | 75 hours | Arithmetic on a measured rate |
| With a penalty for deeper modules of 1.1 to 2.0 times, as assumed in desk reviews | 60 to 110 hours | Assumed range. No measurement on this machine supports either end. On Linux, with ample memory, deeper modules cost about 6 percent more on average (section 9); on 24 GB the limit is memory, which that figure does not capture |
| Kernel replay of every module afterwards | Not known on this machine. With the stock tool and the whole library on its search path it is out of reach here: a check took 14 to 28 seconds with a few percent of the tree compiled and 17 to 90 with a fifth of it, two at a time beside the build, and it grows with the tree. With only the module's imports on the search path, 10 to 18 seconds with a third of the tree compiled; with `rhv-replay`, about 7 (section 10) | Measured on modules from the first third of the tree only |

"Days on a laptop" is the accurate summary. The replay is not a small addition, and with the stock tool it is the larger part: each check first lists every compiled file on the search path, so its cost grows with the tree (section 10).

The build can be stopped and restarted. Lake keeps finished modules. The tuning runs allowed 100 seconds after each restart for Lake to start up before measuring; that start-up time is likely to grow as the number of finished modules grows. On Linux it was 4 to 9 seconds with up to 30,000 modules built (section 9).

## 7. The final files on a machine with little memory

This risk has not been observed, because the build has not reached these files. It follows from the numbers in section 5.

- The last handful of modules each map about 130 GB of compiled files in a single process. A 24 GB machine cannot hold that in memory. Mapped files can be dropped from memory and read again from disk, so this is not automatically fatal, but every access that misses becomes a disk read.
- The compiler's private memory for a module also grows with the size of its import closure. A desk estimate by one reviewer, scaling from Mathlib, was 20 to 35 GB for a final file. The Linux measurement in section 9 is far lower: about 13 KB per imported module, which projects to under 3 GB. That is an extrapolation from closures a tenth the size.
- Well before the end, the top one percent of modules map more than 20 GB each. Eight of those cannot be resident at once on 24 GB.

What to do about it:

- Lower the job count as the build approaches the end. One or two jobs for the last few thousand modules is a reasonable precaution on a small machine; it has not been tried here.
- If the final files fail for lack of memory on a small machine, that is a statement about the machine. It is not a failed proof check. Record it as such and finish those files on a machine with more memory.
- On Linux, raise the per-process limit on memory mappings, `vm.max_map_count`, before starting. A compiler process maps five files for each module of Mathlib and of Lean's own library, 52,260 in all, before it reaches any project module, and about one more for each project module it imports ([`../records/mac-build/mapped-files-sample.txt`](../records/mac-build/mapped-files-sample.txt)). The usual default of 65,530 therefore leaves room for about 12,000 project imports, and about one module in twenty imports more than that. The Linux pilot ran with the limit at 1,048,576 and compiled closures up to 17,860; the default itself was not tested. The last module is projected to map about 240,000 files. `scripts/00_check_prereqs.sh` reports the limit.
- On macOS the corresponding limit is the system-wide table of files in use, `kern.maxvnodes`: 263,168 on the 24 GB machine. The last modules map about 240,000 files at once, which is close to it. Whether macOS copes has not been observed. It can be raised until the next restart with `sudo sysctl kern.maxvnodes=600000`.

## 8. Other practical points

- Keep the machine awake. The Mac run was wrapped in `caffeinate`.
- No module had failed in any of the logs on 2026-11-20, so how a failure behaves at this scale has not been observed here.
- The tree's `lakefile.toml` raises `maxHeartbeats` to 4,000,000 and the compiler's thread stack size. Individual files raise the heartbeat limit further. Some single modules will take a long time; that is expected and is not a hang.
- If you measure anything on a different machine, especially on deeper modules or on Linux, the numbers would be a useful addition to [`../records/`](../records/).

## 9. What a 32-vCPU Linux machine added

Later on 2026-11-20 a calibration pilot ran for just under three hours on a rented machine with 16 cores, 32 threads and 256 GB of memory. It compiled 29,633 modules, including two build targets with import closures of about 8,000 and 17,860 project modules, and kernel-checked 2,233. Nothing failed. The details and the cost estimate built on them are in [`cloud-notes.md`](cloud-notes.md), section 8; the raw data is in [`../records/cloud/pilot/`](../records/cloud/pilot/).

| Question left open above | What was measured |
|---|---|
| Does a module get much dearer as its import closure grows? (section 5) | No. Importing costs 2.4 seconds plus 0.14 seconds per 1,000 project modules imported, for one process alone. Mean CPU per module was 8.4 seconds for closures of 1 to 100 and 8.3 seconds above 8,000. The tree's mean closure adds about 6 percent to the pilot's mean cost |
| How much of the mapped data does a module touch? (section 5) | About 0.6 MB per imported project module, of the 0.72 MB average file: most of it |
| Private memory per compiler process (sections 2 and 7) | Median 0.5 GB, 99th percentile 0.8 GB, largest 8.1 GB; 0.5 GB plus 13 KB per imported project module |
| How many jobs per core? (section 2) | Each compiler process ran about 15 threads and used a little over one core. Sixteen jobs on 16 cores gave 3.1 to 3.3 modules per second; 32 jobs gave 3.2 to 3.5 |
| What does the kernel replay cost? (section 6) | With the stock tool and 29,633 modules compiled: 8.3 CPU seconds per module with 32 running at once, 4.4 seconds for one alone. Most of that is not importing, as first written here, but the tool listing every compiled file before each check, a cost that grows with the tree (section 10) |
| How long does a restart take as finished modules accumulate? (section 6) | 4 to 9 seconds to the first new module with up to 30,000 built |
| Expected duration on that machine (section 6) | About 16 hours for the build, by extrapolation. The 14 hours first given here for the kernel replay was wrong: about 46 hours with the stock tool as it was first run, about 8.5 once each check is shown only what its module imports, and about 6 with a second program, `rhv-replay` (section 10) |

What it does not answer: nothing above 17,860 imports was compiled, so the last few thousand modules, and above all the last handful, remain unmeasured on any machine. And that machine never had to read a compiled file back from disk, so it says nothing about section 7's question of a machine with little memory.

## 10. The kernel replay: what a check costs, and why the stock tool's cost grows with the tree

Sections 6 and 9 gave an estimate of 14 hours for replaying every module on the rented machine. That estimate was wrong, and this section records why, what was measured, and what was done about it: in the end, a different way of invoking the same stock tool. It was found on 2026-11-20 by an audit of the full-run driver, before any full run.

**What the stock tool does.** `leanchecker X` checks every module whose name starts with `X`. To find them it lists every compiled file on the search path and works out each one's module name, once per process, before it replays anything (`src/lean/LeanChecker.lean` in the toolchain: `SearchPath.findAllWithExt`, then `searchModuleNameOfFileName` for each file). Run once per module, as [`../scripts/09_kernel_replay.sh`](../scripts/09_kernel_replay.sh) does, the listing is repeated for every module, and it gets longer as the tree is built. The replay itself, the function `replayFromImports`, does not need the listing: it is handed a module name and finds that one file directly.

**What was measured.**

| Where | Compiled modules on disk | Result |
|---|---|---|
| Cloud, third rehearsal, 32 checks at a time | 1,792 | 4.4 seconds of wall time per check |
| Cloud, pilot, 32 checks at a time | 29,633 | 8.3 CPU seconds per check, which is 8.5 seconds of wall time at the measured 0.971 CPU seconds per second; 61 percent of the CPU time inside the operating system |
| Cloud, fifth rehearsal, the same replay without the listing (`rhv-replay`, below), 32 at a time | 1,796 | 3.1 seconds of one job's time per module (10.4 modules a second); 2.0 seconds at 16 at a time |
| Cloud, fifth rehearsal, `leanchecker` on 150 of those modules, 32 at a time | 1,796 | 4.1 seconds per check; the same verdict on all 150 |
| Mac, one check alone, a module that imports nothing | 32,486 | 8.7 seconds with `leanchecker`; 0.6 seconds for the same replay without the listing |
| Mac, sample of 24 modules (section 6) | a few percent of the tree | about 2 seconds of user CPU time and 9 to 13 of system time per check |

The pilot's 61 percent, and the Mac's system time, had been read as the cost of importing. They are mostly the listing. The estimate of 14 hours took the pilot's 8.3 seconds as the cost of a check at any size of tree.

**The projection.** [`../analysis/replay_cost.py`](../analysis/replay_cost.py) fits the two cloud measurements, in seconds of wall time per check with 32 running at once, as a fixed cost, a cost per compiled file on the search path, and the pilot's cost per imported module; its output is [`../records/cloud/replay_cost.json`](../records/cloud/replay_cost.json).

| | Seconds per check, 32 at a time | Whole tree, hours |
|---|---|---|
| Fixed | 2.6 | |
| Per compiled file on the search path | 0.000144 | |
| `leanchecker`, one process per module, the whole library on its search path, 175,187 modules compiled | 30.1, of which 26.6 is the listing | 46 |
| `leanchecker`, one process per module, only the module's import closure on its search path (below) | 5.6, of which 1.9 is the listing | 8.5 |
| The same replay without the listing, as the fit projects it | 3.4 | 5.2 |
| The same, with the 3.1 seconds measured in the fifth rehearsal in place of the fit's 2.6 | 3.9 | 6.0 |

The stock tool's figure is a line through two points and shows the size of the effect, no more. The measurement in the fifth rehearsal allows a check on it: taking 3.1 seconds as the cost without the listing, the listing itself cost 1.3 seconds with 12,244 compiled files on the search path and 5.3 with 40,085, which is a little more than in proportion. Carried to the whole tree in proportion, by a line, or by a power law through those two values, the stock tool's replay comes to 43, 46 or 56 hours. On any of them it does not fit in a run limited to 42 hours whose build takes about 16.

The last row is still part projection. The 3.1 seconds were measured on modules that import little of this project; the allowance for deeper modules, 0.8 seconds on average, is the stock tool's, measured in the pilot. `rhv-replay` has not been timed on modules with large import closures on the cloud machine.

**What does not solve it.**

- *Fewer, larger `leanchecker` processes, each given a name prefix.* The tree is too flat: 3,402 directories, one of which holds 42,424 modules, and 17 of which hold 104,534 between them. A prefix cannot split a directory, and a process given 42,424 modules to replay one after another runs for days.
- *One `leanchecker` process replaying many modules at once.* It starts one task per module and each task loads its module's whole import closure. Measured: 17.5 GB for a prefix module with twelve small modules beneath it, against 0.2 GB when the same process is limited to one worker thread. The likely reason is that a compiled file already mapped by one task cannot be mapped again at the same address by another, so each further task holds a private copy; that reading has not been confirmed in the runtime's source.

**What does: show each check only what its module imports.** The listing covers whatever is on the search path, and a check needs only the compiled files of its module and of what that module imports. So `scripts/09_kernel_replay.sh` now gives every `leanchecker` process a search path that holds, of this project, exactly that: a directory of hard links to those files, made for the check and removed after it (`rhv_tools.py closure-worker`). The libraries stay on the path as they are. The files are the same files, so the kernel is shown what it was shown before; only what else the tool can see has changed. Symbolic links do not work, because the tool does not recognise a linked file as a module; hard links do, and they need the directory to be on the same volume as the compiled files.

| Safeguard | What it does |
|---|---|
| A closure computed too small cannot make a module pass | The closure comes from the `import` lines of the source files. If a file the module needs were left out, `leanchecker` would stop with "object file ... does not exist", which is recorded as "not checked", never as a pass |
| The module itself must have been replayed | `leanchecker` is run with `-v` and one worker thread, and a module has passed only if the tool ends with status 0 and printed that it replayed that module |
| A module whose name is a prefix of others' is checked like any other | With only its imports visible, `leanchecker A` no longer finds every `A.B` in the tree, so the separate pass for the 114 such modules is not needed. If such a module imports modules beneath it, they are replayed with it and the list is kept |
| A rejection of another module is not charged to this one | 70 of the 114 prefix modules import modules beneath themselves, up to 74 of them, and for those the tool replays the imported ones in the same process. When one of them is rejected, the tool names the module it stopped at. If that is not the module asked for, the module asked for is recorded as not judged, reported as such, and not run again while the other stays failed; the rejected one has a check of its own, where the rejection is recorded. A crash of such a process cannot be pinned on one module, because the tool says nothing before it dies: it is kept as a crash of the module asked for, and the summary lists it as possibly belonging to a module beneath |
| The import graph is the source tree's | The graph is kept between runs with a fingerprint of the source files (names, sizes, modification times) and is read again whenever that fingerprint changes |
| The file checked is the file planned | A result is recorded under the hash the build tool keeps beside the compiled file, read when the run was planned. Just before a check the worker reads that hash again and confirms that the file it linked is the file at the module's path; if either has changed, nothing is run and the module is left for a later run |
| A module is shown whole | If a compiled module has further parts beside it (`.olean.server`, `.olean.private`, which a build with Lean's module system writes), they are linked too, so that the tool replays what it would replay in the library directory. This project has none, and the summary reports any as a fault |

Measured on the Mac, by hand, with 59,000 modules compiled and the build running: six modules with import closures of 1 to 7,753 modules took 10 to 18 seconds this way against 20 to 31 with the whole library on the search path, and all passed both ways. Then through the script itself, on the same build at 59,528 modules (`scripts/09_kernel_replay.sh --sample 24 --seed 31337 --jobs 2`): 24 of 24 random modules passed, in 17.5 seconds each on average and 95 for the longest, two at a time while the build was running. After the changes that followed the fourth review below, 12 more random modules, all passing. Reading the import lines of all 175,187 source files, 753,261 imports in all, took 47 seconds and is done once for a given source tree ([`../records/mac-build/closure-directory-checks.json`](../records/mac-build/closure-directory-checks.json)).

Projected for the cloud machine by the fit above: the listing shrinks from 185,639 files to the 10,452 library files plus the module's closure, 3,086 on average, which gives 5.6 seconds per check and about 8.5 hours for the tree with the stock tool. **This has not been run on the cloud machine.** On the Mac the saving is smaller in proportion than the fit suggests, because listing the library files alone takes several seconds there.

**A second program: `rhv-replay`.** Before the idea above was tried, a program was written that avoids the listing altogether. [`../scripts/verify/replay/RhvReplay.lean`](../scripts/verify/replay/RhvReplay.lean) is 85 lines: a comment, the 23 lines of `replayFromImports` copied from the toolchain's `LeanChecker.lean` without change, and a loop that calls that function on each module name it is given, one after another in one process, and prints the result. `scripts/09_kernel_replay.sh --method rhv-replay` runs it in batches of 25 modules. It is kept as a second way of running the same replay: a different executable, built here, that should agree with the stock tool on every module. It is not the tool criterion C3 names.

| Safeguard | What it does |
|---|---|
| The program is the reviewed file, and its copy of the function is the toolchain's | `rhv_tools.py replay-driver-check` runs before every run and the run does not start unless it passes. It requires the program's source file to have the SHA-256 written in `rhv_tools.py` (`52c1984827f2c461ce4c7db782076a1d47cce8875657722556ae62d26a7bc3ef` for the file as reviewed), so that the program cannot change without that line changing in the same commit; and the function in it to be identical, character for character, to the one in the installed toolchain's `LeanChecker.lean`. It also checks the file's shape: each definition exactly once, one opening comment with no comment inside it and none after it, the three expected lines before the function, and nothing in the loop that could redefine or replace a function. What no comparison of text can show is that the loop does what it appears to do: that is for a reader |
| Every result names its tool and its program | Each result line carries the tool and the SHA-256 of the binary that produced it. The summary says whether every pass by `rhv-replay` came from one recorded program |
| A process that dies does not take its batch with it | The program prints a line when it starts a module and another when it finishes one, and stops after the first failure, as `leanchecker` does. Every module it had finished is already recorded. If it dies after starting a module, that module is recorded as ended from outside (not yet checked) or as a crash. A new process takes the rest. If it dies before starting any module, nothing is charged to any module |

**Rules that hold for both tools.**

| Rule | What it means |
|---|---|
| Every result is kept | The results file is only ever added to, and the summary reads all of it. No result replaces another |
| A rejection is never overwritten | A module that a tool rejects, or crashes on, is run by that tool again as evidence: twice, or until the rejection comes back. If it comes back, the module has failed. If it does not, the module is still not counted as passed, in that results file, by anyone: the kernel is deterministic on a given file, so a rejection that does not recur is a fault of the machine or of these scripts, and it is reported, not waved through. Compiling the module again does not clear it either |
| "Could not open a file" is told apart from "the kernel said no" by how the error begins | A check that could not open or find a compiled file checked nothing and is tried again later. That case is recognised only from the first words of the error, which the tool's own file handling writes; the rest of an error can quote names that the author of a module chose, so it is never searched |
| An internal error of the Lean runtime is not passed over | Both tools run with `LEAN_ABORT_ON_PANIC=1`: a panic, which would otherwise print a message and carry on, ends the process and is recorded as a crash |
| A compiled file the build tool never finished is not counted | A compiled file with no hash beside it was left by a compiler that the build tool did not see finish. It is never planned, no result for it is current, and it blocks "complete" |
| A damaged line in the results file blocks "complete" | A line cut short by a full disk, or two lines run together, is credited to no tool, and nothing is complete while one is there. A damaged line may be what is left of a rejection, so the script never ends with status 0 while there is one. At the start of a run a last line that was cut short is closed off with a marker, so that the next result cannot run into it and the fragment cannot be read as a result |
| One run at a time, and a run that is stopped stops | The script holds a lock while it runs and refuses to start beside another run. Told to stop (Ctrl-C, or a time limit), it ends there, with what it has finished kept, and does not go on to a further pass |
| The tools run with the stack the toolchain gives them | The proof's build file compiles every module with a 400 MB thread stack. The threads that do the replay in these tools already have more than that (measured: a recursion that overflows a 400 MB stack runs to completion at the default), so no stack setting is made |

Tested on a seven-module project: `leanchecker` on every module by both of its ways, including a module whose name is a prefix of two others; `rhv-replay` on every module; a compiled file cut short (the tool crashes on it and on its importer, twice, and both are failures); an imported file removed (its importers are recorded as not checked); a rejection that does not recur (run twice more, then still not a pass, and the two tools reported as disagreeing); a rejection that recurs; a module compiled again after a rejection; a stand-in for `rhv-replay` that crashes on every second module, one that is killed, one that is interrupted, one that dies before it starts, one that stops between modules, one that answers about a different module, and one whose kernel error quotes "No such file or directory"; a compiled file with its hash removed; damaged lines in the results file, among them a last line cut short that would read as a pass, and one that would read as a rejection, if a newline were all that was added to it; `--c3` followed by `--method rhv-replay` (refused); a second replay program that checks nothing (the run is not complete, though the other tool has passed everything); a stand-in for `leanchecker` that rejects a module beneath the one asked for, the one asked for, or neither; a stamp that is no longer the file's; a source file changed after the import graph was read, and a damaged graph file; a list file whose path has a space, with and without a prefix module in it; a second run started while one is going, stale locks, and six starts at once against a stale lock (one runs); the script told to terminate in mid-run; a results file ending in zero bytes; a module not judged while one beneath it is rejected once, and then failed. And on a second small project, in which a module imports a module beneath itself: the stock tool replays both in the one process, the record says so, and criterion C3's conditions hold.

On the Mac, with about 34,000 modules compiled and the build running alongside, two checks at a time: `rhv-replay` replayed a random sample of 120 compiled modules and passed all of them, at a mean of 6.8 seconds each (longest 13). `leanchecker`, with the whole library on its search path, was then run on 30 of the same modules: the same verdict on all 30, for the same compiled files, at a mean of 28 seconds each (17 to 90). A further 20 random modules passed `rhv-replay` at 7.2 seconds each. The program's memory went up and down with the module in hand, from under 1 GB to about 5.6 GB, and did not grow over the life of a process. That is a comparison on 30 modules from the first fifth of the tree, not a verification result.

On the cloud machine, in the fifth rehearsal of the full-run driver ([`../records/cloud/full-rehearsals/`](../records/cloud/full-rehearsals/)): root built the program during setup in 3 seconds; it loads only the system's own shared libraries; it replayed all 1,794 modules the build tool had finished, and all passed; `leanchecker`, with the whole library on its search path, then replayed a random 150 of them, with the same verdict on each for the same compiled file. Again a test on the first hundredth of the tree, not a verification result. That rehearsal ran the driver as it then was, with `rhv-replay` as the main replay; the driver as it is now, with `leanchecker` and import-closure directories, has not been rehearsed.

**Reviewed, four times, by AI agents.** Five reviewers read the first version of `rhv-replay` and its scripts and five more re-checked their findings: 23 findings, none of them a way for a module to be counted as passed without a replay ([`../records/cloud/replay_method_review.json`](../records/cloud/replay_method_review.json)). Four more then looked at the changed code and at these documents, with four to re-check them: 18 of the 23 resolved, 4 in part, one left by decision, and 22 new findings, half of them about the documents ([`../records/cloud/replay_method_recheck.json`](../records/cloud/replay_method_recheck.json)); the one that mattered most was that the check of the program's source could be passed by a file whose visible contents all sat inside a nested comment, which the pinned hash answers.

The third review was of something that was then not done. On 2026-11-21 an amendment to the pre-registration was drafted that would have made `rhv-replay` the tool for every module, with `leanchecker` on a fixed list of 2,000. Four reviewers read the draft and the code for it ([`../records/cloud/c3_amendment_draft_review.json`](../records/cloud/c3_amendment_draft_review.json), which includes the draft as it was reviewed). They found that a rejection could be erased by a later passing run or by compiling the module again, and that nothing tied the results to one program; those are what the rules above now forbid. And one of them, asked to argue against the amendment, pointed out that the cost came from how `leanchecker` was being invoked and not from the tool: give it a search path with only what the module imports. That was tried the same day, it worked, and the amendment was not made.

The fourth review was of the code that resulted: `leanchecker` with import-closure directories, the keeping of results, and the cloud driver's replay phase. Four reviewers, each then checked by a sceptic who tried to refute the findings: 21 findings, all upheld, several of them one defect seen through two lenses ([`../records/cloud/closure_replay_review.json`](../records/cloud/closure_replay_review.json)). None was a way for a module to pass without a replay. One was a wrong verdict: given `--c3` and then `--method rhv-replay`, the script ran the second program and announced that criterion C3 held; that combination is now refused. The others were of three kinds: a record that named the wrong module (a rejection of a module beneath a prefix module, charged to the prefix module); a run that could never finish (an import graph older than the source tree); and behaviour around the edges (a list file with a space in its path, Ctrl-C not stopping the script under the shell macOS ships, two runs at once, a cut-short last line swallowing the result after it). The safeguards and rules above include the answers. In writing them one more fault was found by a test and not by a reviewer: closing a cut-short line with a bare newline could turn it into a complete line of the oldest format, credited to `leanchecker`; the marker that is added instead cannot be read as a result.

Those changes were then looked at again by three agents, one area each, with a sceptic for each ([`../records/cloud/closure_replay_recheck.json`](../records/cloud/closure_replay_recheck.json)): 19 of the earlier findings resolved and 4 in part, and six further points upheld. Five were answered in the code: the lock could be taken by two starts at once, and is now made in one step; a results file ending in zero bytes was not seen as cut short; a module not judged was reported as if its checker had been killed, and planned again for ever; a crash in a process holding modules beneath the one asked for was charged to the one asked for without comment; and the cost script did not read the second replay's phase. One was left by decision: a compiled file newly written beside its old hash, in the instant a build replaces it, would be checked under the old hash. That needs a build running under the replay, which this script's header excludes for results that count and the cloud driver's seal rules out.

**Where this leaves criterion C3.** As registered: every compiled module re-checked by `leanchecker` from the pinned toolchain, and every one passing. `scripts/09_kernel_replay.sh --c3` does that and reports four conditions, all of which this project requires before it will say the criterion holds: every source module is compiled and nothing else is; `leanchecker` has passed every compiled module, for the file now on disk; no tool has a rejection or a crash on record for any module; and the results file has no damaged line. The third is stricter than the criterion's words, which speak only of `leanchecker`: a rejection by `rhv-replay` would also stand in the way until it was explained. The pre-registration has not been amended.
