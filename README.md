# riemann-lean-verify

An independent, reproducible check of a published Lean 4 formalization that claims to prove the Riemann Hypothesis.

The formalization is distributed as a source tarball from `alpo.ge`, with a short announcement at <https://alpo.ge/remark.pdf>. It is about 175,000 Lean files and 17.4 million lines, roughly eight times the size of Mathlib. This repository does not contain that source. Its tooling downloads it, checks it against a recorded SHA-256, inspects it before anything is executed, compiles it with the pinned Lean and Mathlib versions, and runs the checks that decide whether the claimed theorem has actually been proved.

Everything here is meant to be reviewed or re-run by anyone with a Mac, a Linux machine or a Google Cloud account, by hand or with a basic coding agent.

## Status

As of 2026-11-20: **not verified; compile in progress.**

| Check | State |
|---|---|
| Source downloaded and pinned by hash | Done |
| Archive inspected before extraction | Done |
| Source scanned for `sorry`, added axioms, `native_decide`, `unsafe`, IO and similar | Done: none found |
| Pinned Mathlib confirmed to be the unmodified official tag | Done |
| Final reduction step compiled; its axioms and statement checked | Done: standard axioms, Mathlib's statement |
| **C1. Whole tree compiles with zero errors** | **In progress: a few percent done, zero failures so far** |
| **C2. Statement and axioms of the compiled headline theorem** | Not yet possible |
| **C3. Independent kernel replay of every module** | Not yet possible; samples of 24 and 565 modules passed |

"Zero failures so far" is progress, not a verdict. This repository makes no claim that the proof is correct or incorrect.

## Pre-registration

The criteria for calling the proof verified (C1 to C3 above), and what will be reported under every other outcome, were fixed before the result was known. They are in [`PREREGISTRATION.md`](PREREGISTRATION.md), the first commit to this repository. It will not be edited; any change will be a dated amendment.

A verified verdict would be independently reproduced, kernel-checked evidence. It would still rest on the soundness of the Lean kernel, on Mathlib's definitions meaning what is intended, and on the toolchain and prebuilt cache being what they claim. Section 6 of the pre-registration lists these.

## How to review or replicate

Start with [`CLAIMS.md`](CLAIMS.md): every claim, the kind of evidence behind it, and the command that reproduces it. Then go as deep as your time and hardware allow.

| Level | What you establish | Cost |
|---|---|---|
| 0 | What is claimed and on what evidence | Minutes of reading |
| 1 | The source is the recorded artifact, contains none of the usual shortcuts, and states the real theorem against the real Mathlib | 5 to 15 minutes, 2 GB, no Lean needed |
| 2 | The final reduction step is kernel-checked on standard axioms; a sample of modules passes kernel replay | About an hour, 10 GB |
| 3 | The whole tree compiles, or does not | Days on a laptop; about a day on a 32-vCPU cloud machine |
| 4 | The pre-registered verdict | Hours to days after level 3 |

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

[`cloud/gcp/`](cloud/gcp/) has a calibration pilot: one self-deleting virtual machine that compiles a time-boxed sample and measures cost per module, so the cost of a full run can be estimated before committing to it. It enforces a spending cap and never runs the full build. See [`cloud/gcp/README.md`](cloud/gcp/README.md) and [`docs/cloud-notes.md`](docs/cloud-notes.md).

## What has been found so far

- The package is honest in form. It states the real theorem against the real Mathlib, and a scan of all 17.4 million lines finds none of the usual shortcuts.
- The top of the argument is short and readable: the Riemann Hypothesis is derived from non-vanishing of Dirichlet L-functions to the right of the critical line, by the functional equation. Its final lemma has been kernel-checked.
- Everything difficult sits beneath one theorem, and almost nothing beneath it has been kernel-checked yet.
- Three small metaprograms defer type checks from the elaborator to the kernel. Their use sites were read and none looked improper. That is a reason for the independent kernel replay, not a substitute for it.
- Directory and declaration names in the source are often unrelated to their content, so the source cannot be navigated by name.

Details: [`docs/source-audit.md`](docs/source-audit.md) and [`docs/proof-outline.md`](docs/proof-outline.md). Those two documents are readings of the source by AI agents with adversarial review. They are a map, and no conclusion here rests on them.

## How this work is done

The investigation is carried out with substantial help from an AI coding assistant, directed and reviewed by the author, who is responsible for the content. The formalization under test was itself produced with AI assistance, so this is disclosed plainly: the verdict is designed to rest only on the Lean kernel and on scripts that anyone can read and re-run, never on an AI system's judgment.

This is a blind replication. Other people's results on this formalization were not consulted before the criteria were fixed.

## What this repository is not

It is not the proof and does not redistribute it. It is not affiliated with the proof's author. It is neither an endorsement nor a refutation.

## Layout

| Path | Contents |
|---|---|
| `PREREGISTRATION.md` | The criteria, fixed in advance |
| `CLAIMS.md` | Every claim, its evidence tier and how to reproduce it |
| `scripts/` | Numbered, re-runnable steps; `lib.sh` holds the shared configuration |
| `analysis/` | Import-graph and timing analysis |
| `cloud/gcp/` | The Google Cloud calibration pilot |
| `docs/` | Replication guide, verification criteria explained, source audit, outline of the argument, performance and cloud notes |
| `records/` | Hashes, expected values, measurements, audit output and price snapshots from the runs so far |

## Roadmap

1. Finish the compile and run the two decisive checks.
2. A paper describing the method and the outcome.
3. If it verifies: a layered, illustrated explanation of the argument. If it does not: a diagnosis of where and why it fails, and what repair would involve.

## Contact and licence

Questions and corrections: peter.lowes@sie.life, or open an issue.

The tooling and documentation here are under the MIT licence; see [`LICENSE`](LICENSE). The Lean formalization that this tooling downloads is a separate work by its own author.
