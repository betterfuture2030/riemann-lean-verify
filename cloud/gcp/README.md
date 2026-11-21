# Google Cloud: calibration pilot and full run

Two things live here, driven by one controller, `pilot_local.sh`.

- **The calibration pilot** (`pilot_guest.sh`). One rented virtual machine compiles a time-boxed sample of the proof, measures what each module costs, uploads its measurements to a private bucket, and is deleted. The point is to estimate the cost of a full run before committing to one. It was run on 2026-11-20; its results are in [`records/cloud/pilot/`](../../records/cloud/pilot/).
- **The full run** (`full_guest.sh`). One virtual machine builds the whole tree and runs the pre-registered checks. It is described at the end of this page. **It has been rehearsed on a seven-minute build; the full run had not been made when this was written.**

## What you need

- A Google Cloud project used for nothing else. `teardown` deletes every VM and disk in the project.
- The `gcloud` CLI, signed in, with Compute Engine enabled on the project.
- Levels 0 and 1 of the [replication guide](../../docs/replication-guide.md) done, so the tarball and the import graph exist under `RH_WORKDIR`.
- In `config.env`: `GCP_PROJECT`, `GCP_BUCKET` (any unused bucket name) and `GCP_SPEND_CAP_USD`.

## Run the pilot

```bash
bash cloud/gcp/pilot_local.sh stage              # private bucket and inputs; storage only
bash cloud/gcp/pilot_local.sh launch rehearsal   # about 17 minutes, well under 1 USD
bash cloud/gcp/pilot_local.sh watch              # follows the run, then deletes the VM and its disks
bash cloud/gcp/pilot_local.sh launch pilot       # about 3 hours
bash cloud/gcp/pilot_local.sh watch
bash cloud/gcp/pilot_local.sh ledger             # recorded machine-time and estimated spend
```

Run the rehearsal first. It exercises every phase with short windows and costs almost nothing.

## Cost controls, and what each one does

| Control | What it does | What it does not do |
|---|---|---|
| Ledger and cap | `launch` refuses to create a VM whose worst case would take recorded spend past `GCP_SPEND_CAP_USD`. The run is recorded before anything is created | It estimates from machine-time and a list rate. The bill is authoritative |
| Maximum run duration | The VM is created so that Google deletes it, with its disks, at a fixed time (50 minutes for the rehearsal, 6 hours for the pilot, 75 minutes for the full rehearsal, 42 hours for the full run) | It is cleared if the VM is stopped. For that reason the guest never powers itself off; it idles until deleted |
| `watch` | Deletes the VM about a minute after the guest reports a final state, and also if the guest reports nothing for 25 minutes after creation or, in a full run, falls silent for half an hour | Nothing if your machine is off; the previous control covers that case. Interrupting `watch` tears a pilot down at once; for a full run it only stops watching |
| `teardown` | Deletes every VM and disk in the project, and closes the ledger only after the Compute API confirms none remain | It does not delete the bucket |
| A Cloud Billing budget | Sends e-mail alerts | It does not stop spending |

Delete the bucket yourself when you no longer need the results: `gcloud storage rm -r gs://YOUR_BUCKET`.

## Isolation of the build

The proof source is untrusted code. On the VM it is compiled by an unprivileged user that is blocked from the metadata server, so it cannot obtain the VM's credentials, and, once the toolchain and Mathlib cache are installed, from all network access. The VM's service account can read and write objects in the one bucket and nothing else.

## What you may run into

- **Quota.** A project with little Compute Engine history typically has a limit of 32 vCPUs across all regions. The default machine, `n4d-highmem-32`, fits. Requests for much more can be refused automatically.
- **Capacity.** A zone can simply have none of a machine type. `launch` tries each zone in `GCP_ZONES` in order and creates nothing if all fail. Add zones in other regions where you have quota.
- **Disk quota.** Outside the region where you raised it, Hyperdisk capacity is typically 500 GB; the pilot's disks total 490 GB.

## What it measures

| File | Contents |
|---|---|
| `modules.tsv` | One row per compiler or checker process: CPU seconds, peak memory, threads, and the module. Rows for processes killed at the end of a window must be dropped using `phases.tsv` |
| `system.tsv` | Machine-wide CPU, memory, disk and the build tool's own CPU, every 5 seconds |
| `import_only.tsv` | Cost of importing Mathlib alone, at several levels of concurrency |
| `import_probe.tsv` | Cost of importing, and of kernel-checking, modules chosen to span import-closure sizes |
| `phases.tsv` | Start and end of each phase, with modules built and failures |
| `check_results.txt` | Kernel-checker result for each sampled module |
| `disk.txt` | Bytes written, split into compiled output and regenerable setup files |

The build targets and probe modules used for the recorded pilot are in [`records/source/pilot_targets.json`](../../records/source/pilot_targets.json).

## From measurements to an estimate

```bash
python3 analysis/pilot_estimate.py PILOT_RESULTS_DIR records/source/import_graph.json.gz
```

prints the estimated hours for a full build and a full kernel replay on the same machine type, and prices them. Its figure for the kernel replay is wrong for the stock tool on a full tree; `python3 analysis/replay_cost.py` corrects it ([`docs/cloud-notes.md`](../../docs/cloud-notes.md), section 8.5). `PILOT_RESULTS_DIR` is the directory `watch` downloaded the results to. The recorded pilot's results are in [`records/cloud/pilot/`](../../records/cloud/pilot/), and [`docs/cloud-notes.md`](../../docs/cloud-notes.md), section 8, explains the method and what three reviews changed in it. Section 9 lists what a full run needs that these scripts do not do.

## The full run

**Rehearsed, not yet run in full.** Five rehearsals found three faults, which were fixed; the third ran every phase with the stock tool for the replay, and the fifth with `rhv-replay`, and in both each step did what it should ([`records/cloud/full-rehearsals/`](../../records/cloud/full-rehearsals/)). **The kernel-replay phase has been changed since the fifth rehearsal**, so that the stock tool is shown only what each module imports, and has not been rehearsed as it now stands; rehearse before a full run. A rehearsal builds about one module in a hundred, on shortened settings; the paths no rehearsal reaches are listed at the end of that directory's README. Section 9 of [`docs/cloud-notes.md`](../../docs/cloud-notes.md) lists what four reviews of the scripts found and changed.

```bash
git status --short scripts cloud                      # must be empty: a full run is tied to one commit
bash cloud/gcp/pilot_local.sh stage                   # also uploads an archive of scripts/ made from that commit
bash cloud/gcp/pilot_local.sh launch full-rehearsal   # about 20 minutes (0.68 USD recorded), at most 2.50 USD
bash cloud/gcp/pilot_local.sh watch
bash cloud/gcp/pilot_local.sh launch full             # refused unless the cap allows 84 USD more; an estimated 26 hours
bash cloud/gcp/pilot_local.sh watch                   # can be interrupted and resumed
```

`launch full` is refused until `GCP_SPEND_CAP_USD` in `config.env` covers its worst case, 42 hours of machine time, on top of what the ledger already records. Raising the cap is how you authorise the run.

A full run is estimated at about 26 hours and 48 USD: 16 hours of build, 8.5 of kernel replay, and the rest set-up, the axiom check and slack ([`docs/cloud-notes.md`](../../docs/cloud-notes.md), section 8.5). The replay figure is a projection. The replay is by the stock tool `leanchecker` on every module, which is what criterion C3 names; each process is given a search path that holds, of the project, only hard links to the compiled files of its module and of what that module imports, because the tool lists everything on its search path before each check and with the whole library there the replay alone would take about 46 hours.

Two optional settings in `config.env`:

| Setting | What it adds |
|---|---|
| `GCP_SECOND_REPLAY=rhv-replay` | After `leanchecker` has had its whole turn, the program in `scripts/verify/replay` replays every module again: about 6 hours and 11 USD more. It is a second opinion from a different executable and no part of any criterion |
| `GCP_KEEP_OLEANS=1` | Keeps an archive of the compiled files in the bucket afterwards, in 2 GB parts under `keep/`; it costs storage until you delete it |

What the virtual machine does, in order:

| Phase | What happens | Criterion |
|---|---|---|
| Setup | Fetches the proof tarball and this repository's scripts, each checked against a SHA-256; installs the pinned toolchain and Mathlib's cache; records a SHA-256 of every file of the source tree, the toolchain and Mathlib's compiled files; blocks the build user from the metadata server and from opening any connection off the machine; only then compiles two files to confirm the cache is accepted. With `GCP_SECOND_REPLAY=rhv-replay`, root builds that program before anything of the proof is compiled, from its own copy of the toolchain (proved identical to the record just taken), after comparing the program's copy of the replay function with the toolchain's source; it must then replay the two files just compiled | |
| Build | `lake build` of everything. After 3,000 modules it restarts the build tool twice, once plainly and once after deleting setup files, and stops the run if either restart recompiles a finished module. Then it deletes the setup files of finished modules every ten minutes. A failed build is tried once more with half the jobs | C1 |
| Seal | Locks the build user's account. Confirms the source tree, the toolchain and Mathlib are byte-for-byte unchanged, symbolic links included. Gives every file to root. Copies the toolchain to a directory only root has written. Recreates the directories the checks write to. Refuses any file beside the compiled modules that the build tool does not write for this project. Records a SHA-256 of every file there. Creates two fresh users. Lifts the system's rule against hard links to another owner's files, confirms the replay's user can make one, and reads the import graph from the sealed source tree | |
| Axiom check | `scripts/08_check_axioms.sh`, and again with `--deep`, as the user `chk2`. The deep walk runs after the replay's trials: before the main replay if the replay will still fit afterwards, otherwise after it; if no time is left it is skipped, and `facts.json` says so | C2 |
| Kernel replay | `scripts/09_kernel_replay.sh` with `leanchecker` on every module, as the user `chk3`, each process with only its module's import closure on the search path. Short trials at 16, 24 and 32 at a time measure the rate; the rest runs at the fastest. If that rate cannot cover the tree in the time left, the replay gets one hour and the run moves on. Then up to two more passes, with fewer at a time, for modules whose checker was killed or cut off, and for the further runs owed to any module the tool rejected. If part of the axiom check was put off, it runs next. If the second replay was asked for, it comes last, and only if `leanchecker` could cover the tree | C3 |
| End | Hashes the files beside the compiled modules, the toolchain and Mathlib again; any change voids the checks | |
| Report | Uploads logs, measurements and `facts.json` | |

`facts.json` is a file of facts, not a verdict. Read it against section 5 of [`PREREGISTRATION.md`](../../PREREGISTRATION.md). The fields that bear on each criterion:

| Criterion | Fields | What to look for |
|---|---|---|
| C1 | `c1_build` | `state` is `built` or `built_on_second_pass`; `source_modules_not_compiled`, `compiled_modules_without_source` and `compiled_modules_named_like_a_library` are 0; `failed_job_lines_in_all_logs` is 0, or every failure in the first pass is explained in the logs; under `restart_tests`, no finished module was recompiled and each test built new modules |
| C2 | `c2_axioms` | `plain` and `deep` both have `verdict` `PASS` in mode `full`; `compiled_modules` equals the source count; `deep_walk.axioms` lists only the three standard axioms and `missing` is empty; `deep_walk_ran` is `before_replay` or `after_replay` |
| C3 | `c3_kernel_replay` | **`conditions_all_hold` is true**, which means each of the four entries of `conditions` is: every source module is compiled and nothing else is; every compiled module was passed by `leanchecker`; no rejection or crash is recorded, by any tool, in any run; the results file has no damaged line. `tool` is `leanchecker`. `summary` holds the counts behind them: `failed`, `rejected_once`, `remaining`, `tools_disagree`, `compiled_files_never_finished_by_the_build` and `modules_with_unexpected_parts` are 0 and `passed_by_leanchecker` equals `compiled_modules`. `passes_by_how_the_tool_was_run` should show every pass as `import-closure-directory`, or, for the 70 modules that import modules beneath themselves, `import-closure-directory-holding-modules-beneath`. `rejected_once` counts modules a tool rejected or crashed on once and not again: they are not passes, and they are a finding to look into. A module still under `not_run_or_ended_from_outside` after the retries, on a finished tree, is likewise a finding (for example a compiled file that names an import with no compiled file), not a pass. `expected_to_fit` says whether the trials found the replay could cover the tree; if it is false the replay was cut short and C3 is not established by this run. `second_replay` is null unless it was asked for; otherwise `result` says whether `rhv-replay` passed every module and whether every pass came from the one program root built, `unchanged_since_it_was_built` is true, and `not_run_because` is empty. If it did not run, `result` is null and `not_run_because` says why |
| All | `seal`, `end`, `inputs` | Every entry under `seal` and `end` that says "unchanged" or "matches" is true; `files_beside_the_compiled_modules_that_the_build_does_not_write` is 0; `build_user_process_seen_after_seal` is false; `inputs.tarball_sha256` is the recorded hash, `inputs.tools_commit` is a commit of this repository and `guest_script_is_the_one_sent` is true |

A build that fails twice ends the run with the state `BUILD_FAILED` and the compiler's output for each failed module. If any of those failures was a compiler process killed from outside, for lack of memory for instance, the run says so: by section 4 of the pre-registration that is not a test of the module. If the build tool itself died without reporting a failed module, the state is `FAIL`, which is a failure of the run and says nothing about the proof.

The full rehearsal builds for seven minutes, not counting the two restart tests, and then runs every later phase on what was built, with the axiom check in `--probe` mode. It exercises the build loop, both restart tests, pruning, the seal, both checks, the trials that measure the replay's rate, the archive of compiled files and the reports; and, since a rehearsal always asks for the second replay, the building and testing of that program. It does not exercise a failed build, the second build pass, the completeness check, or a replay that cannot cover the tree, and it verifies nothing. The full list is at the end of [`records/cloud/full-rehearsals/README.md`](../../records/cloud/full-rehearsals/README.md).
