# Notes on running this on Google Cloud

What was learned on 2026-11-20 while planning a cloud run of the build. Everything here is generic: no account, project or billing details appear, and none are needed to use these notes. Prices are list prices for the Iowa region (`us-central1`), in US dollars, for Linux, before tax and without any commitment discount. They were read from Google's own price pages and SKU catalogue on 2026-11-20 and will change; read them again before relying on them.

Sections 1 to 7 were written before anything had been run in the cloud; their durations and costs are modelled, not measured, except where a line says otherwise. The calibration pilot in [`../cloud/gcp/`](../cloud/gcp/) then ran on the same day. Section 8 gives what it measured and the estimate for a full run that follows from it, section 9 describes the driver written for a full run and what a review of it changed, and section 10 a way of making that run on Spot machines, which was built, tested locally, rehearsed once and then used for the full run (10.8). Where section 8 and an earlier section disagree, section 8 supersedes it: 8.1 is measured, and 8.2 is an estimate built on 8.1.

## 1. Summary

| Point | Detail |
|---|---|
| Quota decides what you can run | A project with little Compute Engine history had a global limit of 32 vCPUs. Requests for much more were refused automatically |
| The plan that needs no quota increase | One `n4d-highmem-32` (32 vCPUs, 256 GB), about 1.87 USD per hour including its disks |
| Bigger machines finish sooner, not cheaper | Within a machine family the price per vCPU-hour is the same at every size |
| One family has a storage trap | On H4D, network disk throughput is capped per VM at 240 MiB/s whatever the disk is provisioned for |
| The first cost model was optimistic in structure | Three reviewers reproduced its arithmetic and each revised its conclusions; see section 6 |
| A billing budget does not stop spending | It sends alerts, and they can arrive hours late |
| What the pilot's measurements imply | A full build on the 32-vCPU machine: an estimated 16 hours. The kernel replay after it was first put at 14 hours, which was wrong: with the stock tool as first run, about 46 (43 to 56). With the same stock tool shown only what each module imports, about 8.5, which makes a full run about 26 hours and 48 USD (sections 8.2 and 8.5). That last figure is a projection: on a rented machine this way of running the tool has been timed twice, each time on the shallow modules of a rehearsal; the first time a check cost about what it had cost with the whole library on the path, 4 to 8 percent above what the projection gives for so small a tree (section 8.5) |
| The cap, and what fits under it | On 2026-11-21 the cap was set at 50 USD in total, with 9.86 then recorded as spent (10.62 after the Spot rehearsal of 2026-11-22, and 41.83 after the full run that ended on 2026-11-23). The full run as designed needs a cap of about 94, because the launcher counts its worst case. Section 8.6 lists what could be done and what each way risks. The way chosen was the Spot run of section 10 |
| A Spot run that resumes | Built, reviewed, tested locally and, on 2026-11-22, rehearsed once on rented machines: four attempts, three forced cuts, every phase ran, 0.76 USD. **Run in full on 2026-11-22 and 23**: two attempts, one reclaim by Google, 21.5 hours of machine time at work, recorded at 31.21 USD with 4.5 idle hours that a restart of the owner's computer caused (section 10.8). Before that run, with no reclaim it was modelled at 26 hours and about 29 USD at list prices. Each reclaim costs about 24 minutes. In the model it stays cheaper than on demand unless reclaims average more than one every 50 minutes, and half of simulated runs finish under the cap of 50 when they average one every 2 hours, nine in ten at one every 3 (section 10) |

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

When this section was written, how long a full build takes on 32 vCPUs was not known, and the expectation was days rather than hours. The pilot's measurements, extrapolated in section 8.2, give an estimate of about 16 hours for the build and 14 for the kernel replay. Nothing above 17,860 imports was measured.

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

**What changed as a result.** The plan in use is a calibration pilot on one 32-vCPU machine. Every phase is time-boxed. It measures an import-only compile, a window at the start of the build, the import closure of one deep module, a sweep of job counts and a sample kernel replay; it raises the Linux limits on open files and memory mappings before starting; and it uploads its measurements as it goes, so that the unmeasured inputs above (depth penalty, the build tool's serial time, verification cost) can be replaced by numbers. Section 8 has the numbers.

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

## 8. What the pilot measured

The pilot ran on 2026-11-20 on one `n4d-highmem-32` in `us-east1-b`. All four zones tried in `us-central1` had no capacity for that machine type at the time, which is why the zone list in `config.env` should span regions. It ran for 2 hours 55 minutes, deleted itself, and cost 5.82 USD at the ledger's rate; a 17-minute rehearsal before it cost 0.57 USD. The raw measurements are in [`../records/cloud/pilot/`](../records/cloud/pilot/), with a description of every file.

It compiled 29,633 modules with zero failures and kernel-checked a random sample of 2,233 of them with zero failures. That is about 17 percent of the tree. It is not a verification of anything.

### 8.1 Measurements

| Quantity | Measured |
|---|---|
| The machine, as the guest saw it | AMD EPYC 9B45, 16 cores and 32 threads, 251 GiB of memory |
| Set-up, from the start of the guest script to a working toolchain with Mathlib's cache unpacked | 76 seconds |
| Modules compiled per second at 32 jobs | 3.2 to 3.5 in five separate windows |
| At 16 jobs, 24 jobs, 8 jobs | 3.1 to 3.3, 3.0, 1.3 |
| CPU per module at 32 jobs | Mean 8.5 seconds, median 5.9. 95 modules took over a minute of wall time; the longest took 409 seconds |
| Threads per compiler process | Median 15, so 16 jobs already occupy the 16 cores. Going from 16 to 32 jobs raised throughput by about 7 percent and CPU seconds per module by about 50 percent |
| Importing a module, one process alone | 2.37 seconds plus 0.136 seconds per 1,000 project modules in its import closure (17 modules with closures from 0 to 17,860, three repeats each) |
| The same import with 32 running at once | 1.66 times the CPU |
| The build tool's own CPU | 0.35 to 0.38 seconds per module at 32 jobs, on 1.1 to 1.3 cores |
| Restarting the build tool with up to 30,000 modules already built | 4 to 9 seconds until the first new module finished |
| Private memory per compiler process | Median 504 MiB, 99th percentile 765 MiB, largest 8,130 MiB. Against closure size: 508 MiB plus 13 KiB per imported project module, which projects to 2.7 GiB for the last module |
| Compiled files a process maps and touches | 6.4 GiB plus 0.57 MiB per imported project module, which projects to about 104 GiB for the last module. These pages are shared between processes |
| Whole machine | Private memory never above 21 GiB; never less than 219 GiB available. After start-up nothing was read from disk: every compiled file was served from memory |
| Kernel checker, 32 at once | 3.7 modules per second; 8.3 CPU seconds per module, 61 percent of it inside the operating system |
| Kernel checker, one process alone | 4.4 seconds plus 0.13 seconds per 1,000 imported project modules |
| Disk written per module | 0.72 MB of compiled output and a 5.53 MB setup file, at about 21 MB per second in all |
| Open files across the machine | Up to 1.7 million. Regressed on the processes alive and their imports: about 64,000 per compiler process plus about 2 per imported project module |

Three things the earlier sections guessed at are now measured.

- **Deeper modules are not much dearer.** The first model assumed a penalty of 1.1 to 2.0 times. The mean CPU per module barely moves with closure size up to 17,860 imports (8.4 seconds for closures of 1 to 100, 8.3 seconds above 8,000). The import cost that must be there, from the probes, adds about 6 percent between the pilot's mean closure (679) and the tree's (about 3,100).
- **The build tool's serial work does not limit this machine.** At a little over one core it kept 32 jobs supplied. On a much larger machine the same 0.35 seconds per module could become the limit; nothing here measures that.
- **Verification is a second job of the same size.** The kernel replay costs about as much CPU as the build, most of it spent importing.

### 8.2 The estimate

[`../analysis/pilot_estimate.py`](../analysis/pilot_estimate.py) turns the recorded measurements into hours. It needs Python 3 and nothing else, and takes about a minute:

```bash
python3 analysis/pilot_estimate.py records/cloud/pilot/pilot-20261120-162141 records/source/import_graph.json.gz \
  --config "n4d-highmem-32 on demand, 440 GB disk, setup files pruned:1.78:440" \
  --config "n4d-highmem-32 on demand, 2 TB disk, nothing pruned:1.78:2048" \
  --config "n4d-highmem-32 Spot, 440 GB disk, setup files pruned:1.0136:440" \
  --config "n4d-standard-32 on demand, 440 GB disk, setup files pruned:1.355:440" \
  --config "n4d-standard-32 Spot, 440 GB disk, setup files pruned:0.7721:440"
```

The method, in five steps:

1. Cost of compiling one module, in CPU seconds at 32 jobs: `E + s × closure`. A plain regression of CPU on closure size gives a slope of 0.046 seconds per 1,000 imports with a standard error of 0.049: it cannot be told apart from zero, because in the pilot's sample closure size is mixed up with how heavy each module's own content is. So `s` is taken from the import probes, scaled by the measured cost of running 32 at once: 0.136 × 1.66 = 0.226 seconds per 1,000. `E` is set so that the model reproduces the pilot's mean.
2. The model is applied to a random sample of 8,000 modules from the whole tree (mean closure 3,086), giving 442 CPU-hours.
3. CPU becomes wall-clock through the useful CPU delivered per thread-second, measured inside the longest window: 0.911.
4. The kernel checker is treated the same way: 8.1 seconds plus 0.263 per 1,000 imports, 434 CPU-hours, 0.971 useful CPU per thread-second.
5. Fixed allowances are added for set-up, the narrow top of the import graph, the two checks of criterion C2, and slack.

| Case | Build | Kernel replay | Set-up, C2 and slack | Billed hours |
|---|---|---|---|---|
| Low | 13.7 | 14.0 | 0.5 | 28.1 |
| Expected | 15.6 | 14.0 | 1.5 | 31.0 |
| High | 17.9 | 15.4 | 6.0 | 39.3 |

**The kernel replay column is wrong for the stock tool, and so are the totals built on it. Section 8.5 corrects them.** The table is left as it was made.

Low uses the plain regression's slope, per-library corrections shrunk towards zero, and the best utilisation seen. High uses the slope fitted to the 153 largest closures alone (0.41 per 1,000, standard error 0.18) raised by 10 percent, 5 percent lower utilisation, a steeper checker slope, and three hours for one failure that is noticed late. An independent cross-check from raw throughput agrees with the expected case: 175,187 modules at 3.32 per second is 14.7 hours, and 6 percent more for larger closures gives 15.5; 3.7 checks per second, with the checker's own 8 percent for larger closures, gives 14.1.

Priced at list rates read on 2026-11-20, in US dollars, with the disk kept for six hours after the machine stops:

| Configuration | Machine per hour | Low | Expected | High | Measured by the pilot? |
|---|---|---|---|---|---|
| `n4d-highmem-32` on demand, 440 GB disk, setup files deleted as modules finish | 1.78 | 53 | 58 | 74 | Machine and disk yes; deleting setup files only on a small test project (section 9) |
| `n4d-highmem-32` on demand, 2 TB disk, nothing deleted | 1.78 | 59 | 65 | 82 | Yes, but the disk needs quota the pilot's region did not have |
| `n4d-highmem-32` Spot, 440 GB disk | 1.01 | 31 | 34 | 44 | No: adds restarts after each preemption, not included in the hours |
| `n4d-standard-32` (128 GB) on demand, 440 GB disk | 1.36 | 41 | 45 | 57 | No: see below |
| `n4d-standard-32` Spot, 440 GB disk | 0.77 | 25 | 27 | 34 | No: both of the above |

The 128 GB machine is the largest untested saving. The whole tree's compiled output is about 127 GB, Mathlib and Lean's own library add about 7 GB (the 6.4 GiB every process maps), and the last modules each touch about 104 GiB of it. On 256 GB all of that stays in memory, which is what the pilot measured. On 128 GB it would not, and the pilot read nothing from disk, so it says nothing about how much slower that is.

### 8.3 What three reviewers said about the first version

The first version of the script gave 26.7, 29.7 and 36.4 billed hours and 58, 64 and 79 USD with a 2 TB disk. Three AI reviewers were given the recorded data and that script, each with a different brief: re-derive it independently, find what would make a real run cost more or fail, and find a cheaper way. All three rated it "usable with corrections" and reproduced its central figures to within a few percent; one predicted the longest window from the others' data and was 4.7 percent low. Their full text is in [`../records/cloud/pilot/pilot_estimate_review.json`](../records/cloud/pilot/pilot_estimate_review.json).

| # | Point | Raised by | Outcome |
|---|---|---|---|
| 1 | The fitted slope against closure size is below the physical cost of importing | Re-derivation, operations | Accepted. The slope now comes from the import probes (step 1 above) |
| 2 | The per-library correction leaned on two libraries seen only 327 and 92 times | Re-derivation | Accepted. Expected is uncorrected; the low case uses a shrunk correction |
| 3 | Utilisation was averaged over a window with a narrow tail, and a separate allowance covered the same idle time again | Re-derivation, operations | Accepted. Utilisation is measured inside one window; the allowance for the top of the graph fell from 0.8 to 0.4 hours |
| 4 | Disk was priced twice: once inside the hourly rate, once as a separate 2 TB volume | Operations, cheaper | Accepted. Machine and disk are now priced separately |
| 5 | The range covered estimation noise only, not a failure and a restart | Operations | Accepted. The high case carries three hours of slack |
| 6 | The pilot is not a random sample: about 3 percent of modules have a closure larger than any it compiled, and modules deep in the graph are under-represented | Re-derivation, cheaper | Accepted in the high case. It remains the largest unmeasured part of the estimate |
| 7 | A 2 TB disk does not fit the 500 GB quota in the only region where the machine could be had | All three | Addressed by deleting setup files as modules finish; see section 9 |
| 8 | The last six modules would exceed the per-process limits on memory mappings and open files, at about 6 per imported module | Operations | Checked and not upheld. The figure of 6 divided by Mathlib's module count alone; a process also imports the 1,801 modules of Lean's own library. A running compiler process was inspected directly: it had mapped 53,122 files for about 11,300 imported modules, which is 5 per library module and about 1 per project module ([`../records/mac-build/mapped-files-sample.txt`](../records/mac-build/mapped-files-sample.txt)). That projects to about 240,000 for the last module; the regression in section 8.1 projects 430,000. The limit set by the pilot is 1,048,576. A full run should still raise it, since that costs nothing |
| 9 | Spot pricing and the 128 GB machine would cut the cost by more than half | Cheaper | Recorded as options in section 8.2. Neither was measured |
| 10 | One checker process per module imports Mathlib 175,187 times. Checking many modules per process could halve the replay | All three | Taken up later, for a different reason. The saving the reviewers saw was the repeated import; the larger cost turned out to be the stock tool listing every compiled file before each check, which is now avoided without changing the tool (section 8.5). A program that replays many modules per process also exists, as an optional second replay |
| 11 | Run the checker alongside the build to use idle CPU | Cheaper | Not adopted: a gain of under an hour for more moving parts |
| 12 | The count of finished compiles dropped unnamed and repeated rows | Re-derivation | Accepted. 29,606 compiler processes finished; they cover 29,388 distinct named modules. The review also exposed a fault it did not name: the rule that drops processes killed at the end of a time-boxed window was also dropping the last modules of the two windows that ran to completion, among them the largest closure compiled. Fixed; the totals did not change |

After the script was revised, three further AI agents checked it and these notes against the recorded data: one recomputed every figure, one read and exercised the code, and one read as a stranger with only the repository. They corrected one transcription slip, several places where "measured" was said of an extrapolation, and the script's handling of a pilot shaped differently from this one. None of the estimate's figures changed. Their findings are in [`../records/cloud/pilot/pilot_estimate_check.json`](../records/cloud/pilot/pilot_estimate_check.json).

### 8.4 What the estimate does not cover

- **The top of the import graph.** No module with more than 17,860 project imports was compiled. About 3.3 percent of the tree is above that, from a sample of 8,000; two reviewers counted exactly and agree on 27 modules above 50,000 and 13 above 100,000. The projections for them in section 8.1 are straight-line extrapolations.
- **Criterion C2.** The traversal of every dependency of the final theorem has never been run on the full tree. Its time and memory are unknown; the allowance is half an hour, two hours in the high case.
- **A machine where the compiled files do not fit in memory.** See section 8.2.
- **A genuine failure.** A module that fails to compile ends the estimate's relevance: the work becomes diagnosis.
- Tax, network egress and the cost of keeping results in a bucket. Small.

### 8.5 Correction: the kernel replay

Step 4 above took the cost of one kernel check, 8.1 seconds plus 0.263 per 1,000 imports, from the pilot, where 29,633 modules had been compiled, and applied it to a tree of 175,187. An audit of the full-run driver on 2026-11-20 found that the cost of a check with the stock tool is not fixed: `leanchecker` lists every compiled file on the search path before each check, so a check gets dearer as the tree is built. [`performance-notes.md`](performance-notes.md), section 10, has the measurements, the fit, and what was tried.

[`../analysis/replay_cost.py`](../analysis/replay_cost.py) redoes the arithmetic from the recorded runs (`python3 analysis/replay_cost.py`, one second; output in [`../records/cloud/replay_cost.json`](../records/cloud/replay_cost.json)). With the build and the allowances of section 8.2 unchanged, on `n4d-highmem-32` on demand with the 440 GB disk:

| Kernel replay of every module by | Case | Build | Kernel replay | Set-up, C2 and slack | Billed hours | USD |
|---|---|---|---|---|---|---|
| `leanchecker`, the whole library on its search path | Low | 13.7 | 45.7 | 0.5 | 59.9 | 112 |
| | Expected | 15.6 | 45.7 | 1.5 | 62.8 | 118 |
| | High | 17.9 | 48.8 | 6.0 | 72.7 | 136 |
| `leanchecker`, only the module's import closure on its search path | Low | 13.7 | 8.5 | 0.5 | 22.7 | 43 |
| | Expected | 15.6 | 8.5 | 1.5 | 25.6 | 48 |
| | High | 17.9 | 9.6 | 6.0 | 33.5 | 63 |
| `rhv-replay`, a second program (with `leanchecker` on 2,000 modules after it, as an earlier design had it) | Low | 13.7 | 6.8 | 0.5 | 21.0 | 40 |
| | Expected | 15.6 | 6.8 | 1.5 | 23.9 | 45 |
| | High | 17.9 | 7.8 | 6.0 | 31.7 | 60 |

The first three rows rest on two measurements of the stock tool and a straight line through them, whose slope is 0.144 milliseconds per compiled file on the search path. The middle three apply that same line to a search path of 10,452 library files plus the module's own imports, with an assumed 60 microseconds to make and remove each hard link. On a rented machine that way of running the tool has been timed once, in the sixth rehearsal, on modules that import 9 others on average (add `--closure-run records/cloud/full-rehearsals/full-rehearsal-20261121-113516` to the command above). In its trial at 32 at a time a check took 4.65 seconds of one job's time, or 4.56 by the seconds recorded per check; the same trial of the third rehearsal, with the whole library of 12,244 files on the path, took 4.57 and 4.66. The line predicts 6 percent less for the shorter path, so this run came out 4 to 8 percent above the line, which is within what a trial and a main pass of one run differ by. If that held for the whole tree the replay would take 8.8 to 9.1 hours, not 8.5; and the line itself gives 8.9 if its first point is taken from the third rehearsal's trial in place of its main pass. What the links of a deep module cost, and what replaying one costs, has not been measured on a rented machine. The last three use the cost of `rhv-replay` as measured in the fifth rehearsal, 3.1 seconds of one job's time per module at 32 at a time (the command above with `--driver-run records/cloud/full-rehearsals/full-rehearsal-20261120-235539`), plus the stock tool's allowance for deeper modules; that measurement also brackets the first rows between 43 and 56 hours. No replay has been run on a full tree by any of the three.

What follows from it:

- The stock tool as first run does not fit the 42-hour limit of `launch full`.
- The stock tool with import-closure directories should fit with room to spare, and it is what the full-run driver now does. It keeps criterion C3 exactly as registered: `leanchecker`, on every module.
- `rhv-replay` is kept as an optional second replay of every module (`GCP_SECOND_REPLAY=rhv-replay`, about six hours more). Using it in place of `leanchecker` would have needed a dated amendment to `PREREGISTRATION.md`. One was drafted on 2026-11-21 and not made, because its review pointed to the second row of the table ([`performance-notes.md`](performance-notes.md), section 10).
- Whatever the method, the driver measures the replay's rate in short trials before the main pass. If that rate cannot cover the tree in the time left, it gives the replay one hour and goes on to the remaining steps, and `facts.json` says so, in place of running for hours towards a result it cannot reach.

### 8.6 A cap of 50 USD, and what fits under it

On 2026-11-21 three things were settled: the direction of section 8.5 (criterion C3 stays as registered, checked by `leanchecker` on every module), no second replay in the full run, and no seeding of a cloud build with the Mac's compiled files. The spending cap was set at 50 USD in total. After the sixth rehearsal the ledger records 9.86 USD.

The launcher refuses to create a machine unless the cap covers recorded spend plus that machine's worst case. For `launch full` the worst case is 2.00 USD an hour for the 42 hours after which Google deletes the machine, and for the two minutes more that the ledger may record: 84.07 USD. So under a cap of 50 the full run as designed does not start; it would need a cap of about 94. A shorter time limit does not rescue it. What is left under the cap buys about 20 hours of this machine at the ledger's rate, and the lowest estimate for the run is 22.7.

While the sixth rehearsal was running, before its cost or its timings were known, nine AI agents looked at what else could be done ([`../records/cloud/cap_options_review.json`](../records/cloud/cap_options_review.json)). Four analysed one way forward each (A to D below) and four more checked one analysis each, independently. The ninth looked for what was missing, added further ways, which no other agent checked, and ranked them all. All were read-only and none ran anything in the cloud. Their figures assumed 9.73 USD spent; those in the table are recomputed for 9.86. **None of these ways has been tried, every whole-tree figure is a projection, and no choice has been made.**

| Way forward | Cap it needs | Expected further spend, USD | What it takes | What could go wrong |
|---|---|---|---|---|
| A. As designed: `n4d-highmem-32` on demand | About 94 | About 51 at the ledger's rate (45 to 67) | Nothing new | Section 8.4, and nothing can be resumed: any fault costs the whole run again. It does not fit a cap of 50 |
| The same machine at Spot prices, as a single attempt, with the time limit cut to about 33.5 to 35.5 hours (added by the ninth agent; not checked) | 50 | About 29 to 30 at a ledger rate of 1.15, with its rehearsal | One flag in the launcher, a shorter limit, a lower ledger rate, one rehearsal | Google can take a Spot machine back at any moment and publishes no rate for how often. The driver cannot resume, so the attempt and what it had cost would be lost. The guest stops an hour before the limit, at about 32.5 to 34.5 hours, around the high estimate of 33.5: in the high case the replay could be cut short and C3 left unanswered |
| B. Spot, with the driver changed so that it resumes after the machine is taken back | About 57 to 61 at 42 hours, with its rehearsals | About 30 to 33 | New code for re-entry, restart and the seal, with reviews and several rehearsals; a lower ledger rate | Fits a cap of 50 only near the expected case. If the machine is stopped rather than deleted so that it can resume, the cap no longer bounds spend: its disks bill about 2 USD a day until teardown, and nothing restarts it while the local machine is offline |
| C. The 128 GB machine (`n4d-standard-32`) at Spot prices | About 46 to 48 | About 22, before any penalty | The Spot flag and a lower ledger rate | What happens once the compiled files no longer fit in memory has never been measured (section 8.2), and nothing bounds it. If memory runs short the axiom check, which is given two hours at most per run, may time out and leave C2 unanswered, and the run may reach its deadline without C3. A single attempt |
| A cheaper machine family at Spot prices, inside the same quota (added by the ninth agent; not checked) | About 35 at 42 hours and a ledger rate of 0.60, which would leave room for a second attempt | About 14 to 17 | The Spot flag, a lower ledger rate, a rehearsal on that family | Nothing about such a family has been measured here: the speed factor is a guess, the machine shape and its disk support are not in the records, and its quota may be zero. Its high case, 36 to 45 hours, can pass the guest's stop at 41 hours and leave C3 unanswered |
| D. No full cloud run: finish on the Mac | None | 0 | Nothing new. The replay that counts must start after the build, from an empty results file. A system limit on open files (`kern.maxvnodes`) has to be raised by hand, and again after any restart | Time: about 2 to 3 days more for the build (40 hours at best, 6 days or more if the top of the import graph pages heavily), then from about 4 days to about 6 weeks for the replay, which has been timed there only two at a time on a busy machine. If the top of the import graph cannot be built in 24 GB the outcome is INCONCLUSIVE under the pre-registration, unless a cloud run follows. One platform only, so the supplementary goal of a second platform is not met |

Each Spot cap assumes the ledger rate in `config.env` (`GCP_RATE_USD_PER_HOUR`) lowered from 2.00 to a little above the Spot rate for the machine and its disks: 1.12 to 1.15 for `n4d-highmem-32`, 0.87 to 0.90 for `n4d-standard-32`. At 2.00 none of them fits a cap of 50.

Way B has since been built, differently from the sketch in the table: every attempt is a fresh machine and nothing is kept in Compute Engine between attempts, so the cap bounds the spend whatever happens, and each attempt is sized to what the cap leaves. Section 10 describes it. It has been rehearsed once and not run in full.

The ninth agent ranked first a way that is a sequence, not a method: spend nothing more for now, let the Mac build finish, and decide about a cloud run once it is known whether the Mac gets through the top of the import graph and compiles everything. Its reasoning was that the wait costs nothing, the Mac build is running in any case, and what is left under the cap is then spent, if at all, with that knowledge. It ranked last but one a combination, building in the cloud and replaying on the Mac: at or over the cap, with the weeks of Mac replay still to come.

Three things in the record apply to any cloud run. The cap is enforced on the launcher's ledger, which counts 2.00 USD an hour where the list price with disks is about 1.87, so the 9.86 recorded is somewhat more than the list price of the machine time; tax, network egress and bucket storage are outside it, and the bill is authoritative. The guest never powers itself off: a run costs its expected amount only if `watch` is still running on the local machine when the guest finishes; otherwise the machine runs to its deletion time and the worst case is what is spent. And for Spot: the rates used are those of `us-central1` read on 2026-11-20 and can change daily; a machine of this type is not always to be had in the zones tried first (on 2026-11-21 four zones of `us-central1` had none, and the rehearsal ran in `us-east1-b`); and preemptible quota must not be requested, because Spot then stops drawing on the standard quota and that cannot be undone.

## 9. The full run: what was built, and what a review changed

The pilot scripts stop short of a full run by design. After the pilot, a driver for the full run was written: [`../cloud/gcp/full_guest.sh`](../cloud/gcp/full_guest.sh), with two new modes in the controller, and [`../cloud/gcp/README.md`](../cloud/gcp/README.md) describes it. **It has been rehearsed six times, the sixth time as it stood before the Spot code of section 10 was added to it, and had not been run in full when this was written.** With that code switched off the script does what it did in the sixth rehearsal, by review and by a local comparison (section 10.6), but in the on-demand modes it has not been rehearsed since. With that code switched on, the same phases ran in the Spot rehearsal of section 10.7. The reviews below are criticism of code; the rehearsals are measurements, of a build of about one module in a hundred.

| Need, from the pilot | Why | State |
|---|---|---|
| Delete each module's setup file once the module has finished | Without it the setup files alone come to 1.1 to 1.3 TB, on top of about 0.13 TB of compiled output. With it the peak is about 150 GB, which fits the pilot's disk and needs no quota increase | Written and confirmed on real modules. In two rehearsals, deleting the setup files of 641 and 644 finished modules and restarting the build tool recompiled none of them, as did a plain restart used as a control, while over 300 new modules were built each time. The full run repeats the test on its first 3,000 modules and stops if a finished module is recompiled |
| Raise `vm.max_map_count` and the open-file limit well above one million | Costs nothing; removes the question in point 8 above | Written |
| Move from build to the C2 checks to the kernel replay without waiting for a person | An idle machine of this size costs about 1.86 USD per hour | Written |
| A kernel replay that can be resumed and that includes the 114 modules whose name is a prefix of another's | A replay of many hours must survive an interruption, and criterion C3 is every module | Written. With import-closure directories (section 8.5) such a module is checked like any other; when it imports modules beneath itself the tool replays those in the same process, and the record says so. The separate prefix pass that `scripts/09_kernel_replay.sh` first ended with, each such module replayed in one process with the modules beneath it, is now the fallback of `--whole-library`. Both were tested on a small project, and the prefix pass by hand on two real prefix modules of the local build |
| Upload results as the run goes, and a status the local `watch` can read | The machine deletes itself; anything not uploaded is lost | Written |
| A deletion time and a spending cap sized for the run | The pilot's cap and six-hour limit are too small by design | Written: 42 hours, and `launch full` is refused until the cap in `config.env` allows for it. Section 8.5: that limit holds a run whose replay shows each `leanchecker` process only what its module imports, not one that puts the whole library on the search path |
| A kernel replay that fits the run | Section 8.5: the stock tool, with the whole library on its search path, needs about 46 hours for the replay alone | Written: each `leanchecker` process is given a directory of hard links to the compiled files of its module and of what that module imports, and nothing else of the project (`scripts/09_kernel_replay.sh`, `rhv_tools.py closure-worker`). Tested on a seven-module project and on real modules of the Mac build, and rehearsed once on a rented machine, on 1,662 shallow modules (the sixth rehearsal, below). A second program, `rhv-replay`, can replay every module again afterwards; root builds it during setup, before any file of the proof is compiled, after comparing its copy of the replay function with the toolchain's source |
| A short rehearsal of all of the above | The pilot's rehearsal found faults that review had not | Done six times, for 3.47 USD in all; see below |

Four AI reviewers read the first draft before anything was launched: shell correctness, cloud control and cost, whether the pipeline establishes what it claims, and the verification scripts. They found two blockers and twelve major defects. Their text is in [`../records/cloud/full_run_driver_review.json`](../records/cloud/full_run_driver_review.json). The ones that shaped the design:

| Finding | What was wrong in the draft | What the script does now |
|---|---|---|
| Results could be planted before the checks ran | The directories the checks write to belonged to the build user during the build and were only handed over, not emptied. Code run at compile time could have left a results file saying every module had passed, and the replay would have skipped them all | Those directories are deleted and made afresh at the seal, after the build user's account is locked. Nothing under the working directory may be owned by anyone but root at that point, or the run stops |
| The prefix pass could exhaust memory | The checker starts one task per module and each imports its whole closure. With many worker threads those imports are held at once: 17.5 GB measured for a module with twelve small modules beneath it, against 0.2 GB with one worker. The largest prefix module has 119 beneath it | The prefix pass runs the checker with one worker thread and at most eight at a time. Measured wall time was unchanged |
| The axiom check could interfere with the kernel replay | Both ran as one user. The axiom check runs the Lean frontend on a file that imports the proof, which executes any initialisation code the proof declares; that code could have written the replay's results | They run as two users, and neither can write where the other's results go (both can use the system's temporary directories). The replay's own tool loads compiled files as data and runs none of their code |
| The toolchain could be swapped under the checks | Its files were given to root but its parent directory still belonged to the build user, who could have renamed it | The checks use a copy made under a directory only root has written, proved identical to the toolchain as first installed. The compiled files, the toolchain and Mathlib are hashed again after the checks, and any change voids them |
| A killed process would be reported as a failed proof | A compiler or checker killed for lack of memory was counted like a Lean error, and the run would have said criterion C1 or C3 was not met | An exit status of 128 or more is recorded as killed, counted as not yet checked, and tried again with fewer jobs. The run's messages distinguish the two cases, as section 4 of the pre-registration requires |
| The second build pass was unwatched | If the first pass failed early, most of the tree was left for the retry, which ran with no pruning and no disk check: the disk would fill and the run would report a failed build | Both passes run under the same monitor |
| Completeness was judged by counts | A compiled file with no source could have stood in for a missing module | Sources and compiled files are compared by name; a compiled file named like a library module stops the run |
| A full run was not tied to what ran | The guest script was read from the working tree, and an untracked file passed the check for uncommitted changes | The guest script and the scripts archive both come from the current commit, the working tree must be clean, and the guest records the SHA-256 of the script it actually ran |
| One keystroke could destroy a day's work | Interrupting `watch` tore the machine down, which is right for a pilot | For a full run it only stops watching |
| Uploads could fail silently, or collide | A final status that failed to upload was never retried, leaving the machine billing until its limit; two uploads could share one temporary file | Uploads retry with a fresh token and report failure; the final status is re-sent every minute; each upload has its own temporary file; evidence is uploaded as each phase ends, not only at the end |

The rewrite was then reviewed again by two agents ([`../records/cloud/full_run_driver_recheck.json`](../records/cloud/full_run_driver_recheck.json)). They confirmed twelve of the thirteen earlier blockers and major findings as fixed and one as partly fixed, and found two new blockers and four major defects, also fixed before anything ran:

| Finding | What was wrong | What the script does now |
|---|---|---|
| The kernel replay and the axiom check could be shown different contents | The replay tool reads a module's `.olean.private` part when one exists; a file that imports the module reads only its `.olean`. This project's build writes no such parts, so one planted beside a compiled module would have been replayed in place of the file every other check reads, and it was neither hashed nor refused | At the seal, anything beside the compiled modules other than the five kinds of file the build writes stops the run, and every file there is hashed, then and at the end. `scripts/09_kernel_replay.sh` reports such parts too, and they block "complete" |
| The local watcher could tear down a run after one network blip | Any failure to fetch the status, for whatever reason, was read as "the guest has reported nothing" | A missing status counts only if no status has ever been read, the bucket itself says three times running that the object does not exist, and 25 minutes have passed |
| Symbolic links were invisible to the comparisons | The manifests listed regular files only. A link added to the toolchain's library directory would have survived the comparison and the copy, and the checkers would have loaded whatever it pointed to | Manifests list links and other non-files with their targets, and the sealed toolchain may contain no link that leads out of it |
| Root could be made to wait for ever | Root read result files from a directory the axiom check's user owns; a named pipe planted there would have blocked the run until its deadline | Root copies only plain files from such directories, with a time limit, after every process of that user is gone |
| A dead build tool would have been called a failed proof | If the build tool itself was killed, with no failed module, the run reported "failed twice with Lean errors" | That case ends as a failure of the run. A compiler that crashed by itself is now told apart from one killed from outside |
| The rehearsal would have looked green without testing much | Its time limits were too tight for the restart tests, the periodic pruning and the archive to run | The rehearsal's time box excludes the restart tests, pruning runs every two minutes in it, and the facts record whether each restart test built anything and whether the archive was made |

**The replay method.** When the audit of section 8.5 led to a second program for the kernel replay, `rhv-replay`, the driver was changed to offer it as the tool for the whole tree, and that change was reviewed in its turn before anything ran (the driver has since gone back to `leanchecker` for the whole tree; see the end of this part): five agents, then five more to re-check them ([`../records/cloud/replay_method_review.json`](../records/cloud/replay_method_review.json)). They reported 23 findings, none of them a way for a module to be counted as passed without a replay. Those that changed the driver:

| Finding | What was wrong | What the script does now |
|---|---|---|
| A kernel rejection could be filed as "not checked" | A check that cannot open a compiled file is tried again later, and that case was recognised by searching the whole error for phrases such as "No such file or directory". A kernel error quotes names the author of a module chose, so a rejected declaration with such a name would have been retried for ever and never shown as a failure | Both methods look only at how the error begins, which the tool's own file handling writes. Anything else is a failure |
| Time kept for the stock tool's sample could cost the main replay | If the main pass and the sample together did not fit, the main pass was cut to one hour, though it would have fitted alone | Whether the replay fits is decided on the main pass alone, and the main pass comes first; the sample and the prefix pass take what is left, and `facts.json` records it |
| The measured rate counted checks that never ran | A trial's rate counted every result line, including those of checkers that were killed or could not start, so the worst job count could look best | Only lines of modules that were really checked count |
| The replay program was built with the build user's copy of the toolchain | Root ran the build tool from a directory the build user could write, and only the result was recorded | Root first makes its own copy of the toolchain, proves it identical to the record taken before anything was compiled, and builds with that; the program may load shared libraries only from the system or from that copy |
| A process that died before starting was charged to a module | Every module of its batch was then recorded as a crash of the checker, which counts as a failure | The program announces each module before it starts on it. A death is charged only to a module that had been started; a death before the first leaves the batch for later |
| The source check proved less than it said | It compared the copied function and nothing around it, so an attribute on the line above could have swapped the function out; and, as a second look found after the first fix, a file whose visible contents all sat inside a nested comment could still pass | The program's source must have the SHA-256 written in `rhv_tools.py`, so it cannot change without that line changing in the same commit; the function must be the installed toolchain's, character for character; and the file's shape is checked as well. That the remaining loop does what it appears to do is for a reader, and the documents say so |
| The watchdog could cut off the final report | At the deadline it ended every time-limited command, including the one inside a report already under way | It leaves a report alone, and waits longer for one that has begun |

The changed code was then looked at again by four agents, with four more to re-check them ([`../records/cloud/replay_method_recheck.json`](../records/cloud/replay_method_recheck.json)): 18 of the 23 findings resolved, 4 in part, one left by decision and stated as a limit, and 22 new findings, half of them about the documents. Those in the driver were small and are fixed: root's copy of the toolchain is checked for links that lead out of it before anything is built with it; the summary's two files are replaced together and only by a run that succeeded; and `facts.json` says why a pass of the stock tool did not run when it did not.

A third review, on 2026-11-21, was of a draft amendment to the pre-registration that would have made `rhv-replay` the tool for every module ([`../records/cloud/c3_amendment_draft_review.json`](../records/cloud/c3_amendment_draft_review.json)). It found that the scripts let a rejection be erased by a later passing run, or by compiling the module again, and tied results to no particular program; and it pointed out that the stock tool's cost came from what was on its search path. The amendment was not made. The scripts now keep every result, never count a module as passed once any tool has rejected or crashed on it, record the program behind every result line, and run `leanchecker` on every module with only that module's imports on its search path. The driver was changed to match: `leanchecker` is the replay, `rhv-replay` an optional second one, and at the seal root lifts the system's rule against hard links to files of another owner so that the replay's user can make those directories. That last change was rehearsed once, in the sixth rehearsal, on 1,662 shallow modules (below).

A fourth review, the same day, was of that changed code ([`../records/cloud/closure_replay_review.json`](../records/cloud/closure_replay_review.json)): 21 findings, none a way for a module to pass without a replay ([`performance-notes.md`](performance-notes.md), section 10). Three were about this driver. The optional second replay ran before a deferred deep walk of the axiom check and could have used up its time; the deep walk, which is part of criterion C2, now comes first, and the second replay is not run at all when `leanchecker` could not cover the tree. `facts.json` gave the second replay's two answers as false when it had not run; they are now null, with the reason beside them. And `facts.json` stated how `leanchecker` had been run as a fixed sentence; it now reports the count of passes by the way each was run, as the result lines record it, with the time the main pass was allowed and the number of passes. The count of modules still to check, which decides whether another pass is made, is now the one the planner itself would select. A second look at those changes ([`../records/cloud/closure_replay_recheck.json`](../records/cloud/closure_replay_recheck.json)) found the four points about this driver resolved and nothing new in it.

Two limits remain and are stated in the script's header. The axiom check's own output comes from a process that has imported the proof. And "no network" for the three unprivileged users means no connection off the machine: name lookups through the system resolver are not blocked. The machine holds nothing worth sending, since its credentials are behind the metadata server, which is blocked, and the proof source is public.

On the first of these: a text scan of the source found no file or process IO at all, and the kernel replay does not share the exposure, but the `#print axioms` half of criterion C2 can be no more trustworthy than the process that produces it.

**The rehearsals.** Each ran the driver with the build boxed at seven minutes. Their records are in [`../records/cloud/full-rehearsals/`](../records/cloud/full-rehearsals/).

| Rehearsal | What happened | What it changed |
|---|---|---|
| First, 2 minutes | Stopped itself in setup: a new check that a build leaves Mathlib's compiled files untouched found five files changed | They were the build tool's own `.hash` bookkeeping, which it rewrites and no check reads. The comparison now leaves `.hash` and `.trace` files out |
| Second, 15 minutes | Ran every phase. The restart tests, the pruning, the seal and the end check all worked. Both checks then failed with "Permission denied": Mathlib's cache is unpacked readable by its owner only, and the seal had given it to root without read permission for the users that run the checks. The replay recorded 1,710 modules as failed although no checker had checked anything | The seal adds read permission and refuses an unreadable file. Each checker user must now do one real piece of work in the sealed environment before the checks start. A checker that cannot open a compiled file is recorded as not having run, not as a failed module |
| Third, 17 minutes | Ran every phase, and each step did what it should: 1,792 modules built with no failed job; no finished module recompiled in either restart test; seal and end check clean; the axiom probe passed, plain and deep; all 1,792 modules passed the kernel replay | Nothing |
| Fourth, 11 minutes, the first with `rhv-replay` | Setup built and tested the replay program; the build and restart tests ran as before. The seal then stopped the run: a compiler cut off in mid-write by the time box had left a half-written file, `<module>.olean.tmp.<pid>`, beside the compiled modules, and the seal refuses any file there that the build tool does not write | The seal lists, removes and counts exactly those files first. A full run kills compilers in its restart tests, so it could have met the same fault after the whole build |
| Fifth, 16 minutes | Ran every phase, and each step did what it should: 1,794 modules replayed by `rhv-replay` at 10.4 a second, all passing; 150 of them replayed again by the stock tool with the same verdict on each; the two compiled files the build tool never finished left out and reported; seal and end check clean; the axiom probe passed, plain and deep | Nothing |
| Sixth, 21 minutes, the first with `leanchecker` on every module and import-closure search paths | Ran every phase, and each step did what it should: 1,662 modules replayed by `leanchecker`, each process with only its module's imports on the search path, at 6.9 a second in the trial at 32 at a time, all passing; the same 1,662 replayed again by `rhv-replay`, all passing; the one compiled file the build tool never finished left out and reported; the seal removed a real half-written file as well as the stand-in; seal and end check clean; the axiom probe passed, plain and deep | Nothing |

Neither review had caught the permission fault. A rehearsal is not a full run either: it builds modules from the bottom of the import graph only and does not reach a failed build, the second build pass, the completeness check, the axiom check on the final theorem, a module that imports thousands of others or one that imports modules beneath itself, the fallback prefix pass, or the deadline. Those remain reviewed and, where possible, tested on a small project.

Two things were changed after the sixth rehearsal and have been tested only locally. The launcher's cap test now counts the two minutes that the ledger can record past a machine's deletion time. And the replay script hands fewer modules to a worker when a pass is short, so that every job has work: the rehearsal's main pass of 635 modules had made 26 workers where 32 were allowed. The driver's estimate of how long the replay will take is throughput times modules; it leaves out a pass's planning, start and tail, and the margin of an eighth that it keeps before an early deep walk is what absorbs that.

Two optional tests could lower the cost: the kernel checker at 16, 24 and 32 at once, which the full run now does in its first fifteen minutes of replay, and the kernel checker given many modules per process. The second exists as `rhv-replay` (section 8.5), an optional second replay; the criterion's own replay stays with `leanchecker`.

## 10. A full run on Spot machines that survives being taken back

Section 8.6 left a full run without a way to fit under the cap of 50 USD. Its way B, a Spot run that resumes, has since been built, in a different shape from the one sketched there. **It was rehearsed once on rented machines, on 2026-11-22 (section 10.7), and had not been run in full when this was written. Sections 10.1 to 10.6 are design, local tests, review and a cost model, and were written before the rehearsal.** The model is [`../analysis/spot_resume_model.py`](../analysis/spot_resume_model.py), its output [`../records/cloud/spot_resume_model.json`](../records/cloud/spot_resume_model.json).

### 10.1 The design

A Spot machine costs about six tenths of what the same machine costs on demand, and Google may take it back at any moment, with about thirty seconds' notice or none. The run is therefore a chain of *attempts*. Each attempt is a fresh Spot machine that Google deletes, with its disks, when it takes the machine back or at the attempt's own time limit. Nothing is kept in Compute Engine between attempts, so between attempts nothing there bills, and the difficulty section 8.6 named for way B (a stopped machine whose disks bill outside the cap) does not arise. What carries the work from one attempt to the next is in the project's private bucket, under `ckpt/RUNTAG/`:

| Object | What it is | When it is written |
|---|---|---|
| `part-NNNNNN.tar.zst` | An archive of the compiled files of modules that have finished since the last part | Every ten minutes during the build, and when the build ends |
| `manifest.tsv` | One row per part: its number, SHA-256, size, how many modules it holds, and which attempt cut it | After each part is in the bucket |
| `state.json` | Every decision and result so far: which units of the run are complete, the values a later machine needs, one entry per attempt | After the manifest, and after each completed unit |
| `baseline_*.txt.gz`, `seal/*.txt.gz` | The first attempt's fingerprints of the source tree, the toolchain and Mathlib's compiled files, and the seal's fingerprints | Once |
| `c2/*.json`, `results/NNNNNNNNN.tsv.gz` | The axiom check's summaries and the kernel replay's result lines so far (one object per save, named by its count of lines) | Only after a confirming hash (10.2) |

The order is always part, then manifest, then state. Whatever is in the bucket after a cut is then consistent: a part the manifest does not list is ignored, and a unit the state does not record as complete is run again in full. A later attempt installs everything again on its fresh machine, proves that its source tree, toolchain and Mathlib files are identical to the first attempt's, fetches and checks the parts, extracts them, and carries on from the stage the state records: the rest of the build, the seal, the axiom checks, or the replay from the results already saved.

On the local machine, `watch` accounts for each attempt that ends and starts the next, checking the cap again every time. It pauses the run, with nothing running and nothing lost, when the cap, a give-up time (120 hours after the first launch), a limit of 24 attempts, or three attempts in a row without progress says so. `watch` run again continues from the state file, the ledger, the Compute API and the bucket.

**Where Google Drive fits.** The request was for results streamed to the owner's Google Drive. The checkpoints go to the project's bucket instead, and the reasons are these. A machine's own service account cannot own files in a personal Drive; to write there the machine would have to hold the owner's personal sign-in token, on a machine that runs the proof's code at compile time and whose design goes to some length to keep credentials away from that code. The checkpoints come to an estimated 40 GB in hundreds of objects, which a bucket in the machine's own region takes at disk speed and without transfer charges, and which the Drive interface rate-limits. And the next attempt must read exactly what the last one wrote, checked against a SHA-256 the launcher recorded; a bucket gives that directly. What does go to Drive is the part a person wants to see: with `GCP_RESULTS_MIRROR_DIR` set to a folder that Google Drive for desktop syncs, `watch` copies the status, the facts file, the logs and each attempt's small results there every ten minutes and at the end of every attempt. The Drive credential stays on the owner's machine. The parts themselves are not mirrored; copying them out of Google's network would cost about 0.12 USD per GiB at list price, and they are only needed until the run ends.

### 10.2 What crosses from one machine to the next

An uninterrupted run rests on one machine: the same disk from the build to the end check, with the compiled files fingerprinted at the seal and again at the end. A chain of machines has to earn the same statement. The rules:

| What crosses | How the next machine knows it is what was written |
|---|---|
| The state and the manifest | After every attempt, once the Compute API has confirmed the machine gone, the launcher downloads both and records their SHA-256. The next machine is created with those two values and refuses any other state or manifest |
| A part | Its SHA-256 and size are in the manifest. The build user makes the archive, on its own tree; root reads the archive from a file root opened, lists and hashes what it holds, and uploads it. A restore refuses anything but regular files under the two build directories and never writes through an existing file or a link |
| The compiled files as a whole | At the first seal, on the sealing machine, the parts taken in order must reproduce exactly the files the seal has just fingerprinted, path by path and hash by hash. Files they lack or hold differently go into one repair part, cut by root; then they must match, or the run ends. Every later attempt seals what it restored and must arrive at the first seal's fingerprint, or the run ends |
| A result of a check | Results leave a machine only after a *confirming hash* on that machine: the compiled files, Mathlib's and the sealed toolchain hashed again and found identical to the seal's, with no process of the build user seen since the seal. The copy of the results that is uploaded is taken before the hash starts, so every line in it was produced before a moment at which the inputs were shown unchanged. Each saved copy goes up under its own name, and the state records that name and the copy's SHA-256, which the next machine checks. A unit of the run (each axiom check, the replay's trials, the main replay) is recorded as complete only after such a hash. When a machine is taken back, nothing unconfirmed is carried over: about a quarter of an hour of replay is done again on average, half an hour at most |
| The source tree, toolchain and Mathlib | Fingerprinted on every machine before anything is compiled or restored, and compared with the first attempt's; any difference ends the run |

So everything a later machine takes from the bucket is checked against a SHA-256 that the state or the manifest records, and those two against the values the launcher recorded on the owner's machine. The end check of an uninterrupted run is kept as it is, on whichever attempt finishes: everything hashed once more, and any change, or any sighting of the build user on any attempt, voids the checks. A failure found by a confirming hash or by the end check is final whatever else is happening; it is never turned into a pause.

What remains different from an uninterrupted run, and should be said wherever a Spot run's result is reported: the compiled files were produced on several machines and the result lines on several more; the statement that they are one consistent set rests on SHA-256 comparisons made by root's script on each machine and by the launcher between them, and on the bucket returning what was stored. The files under each attempt's own `attempt-N/` prefix are that machine's logs and working copies, uploaded as they stood; only what the state records, saved after a confirming hash, is carried between machines.

### 10.3 What a reclaim costs, and where thrashing begins

Each reclaim costs a fresh machine's setup, the restore of what was saved, and the work since the last save. In the model:

| Where the reclaim falls | Setup and restore, hours | Work done again, hours | Lost per reclaim, hours |
|---|---|---|---|
| The build (15.2 hours) | 0.17 | 0.10 | 0.27 |
| The top of the import graph (0.4 hours, taken as one unit that cannot be split) | 0.25 | 0.20 | 0.45 |
| The seal | 0.25 | 0.13 | 0.38 |
| The axiom check, plain | 0.35 | 0.09 | 0.44 |
| The replay's trials | 0.35 | 0.13 | 0.48 |
| The axiom check, deep | 0.35 | 0.29 | 0.64 |
| The main replay (9.1 hours) | 0.35 | 0.25 | 0.60 |
| Weighted by the time each stage takes | | | 0.40 |

So a reclaim costs about 24 minutes on average: about 16 during the build, about 36 during the replay. Google publishes no rate of reclaims for any machine type or zone, so the mean time between reclaims, M, is a free variable here and not an estimate. The run was simulated attempt by attempt, 4,000 times for each value of M, with reclaims arriving at random at that mean rate:

| M, hours | Machine hours to finish, median (nine in ten under) | Attempts, median | Cost at list prices, USD, median | Share of runs that finish under the launcher's rules and the cap of 50 |
|---|---|---|---|---|
| 0.5 | 61.7 (71.2) | 124 | 67.86 | 0 |
| 1 | 39.3 (43.6) | 40 | 43.22 | 0.2 percent |
| 2 | 31.9 (34.4) | 17 | 35.04 | 47 percent |
| 3 | 29.7 (31.7) | 11 | 32.66 | 89 percent |
| 4 | 28.7 (30.5) | 8 | 31.52 | 97 percent |
| 6 | 27.7 (29.1) | 5 | 30.48 | 99.7 percent |
| 8 | 27.3 (28.5) | 4 | 30.00 | 99.8 percent |
| 12 | 26.8 (27.8) | 3 | 29.49 | all |
| 24 | 26.4 (27.1) | 2 | 29.00 | all |
| never | 26.0 | 1 | 28.65 | all |

The same work on demand is 25.6 hours and 47.87 USD at list prices, 51.20 at the ledger's rate, which the cap does not allow at all. There are two cut-offs, and they are far apart:

- **Against the on-demand price.** Spot costs more than on demand only when reclaims come more often than about once every 50 minutes on average (M below 0.81 hours at list prices, 0.88 at the ledger's rates; below 1.0 hours for the unluckiest run in ten). It takes about 44 reclaims in one run to use up the saving.
- **Against the cap.** With 9.86 USD already recorded, as it was when the model was run, the cap leaves 32.6 hours of machine time at the Spot ledger rate of 1.20 USD an hour, against 26.0 needed with no reclaim: room for about 16 reclaims. (The rehearsal of 10.7 has since taken recorded spend to 10.62, which leaves 32.0 hours and room for about 15; the model has not been run again.) Half of the simulated runs finish under the cap when reclaims average one every 2.0 hours, nine in ten at one every 3.1 hours, and 97 percent at one every 4.

A run that meets more reclaims than that is stopped by the launcher's rules, not by a lost run. It pauses with its checkpoints in the bucket and what it has spent recorded; `watch` continues it later, at another hour or in another zone, at the price of the bucket storage in between (about 0.80 USD a month for 40 GB, for which 1.00 USD is held back from the cap). A paused run is not a result of any kind.

How the cut-offs move if the guesses are wrong (hours; the three columns are the M below which Spot costs more than on demand, at which half of the runs finish under the cap, and at which nine in ten do):

| Variant | Dearer than on demand below | Half finish above | Nine in ten finish above |
|---|---|---|---|
| As above | 0.81 | 2.03 | 3.10 |
| Restore twice as slow | 1.11 | 2.61 | 4.26 |
| The deep axiom check takes 2 hours, not 0.5 | 1.06 | 3.03 | 5.25 |
| A confirming hash takes 15 minutes, not 5 | 1.03 | 2.71 | 4.44 |
| Parts every 5 minutes, or every 20 | 0.77, 0.88 | 1.91, 2.22 | 2.99, 3.38 |
| Replay results saved every 10 minutes, or every 40 | 0.76, 0.94 | 2.00, 2.22 | 2.95, 3.58 |
| Reclaims bunched early in an attempt | 0.63 | 2.10 | 4.09 |
| A limit of 12 attempts, not 24 | 0.81 | 2.60 | 3.94 |

The limits of this model are those of its inputs. When the model was run no restore of parts had been timed at all, and still no restore, seal or confirming hash at full scale, no deep axiom check on the whole tree, and nothing at the top of the import graph has been (10.7 sets the model's guesses beside what the rehearsal measured on a small tree); the build and replay hours are the projections of section 8. Reclaims are unlikely to arrive at a steady random rate: they vary by day, zone and hour and may come in bursts when a zone runs short, and on 2026-11-21 four zones of `us-central1` had no machine of this type at all. The model leaves out waits for capacity between attempts, which bill nothing but count towards the give-up time; attempts outside the bucket's region, which pay to move the checkpoints (0.02 USD a GiB each way, counted in the cap's worst case and recorded in the ledger); and the rehearsal of the Spot path, which came out of the same cap (0.76 USD).

### 10.4 The launcher's money rules for a Spot run

The rules of the on-demand modes hold, attempt by attempt, with these added:

- Every attempt has an open ledger row before its machine is created, at most one row is open, and the row and the launcher's own state are forced to disk before the request is sent, so that a power cut on the local machine cannot leave a machine with no record.
- An attempt is over only when the Compute API has confirmed that no instance and no disk remains; until then its row stays open and nothing starts.
- Each attempt's time limit is sized so that recorded spend, with the attempt run to its limit and the worst transfer charge, stays under the cap less the reserve. When what is left would buy less than a minimum attempt (90 minutes), the run pauses.
- A request to create a machine that fails in a way that does not show nothing was created is never followed by a request in another zone: there can be one machine at most.
- One Spot command runs at a time, so that a `teardown` cannot be undone by a running `watch`. The lock is one the operating system holds on a file and releases when the command ends, however it ends, so there is never a stale lock to clear.
- The ledger is rewritten by swapping in a whole new file, never in place, and a ledger found with fewer rows or less spend than the run last saw stops every start.
- A machine reports why it paused: its own deadline, trouble a fresh machine may not have (the next attempt starts), the checkpoints reaching the size the cap's worst case allows outside the bucket's region (no further attempt starts outside it), or a condition that another attempt would meet again (the run pauses and says why).

The ledger records machine time at 1.20 USD an hour for a Spot attempt, a little above the list price of the machine with its disks at Spot rates (about 1.10 on 2026-11-20), and the bill is authoritative.

### 10.5 What was reviewed, and what the reviews changed

The code was written by AI agents to a written design and looked at by others five times before anything was launched; the records are [`../records/cloud/spot_resume_review.json`](../records/cloud/spot_resume_review.json) and [`../records/cloud/spot_resume_recheck.json`](../records/cloud/spot_resume_recheck.json). These are criticism of code, not results.

The first round, five reviewers (money, the integrity of the evidence, the unchanged on-demand path, a walk through every way an attempt can end, and Google's documented behaviour), graded nothing a blocker and thirteen findings major. Those that shaped the design:

| Finding | What was wrong | What the scripts do now |
|---|---|---|
| Results could cross from a machine whose inputs were never re-checked | The replay's results were uploaded as they were produced; the end check, which proves the compiled files unchanged, ran only on the last machine | The confirming hash of 10.2: nothing that is evidence leaves a machine until that machine has shown its inputs unchanged after the evidence was produced |
| The parts were never shown to reproduce the sealed files | A module the build tool rewrote after its part was cut would have been restored stale, and found only by a later machine | Tracking is file by file; a saved output that changes ends the run; and the cover check of 10.2 proves the parts against the seal on the sealing machine |
| A truncated download could end a run for good | The guest's fetch looked at the server's answer, not at whether the transfer completed | Every fetch is checked against a recorded SHA-256 and tried three times; only three complete downloads with the wrong checksum are final |
| Two commands could undo each other | A `teardown` during a `watch` was followed at once by the next attempt | One Spot command at a time |
| The ledger could be left empty | It was rewritten in place; an interruption could truncate it, and recorded spend would have read as zero | Written to a new file and swapped in; a ledger that has shrunk stops every start |
| A create that reported an error could still have made a machine | The next zone was tried at once | No second zone after an unclear error; the machine is looked for in every zone |
| The rehearsal's forced cuts did not test what they claimed | A cut during the build could land before anything was saved, and the cut during the replay could land in the trials | Each cut waits for what it is meant to interrupt, and one of the three is a hard reset with no notice at all |
| The launcher's test passed only on its author's settings | Four cases failed with the default temporary directory of macOS | Fixed, and the test now includes one case that runs the guest's own code against the launcher |

The changed code was checked again four times, each time by fresh agents who were told to refute the fixes, and each time what they found was fixed before the next look:

| Look | By | Major findings | Among them |
|---|---|---|---|
| Second | Three verifiers | 5, with about 15 minor | A setup step that needs the network would have ended a whole run on one bad minute of a package mirror; the count of failed compile jobs of a machine cut without notice was lost; a power cut on the owner's machine just after a create could leave a machine with no ledger row; a rehearsal could finish without one of its cuts and say nothing |
| Third | Two verifiers | 2, in the launcher; none in the guest | The lock, then a directory holding a process number, could end with two holders if two commands found a stale lock in the same instant; a simulated reclaim that Google accepted but never carried out counted as done |
| Fourth | Two verifiers | 3, in the launcher; none in the guest | Two more ways for a rehearsal's cut to be reported as done when a restarted `watch` had lost track of it; `teardown` could act without the lock in the first seconds of a launch |
| Fifth | Two verifiers | None | One minor point in the launcher, since fixed: the very first time a Spot run is launched in a work directory, an old-mode command started in the same instant could still act without the lock. Nothing in the guest |

No look graded anything a blocker. After the third look the lock was replaced by one the operating system holds, which has no stale state to mishandle. After the fourth, the saved replay results, the one thing that had crossed between machines without a recorded checksum, were given one. The fixes that only concern the rehearsal's own reporting matter because the rehearsal is the test of everything else: it now ends with a warning status unless each of its forced cuts was seen to take effect.

### 10.6 What is tested, and what only a rehearsal can show

Three test scripts run on a Mac with no cloud access: [`../scripts/dev/test_spot_checkpoint.sh`](../scripts/dev/test_spot_checkpoint.sh) (the helper that cuts, lists, restores and compares parts), [`../scripts/dev/test_spot_guest.sh`](../scripts/dev/test_spot_guest.sh) (the guest's own Spot code, extracted from the script and run against a pretend bucket and metadata server), and [`../scripts/dev/test_spot_launcher.sh`](../scripts/dev/test_spot_launcher.sh) (the launcher against a pretend `gcloud`, with reclaims, refusals, errors and interruptions injected). In the first of them a small Lake project on this toolchain, with a module that compiles with a warning and one that fails to compile, is built, cut into parts, wiped, restored from the parts and built on: the build tool compiled nothing again and changed no restored file's time, size or bytes. That is the behaviour the whole design rests on, seen on five modules.

The tests check logic. They cannot show any of the following, each of which a paid rehearsal with forced reclaims (`launch full-spot-rehearsal`, four attempts on the seven-minute build, then estimated at 1.50 to 2.00 USD) would be the first to exercise; section 10.7 says what the one made since did show, and that it cost 0.76:

- that Google's notice reaches the guest, and that the guest's last uploads fit in the seconds it leaves;
- a hard reset with no notice, and the bucket found consistent after it;
- the restore on a real machine as the build user and, after the seal, as root, and the build tool accepting restored files there;
- how long a part, a restore and a confirming hash take, and how big the parts are;
- that the parts reproduce the sealed files on a real tree;
- the Linux tools the Mac tests stand in for (`flock`, `runuser`, the metadata server).

A rehearsal builds about one module in a hundred. It does not show a restore of the whole tree, a confirming hash of 140 GB while the replay runs, or a reclaim at the top of the import graph.

The on-demand modes run the same guest script with the Spot code switched off. Reviewers compared that path with the committed version line by line and found it unchanged, and the launcher's test compares what the four older modes send and write; but in the on-demand modes the script as it now stands has not been rehearsed in the cloud: the sixth rehearsal of section 9 was of the version before this change, and the rehearsal of 10.7 ran it with the Spot code switched on.

### 10.7 The rehearsal

On 2026-11-22 the Spot path was rehearsed once, from commit `e8553dd`: `launch full-spot-rehearsal`, four attempts in `us-central1-a`, 2,275 seconds of machine time, 0.76 USD in the ledger. The record is [`../records/cloud/spot-rehearsals/`](../records/cloud/spot-rehearsals/).

| Attempt | What it did | How it ended |
|---|---|---|
| 1 | Built 393 modules and saved them as one part | Google's simulated reclaim, asked for by `watch` once the part was in the bucket. The guest logged the notice 20 seconds later and reported it; Google deleted the machine within about a minute and a half |
| 2 | Restored the 393 modules in 1 second and built on to 1,636, compiling no restored module again; four more parts | Deleted at the seal |
| 3 | Restored all 1,636 modules in 7 seconds; sealed; the parts reproduced the sealed files exactly, 8,180 of them, with no repair needed; the plain axiom check; the first replay trial, with 248 results saved | A hard reset with no notice |
| 4 | Locked the build user, restored the parts as root in 5 seconds, arrived at the first seal's fingerprint, took back the 248 results, and ran everything that was left | Every phase ran |

A rehearsal tests the driver and verifies nothing about the proof: it compiled 1,636 of 175,187 modules, so the facts' own reading of criterion C3 is false, as in every rehearsal. On what it did compile, all 1,636 modules passed `leanchecker`, the axiom probe passed plain and deep, and the end check found nothing changed. Every machine's source tree, toolchain and Mathlib matched the first one's. Ten confirming hashes were made on the last attempt: 2 to 4 seconds each on a quiet machine, 16 to 18 while a replay was running. `watch` reported each of the three cuts as done as configured.

Against the list in 10.6, the rehearsal showed: that Google's notice reaches the guest and that the guest's report gets out in time, once (the report was out 5 seconds after the notice was logged; the last part had gone up before the reclaim was asked for, so no part had to fit in the notice); a hard reset, with the bucket found consistent after it; the restore as the build user and, after the seal, as root, and the build tool accepting restored files on a real tree of 1,636 modules; that the parts reproduce the sealed files; and that the Linux tools the local tests stand in for behave as those tests assume. The five parts held 1,158 MB of compiled files in 353 MB, 0.22 MB a module, which puts the whole tree at about 38 GB of parts if deeper modules compress alike.

The model's guesses beside what was measured, on a tree a hundredth of the size:

| Input of the model | Its value | Measured in the rehearsal | Reading |
|---|---|---|---|
| Boot, setup and teardown of one attempt | 0.10 hours | 92 to 136 seconds of setup in the guest, and about 2 minutes more billed around it | The model is somewhat high |
| Size of the parts | 0.23 MB a module, 41 GB in all | 0.22 MB a module, which scales to 38 GB | Close, if deeper modules compress alike |
| Time from a finished module to its part being in the bucket, beyond the ten-minute interval | 1 minute | 2 to 3 seconds for a part of about 100 MB | The model is high |
| Restore of everything, before the seal | 0.15 hours | 7 seconds for 353 MB, which scales in a straight line to about 0.15 to 0.23 hours | The model is at the fast end |
| The seal | 0.25 hours | 25 to 27 seconds; the seal also hashes the source tree, the toolchain twice and Mathlib, none of which grows with the compiled tree | Not settled by this |
| A confirming hash during the replay | 5 minutes | 16 to 18 seconds, four to six times what it takes on a quiet machine; it too covers Mathlib and the toolchain as well as the compiled tree | Not settled; the slowdown under load is the thing to watch |
| Ledger time after a reclaim | 72 seconds | 111 seconds after the simulated reclaim, about 60 after a deletion or a reset | The model is a little low |

None of this changes the cut-offs of 10.3 by much, and none of it is a measurement at scale.

It did not show anything at scale, and it did not meet: a reclaim that Google itself decides on; a reclaim during the main replay, the deep axiom check or the end check; an attempt outside the bucket's region; an attempt that ends at its own deadline; a pause on the cap; a repair part; or a failed upload or download. Those remain reviewed and tested locally. The on-demand modes were not rehearsed again.

### 10.8 The full run

The full run was made this way on 2026-11-22 and 23, from commit `e8553dd`, as run `full-spot-20261122-150121` ([`../records/cloud/full-run/`](../records/cloud/full-run/)). This section is about how the driver behaved and what it cost. What the run recorded about the proof is in that record and in [`../CLAIMS.md`](../CLAIMS.md).

| Attempt | Billed | What happened |
|---|---|---|
| 1 | 4,515 s | Google took the machine back 73 minutes after boot, during the build. Six parts holding 12,450 modules were in the bucket; the last status line before the notice showed 13,899 built |
| 2 | 89,128 s | Restored the six parts in 47 seconds, compiled none of them again, and ran everything else without another reclaim: `DONE` 72,954 seconds after boot. About 16,150 of the billed seconds were the finished machine idling |

There was one reclaim in 21.5 hours of machine time at work. That is one observation and says nothing reliable about the rate; Google publishes none.

**What the reclaim cost.** From the guest's `RECLAIMED` report to the next machine starting its build was 4 minutes 41 seconds, of which the new machine's setup took 158 seconds, the restore included. The second machine passed the first one's last reported count between five and ten minutes into its build. That is roughly ten to twelve minutes lost, against the 16 minutes (0.27 hours) the model allows for a reclaim during the build. The ledger closed the first attempt 67 seconds after the report.

**The idle machine.** `watch` runs on the owner's computer, and that computer restarted at 16:33 UTC on 2026-11-23, two hours before the guest finished. Nothing started `watch` again until 23:01 UTC, so the finished machine was billed for about 4.5 idle hours, 5.38 USD of the run's 31.21. The design held in the sense that mattered: the results were in the bucket, nothing was lost, and the machine's own time limit would have deleted it six hours later. But the launcher has no way to notice that `watch` has died, and a finished guest does not delete itself. A run that should not depend on one computer staying up needs either a guest that shuts itself down on `DONE` or a `watch` that is restarted at login; neither exists yet.

**The model against the run.** The model's inputs were the pilot's estimate and several guesses (10.3). With one reclaim where the model's no-reclaim case has none:

| Quantity | Model | The run |
|---|---|---|
| Build | 15.6 hours | 13.8 hours over the two machines, the restart tests and the work done twice included |
| Seal | 0.25 hours | 83 seconds |
| Axiom check, deep | not separated from its setup | 551 seconds |
| Main replay | 9.1 hours | 7.2 hours |
| Machine time at work | 26.0 hours with no reclaim | 21.5 hours with one |
| Recorded cost at the ledger rate | 31.25 USD with no reclaim | 25.83 USD for the time at work; 31.21 with the idle hours |
| Size of the parts | 0.23 MB a module, 41 GB | 0.17 MB a module, 30.6 GB; the compiled files are 100.2 GB |
| Restore before the seal | 0.15 hours for everything | 47 seconds for 2.9 GB; a restore of everything was not needed and so was not timed |
| A confirming hash during the replay | 5 minutes | 184 to 189 seconds with four hashing processes while the replay ran; 25 to 39 seconds on an idle machine |

The model was cautious on every line that the run tested. The cut-offs of 10.3 were computed from the model's figures and have not been recomputed.

**What the run did not meet:** a reclaim after the seal (during the axiom checks, the replay or the end check), a restore of the whole tree, an attempt outside the bucket's region, an attempt ending at its own deadline, a pause on the cap, a repair part, and a failed upload or download. Those remain reviewed, tested locally and, for some, rehearsed at small scale (10.7).

Recorded spend after the run was 41.83 USD of the cap of 50. The run's checkpoints (28.6 GiB in the bucket, about 0.57 USD a month) were kept.

### 10.9 The export check

On 2026-11-24 a further machine was rented for 2.2 hours (4.49 USD, on demand) to do what the three criteria do not: export the proof and give it to a kernel other than Lean's. The record and its limits are in [`../records/cloud/export-check/`](../records/cloud/export-check/); how this sits beside what others did is in [`related-work.md`](related-work.md).

It built nothing. The 77 parts the full run had saved in the bucket were fetched, checked and unpacked in 11 minutes, and the result was shown to be the sealed files of that run before anything read them. This is the second use of those parts, and the reason for keeping them: a check thought of afterwards cost 4.49 USD and not another 26.

| Step | Time on 32 vCPUs |
|---|---|
| Setup, toolchains, building the exporter and `con-leche` | 7 minutes |
| Fetching and unpacking the compiled files (30.6 GB in 77 parts) | 11 minutes |
| Export of the proof, single-threaded | 95 minutes, 61.6 GB |
| `con-leche`, each of two runs | under 8 minutes, peak 45 GiB |

Both exports matched the published hashes and `con-leche` accepted the export. `nanoda` was given the wrong argument by the script and did not run. The export sets the length of such a run, and it uses one core, so a smaller machine might do the same work for less at the price of a slower kernel run. How much memory the export needs was not measured, and a smaller machine has not been tried.
