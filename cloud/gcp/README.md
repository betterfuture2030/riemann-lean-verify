# Google Cloud calibration pilot

One rented virtual machine compiles a time-boxed sample of the proof, measures what each module costs, uploads its measurements to a private bucket, and is deleted. The point is to estimate the cost of a full cloud run before committing to one.

It does not run the full build.

## What you need

- A Google Cloud project used for nothing else. `teardown` deletes every VM and disk in the project.
- The `gcloud` CLI, signed in, with Compute Engine enabled on the project.
- Levels 0 and 1 of the [replication guide](../../docs/replication-guide.md) done, so the tarball and the import graph exist under `RH_WORKDIR`.
- In `config.env`: `GCP_PROJECT`, `GCP_BUCKET` (any unused bucket name) and `GCP_SPEND_CAP_USD`.

## Run it

```bash
bash cloud/gcp/pilot_local.sh stage              # private bucket and inputs; storage only
bash cloud/gcp/pilot_local.sh launch rehearsal   # about 12 minutes, well under 1 USD
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
| Maximum run duration | The VM is created so that Google deletes it, with its disks, at a fixed time (50 minutes for the rehearsal, 6 hours for the pilot) | It is cleared if the VM is stopped. For that reason the guest never powers itself off; it idles until deleted |
| `watch` | Deletes the VM about a minute after the guest reports a final state | Nothing if your machine is off; the previous control covers that case |
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
