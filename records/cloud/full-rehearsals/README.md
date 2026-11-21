# Rehearsals of the full-run driver

Short runs of [`../../../cloud/gcp/full_guest.sh`](../../../cloud/gcp/full_guest.sh) in its rehearsal mode: a build boxed at seven minutes, then every later phase on what was built. A rehearsal tests the driver. It verifies nothing about the proof.

**The driver has changed since the last rehearsal here.** On 2026-11-21 its kernel-replay phase was rewritten: `leanchecker` now checks every module, each process with only its module's import closure on the search path, and `rhv-replay` is an optional second replay ([`../../../docs/performance-notes.md`](../../../docs/performance-notes.md), section 10). The five runs below are of the driver as it was at the time; the settings and `facts.json` fields they mention (`GCP_REPLAY_METHOD`, `method_for_the_whole_tree`, `replay_program`, the stock sample) are those of that driver. The present driver has not been rehearsed.

| Run | Outcome | Machine time | Recorded cost |
|---|---|---|---|
| `full-rehearsal-20261120-211809` | Stopped itself during setup, 109 seconds in | 353 seconds | 0.20 USD |
| `full-rehearsal-20261120-212636` | Ran every phase; both checks failed for a fault of the driver, not of the proof | 1,142 seconds | 0.63 USD |
| `full-rehearsal-20261120-214914` | Ran every phase; every step it reached did what it should | 1,216 seconds | 0.68 USD |
| `full-rehearsal-20261120-233826` | First rehearsal of the driver with the second replay method. Stopped itself at the seal, for a fault that a full run could have met too | 872 seconds | 0.48 USD |
| `full-rehearsal-20261120-235539` | Ran every phase with the second replay method; every step it reached did what it should | 1,175 seconds | 0.65 USD |

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

## `full-rehearsal-20261120-214914`

The third rehearsal, with those changes, ran every phase in under 17 minutes. Each step did what it was written to do.

| Step | Result | Where |
|---|---|---|
| Setup | 122 seconds | `setup.tsv` |
| Restart test, plain | 0 finished modules recompiled; 316 new ones built | `restart_tests.txt` |
| Restart test after deleting the setup files of 644 finished modules | 0 finished modules recompiled; 305 new ones built | the same |
| Build, boxed at seven minutes | 1,788 modules finished by the build tool, no failed job, and 4 more whose compiler had written its file when the time box stopped the build tool: 1,792 compiled files; 40 setup files left at the end | `phases.tsv`, `pilot.log`, `disk.txt` |
| Seal | Source tree, toolchain and Mathlib unchanged since before the first compile; toolchain copy identical; no unexpected file beside the compiled modules; both checker users able to work | `facts.json`, `seal` |
| Axiom check in probe mode, plain | Pass: `Formalism.VW.rh_of_right` depends on `propext`, `Classical.choice`, `Quot.sound`; its conclusion is the constant `RiemannHypothesis` | `c2_plain.json` |
| The same with the deep walk | Pass: 54,444 constants visited, the same three axioms, nothing missing; 1 project module and 1,759 library modules touched | `c2_deep.json`, `c2_deep.modules.tsv` |
| Kernel replay | 1,792 of 1,792 compiled files passed. By the time each result was written: 452 in the trial at 16 at a time (mean 3.1 seconds each), 595 in the trial at 32 (4.7 seconds), 745 in the main pass at 32 (4.4 seconds) | `c3_summary.txt`, `c3_results.tsv.gz` |
| End check | Compiled files, toolchain and Mathlib unchanged since the seal; no process of the build user seen | `facts.json`, `end` |
| Archive of compiled files | Made and uploaded | `facts.json` |

The deep walk visited 54,444 constants on this Linux machine. The same probe on a Mac visited the same number.

The replay's exit status of 3 and `complete: false` are correct for a rehearsal: 173,395 source modules were never compiled.

Two things in this run were changed afterwards. The four files the build tool never finished were replayed and counted with the rest (their lines in `c3_results.tsv.gz` carry `nohash` where the others carry a hash); the summary now treats a compiled file with no hash beside it as unfinished, never counts a result for it, and reports it. And the replay's rate here, about seven modules a second, says little about the whole tree: with the stock tool the cost of a check grows with the number of compiled modules ([`../../../docs/performance-notes.md`](../../../docs/performance-notes.md), section 10), and this run had 1,792 of them.

**What a rehearsal does not show.** See the list at the end of this page, which covers all five.

Files: as for the second run, plus `c2_plain.json` and `c2_deep.json` (the axiom check's summaries), `c2_deep.modules.tsv` (which modules the deep walk touched), `c3_summary.json` and `c3_results.tsv.gz` (one line per replayed module: exit status, seconds, the stamp of the compiled file, time).

## `full-rehearsal-20261120-233826`

The fourth rehearsal was the first of the driver as changed to offer a second method for the kernel replay ([`../../../docs/performance-notes.md`](../../../docs/performance-notes.md), section 10), launched with `GCP_REPLAY_METHOD=rhv-replay`. It ended at the seal, eleven minutes in, with the state `FAIL`.

What worked that had not run before:

| Step | Result | Where |
|---|---|---|
| Root builds the replay program during setup, before any file of the proof is compiled | 3 seconds, from root's own copy of the toolchain, after that copy was found identical to the record taken just before | `setup.tsv` (`replay_program`), `env.txt` |
| The program's source is the reviewed file and its replay function is the toolchain's | Both checks passed on the Linux toolchain; the hashes are in the record | `env.txt`, `facts.json` (`replay_program.source_check`) |
| The program loads nothing but system libraries | `libc`, `libm`, `libpthread`, `libdl`, `librt` and the loader | `env.txt` |
| The program replays the two modules of the smoke build | Both passed, 1.8 seconds each, one process | `env.txt` |

The restart tests again recompiled nothing (308 and 306 new modules built), and the seal found the source tree, the toolchain and Mathlib unchanged.

What stopped it: the seal refuses any file beside the compiled modules that the build tool does not write for this project, and it found one, `EtaleIntegralityFacts.olean.tmp.66116` (`unexpected_lib_files.txt`). That is a compiler's own half-written output. Lean writes a compiled file under a temporary name ending in `.tmp.` and its process number, and renames it when it is complete; the rehearsal's time box had stopped the build tool while that compiler was writing. Nothing reads such a file, and the build tool compiles the module again under its proper name.

The refusal was the check working as written, and too strict. It matters beyond rehearsals: a full run stops and restarts the build tool twice in its restart tests, killing whatever compilers are running, so the same leftover could have ended a full run at the seal, after the whole build. The earlier rehearsals killed compilers at the same points and happened not to catch one in mid-write.

The seal now lists, removes and counts exactly these files, regular files whose name ends in `.olean.tmp.` or `.ilean.tmp.` and digits, before it applies the rule to everything else, and `facts.json` records how many there were. A rehearsal plants one stand-in, so that the step runs whether or not a compiler happens to be cut off in mid-write.

Files: `setup.tsv`, `pilot.log`, `env.txt`, `facts.json`, `status.json`, `phases.tsv`, `restart_tests.txt`, `progress.tsv`, `disk.txt`, `unexpected_lib_files.txt`. Each was written by `scripts/dev/scrub.py clean`; one home-directory path in `env.txt` was replaced by a placeholder.

## `full-rehearsal-20261120-235539`

The fifth rehearsal repeated the fourth with the seal changed as described above. It ran every phase in under 16 minutes and each step did what it was written to do.

| Step | Result | Where |
|---|---|---|
| Setup, with the replay program built by root and tested on two modules | 95 seconds | `setup.tsv`, `env.txt` |
| Restart test, plain | 0 finished modules recompiled; 304 new ones built | `restart_tests.txt` |
| Restart test after deleting setup files | 0 finished modules recompiled; 313 new ones built | the same |
| Build, boxed at seven minutes | 1,794 modules finished by the build tool, no failed job, and 2 more compiled files that it never finished | `phases.tsv`, `pilot.log`, `facts.json` |
| Seal | Source tree, toolchain and Mathlib unchanged since before the first compile; the stand-in for a killed compiler's half-written file removed and counted; no other unexpected file; the replay program unchanged since it was built; both checker users able to work | `facts.json`, `seal`; `compiler_leftovers.txt` |
| Axiom check in probe mode, plain | Pass, the same result as in the third rehearsal | `c2_plain.json` |
| Trials of the replay, by `rhv-replay` | At 16 at a time, 8.1 modules a second; at 32 at a time, 10.4 a second, which is 3.1 seconds of one job's time per module | `c3_results.tsv.gz`, `phases.tsv` |
| The decision the trials feed | 183 modules to go, about 19 seconds needed, 2,459 seconds left: the replay fits, so the deep walk ran before the main pass | `pilot.log`, `facts.json` |
| The axiom check with the deep walk | Pass: 54,444 constants visited, the same three axioms | `c2_deep.json` |
| Kernel replay by `rhv-replay` | 1,794 of 1,794 finished modules passed. The 2 compiled files the build tool never finished were not replayed and are listed as such | `c3_summary.txt`, `c3_results.tsv.gz` |
| The stock tool on a random sample | 150 of 150 passed, each for the same compiled file as the `rhv-replay` result for that module; 4.1 seconds per check | the same |
| The stock tool's prefix pass | Ran; none of the 114 prefix modules was among those built | `pilot.log` |
| End check | Compiled files, toolchain and Mathlib unchanged since the seal; no process of the build user seen | `facts.json`, `end` |
| Archive of compiled files | Made and uploaded | `facts.json` |

`facts.json` shows what a reader of a full run would look for: `method_for_the_whole_tree` is `rhv-replay`; under `replay_program`, `unchanged_since_it_was_built` and `every_recorded_run_used_this_program` are true and both of the stock tool's exit statuses are 0; in the summary, `passed_by_rhv_replay` is 1,794, `passed_by_leanchecker` and `passed_by_both` are 150, and `failed` and `methods_disagree` are 0. `complete` is false and the replay's exit status is 3, as they must be for a rehearsal: 173,391 source modules were never compiled, and two compiled files were never finished.

Files: as for the third run, plus `compiler_leftovers.txt`. The result lines in `c3_results.tsv.gz` now end with the method that produced them.

## What the rehearsals do not show

Each built about one module in a hundred, all from the bottom of the import graph, on settings shortened to fit a quarter of an hour: a seven-minute build, trials of 90 seconds, a stock sample of 150 modules. A full run uses the same script with longer limits. Not exercised by any rehearsal:

- a build that fails, and the second build pass that follows it;
- the check that every source module is compiled, which a time-boxed build cannot pass;
- the axiom check on the final theorem, which must load all 175,187 modules;
- the stock tool's prefix pass on real prefix modules: none of the 114 was among those built (it has been run on a seven-module project and, by hand, on two real ones);
- the kernel replay as the driver now runs it: `leanchecker` on every module with import-closure search paths, the hard links those need across two users, and the optional second replay after it. The third rehearsal used the stock tool for everything it had built, with the whole library on the search path; the fifth used it for a sample only;
- the retry passes of the replay, and a replay that the trials find cannot cover the tree, which is then cut to an hour;
- a real half-written file left by a killed compiler at the seal: the fourth rehearsal met one and stopped; the fifth removed a stand-in;
- a run that reaches its deadline, and the watchdog;
- an archive of compiled files larger than one part.

Those paths have been reviewed and, where possible, tested on a small project, but not run on this machine. A rehearsal tests the driver. None of this is evidence about the proof.
