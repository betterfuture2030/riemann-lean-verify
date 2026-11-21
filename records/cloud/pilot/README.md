# Calibration pilot records

Measurements from two runs of [`../../../cloud/gcp/pilot_guest.sh`](../../../cloud/gcp/pilot_guest.sh) on Google Cloud on 2026-11-20, and the estimate for a full run that was derived from them.

Neither run is a verification. The pilot compiled 29,633 of the 175,187 modules and kernel-checked 2,233 of those. Zero failures in a sample is progress, not a verdict.

## The runs

| Run | Machine | Length | Modules compiled | Failures | Modules kernel-checked | Failures | Recorded cost |
|---|---|---|---|---|---|---|---|
| `rehearsal-20261120-160322` | `n4d-highmem-32` | 17 minutes | 1,439 | 0 | 565 | 0 | 0.57 USD |
| `pilot-20261120-162141` | `n4d-highmem-32`, `us-east1-b` | 2 hours 55 minutes | 29,633 | 0 | 2,233 | 0 | 5.82 USD |

The machine reported an AMD EPYC 9B45, 16 cores and 32 threads, 251 GiB of memory, Ubuntu 24.04 and Lean 4.33.1 (`env.txt`). The pilot's data disk was a 440 GB Hyperdisk Balanced volume provisioned at 6,000 IOPS and 300 MB/s; the rehearsal's was 100 GB. Costs are machine-time multiplied by a rate of 2.00 USD per hour, which is slightly above the list price; the bill is authoritative.

## Files in each run directory

| File | Contents |
|---|---|
| `phases.tsv` | Epoch seconds and phase label. A line ending `:end` also carries the number of modules the build tool reported built in that window and the number of failures |
| `modules.tsv.gz` | One row per compiler (`lean`) or checker (`leanchecker`) process: phase, module, start and end time, user and system CPU seconds, peak resident memory, peak private memory, peak thread count. A process still running when a time-boxed window ended was killed, and appears with an end time within about 3 seconds of the window's end; drop those rows when measuring cost per module. A module name of `?` means the sampler did not catch the process's command line |
| `system.tsv.gz` | Machine-wide counters every 5 seconds: cumulative CPU time by state, memory, bytes read and written, open files, and the build tool's own CPU. The `lake_*` columns start again from zero each time the build tool is restarted |
| `import_only.tsv` | Time to compile a file that only imports Mathlib, alone and at 8, 16, 24 and 32 at once |
| `import_probe.tsv` | For modules chosen to span import-closure sizes: time for a single process to import the module, three repeats, and time for a single process to kernel-check it |
| `check_results.txt.gz` | Module name and exit status of the kernel checker, one line per sampled module. Every status is 0 |
| `disk.txt` | Bytes of compiled output, bytes of setup files, and the state of the data disk at the end |
| `lake_log_summary.tsv` | For each build-tool log: line count, lines starting with the success mark, with the warning mark, and with the failure mark, the last status line, and the exit code. Exit code 124 means the window's time limit ended the build, as intended. The logs themselves are not included because their warnings quote the proof source |
| `env.txt`, `setup.tsv`, `pilot.log`, `status.json` | The machine as the guest saw it, the set-up steps and their durations, the phase log, and the final status |

The phases, in order: `import_only`; `cold` (the whole tree from nothing, 32 jobs, 10 minutes); `deepA` and `deepB` (two build targets with large import closures, 32 jobs, run to completion); `sweep1` to `sweep6` (the whole tree at 16, 32, 16, 32, 24 and 8 jobs, 6 minutes each); `check` (the kernel checker on a random sample of compiled modules, 32 at a time, 10 minutes). The targets are in [`../../source/pilot_targets.json`](../../source/pilot_targets.json).

## The estimate

| File | Contents |
|---|---|
| `pilot_estimate.json` | Output of [`../../../analysis/pilot_estimate.py`](../../../analysis/pilot_estimate.py) on the pilot run |
| `pilot_estimate_review.json` | Three independent reviews of the first version of that estimate, written by AI agents from the recorded data. Criticism, not measurement |
| `ledger.tsv` | The spend ledger kept by `pilot_local.sh`: one row per machine created, with its lifetime and estimated cost. The first row is a launch that found no capacity and created nothing |

To reproduce `pilot_estimate.json` from the repository root, with Python 3 and no other dependency (about a minute):

```bash
python3 analysis/pilot_estimate.py records/cloud/pilot/pilot-20261120-162141 records/source/import_graph.json.gz
```

Add `--config NAME:USD_PER_HOUR:DISK_GB` once for each machine and disk you want priced. The recorded file used five; the command is in [`../../../docs/cloud-notes.md`](../../../docs/cloud-notes.md), section 8, with the method, the results and what the reviews changed.

## Sanitising

Every file here was written by `scripts/dev/scrub.py clean`. The run files needed no replacement and are byte-for-byte the guest's output, compressed where the name ends in `.gz`. In `pilot_estimate_review.json` one scratch directory path and one name of a local disk were replaced by placeholders. The cloud project, bucket and account do not appear.
