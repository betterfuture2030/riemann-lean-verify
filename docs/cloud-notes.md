# Notes on running this on Google Cloud

What was learned on 2026-11-20 while planning a cloud run of the build. Everything here is generic: no account, project or billing details appear, and none are needed to use these notes. Prices are list prices for the Iowa region (`us-central1`), in US dollars, for Linux, before tax and without any commitment discount. They were read from Google's own price pages and SKU catalogue on 2026-11-20 and will change; read them again before relying on them.

Sections 1 to 7 were written before anything had been run in the cloud; their durations and costs are modelled, not measured, except where a line says otherwise. The calibration pilot in [`../cloud/gcp/`](../cloud/gcp/) then ran on the same day. Section 8 gives what it measured and the estimate for a full run that follows from it, and section 9 lists what a full run still needs. Where section 8 and an earlier section disagree, section 8 is the measurement.

## 1. Summary

| Point | Detail |
|---|---|
| Quota decides what you can run | A project with little Compute Engine history had a global limit of 32 vCPUs. Requests for much more were refused automatically |
| The plan that needs no quota increase | One `n4d-highmem-32` (32 vCPUs, 256 GB), about 1.87 USD per hour including its disks |
| Bigger machines finish sooner, not cheaper | Within a machine family the price per vCPU-hour is the same at every size |
| One family has a storage trap | On H4D, network disk throughput is capped per VM at 240 MiB/s whatever the disk is provisioned for |
| The first cost model was optimistic in structure | Three reviewers reproduced its arithmetic and each revised its conclusions; see section 6 |
| A billing budget does not stop spending | It sends alerts, and they can arrive hours late |
| What the pilot then measured | A full build and full kernel replay on the 32-vCPU machine: about 31 hours and 58 USD, range 53 to 74 USD (section 8) |

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

When this section was written, how long a full build takes on 32 vCPUs was not known, and the expectation was days rather than hours. The pilot measured it: about 16 hours for the build and 14 for the kernel replay (section 8).

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
| CPU per module at 32 jobs | Mean 8.5 seconds, median 5.9. 106 modules took over a minute of wall time; the longest took 409 seconds |
| Threads per compiler process | Median 15, so 16 jobs already occupy the 16 cores. Going from 16 to 32 jobs raised throughput by about 7 percent and CPU seconds per module by about 50 percent |
| Importing a module, one process alone | 2.37 seconds plus 0.136 seconds per 1,000 project modules in its import closure (17 modules with closures from 0 to 17,860, three repeats each) |
| The same import with 32 running at once | 1.66 times the CPU |
| The build tool's own CPU | 0.35 to 0.38 seconds per module at 32 jobs, on 1.1 to 1.3 cores |
| Restarting the build tool with up to 30,000 modules already built | 4 to 9 seconds until the first new module finished |
| Private memory per compiler process | Median 504 MB, 99th percentile 765 MB, largest 8,130 MB. Against closure size: 508 MB plus 13 KB per imported project module, which projects to 2.7 GB for the last module |
| Compiled files a process maps and touches | 6.6 GB plus 0.57 MB per imported project module, which projects to about 104 GB for the last module. These pages are shared between processes |
| Whole machine | Private memory never above 21 GB; never less than 219 GB available. After start-up nothing was read from disk: every compiled file was served from memory |
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

1. Cost of compiling one module, in CPU seconds at 32 jobs: `E + s × closure`. A plain regression of CPU on closure size gives a slope of 0.048 seconds per 1,000 imports with a standard error of 0.049: it cannot be told apart from zero, because in the pilot's sample closure size is mixed up with how heavy each module's own content is. So `s` is taken from the import probes, scaled by the measured cost of running 32 at once: 0.136 × 1.66 = 0.226 seconds per 1,000. `E` is set so that the model reproduces the pilot's mean.
2. The model is applied to a random sample of 8,000 modules from the whole tree (mean closure 3,086), giving 442 CPU-hours.
3. CPU becomes wall-clock through the useful CPU delivered per thread-second, measured inside the longest window: 0.911.
4. The kernel checker is treated the same way: 8.1 seconds plus 0.263 per 1,000 imports, 434 CPU-hours, 0.971 useful CPU per thread-second.
5. Fixed allowances are added for set-up, the narrow top of the import graph, the two checks of criterion C2, and slack.

| Case | Build | Kernel replay | Set-up, C2 and slack | Billed hours |
|---|---|---|---|---|
| Low | 13.7 | 14.0 | 0.5 | 28.1 |
| Expected | 15.6 | 14.0 | 1.5 | 31.0 |
| High | 17.9 | 15.4 | 6.0 | 39.3 |

Low uses the plain regression's slope, per-library corrections shrunk towards zero, and the best utilisation seen. High uses the slope fitted to the 153 largest closures alone (0.41 per 1,000, standard error 0.18) raised by 10 percent, 5 percent lower utilisation, a steeper checker slope, and three hours for one failure that is noticed late. An independent cross-check from raw throughput agrees with the expected case: 175,187 modules at 3.32 per second is 14.7 hours, and 6 percent more for larger closures gives 15.5; 3.7 checks per second, with the checker's own 8 percent for larger closures, gives 14.1.

Priced at list rates read on 2026-11-20, in US dollars, with the disk kept for six hours after the machine stops:

| Configuration | Machine per hour | Low | Expected | High | Measured by the pilot? |
|---|---|---|---|---|---|
| `n4d-highmem-32` on demand, 440 GB disk, setup files deleted as modules finish | 1.78 | 53 | 58 | 74 | Machine and disk yes; deleting setup files only on a small test project (section 9) |
| `n4d-highmem-32` on demand, 2 TB disk, nothing deleted | 1.78 | 59 | 65 | 82 | Yes, but the disk needs quota the pilot's region did not have |
| `n4d-highmem-32` Spot, 440 GB disk | 1.01 | 31 | 34 | 44 | No: adds restarts after each preemption, not included in the hours |
| `n4d-standard-32` (128 GB) on demand, 440 GB disk | 1.36 | 41 | 45 | 57 | No: see below |
| `n4d-standard-32` Spot, 440 GB disk | 0.77 | 25 | 27 | 34 | No: both of the above |

The 128 GB machine is the largest untested saving. The whole tree's compiled output is about 127 GB, Mathlib's adds about 7 GB, and the last modules each touch about 104 GB of it. On 256 GB all of that stays in memory, which is what the pilot measured. On 128 GB it would not, and the pilot read nothing from disk, so it says nothing about how much slower that is.

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
| 10 | One checker process per module imports Mathlib 175,187 times. Checking many modules per process could halve the replay | All three | Open. It would change how criterion C3 is carried out and needs its own test first |
| 11 | Run the checker alongside the build to use idle CPU | Cheaper | Not adopted: a gain of under an hour for more moving parts |
| 12 | The count of finished compiles dropped unnamed and repeated rows | Re-derivation | Accepted. 29,606 compiler processes finished; they cover 29,388 distinct named modules. The review also exposed a fault it did not name: the rule that drops processes killed at the end of a time-boxed window was also dropping the last modules of the two windows that ran to completion, among them the largest closure compiled. Fixed; the totals did not change |

### 8.4 What the estimate does not cover

- **The top of the import graph.** No module with more than 17,860 project imports was compiled. About 3.3 percent of the tree is above that, from a sample of 8,000; two reviewers counted exactly and agree on 27 modules above 50,000 and 13 above 100,000. The projections for them in section 8.1 are straight-line extrapolations.
- **Criterion C2.** The traversal of every dependency of the final theorem has never been run on the full tree. Its time and memory are unknown; the allowance is half an hour, two hours in the high case.
- **A machine where the compiled files do not fit in memory.** See section 8.2.
- **A genuine failure.** A module that fails to compile ends the estimate's relevance: the work becomes diagnosis.
- Tax, network egress and the cost of keeping results in a bucket. Small.

## 9. Before a full run

The pilot scripts stop short of a full run by design. A full run needs the following, none of which had been built when this was written.

| Need | Why | State |
|---|---|---|
| Delete each module's setup file once the module has finished | Without it the build writes 1.1 to 1.3 TB. With it the peak is about 150 GB, which fits the pilot's disk and needs no quota increase | [`../scripts/prune_setup_files.sh`](../scripts/prune_setup_files.sh). On a five-module project with the same Lake version, a second build after pruning recompiled nothing, importers of pruned modules compiled normally, and the kernel checker passed. A full run should repeat that check on its first few thousand real modules and stop if anything is rebuilt |
| Raise `vm.max_map_count` and the open-file limit well above one million | Costs nothing; removes the question in point 8 above | One line each in the guest script |
| Move from build to the C2 checks to the kernel replay without waiting for a person | An idle machine of this size costs about 1.86 USD per hour | To be written |
| A kernel replay that can be resumed and that includes the 114 modules whose name is a prefix of another's | A replay of 14 hours must survive an interruption, and criterion C3 is every module | `scripts/09_kernel_replay.sh` skips the 114 at present |
| Upload results as the run goes, and a status object the local `watch` can read | The machine deletes itself; anything not uploaded is lost | The pilot does this for its own files |
| A deletion time and a spending cap sized for about 40 hours | The pilot's cap and six-hour limit are too small by design | Settings |
| A short rehearsal of all of the above | The pilot's rehearsal found faults that review had not | About 1 USD |

Two optional tests could lower the cost and are cheap to run at the start: the kernel checker at 16, 24 and 32 at once, and the kernel checker given many modules per process.
