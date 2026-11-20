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
- Wall time was 13.8 to 28.1 seconds per module. User time was about 2 seconds in 23 of the 24 runs and system time 9 to 13 seconds. A plausible reading is that loading the imported modules dominates and kernel checking of one small module is quick; that split was not measured separately.

This is a timing sample taken to plan a full replay. It covers 24 of 175,187 modules, all from the first few percent to be compiled, and it is not a verification result for the proof.
