# riemann-lean-verify

A low-cost, reproducible way to check a very large Lean 4 proof on a laptop or one rented machine, worked out on the published formalization that proves the Riemann Hypothesis.

**This is not the verification of that proof.** The Lean and Mathlib communities checked it within a day of its release, with stronger methods than are used here; their record is at <https://math.mit.edu/~drew/grh/> and their statement at <https://leanprover-community.github.io/blog/posts/riemann-hypothesis/>. What this repository did is repeat most of that check on one rented 32-vCPU machine at a time, the build and the three criteria blind and the later checks by the community's own method and with its files, and write down how and at what cost: the three runs behind the results below are recorded in the launcher's ledger at 58.67 USD of machine time between them, and everything rented, the pilot, every rehearsal and a trial of the scripts on a second archive included, at 70.01. The ledger counts machine time at a list rate that is rounded up, writes each row to the nearest cent, and leaves out what the storage bucket costs; the bill is authoritative and is not in this repository. [`docs/related-work.md`](docs/related-work.md) says what others did, how the checks here compare, and what is still missing here.

The formalization is the work of Levent Alpöge, who announced it on 2026-11-20 at <https://alpo.ge/remark.pdf> and distributes it as a source tarball from `alpo.ge`. It is about 175,000 Lean files and 17.4 million lines, roughly eight times the size of Mathlib. This repository does not contain that source. Its tooling downloads it, checks it against a recorded SHA-256, inspects it before anything is executed, compiles it with the pinned Lean and Mathlib versions, and runs the checks that decide whether the claimed theorem has actually been proved.

Everything here is meant to be reviewed or re-run by anyone with a Mac, a Linux machine or a Google Cloud account, by hand or with a basic coding agent.

## Status

As of 2026-11-26: **one full run in the cloud, made on 2026-11-22 and 23, recorded all three pre-registered criteria as holding.** Under section 5 of the pre-registration that outcome is reported as VERIFIED, relative to the trust assumptions of its section 6. It is one run, it has not been repeated, and its records have so far been read only by the scripts that made them and by AI agents. A second, independent build on a Mac is still in progress.

That result is one confirmation among many, and it came after the community's. The three criteria stop short of the standard the community applied ([`docs/related-work.md`](docs/related-work.md)). Two further runs closed most of that gap, using the community's own challenge file, exporter, configuration and checkers:

- **2026-11-24, the export check.** The proof exported from the cloud run's compiled files is byte for byte the export others published (SHA-256 `5ea74b91…244e`), and `con-leche`, a kernel written independently of Lean's, accepted all of it and reported the five challenge statements as justified ([`records/cloud/export-check/`](records/cloud/export-check/)).
- **2026-11-25 and 26, the kernel check.** On the published copy of that export, `nanoda`, a second independently written kernel, checked 1,484,733 declarations with no errors; `lake comparator`, with Lean's own kernel in its sandbox, ended with "Your solution is okay!"; and Lean's paranoid kernel accepted it. One machine, 11.5 hours, 22.97 USD ([`records/cloud/kernel-check/`](records/cloud/kernel-check/)). `lake comparator` was not run exactly as published: the kernel was given an allocator setting that, by the published measurements, takes it from 48 hours to 9, and the two external kernels of the community's configuration ran beside it and not inside it. The file checked has the SHA-256 of this repository's own export, which was not kept.

Still not done: a build in a sandbox, `lake comparator` with stock settings, and `lean4lean`. Each of these two runs was made once, by a script that no person has reviewed. Of their checkers, only the kernel inside `lake comparator` ran in a sandbox. The counts quoted on this page (1,484,733 declarations by `nanoda`, 1,478,243 constants in C2) are made by different rules and have not been reconciled.

A much shorter proof of the same five theorems, which its README describes as a shorter version of the original, was published on 2026-11-25, and a record of its checks followed within hours (<https://math.mit.edu/~drew/shortgrh/>). This repository's own steps were run on its compact edition once, on 2026-11-27, on a rented 16-vCPU machine: all 794 modules built in 32 minutes, the axiom check passed and `leanchecker` passed every module, for 0.61 USD with the rehearsal ([`records/cloud/target-runs/`](records/cloud/target-runs/)). That was a trial of these scripts on a second archive, with the build and the checks run by one user on the machine, and it is not on a par with the record above: no sandboxed build, no export, no independently written kernel and no Comparator were run on it here ([`docs/related-work.md`](docs/related-work.md), [`targets/README.md`](targets/README.md)).

| Check | State |
|---|---|
| Source downloaded and pinned by hash | Done |
| Archive inspected before extraction | Done |
| Source scanned for `sorry`, added axioms, `native_decide`, `unsafe`, IO and similar | Done: none found |
| Pinned Mathlib confirmed to be the unmodified official tag | Done |
| Final reduction step compiled; its axioms and statement checked | Done: standard axioms, Mathlib's statement |
| **C1. Whole tree compiles with zero errors** | **Recorded as holding in the cloud run: 175,187 of 175,187 modules, `lake build` exit status 0, no failed job ([`records/cloud/full-run/`](records/cloud/full-run/)). The Mac build was at 149,438 of 175,187 at 08:33 UTC on 2026-11-26, with zero failures ([`records/mac-build/progress-20261126-0233.txt`](records/mac-build/progress-20261126-0233.txt))** |
| **C2. Statement and axioms of the compiled headline theorem** | **Recorded as holding in the cloud run: the type of `riemannHypothesis` is Mathlib's `RiemannHypothesis`; `#print axioms` and a traversal of 1,478,243 constants find `propext`, `Classical.choice`, `Quot.sound` and no other axiom** |
| **C3. Independent kernel replay of every module** | **Recorded as holding in the cloud run: all 175,187 compiled modules passed by `leanchecker`, with no rejection or crash** |

The run was made on 2026-11-22 and 23 on rented Google Cloud machines, from the published tarball, unmodified. What it recorded, how the work was carried across the one machine that Google took back, and what the run does not show are in [`records/cloud/full-run/README.md`](records/cloud/full-run/README.md). The verdict follows from the criteria fixed in advance and from what the Lean kernel accepted, not from anyone's reading of the mathematics. In the words of the pre-registration it is independently reproduced, kernel-checked evidence, and not proof beyond any possible doubt: it rests on the Lean kernel and the pinned toolchain, on Mathlib's definitions saying what is meant, on Mathlib's prebuilt cache, and on the hardware. Anyone can repeat it with the scripts here.

## Pre-registration

The criteria for calling the proof verified (C1 to C3 above), and what will be reported under every other outcome, were fixed before the result was known. They are in [`PREREGISTRATION.md`](PREREGISTRATION.md), the first commit to this repository. It will not be edited; any change will be a dated amendment.

That first commit was made public on 2026-11-21 at 03:05 UTC and is archived at Zenodo as release `prereg-v1`: [doi:10.5281/zenodo.24410554](https://doi.org/10.5281/zenodo.24410554). At that moment no build of the whole tree had finished and none of the three criteria had been evaluated. The details are in [`records/preregistration_marker.json`](records/preregistration_marker.json).

A verified verdict would be independently reproduced, kernel-checked evidence. It would still rest on the soundness of the Lean kernel, on Mathlib's definitions meaning what is intended, and on the toolchain and prebuilt cache being what they claim. Section 6 of the pre-registration lists these.

## How to review or replicate

Start with [`CLAIMS.md`](CLAIMS.md): every claim, the kind of evidence behind it, and the command that reproduces it. Then go as deep as your time and hardware allow.

| Level | What you establish | Cost |
|---|---|---|
| 0 | What is claimed and on what evidence | Minutes of reading |
| 1 | The source is the recorded artifact, contains none of the usual shortcuts, and states the real theorem against the real Mathlib | 5 to 15 minutes, 2 GB, no Lean needed |
| 2 | The final reduction step is kernel-checked on standard axioms; a sample of modules passes kernel replay | About an hour, 10 GB |
| 3 | The whole tree compiles, or does not | Days on a laptop; 13.8 hours in the one cloud run, on 32-vCPU machines (estimated beforehand at 16) |
| 4 | The pre-registered verdict | Days to weeks more on a laptop; in that cloud run, 7.2 hours for the kernel replay and 9 minutes for the axiom walk (projected beforehand at about 10 hours) |

```bash
git clone https://github.com/betterfuture2030/riemann-lean-verify
cd riemann-lean-verify
scripts/reproduce_findings.sh         # level 1: PASS or FAIL for every no-compile claim
```

[`docs/replication-guide.md`](docs/replication-guide.md) covers every level and gives the plain commands each script runs, so the scripts are a convenience and not a requirement. [`AGENTS.md`](AGENTS.md) has the rules for a coding agent helping with this.

For the full build:

```bash
scripts/verify.sh                     # prerequisites, download, inspection, source audit, toolchain, smoke build
scripts/05_build.sh start             # the long part; runs detached
scripts/06_progress.sh                # check on it whenever you like
scripts/08_check_axioms.sh --deep     # after the build: criterion C2
scripts/09_kernel_replay.sh           # after the build: criterion C3
```

Each script says at the top what it does, what it changes on disk and how long it takes. Nothing is written outside `RH_WORKDIR`.

## On Google Cloud

[`cloud/gcp/`](cloud/gcp/) has a calibration pilot: one self-deleting virtual machine that compiles a time-boxed sample and measures cost per module, so the cost of a full run can be estimated before committing to it. It enforces a spending cap and never runs the full build. See [`cloud/gcp/README.md`](cloud/gcp/README.md).

The pilot was run on 2026-11-20 for 5.82 USD. It compiled 29,633 modules and kernel-checked 2,233, with no failures. From its measurements a full build on the same 32-vCPU machine is estimated at about 16 hours. The kernel replay after it was first put at 14 hours; that was wrong. The stock tool `leanchecker` lists every compiled file on its search path before each check, and run once per module with the whole library on that path it comes to about 46 hours. Given a search path that holds only what each module imports, the same tool is projected at about 8.5 hours, which makes a full run about 26 hours and 48 USD ([`docs/performance-notes.md`](docs/performance-notes.md), section 10). That keeps criterion C3 as registered: `leanchecker`, on every module. A draft amendment that would have replaced the tool was written, reviewed and not made; the pre-registration is unchanged. All of these are extrapolations: no module importing more than 17,860 others has been compiled on a rented machine (the Mac build has since reached modules importing 34,926, without timings), no replay has been run on a full tree, the 46 hours are a line through two measurements (43 to 56, depending on how it is drawn), and the 8.5 hours apply that line to a way of running the tool that has been timed on a rented machine only twice, each time on the shallow modules of a rehearsal. The data, the estimate, three AI reviews of a first version of it and the list of what a full run still needs are in [`records/cloud/pilot/`](records/cloud/pilot/) and [`docs/cloud-notes.md`](docs/cloud-notes.md), sections 8 and 9. A driver for the full run was written, reviewed and rehearsed six times on a seven-minute build ([`cloud/gcp/full_guest.sh`](cloud/gcp/full_guest.sh), [`records/cloud/full-rehearsals/`](records/cloud/full-rehearsals/)). No full run has been made on demand. The spending cap then set for this work, 50 USD in total, was below what the launcher requires before it will start one on demand; what could be done about that is in [`docs/cloud-notes.md`](docs/cloud-notes.md), section 8.6. One of those ways has since been built: a run on Spot machines, at about six tenths of the price, that saves its work to the bucket every ten minutes and carries on from there on a fresh machine when Google takes one back ([`docs/cloud-notes.md`](docs/cloud-notes.md), section 10). It was reviewed, tested locally and rehearsed once on rented machines, as four attempts cut off on purpose three times ([`records/cloud/spot-rehearsals/`](records/cloud/spot-rehearsals/)). **The full run was then made that way on 2026-11-22 and 23**: two machines, one reclaim by Google 73 minutes in, 13.8 hours of building and 7.2 of kernel replay, recorded at 31.21 USD, of which about 5.38 was a finished machine left idle ([`records/cloud/full-run/`](records/cloud/full-run/); [`docs/cloud-notes.md`](docs/cloud-notes.md), section 10.8). The estimates earlier in this paragraph are kept as they were made; the build and the replay each took less than forecast. The on-demand modes of the driver as changed for the Spot run have not been rehearsed again.

Two later modes build nothing. `export-check` (2026-11-24; 2.2 hours, 4.49 USD) exports the proof from the compiled files that run left in the bucket and runs `con-leche` on the export. `kernel-check` (2026-11-25 and 26; 11.5 hours, 22.97 USD, after a rehearsal at 0.11) gives the export to `nanoda`, to `lake comparator` with Lean's kernel in its sandbox, and to Lean's paranoid kernel ([`docs/cloud-notes.md`](docs/cloud-notes.md), sections 10.9 and 10.10). The spending cap was raised from 50 to 100 USD for the second; with 69.40 then recorded as spent, an on-demand full run would still have been refused, as it would be now. Everything rented for this work, the pilot, every rehearsal and the two runs on a second archive of 2026-11-27 included, is recorded at 70.01 USD ([`records/cloud/ledger.tsv`](records/cloud/ledger.tsv)).

## What has been found so far

- The package is honest in form. It states the real theorem against the real Mathlib, and a scan of all 17.4 million lines finds none of the usual shortcuts.
- The top of the argument is short and readable: the Riemann Hypothesis is derived from non-vanishing of Dirichlet L-functions to the right of the critical line, by the functional equation. Its final lemma has been kernel-checked.
- Everything difficult sits beneath one theorem. Until the cloud run of 2026-11-23 almost nothing beneath it had been kernel-checked; in that run every module was.
- Three small metaprograms defer type checks from the elaborator to the kernel. Their use sites were read and none looked improper. That is a reason for the independent kernel replay, not a substitute for it.
- Directory and declaration names in the source are often unrelated to their content, so the source cannot be navigated by name.

Details: [`docs/source-audit.md`](docs/source-audit.md) and [`docs/proof-outline.md`](docs/proof-outline.md). Those two documents are readings of the source by AI agents with adversarial review. They are a map, and no conclusion here rests on them.

## How this work is done

The investigation is carried out with substantial help from an AI coding assistant, directed and reviewed by the author, who is responsible for the content. The formalization under test was itself produced with AI assistance, so this is disclosed plainly: the verdict is designed to rest only on the Lean kernel and on scripts that anyone can read and re-run, never on an AI system's judgment.

This was a blind replication until 2026-11-23. Other people's results on this formalization were not consulted before the criteria were fixed, nor before the full cloud run had finished and been written up (commit `53c3139`). They were first read later that day; [`docs/related-work.md`](docs/related-work.md) is the result.

## What this repository is not

It is not the proof and does not redistribute it. It is not affiliated with the proof's author. It is neither an endorsement nor a refutation of the mathematics: it reports what the Lean kernel accepted, under criteria fixed in advance.

## Layout

| Path | Contents |
|---|---|
| `PREREGISTRATION.md` | The criteria, fixed in advance |
| `CLAIMS.md` | Every claim, its evidence tier and how to reproduce it |
| `scripts/` | Numbered, re-runnable steps; `lib.sh` holds the shared configuration |
| `analysis/` | Import-graph and timing analysis, and the cost estimate from the pilot |
| `cloud/gcp/` | The Google Cloud launcher and the scripts it runs on a rented machine: the calibration pilot, the full run, the export check, the kernel check, and the numbered steps for another target |
| `docs/` | Replication guide, verification criteria explained, what others have done and how this compares, what to change for another archive, source audit, outline of the argument, performance and cloud notes |
| `records/` | Hashes, expected values, measurements, audit output, price snapshots, and what each cloud run wrote, with the ledger of what each cost |

## Roadmap

1. Bring the checks up to the community's standard ([`docs/related-work.md`](docs/related-work.md)). Done on 2026-11-24: the export of the proof, equal to the published one, and one independently written kernel on it. Done on 2026-11-26: a second independent kernel, Lean's own kernel and its paranoid build on the export, and `lake comparator`, with two differences from the published run. Still not done: a sandboxed build, `lake comparator` with stock settings, and `lean4lean` (Status, above).
2. Finish the build on the Mac and record what a laptop needs.
3. Separate what is specific to this proof from what would serve any large Lean archive, and try the result on a second, smaller one. The first half is done: every fact about the archive that the scripts in `scripts/` use is now read from a target profile, apart from the limits listed with it (the default target's cloud modes, the cost models, Lean's module system and the dependence on Mathlib; [`targets/README.md`](targets/README.md), [`docs/adapting-to-another-proof.md`](docs/adapting-to-another-proof.md)). This is tested offline on small made-up projects and on a made-up stand-in for this archive's tarball (on the real tarball only the archive checks were run again, with the same output as before). On a second real archive, the compact edition of the shorter proof published on 2026-11-25, the steps that compile nothing were run on 2026-11-27. They met a library outside the sources, which the scripts now allow for under conditions. Its build, axiom check and kernel replay were then run once, on a rented machine, for 0.61 USD with the rehearsal ([`records/cloud/target-runs/`](records/cloud/target-runs/)). Not done: the same on a laptop, and anyone but the author following the guide.
4. A short write-up of the method and its costs, offered to the Lean community for criticism.

An explanation of the mathematics is not on this list. That is work for mathematicians, and it is under way elsewhere.

## Contact and licence

Questions and corrections: peter.lowes@sie.life, or open an issue.

The tooling and documentation here are under the MIT licence; see [`LICENSE`](LICENSE). The Lean formalization that this tooling downloads is a separate work by its own author.
