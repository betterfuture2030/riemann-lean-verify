# Google Cloud: calibration pilot, full run, and the checks on the export

Four things live here, driven by one controller, `pilot_local.sh`.

- **The calibration pilot** (`pilot_guest.sh`). One rented virtual machine compiles a time-boxed sample of the proof, measures what each module costs, uploads its measurements to a private bucket, and is deleted. The point is to estimate the cost of a full run before committing to one. It was run on 2026-11-20; its results are in [`records/cloud/pilot/`](../../records/cloud/pilot/).
- **The full run** (`full_guest.sh`). One virtual machine builds the whole tree and runs the pre-registered checks. It is described in the section "The full run". **It has been rehearsed on a seven-minute build, and never run in full on demand.** The same script can make the run on Spot machines, as a chain of machines that each carry on from what the last one saved; that is the section "The full run on Spot machines", and **the full run was made that way on 2026-11-22 and 23** ([`records/cloud/full-run/`](../../records/cloud/full-run/)).
- **The export check** (`export_guest.sh`). Builds nothing: from the compiled files a finished Spot run left in the bucket it exports the proof, compares the export with the published one and runs an independently written kernel on it. Run once, on 2026-11-24 ([`records/cloud/export-check/`](../../records/cloud/export-check/)).
- **The kernel check** (`kernel_guest.sh`). Builds nothing and needs only the export: a second independent kernel, `lake comparator` with Lean's own kernel in its sandbox, and Lean's paranoid kernel. Rehearsed once and run once, on 2026-11-25 and 26 ([`records/cloud/kernel-check/`](../../records/cloud/kernel-check/)). It is the last section of this page.

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
| Maximum run duration | The VM is created so that Google deletes it, with its disks, at a fixed time (50 minutes for the rehearsal, 6 hours for the pilot, 75 minutes for the full rehearsal, 42 hours for the full run, 5 hours for the export check, 20 hours for the kernel check) | It is cleared if the VM is stopped. For that reason the guest never powers itself off; it idles until deleted. The kernel check is the one exception: see its section |
| `watch` | Deletes the VM about a minute after the guest reports a final state, and also if the guest reports nothing for 25 minutes after creation or, in a full run or a kernel check, falls silent for half an hour | Nothing if your machine is off; the previous control covers that case. Interrupting `watch` tears a pilot or an export check down at once; for a full run or a kernel check it only stops watching |
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

**Rehearsed on demand; run in full once, on Spot machines (the section after this one).** Six rehearsals found three faults, which were fixed. The third ran every phase with the stock tool for the replay and the whole library on its search path, the fifth with `rhv-replay`, and the sixth with the stock tool shown only what each module imports, which is how the driver now runs (two things have changed since: one line of the replay script, for short passes, and the code for Spot runs described in the next section, which is switched off here; with it switched off the script has been tested only locally); in each of those every step did what it should ([`records/cloud/full-rehearsals/`](../../records/cloud/full-rehearsals/)). A rehearsal builds about one module in a hundred, all of them shallow, on shortened settings; the paths no rehearsal reaches are listed at the end of that directory's README. Section 9 of [`docs/cloud-notes.md`](../../docs/cloud-notes.md) lists what four reviews of the scripts found and changed.

```bash
git status --short scripts cloud                      # must be empty: a full run is tied to one commit
bash cloud/gcp/pilot_local.sh stage                   # also uploads an archive of scripts/ made from that commit
bash cloud/gcp/pilot_local.sh launch full-rehearsal   # about 20 to 25 minutes (0.65 to 0.83 USD recorded), at most 2.57 USD
bash cloud/gcp/pilot_local.sh watch
bash cloud/gcp/pilot_local.sh launch full             # refused unless the cap allows 84.07 USD more; an estimated 26 hours
bash cloud/gcp/pilot_local.sh watch                   # can be interrupted and resumed
```

`launch full` is refused until `GCP_SPEND_CAP_USD` in `config.env` covers its worst case, 42 hours of machine time, on top of what the ledger already records. Raising the cap is how you authorise the run. What that means for a cap below the worst case, and what else could be done, is in [`docs/cloud-notes.md`](../../docs/cloud-notes.md), section 8.6.

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

## The full run on Spot machines

**Rehearsed once and run in full once.** The rehearsal of 2026-11-22 made four attempts with three forced cuts ([`records/cloud/spot-rehearsals/`](../../records/cloud/spot-rehearsals/)). The full run of 2026-11-22 and 23 took two attempts, with one reclaim by Google 73 minutes in, 21.5 hours of machine time at work and 26.0 billed, recorded at 31.21 USD ([`records/cloud/full-run/`](../../records/cloud/full-run/)). About 4.5 of the billed hours were a finished machine idling because `watch` had stopped: **keep `watch` running until it reports the run over, and start it again if the computer it runs on restarts.** A Spot machine costs about six tenths of the on-demand price and Google may take it back at any moment. `launch full-spot` makes the full run as a chain of *attempts*: each is a fresh Spot machine that Google deletes, with its disks, when it takes it back or at the attempt's own time limit. The guest saves its work to the bucket under `ckpt/RUNTAG/` (the compiled files of finished modules every ten minutes during the build; the replay's results about every twenty minutes, after hashing the sealed files again), and the next attempt carries on from there. Nothing is kept in Compute Engine between attempts. The design, what crosses from one machine to the next and how it is checked, the cost model and what the reviews changed are in [`docs/cloud-notes.md`](../../docs/cloud-notes.md), section 10.

```bash
git status --short scripts cloud                          # must be empty: every attempt of a run comes from one commit
bash cloud/gcp/pilot_local.sh stage
bash cloud/gcp/pilot_local.sh launch full-spot-rehearsal  # the seven-minute build as four attempts, three of them cut on purpose
bash cloud/gcp/pilot_local.sh watch                       # follows each attempt, accounts for it and starts the next
bash cloud/gcp/pilot_local.sh launch full-spot            # the whole tree
bash cloud/gcp/pilot_local.sh watch                       # can be interrupted and run again at any time
```

`watch` ends with status 0 when the run is over, 3 when it has paused, and 4 when a rehearsal finished without making every cut it was configured to make. A pause means that nothing is running and nothing in Compute Engine bills: the cap leaves too little for another attempt, 120 hours have passed since the first launch, 24 attempts have been started, three attempts in a row saved no progress, or a machine reported a condition another attempt would meet again. `watch` run again continues a paused run; `abandon` ends it. `teardown` ends the current attempt at once and keeps the run.

| What | Detail |
|---|---|
| The cap | Each attempt is sized so that recorded spend, with the attempt run to its time limit, stays under `GCP_SPEND_CAP_USD` less a reserve of 1.00 USD for the checkpoints' storage. The ledger counts a Spot attempt at 1.20 USD an hour. No cap that covers a whole worst case of 42 hours (84.07 USD on top of what is already recorded) is needed, as it is for `launch full`: a run that the cap cannot carry to its end pauses, with its work kept |
| Expected cost | With no reclaim about 26 hours and 29 USD at list prices; about 24 minutes more for each reclaim. These are a model's figures ([`records/cloud/spot_resume_model.json`](../../records/cloud/spot_resume_model.json)); Google publishes no rate of reclaims |
| The rehearsal | By default it ends an attempt during the build with Google's own simulated reclaim, a second at the seal by deleting the machine, and a third during the replay with a hard reset that gives no notice (`GCP_SPOT_REHEARSAL_CUTS`). The one rehearsal made cost 0.76 USD at the ledger rate; each attempt can cost at most about 1.55 |
| A copy for you | With `GCP_RESULTS_MIRROR_DIR` set to a local folder, for example one that Google Drive for desktop syncs, `watch` copies the status, `facts.json`, the logs and each attempt's small results there every ten minutes and when each attempt ends. The checkpoints themselves stay in the bucket |
| The checkpoints | An estimated 40 GB for the whole tree. They bill as bucket storage, about 0.80 USD a month, until you delete them; `watch` prints their size and the command to delete them whenever a run pauses or ends |
| Zones | Attempts are tried in the order of `GCP_ZONES`. An attempt outside the bucket's region pays to move the checkpoints, which the cap test counts and the ledger records |
| Settings | All optional, in `config.example.env` under "Spot runs" |

What a Spot run's `facts.json` adds is a `spot` block: one entry per attempt (when it started, in which zone, how it ended, what it restored), the units of the run completed so far, how many confirming hashes were made, and whether the checkpoints were shown at the seal to reproduce the sealed files exactly. The criteria are read from the same fields as for an on-demand run. A paused run is not a result.

## The export check

**Run once, without a rehearsal** (2026-11-24; [`records/cloud/export-check/`](../../records/cloud/export-check/)). The mode `export-check` builds nothing. On one on-demand machine it fetches the compiled files a finished Spot run left in the bucket, shows that they are that run's sealed files, exports the community's challenge file and the proof with `lean4export`, compares both SHA-256 values with the published ones, and runs `con-leche`, a kernel written independently of Lean's, on the export ([`export_guest.sh`](export_guest.sh), whose header lists each step and what it is not).

```bash
git status --short scripts cloud                          # must be empty
bash cloud/gcp/pilot_local.sh stage
GCP_EXPORT_FROM=full-spot-YYYYMMDD-HHMMSS bash cloud/gcp/pilot_local.sh launch export-check
bash cloud/gcp/pilot_local.sh watch                       # collects the results and deletes the machine
```

| What | Detail |
|---|---|
| What it needs | The run named by `GCP_EXPORT_FROM` must have finished, its checkpoints must still be in the bucket, and its `facts.json` and `ckpt/manifest.tsv` must be in the local results folder, where `watch` put them |
| Cost | The machine is limited to five hours, so the cap test counts about 10 USD. The one run took 2.2 hours and is recorded at 4.49 USD. The export of the proof is single-threaded and took 95 minutes of that |
| What it writes | `export_facts.json`: the hashes, sizes, times and each program's exit status. It is a list of facts, not a verdict. The kernels' whole output is in `logs/` |
| Known fault | The `nanoda` step passes the export where that program expects a configuration file, and stops at once with status 101. It is recorded as such and does not end the run. This script has not been changed; `nanoda` is run correctly by the kernel check below |
| What it is not | `lake comparator`, which also runs Lean's own kernel over the export under a sandbox: that is the kernel check below. Nor does it make the build any more sandboxed than it was |

The launcher's local test (`scripts/dev/test_spot_launcher.sh`, 90 checks) was run after this mode was added and passed. It does not exercise this mode.

## The kernel check

**Rehearsed once and run once** (2026-11-25 and 26; [`records/cloud/kernel-check/`](../../records/cloud/kernel-check/)). The modes `kernel-check-rehearsal` and `kernel-check` build nothing and need neither the source nor the compiled files. On one on-demand machine they give the proof's export to `nanoda`, to `con-ron --compare`, to `lake comparator`, which compares the five statements and the axioms with the challenge in its own process and then runs Lean's own kernel over the export in its `bubblewrap` sandbox, and to Lean's paranoid kernel ([`kernel_guest.sh`](kernel_guest.sh), whose header lists each step, the two ways it differs from the published runs, and what it is not).

```bash
git status --short scripts cloud                          # must be empty
export GCP_KERNEL_FROM=export-check-YYYYMMDD-HHMMSS       # a finished export check: its two hashes are the ones insisted on
bash cloud/gcp/pilot_local.sh launch kernel-check-rehearsal   # a 4-vCPU machine, about 25 minutes
bash cloud/gcp/pilot_local.sh watch
bash cloud/gcp/pilot_local.sh launch kernel-check         # a 32-vCPU machine with 256 GB, about 12 hours
bash cloud/gcp/pilot_local.sh watch                       # collects the results and deletes the machine
```

| What | Detail |
|---|---|
| What it needs | The run named by `GCP_KERNEL_FROM` must have finished with both exports equal to the published ones, its `export_facts.json` must be in the local results folder, and its challenge export must still be in the bucket. Nothing that `stage` uploads is used |
| The rehearsal | Runs every step on small stand-ins, in minutes. It also does one piece of real work: it fetches the published copy of the proof's export (7.7 GB), checks it against the published SHA-256 and against the one the export check recorded, and keeps it in the bucket. `launch kernel-check` is refused until that file is there, unless `GCP_KERNEL_FETCH_OK=1` lets the large machine fetch it |
| Cost | The long run's machine is limited to 20 hours, so the cap test counts 40.07 USD; the one run took 11.5 hours and is recorded at 22.97 USD. The rehearsal's is limited to 100 minutes at its own ledger rate of 0.30 USD an hour; the one rehearsal is recorded at 0.11 USD |
| Why so large a machine | For memory. The two long checks use one core each for about ten hours and are run side by side: Lean's kernel peaked at 82.6 GiB and its paranoid build at 98.8. `GCP_KERNEL_LONG=0` runs only `nanoda` and `con-ron` |
| The allocator setting | Lean's two kernels are run with `MIMALLOC_GENERIC_COLLECT=1000000`, without which they take about 48 and 72 hours on this export by the published measurements. `lake comparator` clears the environment of what it starts, so the setting reaches its kernel through a wrapper named as the sandbox program. The guest reads the running kernel's environment and stops it if the setting is missing |
| When it ends | The guest uploads each checker's result as it ends, then a final state. `watch` then copies the results and deletes the machine. **If nobody collects them within twenty minutes the guest powers the machine off.** It does the same two minutes after reporting a failure, if its script has died or is still unfinished ten minutes after its own deadline, and at once if the machine is ever restarted. That ends the charge for the machine but cancels Google's deletion of it: the stopped machine and its two disks stay, and the disks bill about 1.4 USD a day, until `watch` or `teardown` is run. So keep `watch` running, and if it has stopped, start it again |
| What it writes | `kernel_facts.json`: hashes, sizes, times, peak memory and each program's exit status and last line. It is a list of facts, not a verdict. Each checker's output is in `logs/`, with every sandbox command line `lake` issued (`bwrap_calls.log`) |
| What it is not | A sandboxed build, since nothing is built. `lake comparator` as published: here the configuration is the community's without its two external kernels, which run beside it as a user with no network access and not in the sandbox. `lake comparator --paranoid`. `lean4lean` |

The launcher's local test (`scripts/dev/test_spot_launcher.sh`) was run again on 2026-11-26, with these modes in the launcher, and passed (90 checks). It does not exercise them. The pieces of `kernel_guest.sh` that can run without a rented machine were tested separately against stand-ins ([`docs/cloud-notes.md`](../../docs/cloud-notes.md), section 10.10).
