# Rehearsals of the full-run driver

Short runs of [`../../../cloud/gcp/full_guest.sh`](../../../cloud/gcp/full_guest.sh) in its rehearsal mode: a build boxed at seven minutes, then every later phase on what was built. A rehearsal tests the driver. It verifies nothing about the proof.

| Run | Outcome | Machine time | Recorded cost |
|---|---|---|---|
| `full-rehearsal-20261120-211809` | Stopped itself during setup, 109 seconds in | 353 seconds | 0.20 USD |
| `full-rehearsal-20261120-212636` | Ran every phase; both checks failed for a fault of the driver, not of the proof | 1,142 seconds | 0.63 USD |

## `full-rehearsal-20261120-211809`

The first rehearsal ended at the setup step `smoke_build`. That step compiles two files to confirm that Mathlib's prebuilt cache is accepted, and then, as a new safety check, compares a SHA-256 of every file under the packages' compiled-library directories with the record taken just before. The comparison found five files changed, all of them `.hash` files of Mathlib (`pilot.log` lists them).

Those are the build tool's own bookkeeping: beside each compiled file it keeps a small file holding that file's hash, and it rewrites one when it cannot read it. The same five were found rewritten on the local Mac build, each a 16-digit hash made of decimal digits only and starting with zero. Nothing that the checks read had changed, and no Mathlib module was recompiled.

The check was too strict, not wrong to exist. The driver now leaves the build tool's `.hash` and `.trace` files out of that comparison and compares every other file as before. Nothing else in the run was reached.

Files: `setup.tsv` (the setup steps and their durations), `pilot.log` (the guest's log, with the five differences), `env.txt` (the machine, the toolchain and the manifests' hashes), `facts.json` and `status.json` (as the guest wrote them on stopping), `phases.tsv`.

Each file was written by `scripts/dev/scrub.py clean`; one home-directory path in `env.txt` was replaced by a placeholder.

## `full-rehearsal-20261120-212636`

The second rehearsal ran every phase in 15 minutes and ended with the state `DONE`, which means only that every phase ran. Its facts show that both checks failed, and why.

What worked, on real modules for the first time:

| Step | Result | Where |
|---|---|---|
| Setup, including the records of the source tree, the toolchain and Mathlib | 84 seconds | `setup.tsv` |
| Restart test, plain | 0 finished modules recompiled; 303 new ones built | `restart_tests.txt`, `facts.json` |
| Restart test after deleting the setup files of 641 finished modules | 0 finished modules recompiled; 323 new ones built | the same |
| Periodic pruning | Ran twice during the build; 32 setup files left at the end, against 1,715 modules compiled | `pilot.log`, `disk.txt` |
| Build | 1,715 modules in the seven-minute box, no failed job | `phases.tsv` |
| Seal | Source tree, toolchain and Mathlib unchanged; toolchain copy identical; no unexpected file beside the compiled modules | `facts.json`, `seal` |
| End check | Compiled files, toolchain and Mathlib unchanged; no process of the build user seen | `facts.json`, `end` |
| Archive of compiled files | Made and uploaded | `facts.json` |

What failed:

| Check | Result | Cause |
|---|---|---|
| Axiom check (probe mode), plain and deep | Exit status 1 | `failed to open file '.../mathlib/.lake/build/lib/lean/Mathlib.olean': Permission denied` (`c2_plain.out`) |
| Kernel replay | 5 of 1,715 passed, 1,710 recorded as failed | The same error from every checker process. The five that passed import nothing from Mathlib |

Mathlib's prebuilt cache is unpacked readable by its owner only. During the build the owner is the build user, so everything works; the seal then gives the files to root without adding read permission for anyone else, and the two users that run the checks could no longer read them. No module was rejected by the kernel: no checker got as far as checking.

This is the kind of fault a rehearsal exists to find, and it exposed a second one: the replay recorded "could not open a file" as a failed module. Three changes followed.

- The seal adds read permission for all users and refuses to continue if any file or directory of the project lacks it.
- Before the checks start, each checker user must do a real piece of work in the sealed environment: one elaborates a file that imports a compiled module, the other replays one. If either cannot, the run stops as a failure of the run.
- `scripts/verify/kernel_check_one.sh` records a checker that could not open or find a compiled file with status 96, "could not do its work", which the summary counts as not yet checked.

Files: as for the first run, plus `restart_tests.txt`, `progress.tsv`, `disk.txt`, `c2_plain.out` (the axiom check's output), `c3_summary.txt` (the replay's summary), and `modules.tsv.gz` and `system.tsv.gz` (the sampler's measurements, in the pilot's format). `facts.json` is large because this version listed every module recorded as failed; later versions cut such lists to 50 names.
