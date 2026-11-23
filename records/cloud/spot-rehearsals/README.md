# Rehearsals of the Spot run that resumes

Short runs of [`../../../cloud/gcp/full_guest.sh`](../../../cloud/gcp/full_guest.sh) in the mode `full-spot-rehearsal`: a build boxed at seven minutes (the mode's setting, counted across the attempts that build) and every later phase of the full run, made as a chain of Spot machines, with `watch` ending an attempt on purpose at chosen points so that the next machine has to carry on from what the last one saved ([`../../../docs/cloud-notes.md`](../../../docs/cloud-notes.md), section 10). A rehearsal tests the driver. It verifies nothing about the proof.

| Run | Outcome | Machine time | Recorded cost |
|---|---|---|---|
| `full-spot-rehearsal-20261122-092917` | Four attempts; each of the three forced cuts was seen to take effect; every phase ran, and every step it reached did what it should | 2,275 seconds in all | 0.76 USD at the Spot ledger rate of 1.20 USD an hour |

## `full-spot-rehearsal-20261122-092917`

The first run of this code on rented machines, on 2026-11-22, from commit `e8553dd`, all four attempts in `us-central1-a`, which `watch` treated as the bucket's own region (it sized each attempt with a transfer charge of 0.00). The cuts were the default three: Google's simulated reclaim during the build, a deletion at the seal, and a hard reset with no notice during the replay.

| Attempt | Billed | What it did | How it ended |
|---|---|---|---|
| 1 | 408 s | Setup in 135 seconds; built 393 modules and saved them as one part of 49 MB | `watch` asked Google for a simulated reclaim once the part was in the bucket. The guest's watcher logged Google's notice 20 seconds later and the guest reported `RECLAIMED`; the machine was still listed as stopping 90 seconds after the request, and the ledger closes the attempt 111 seconds after it |
| 2 | 623 s | Setup in 92 seconds; restored the 393 modules in 1 second (before the seal the script restores as the build user); built on to 1,636 modules without compiling any restored module again; four more parts | Deleted by `watch` at the seal. Its entry in the state reads "no report: cut without notice" |
| 3 | 396 s | Restored all 1,636 modules from the five parts in 7 seconds; sealed; the parts were shown to reproduce the sealed files exactly (8,180 files, none missing, different or extra); the plain axiom check; the first replay trial, with 248 result lines saved after a confirming hash | Hard reset by `watch`, with no notice |
| 4 | 848 s | The seal had been recorded by attempt 3, so there was no build: the log says the build user was locked before the compiled files were restored (after the seal the script restores as root), and the restore took 5 seconds; the restored files hashed to the first seal's fingerprint; the 248 saved results were restored; both replay trials, the deep axiom check, the main replay, the second replay, the end check | `DONE` |

What the facts record (`facts.json`; the `spot` block has one entry per attempt):

| Point | Value |
|---|---|
| Source tree, toolchain and Mathlib on attempts 2, 3 and 4 | Identical to attempt 1's (`baselines_same` true) |
| Restored modules compiled again | 0 on attempts 2 and 3 |
| Parts against the seal | `parts_cover_seal` true, with no repair part needed |
| Confirming hashes | 10 on the last attempt, each "as sealed": 2 to 4 seconds on a quiet machine, 16 to 18 seconds with four hashing processes while a replay was running. One is in attempt 3's log, which ends 63 seconds before the reset; the 248 results that attempt saved imply another after it |
| Files the build tool wrote again with the same bytes | 0 |
| Kernel replay | 1,636 modules, every one passed by `leanchecker` with only its import closure on the search path; no rejection or crash by either tool; no damaged line |
| Axiom check, in `--probe` mode | Plain and deep both `PASS` |
| Restart tests (attempt 2) | 0 finished modules compiled again in either; 313 new ones built in each |
| End check | Compiled files, toolchain and Mathlib unchanged since the seal; no process of the build user seen after the seal on any of the three attempts that reached it |

As in every rehearsal, `conditions_all_hold` is false, because a seven-minute build compiles about one module in a hundred, and the second replay's exit status is 3 for the same reason (the sixth on-demand rehearsal recorded the same two values: `../full-rehearsals/full-rehearsal-20261121-113516/facts.json`).

Sizes and times, for what they say about a full run. The five parts hold 1,158 MB of compiled files in 353 MB, 0.22 MB a module after compression; at that ratio the whole tree would come to about 38 GB of parts, if deeper modules compress alike, which is not known. Cutting and listing a part took 1 to 2 seconds and uploading it about 1. A restore of everything took 5 to 7 seconds. None of these has been seen at a hundred times the size.

Two things in the files that look odd and are not faults. Attempt 2's status at the seal says 1,639 modules compiled, where its own log says the build tool finished 1,636 and every later file says 1,636. The first is a count of compiled files and the second of modules the build tool had recorded as finished, so the likely reason is three compiles that the time box cut off after their compiled file was written; a part never holds a module the build tool has not finished, and the later machines restored 1,636. No file states that reason. And attempt 4's log has one line from `gzip`, "file size changed while zipping", from the ten-minute upload of that machine's working copy of the replay's results while the replay was writing to it; the copies that count are taken whole, trimmed to complete lines and saved only after a confirming hash, and the summary found no damaged line.

The time Google's notice left: `watch` sent the simulated reclaim at 15:34:20 UTC, the guest logged the notice at 15:34:40 and had reported `RECLAIMED` by 15:34:45. Its last part had gone up at 15:34:13, before the request, so the only upload that had to fit after the notice was the report itself.

What this rehearsal did not reach, besides what no rehearsal reaches ([`../full-rehearsals/README.md`](../full-rehearsals/README.md), at its end): a reclaim that Google itself decides on; a reclaim during the main replay, the deep axiom check or the end check; an attempt outside the bucket's region; an attempt that ends at its own deadline; a pause on the cap; a repair part; and any failure of an upload or a download.

Files. At the top: `facts.json` and `status.json` as the last attempt wrote them, `cuts.txt` (what each configured cut did), `watch.log` (what `watch` printed on the owner's machine, from the first attempt to the ledger), and `ckpt/` (the run's final `state.json` and `manifest.tsv`). Under each `attempt-N/`: that machine's `env.txt`, `setup.tsv`, `phases.tsv`, `pilot.log`, `spot.log` (parts, restores, confirming hashes, saved results) and what else it produced: `progress.tsv` and `restart_tests.txt` from the build, the axiom check's summaries under `c2/`, and from the last attempt the replay's `c3/results.tsv.gz` and `c3/summary.*`, `modules.tsv.gz`, `system.tsv.gz` and `disk.txt`, and from the last two `compiler_leftovers.txt`. The build logs and the three hash manifests (about 3.6 MB on each of the last two attempts) were not copied. Each file was written by `scripts/dev/scrub.py clean`; a home-directory path in each `env.txt` and the project, bucket and work-directory names in `watch.log` were replaced by placeholders.
