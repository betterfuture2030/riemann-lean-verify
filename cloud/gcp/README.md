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

prints the estimated hours for a full build and a full kernel replay on the same machine type, and prices them. `PILOT_RESULTS_DIR` is the directory `watch` downloaded the results to. The recorded pilot's results are in [`records/cloud/pilot/`](../../records/cloud/pilot/), and [`docs/cloud-notes.md`](../../docs/cloud-notes.md), section 8, explains the method and what three reviews changed in it. Section 9 lists what a full run needs that these scripts do not do.

## The full run

**Rehearsed, not yet run in full.** Three rehearsals on 2026-11-20 found two faults, which were fixed; the third ran every phase and each step did what it should ([`records/cloud/full-rehearsals/`](../../records/cloud/full-rehearsals/)). A rehearsal builds about one module in a hundred and does not reach the paths listed at the end of this page. Section 9 of [`docs/cloud-notes.md`](../../docs/cloud-notes.md) lists what two reviews of the scripts found and changed.

```bash
git status --short scripts cloud                      # must be empty: a full run is tied to one commit
bash cloud/gcp/pilot_local.sh stage                   # also uploads an archive of scripts/ made from that commit
bash cloud/gcp/pilot_local.sh launch full-rehearsal   # about 20 minutes (0.68 USD recorded), at most 2.50 USD
bash cloud/gcp/pilot_local.sh watch
bash cloud/gcp/pilot_local.sh launch full             # an estimated 31 hours; refused unless the cap allows 84 USD more
bash cloud/gcp/pilot_local.sh watch                   # can be interrupted and resumed
```

`launch full` is refused until `GCP_SPEND_CAP_USD` in `config.env` covers its worst case, 42 hours of machine time, on top of what the ledger already records. Raising the cap is how you authorise the run. The estimate is about 31 hours and 58 USD ([`docs/cloud-notes.md`](../../docs/cloud-notes.md), section 8). Set `GCP_KEEP_OLEANS=1` to keep an archive of the compiled files in the bucket afterwards, in 2 GB parts under `keep/`; it costs storage until you delete it.

What the virtual machine does, in order:

| Phase | What happens | Criterion |
|---|---|---|
| Setup | Fetches the proof tarball and this repository's scripts, each checked against a SHA-256; installs the pinned toolchain and Mathlib's cache; records a SHA-256 of every file of the source tree, the toolchain and Mathlib's compiled files; blocks the build user from the metadata server and from opening any connection off the machine; only then compiles two files to confirm the cache is accepted | |
| Build | `lake build` of everything. After 3,000 modules it restarts the build tool twice, once plainly and once after deleting setup files, and stops the run if either restart recompiles a finished module. Then it deletes the setup files of finished modules every ten minutes. A failed build is tried once more with half the jobs | C1 |
| Seal | Locks the build user's account. Confirms the source tree, the toolchain and Mathlib are byte-for-byte unchanged, symbolic links included. Gives every file to root. Copies the toolchain to a directory only root has written. Recreates the directories the checks write to. Refuses any file beside the compiled modules that the build tool does not write for this project. Records a SHA-256 of every file there. Creates two fresh users | |
| Axiom check | `scripts/08_check_axioms.sh`, and again with `--deep`, as the user `chk2`. The deep walk runs before the replay if the replay will still fit afterwards, otherwise after it; if no time is left it is skipped, and `facts.json` says so | C2 |
| Kernel replay | `scripts/09_kernel_replay.sh` on every module, as the user `chk3`: short trials at 16, 24 and 32 at a time, the rest at the fastest, then the prefix pass; then up to two more passes, with fewer at a time, for modules whose checker was killed or cut off | C3 |
| End | Hashes the files beside the compiled modules, the toolchain and Mathlib again; any change voids the checks | |
| Report | Uploads logs, measurements and `facts.json` | |

`facts.json` is a file of facts, not a verdict. Read it against section 5 of [`PREREGISTRATION.md`](../../PREREGISTRATION.md). The fields that bear on each criterion:

| Criterion | Fields | What to look for |
|---|---|---|
| C1 | `c1_build` | `state` is `built` or `built_on_second_pass`; `source_modules_not_compiled`, `compiled_modules_without_source` and `compiled_modules_named_like_a_library` are 0; `failed_job_lines_in_all_logs` is 0, or every failure in the first pass is explained in the logs; under `restart_tests`, no finished module was recompiled and each test built new modules |
| C2 | `c2_axioms` | `plain` and `deep` both have `verdict` `PASS` in mode `full`; `compiled_modules` equals the source count; `deep_walk.axioms` lists only the three standard axioms and `missing` is empty; `deep_walk_ran` is `before_replay` or `after_replay` |
| C3 | `c3_kernel_replay.summary` | `complete` is true; `failed`, `prefix_failed` and `modules_with_unexpected_parts` are 0 |
| All | `seal`, `end`, `inputs` | Every entry under `seal` and `end` that says "unchanged" or "matches" is true; `files_beside_the_compiled_modules_that_the_build_does_not_write` is 0; `build_user_process_seen_after_seal` is false; `inputs.tarball_sha256` is the recorded hash, `inputs.tools_commit` is a commit of this repository and `guest_script_is_the_one_sent` is true |

A build that fails twice ends the run with the state `BUILD_FAILED` and the compiler's output for each failed module. If any of those failures was a compiler process killed from outside, for lack of memory for instance, the run says so: by section 4 of the pre-registration that is not a test of the module. If the build tool itself died without reporting a failed module, the state is `FAIL`, which is a failure of the run and says nothing about the proof.

The full rehearsal builds for seven minutes, not counting the two restart tests, and then runs every later phase on what was built, with the axiom check in `--probe` mode. It exercises the build loop, both restart tests, pruning, the seal, both checks, the archive of compiled files and the reports. It does not exercise a failed build, the second build pass or the completeness check, and it verifies nothing.
