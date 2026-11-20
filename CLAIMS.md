# Claims ledger

Every claim this repository makes, with the kind of evidence behind it, how to reproduce it, and its state. If a claim here cannot be reproduced as described, that is a bug in this repository: please open an issue.

Status as of 2026-11-20. The verdict criteria are fixed in [`PREREGISTRATION.md`](PREREGISTRATION.md).

## Evidence tiers

| Tier | Meaning | Who can re-check it |
|---|---|---|
| **S** | Script-reproducible. A deterministic check on the downloaded source; no compiling. | Anyone, in minutes, on a laptop |
| **K** | Kernel-checked. The Lean kernel accepted something; requires compiling the modules involved. | Anyone with the toolchain; cost depends on how many modules |
| **M** | Measured. Timings, memory, disk, prices. Depends on the machine or the date. | Anyone, on their own machine; expect different numbers |
| **R** | Reading. Statements about what the source says, produced by AI agents with adversarial review and spot checks. | By hand, using the pointers given; not mechanically |

**No conclusion in this repository rests on tier R.** Reading is used to navigate and to decide what to check. The verdict rests on tiers S and K only.

## Tier S: reproducible without compiling

Run all of these with `scripts/reproduce_findings.sh`. Expected values are in [`records/source/expected.json`](records/source/expected.json).

| ID | Claim | Reproduce | By hand |
|---|---|---|---|
| S1 | The source is 14 parts, 239,275,554 bytes, SHA-256 `9631b4f0…49c7fc` | `scripts/01_fetch.sh` | `curl` each part, `cat` in order, `shasum -a 256` |
| S2 | The archive holds 175,190 regular files, all under `lean/`, with no symbolic or hard links, absolute paths, `..` components or executable bits | `scripts/02_inspect_and_extract.sh --check-only` | `tar -tvzf lean.tar.gz` and inspect the mode and path columns |
| S3 | 175,187 `.lean` files and 17,374,215 lines | `scripts/02_inspect_and_extract.sh` | `find src -name '*.lean' \| wc -l`; `find src -name '*.lean' -print0 \| xargs -0 cat \| wc -l` |
| S4 | The build configuration is a declarative `lakefile.toml`; Lean is pinned to `v4.33.1`; Mathlib is required from the official repository at `0df444a3…5474` | `scripts/02_inspect_and_extract.sh` | Read `lakefile.toml`, `lean-toolchain`, `lake-manifest.json` |
| S5 | That Mathlib revision is the official tag `v4.33.1` | `scripts/04_setup_toolchain.sh` prints it | `git ls-remote https://github.com/leanprover-community/mathlib4 refs/tags/v4.33.1` |
| S6 | Whole-word, case-sensitive scan of every source line finds zero `sorry`, `admit`, `axiom`, `native_decide`, `unsafe`, `implemented_by`, `extern`, `#eval` | `scripts/03_audit_source.sh` | `grep -rwc` for each word over `src/` |
| S7 | No file or process IO primitives; compile-time code is confined to five `run_cmd` stubs in `BuildAid/` and three files defining `elab` commands | `scripts/03_audit_source.sh` lists them | Read the eight files; they total under 200 lines |
| S8 | Nothing in the source defines `RiemannHypothesis` or `riemannZeta`; `Statements.lean` imports only Mathlib; `Main.lean` states `theorem riemannHypothesis : RiemannHypothesis` | `scripts/03_audit_source.sh` | Read `src/Statements.lean` (16 lines) and `src/Main.lean` (12 lines) |
| S9 | Every one of the 175,187 modules is in the import closure of `Main`; the longest import chain is 203 modules | `python3 analysis/import_graph.py` | Not practical by hand |
| S10 | The kernel-deferring tactics (`kexactB`, `kc%`, `kcopy`, `tr_via`, `tr_clause`, `cpt_copy_thms`) are used in 77 files | `scripts/reproduce_findings.sh` (check S10) | `grep -rlE 'kexactB\|kc%\|kcopy\|tr_via\|tr_clause\|cpt_copy_thms' src \| wc -l` |

## Tier K: checked by the Lean kernel

| ID | Claim | State | Reproduce |
|---|---|---|---|
| K1 | Mathlib's prebuilt cache for the pinned revision is accepted by the pinned toolchain, with no Mathlib module rebuilt | Done | `scripts/04_setup_toolchain.sh` |
| K2 | `Formalism.VW.rh_of_right` (zeta has no zeros right of the critical line implies `RiemannHypothesis`) depends only on `propext`, `Classical.choice`, `Quot.sound`; its conclusion is the constant `RiemannHypothesis`, defined in `Mathlib.NumberTheory.LSeries.RiemannZeta` | Done | `scripts/08_check_axioms.sh --probe` |
| K3 | Sampled kernel replay passes: 24 of 24 modules on a Mac, 565 of 565 on a cloud machine | Done, samples only | `scripts/09_kernel_replay.sh --sample 24` |
| K4 | Modules compiled so far, with zero failures | In progress; see `records/` for dated counts | `scripts/05_build.sh start`, `scripts/06_progress.sh` |
| **C1** | **The whole tree compiles with zero errors** | **Not yet known** | `scripts/05_build.sh start` to completion |
| **C2** | **The compiled `riemannHypothesis` has type `RiemannHypothesis` and standard axioms only, by `#print axioms` and by full traversal** | **Not yet possible** | `scripts/08_check_axioms.sh --deep` |
| **C3** | **Every compiled module passes an independent kernel replay** | **Not yet possible** | `scripts/09_kernel_replay.sh` |

C1 to C3 are the pre-registered criteria. Nothing else in this ledger amounts to a verdict.

## Tier M: measurements

| ID | Claim | Record |
|---|---|---|
| M1 | On a 10-core, 24 GB Mac the best setting was 8 parallel jobs at about 3,230 modules per hour on shallow modules; memory was the first limit | `records/mac-build/` |
| M2 | Importing Mathlib alone costs about 6 CPU-seconds per process on macOS and about 2.6 on Linux | `records/mac-build/`, `records/cloud/` |
| M3 | Each compiled module leaves about 0.8 MB of compiled output plus a regenerable JSON file of 5 to 6 MB or more | `docs/performance-notes.md` |
| M4 | A 32-vCPU cloud machine compiled shallow modules at about 3.9 per second | `records/cloud/` |
| M5 | Cloud prices and quota behaviour as read on 2026-11-20 | `records/cloud/`, `docs/cloud-notes.md` |

Early throughput cannot be extrapolated to the whole tree: later modules import far more. See `docs/performance-notes.md`.

## Tier R: reading, with pointers for spot checks

These came from a 43-agent static audit in which every medium or high flag went to a second agent instructed to refute it. The full output is in [`records/audit/`](records/audit/). They are a map. To check one, open the file named and read it.

| ID | Claim | Spot check |
|---|---|---|
| R1 | The top of the argument is: `riemannHypothesis` from `UpperTheory.EveryCharacter` (non-vanishing of Dirichlet L-functions right of the critical line) by the functional equation | Read `src/Supplements/Kernels/MainTheorems.lean` (17 lines), `src/Formalism/GammaFactorNonvanishing/RhOfRight.lean` (63 lines), `CritLine.lean` (33 lines). K2 covers `rh_of_right` mechanically |
| R2 | `UpperTheory.EveryCharacter` is stated purely in Mathlib terms | Read the `def` in `src/Development/AutomorphicArithmetic/CharacterBoxes/EveryCharacter.lean` |
| R3 | The three metaprograms defer a type check to the kernel and perform no IO | Read `…/HeckeNonvanishing/Imports.lean` (8 lines), `…/NumberFieldFamilies/OwnStruct.lean` (66 lines), `…/HermitianCurvatureProofs/CutCptCopy.lean` (91 lines) |
| R4 | At the roughly 820 use sites of those tactics, each is a transport between repackagings of one record; none proves `False` or evaluates arithmetic | List the sites with the S10 grep and sample them. Not verified exhaustively by a human; C3 is the mechanical counterpart |
| R5 | No statement labelled as literature is used by the final theorem without an in-tree proof term | Follows mechanically from C2 once it passes (no axioms, no hypotheses). Until then: read `…/CharacterBoxes/MainConclusion.lean` (14 lines) |
| R6 | Directory and declaration names are often unrelated to content | `docs/source-audit.md` gives examples; open any of them |
| R7 | The outline of the argument and the match against the announcement's 20-item list | `docs/proof-outline.md`. A second reader found dependency-edge errors in roughly a quarter of the mapped nodes. Treat as orientation only |

## What has not been checked

- Whether any module beyond those compiled so far compiles.
- Whether Mathlib's definitions of the zeta function and of `RiemannHypothesis` say what is intended. They are Mathlib's, unmodified; this project has not audited them.
- The 114 modules whose name is a prefix of another module's name are skipped by the per-module replay script and need a separate pass.
- The Linux code paths of the numbered scripts have been run only in part (through the cloud pilot); the scripts were developed on macOS.
