# Local build records

Recorded on 2026-11-20 while the build was still running. Times in these files are the local time of the build machine.

## The machine

A 10-core Apple silicon Mac with 4 performance cores and 6 efficiency cores, 24 GB of memory, and the working directory on an external SSD. The toolchain is the one the source pins, Lean `v4.33.1`, with Mathlib's prebuilt cache for the pinned revision.

## State when these records were taken

At 15:44 local time on 2026-11-20 there were 10,815 compiled project modules (`.olean` files) on disk out of 175,187, and the build logs contained no failed-job line. The build was still running. This is a snapshot: the count goes out of date at once, and the modules compiled first are the ones with the fewest imports beneath them.

A module that compiles has had each of its declarations accepted by the Lean kernel during compilation. That is true of the modules compiled so far and of nothing else. The headline theorem is in the last module to be compiled.

## Files

### `build-status.txt`

One `START` line each time `lake build` was launched and one `END` line each time it stopped.

```
START <local time> epoch=<Unix time> threads=<cap> log=<WORKDIR>/logs/build-<timestamp>.log
END   <local time> epoch=<Unix time> rc=<exit status>
```

- `threads` is the value of `LEAN_NUM_THREADS` given to `lake build`, which limits how many modules are compiled at once. `default` means it was not set.
- `rc=143` means the process was ended by a termination signal (128 + 15). That is how the build was stopped on purpose, to restart it with a different cap. Every `END` line in the file has `rc=143`. None of them records a compile error.
- Lake keeps the modules already compiled, so each `START` continues the same build.
- The last line is a `START` with no `END`: that run, with a cap of 8, was still going when the file was copied.
- `<WORKDIR>` stands for the working directory (`RH_WORKDIR`). The log files named on these lines are not included in the records.

### `tuning.tsv` and `tuning2.tsv`

Two passes that compared parallelism caps. For each cap the build was stopped, restarted with that cap, left to warm up for 100 seconds, and then measured over one window.

| Column | Meaning |
|---|---|
| `cap` | `LEAN_NUM_THREADS` for that window |
| `modules` | Modules that finished compiling during the window (new `.olean` files) |
| `seconds` | Length of the window |
| `modules_per_hour` | `modules * 3600 / seconds` |
| `cpu_user`, `cpu_sys`, `cpu_idle` | Whole-machine CPU percentages from a single sample of `top` at the end of the window |
| `failed_total` | Failed-job lines in all build logs up to that moment. It is 0 in every row |

`tuning.tsv` is the first pass (caps 5, 3, 7, 4, 6 in that order, windows of about 380 seconds, 11:26 to 12:06). `tuning2.tsv` is the second (caps 8, 5, 10, 6, 7, 9, windows of about 300 seconds, 13:37 to 14:18). The rows are in the order the windows were run.

What the tables support, and what they do not:

- In the second pass a cap of 8 gave the highest rate, 3,230 modules per hour. At a cap of 10 nearly half of all CPU time was system time and the rate was lower.
- Each window compiled different modules, and one window of five or six minutes per setting is a small sample. A cap of 5 measured 2,331 modules per hour in the first pass and 2,057 in the second. A cap of 7 measured 914 in the first pass, with 39% of the CPU idle, and 2,858 in the second. Differences of that size between settings are therefore not significant.
- These rates are for early modules, which import little. Later modules import far more and take longer, so the rates cannot be extrapolated to the whole tree.

### `checker-sample-times.txt`

Results of running `leanchecker`, the kernel replay tool shipped with the toolchain, on 24 modules taken from those that had been compiled by then. Each module was replayed in its own process between 14:22 and 14:25, while the build was running on the same machine.

```
<module name> rc=<exit status> real <seconds> user <seconds> sys <seconds>
```

- All 24 lines have `rc=0`: the tool accepted each module and printed nothing else.
- Run this way (without `--fresh`), `leanchecker` loads the compiled files of everything the module imports and replays through the kernel only the declarations of the named module. Each run therefore re-checks one module and trusts its imports.
- Wall time was 13.8 to 28.1 seconds per module. User time was about 2 seconds in 23 of the 24 runs and system time 9 to 13 seconds. A plausible reading is that loading the imported modules dominates and kernel checking of one small module is quick; that split was not measured separately. (Later the same day that reading was found to be wrong: most of the system time is `leanchecker` listing every compiled file on the search path, once per process. See [`../../docs/performance-notes.md`](../../docs/performance-notes.md), section 10.)

This is a timing sample taken to plan a full replay. It covers 24 of 175,187 modules, all from the first few percent to be compiled, and it is not a verification result for the proof.

### `replay-method-comparison.tsv`

The kernel replay's results file from the Mac build as it stood at 05:20 UTC on 2026-11-21, with about 34,000 modules compiled and the build running: 170 result lines, written by [`../../scripts/09_kernel_replay.sh`](../../scripts/09_kernel_replay.sh).

```
module <TAB> exit status <TAB> seconds <TAB> stamp of the compiled file <TAB> time (epoch) <TAB> method
```

- 140 lines by `rhv-replay`, all with exit status 0: a random sample of 120 compiled modules (`--method rhv-replay --sample 120 --seed 77`), then, after the changes that followed the first review of that program, 20 more (`--method rhv-replay --sample 20 --seed 4242`).
- 30 lines by `leanchecker`, all with exit status 0: the first 30 modules of the 120, replayed again by the stock tool (`--list` with those names). The stamp on each of those 30 lines is the same as on the `rhv-replay` line for the same module: both tools were given the same compiled file.
- Seconds per module, two checks at a time: `rhv-replay` 6.8 on average over the 120 and 7.2 over the 20; `leanchecker` 28 on average, 17 to 90.

A seeded sample is drawn from the modules compiled at the time, so the same command on a build that has moved on picks different modules; the names here are the record of which were checked. This is a comparison of two ways of running one check on 30 modules, and a timing sample. It covers modules from the first fifth of the tree and is not a verification result for the proof. Background: [`../../docs/performance-notes.md`](../../docs/performance-notes.md), section 10.

### `mapped-files-sample.txt`

A count of the files one running compiler process had memory-mapped, by file type and by where the files came from, read once with `vmmap` on 2026-11-20 at about 19:40 local time. It is the basis for the figures of five mapped files per library module and about one per project module in [`../../docs/performance-notes.md`](../../docs/performance-notes.md), section 7. It is one process on macOS; the Linux count is estimated separately in [`../cloud/pilot/pilot_estimate.json`](../cloud/pilot/pilot_estimate.json) under `open_files`.

### `progress-20261120-2001.txt`

A dated snapshot of the build: the output of `scripts/06_progress.sh` followed by `scripts/prune_setup_files.sh` in report mode, taken at 20:01 local time on 2026-11-20 (02:01 UTC on 2026-11-21). It records 23,981 compiled modules of 175,187 and no failed job, and 23,991 setup files occupying 156.1 GB. Nothing was removed. It supersedes the count under "State when these records were taken" above as the latest recorded figure.
