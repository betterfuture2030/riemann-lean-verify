# Notes on running this on Google Cloud

What was learned on 2026-11-20 while planning a cloud run of the build. Everything here is generic: no account, project or billing details appear, and none are needed to use these notes. Prices are list prices for the Iowa region (`us-central1`), in US dollars, for Linux, before tax and without any commitment discount. They were read from Google's own price pages and SKU catalogue on 2026-11-20 and will change; read them again before relying on them.

No cloud build had been run when this was written. The durations and costs below are modelled, not measured, except where a line says otherwise. The calibration pilot in [`../cloud/gcp/`](../cloud/gcp/) exists to replace the model with measurements.

## 1. Summary

| Point | Detail |
|---|---|
| Quota decides what you can run | A project with little Compute Engine history had a global limit of 32 vCPUs. Requests for much more were refused automatically |
| The plan that needs no quota increase | One `n4d-highmem-32` (32 vCPUs, 256 GB), about 1.87 USD per hour including its disks |
| Bigger machines finish sooner, not cheaper | Within a machine family the price per vCPU-hour is the same at every size |
| One family has a storage trap | On H4D, network disk throughput is capped per VM at 240 MiB/s whatever the disk is provisioned for |
| The first cost model was optimistic in structure | Three reviewers reproduced its arithmetic and each revised its conclusions; see section 6 |
| A billing budget does not stop spending | It sends alerts, and they can arrive hours late |

## 2. Quota

Three different kinds of quota turned out to matter.

| Quota | What it limits | Value found on a project with little history |
|---|---|---|
| CPUs (all regions) | The sum of all vCPUs in the project, in every region. It applies on top of regional and per-family quotas, so it alone decides the largest machine that can start | 32 |
| CPUs per VM family, per region | vCPUs of one of the newer machine families in one region | 0 for the H4D family |
| Hyperdisk Balanced capacity, per region (with separate quotas for provisioned IOPS and throughput per zone) | Total size of Hyperdisk Balanced volumes | 500 GB |

Requests filed on 2026-11-20, and what happened:

| Request | Outcome |
|---|---|
| CPUs (all regions): 32 to 200 | Refused automatically within the hour |
| H4D family CPUs in one region: 0 to 192 | Refused automatically within the hour |
| Hyperdisk Balanced capacity in one region: 500 GB to 2,200 GB | Approved |

What follows from this:

- Read the quotas of the project you will actually use before choosing a machine. A new project starts from defaults and does not inherit increases granted to another project.
- Requests are judged by an automated system whose criteria are not published. Google's documentation, as read by a reviewer, says they include how long the account has been in use. A large first request can be refused within the hour.
- Per-family quotas for families a project has never used may not be shown in the console. Google's documentation says to read them with the command-line tools.
- The practical response is to fit the plan to the quota. A 32-vCPU machine needs no increase. No further quota requests are planned for this work until the pilot has produced measurements worth showing.
- A low vCPU quota is also a spending limit of a kind: a 32-vCPU machine of the family used here costs under 2 USD per hour.

## 3. Candidate machines

List prices per hour, on demand and Spot, for the whole machine. "Cores" is physical cores: on most families one vCPU is one hardware thread, two per core; on H4D simultaneous multithreading is off, each vCPU is a whole core and each VM occupies a whole host.

| Machine type | vCPUs | Cores | Memory (GiB) | On demand | Spot | On demand per core-hour | Storage |
|---|---|---|---|---|---|---|---|
| `n4d-highmem-32` | 32 | 16 (see note) | 256 | 1.78 | 1.01 | 0.111 | Hyperdisk only |
| `h4d-standard-192` | 192 | 192 | 720 | 7.85 | 3.82 | 0.041 | Hyperdisk Balanced (capped, section 4) |
| `h4d-highmem-192` | 192 | 192 | 1,488 | 8.84 | 4.30 | 0.046 | Hyperdisk Balanced (capped, section 4) |
| `h4d-highmem-192-lssd` | 192 | 192 | 1,488 | 9.42 | 4.58 | 0.049 | Includes 3,750 GiB of local SSD |
| `c4d-highmem-96-lssd` | 96 | 48 | 756 | 6.63 | 2.79 | 0.138 | Includes 3,000 GiB of local SSD |
| `c4d-standard-192` | 192 | 96 | 744 | 9.07 | 3.82 | 0.094 | Hyperdisk only |
| `c4d-standard-384-lssd` | 384 | 192 | 1,488 | 20.77 | 8.74 | 0.108 | Includes 12,000 GiB of local SSD |
| `c3d-standard-180-lssd` | 180 | 90 | 720 | 8.83 | 2.26 | 0.098 | Includes 6,000 GiB of local SSD, billed as a separate line |
| `n2-highmem-128` | 128 | 64 | 864 | 7.71 | 4.39 | 0.120 | Persistent disk, or optional local SSD at about 0.66 per hour for 6,000 GiB |
| `n2d-standard-224` | 224 | 112 | 896 | 9.46 | 4.78 | 0.084 | Persistent disk or optional local SSD |

Notes:

- The `n4d-highmem-32` price is computed from the SKU catalogue rates for that family, 0.02911 per vCPU-hour and 0.00331 per GiB-hour: `32 × 0.02911 + 256 × 0.00331 = 1.78`. With a 50 GB boot disk and a 500 GB Hyperdisk Balanced data disk provisioned at 6,000 IOPS and 300 MiB/s, as the pilot uses, the total is about 1.87. Its core count of 16 assumes two threads per core, as on the other general-purpose families; that was not read from a Google page here and the pilot records what the guest reports.
- Prices for the other rows are Google's published whole-machine prices. For five families (H4D, C4D, C3D, N2, N2D) one machine each was also recomputed from per-vCPU and per-GiB SKU rates and agreed to the cent.
- The SKU catalogue quotes memory for some families per decimal gigabyte and for others per binary gibibyte. Mixing the two understates memory cost by about 7 percent.
- Spot prices can change daily. A Spot VM can be taken away at short notice.
- Local SSD contents are lost when the VM stops, is preempted, or reaches a run-duration limit with a stop action. A build kept only on local SSD is not resumable after a stop.
- A stopped VM stops paying for CPU and memory but keeps paying for every attached persistent disk until the disk is deleted.

## 4. The disk throughput cap on H4D

The H4D family has by far the cheapest physical cores in the table and was the first choice. It supports only two kinds of storage: Hyperdisk Balanced and bundled local SSD.

On H4D, Hyperdisk Balanced is capped **per VM** at 15,000 IOPS and 240 MiB/s. The cap is shared by every attached volume, including the boot disk, and by reads and writes together. A volume can be provisioned, and billed, for more; the VM will not deliver it.

Why it matters for this build: the full build writes on the order of 1.4 TB (see [`performance-notes.md`](performance-notes.md)). At 240 MiB/s that alone takes at least an hour and a half. A plan that hopes to finish the parallel phase in two or three hours on 192 cores becomes limited by the disk. At slower, more likely rates the cap does not bind. The first budget had assumed a disk provisioned at 16,000 IOPS and 1,000 MiB/s on this family, which cannot be had.

For comparison, the per-VM limits read on the same day for other shapes were 100,000 IOPS and 1,600 MiB/s for a 32-vCPU N4 machine and 160,000 IOPS and 3,125 MiB/s for a 96-vCPU C4D machine. On H4D the only fast storage is the local SSD of the `-lssd` shape, with the loss-on-stop behaviour noted above.

## 5. Cost per module does not depend on machine size

Within a machine family, the hourly price is a sum of two terms, one proportional to vCPUs and one to memory, and predefined shapes keep memory per vCPU fixed. So the price per vCPU-hour is the same at every size:

| Machine | On demand per hour | Per vCPU-hour |
|---|---|---|
| `n4d-highmem-32` | 1.78 | 0.0556 |
| `n4d-highmem-96` | 5.34 | 0.0556 |

A build is a fixed amount of CPU work. If the compiler jobs run as efficiently on the large machine as on the small one, that work costs the same on either. The large machine finishes in a third of the time and charges three times as much per hour.

What moves the answer away from "exactly the same":

| Effect | Direction |
|---|---|
| Parallel efficiency usually falls as the job count rises: memory bandwidth, the operating system's handling of many processes mapping the same files, and the build tool's own serial work | Favours the smaller machine slightly, per module |
| Set-up time (installing the toolchain, downloading, unpacking) uses few cores and is billed at the whole machine's rate | Favours the smaller machine |
| Disks are billed by elapsed time, not by work done | Favours finishing sooner; small next to the machine price |
| A long chain of imports has to be compiled in sequence whatever the core count (203 modules deep here) | Limits what extra cores can buy |
| Changing **family** changes the price per physical core by a factor of up to about three (the per-core column of the table in section 3) | Can matter more than any of the above |

So the choice of size is a choice about waiting time and about quota, not about cost. With a 32-vCPU limit the build costs about what it would on a larger machine of the same family, and takes proportionally longer. The choice of family is a real cost decision, and the cheapest family per core was the one the quota refused.

How long a full build takes on 32 vCPUs is not known. Sixteen cores are not many more than the laptop's ten, so it should be expected to take days rather than hours. Nothing more precise can be said until deep modules have been measured on this hardware: the laptop figures are for shallow modules on a different processor and operating system.

## 6. The budget model and what three reviewers corrected

Before the quota refusals, a cost model was built for a 192-core H4D machine and five alternatives. It is recorded here because the corrections apply to any plan.

**The model.**

| Step | Low | Expected | High |
|---|---|---|---|
| Local work: 175,187 modules at the measured 3,230 per hour | 54.2 machine-hours | same | same |
| Worth of an efficiency core relative to a performance core | 0.35 | 0.45 | 0.60 |
| Penalty for deeper modules | 1.1 | 1.3 | 2.0 |
| Linux relative to macOS | 0.75 | 0.9 | 1.0 |
| Work, in performance-core hours | 273 | 425 | 824 |
| Effective performance cores delivered by the 192-core machine | 112 | 45 | 19 |
| Build hours | 2.9 | 10.5 | 44.4 |
| Billed hours, with set-up, a 30 percent rerun margin and verification at 30 to 60 percent of build hours | 7.7 | 21.3 | 88.4 |
| Cost on demand, with a 2 TiB network disk | 77 USD | 206 USD | 827 USD |

The same machine on Spot came to 42, 117 and 520 USD. A 128-vCPU machine of an older family came to 123, 344 and 989 USD.

**The reviews.** Three independent desk reviews were commissioned, each from a different angle: a sceptic of the model, a cloud-operations review, and a search for better alternatives. None ran anything in the cloud. All three reproduced the model's figures (one noted about 2 USD unexplained in the high case), rated it "usable with corrections", and revised the 192-core on-demand figures:

| Reviewer | Low | Expected | High |
|---|---|---|---|
| Original model | 77 | 206 | 827 |
| Model sceptic | 100 | 340 | 1,500 |
| Cloud operations | 90 | 226 | 890 |
| Alternatives | 89 | 244 | 821 |

**What they corrected.**

| # | Correction | Raised by |
|---|---|---|
| 1 | The penalty for deeper modules rests on no measurement. The modules compiled so far are the first in dependency order, not a random sample | Sceptic, alternatives |
| 2 | Contention inside the build tool was modelled as a multiplier. A lock is a serial term: if the tool spends 0.1 to 0.2 seconds of serialised time per module, the build cannot finish in under about 5 to 10 hours on any number of cores. That time per module has not been measured | Sceptic, alternatives |
| 3 | Verification was priced as a share of build hours, so it inherited the build tool's contention in a phase that does not use the build tool. It should be a separate amount of work, run one process per module | Sceptic, alternatives |
| 4 | The disk assumed for H4D cannot be delivered (section 4), and the model had no input/output limit at all | Operations |
| 5 | Quota was treated as free. Every option needed between 128 and 384 vCPUs against a limit of 32, and no fallback was priced | All three |
| 6 | "High" was not a ceiling. Nothing in the plan stopped spending, and an idle 192-core machine left running overnight costs about 70 USD. Against the model's own ranges the high figure was beyond the 99th percentile, so the real exposure was in what the model left out | Sceptic, alternatives |
| 7 | A run-duration limit on the VM is not a hard stop on spending: it starts again after a restart, a stop leaves the disks billing, and on local-SSD shapes a timed stop destroys the data. Use an absolute termination time and delete disks explicitly | Operations |
| 8 | A pilot that runs the first hour of the build sees only shallow modules, the same blind spot as the laptop. It should build the import closure of one deep module | Sceptic, alternatives |
| 9 | Memory hazards were mis-specified. Mapped compiled files are shared between processes. What matters is the per-process limit on memory mappings on Linux, which the reviewer expects the final modules to exceed at its default (not tested), and private memory that grows with a module's import closure | Sceptic |
| 10 | The same machine on Spot was about 43 percent cheaper in the model's own figures and was passed over. A queued, non-preemptible provisioning model was also listed about 25 percent below on demand | Alternatives, operations |
| 11 | Small costs were missing: boot disk, external address, disk retention after the run, snapshots, egress, tax. About 3 to 15 USD before tax | Operations |
| 12 | "Expected" was the cost at the most likely value of each input, not a probability-weighted mean. The mean is higher | Sceptic, alternatives |

The reviewers' ranges are themselves judgement, not measurement, and they say so.

**What changed as a result.** The plan in use is a calibration pilot on one 32-vCPU machine. Every phase is time-boxed. It measures an import-only compile, a window at the start of the build, the import closure of one deep module, a sweep of job counts and a sample kernel replay; it raises the Linux limits on open files and memory mappings before starting; and it uploads its measurements as it goes, so that the unmeasured inputs above (depth penalty, the build tool's serial time, verification cost) can be replaced by numbers. It had not yet run when this was written.

## 7. A billing budget only alerts

A Cloud Billing budget, as read on 2026-11-20:

- sends notifications by email, and optionally to a message topic, when actual or forecast spend crosses thresholds you set;
- does **not** cap usage or stop any resource when the budget is reached;
- reports with a delay. Usage takes time to reach the billing system, and Google's documentation warns that the first notification can take several hours. For a job that lasts a day, an alert can arrive after most of the money is spent.

A newer kind of budget that pauses usage exists, but on the date read it did not cover Compute Engine, and it does not pause persistent resources such as running machines and disks.

What does bound spending:

| Mechanism | What it does | Limits |
|---|---|---|
| A run-duration limit or termination time set on the VM at creation, with a stop or delete action | Google stops or deletes the VM when the time is up, whatever the guest is doing | A duration starts again if the VM is restarted; an absolute time does not. A stop action leaves disks billing; a delete action, with disks set to auto-delete, removes both |
| A deadline inside the guest that shuts the machine down when the work is done or the time is up | Ends billing for CPU and memory promptly | Depends on the guest still working |
| Deleting the VM and its disks, and checking that nothing is left | The only certain end to all charges | Has to be done, and verified |
| A local ledger that refuses to launch when the worst case of the next run would exceed a cap | Bounds the total before anything starts | It is an estimate from list prices and elapsed time; the bill is authoritative |
| The vCPU quota itself | Bounds the hourly rate | Only as low as the quota |

The pilot in [`../cloud/gcp/`](../cloud/gcp/) uses the first four together. Billing rules worth knowing when reading its ledger: machines are charged by the second with a one-minute minimum, from start until they begin stopping; an idle machine that is still running is charged in full; disks are charged by the second on their provisioned size and performance, used or not, until deleted.
