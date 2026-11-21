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
| K2 | `Formalism.VW.rh_of_right` (zeta has no zeros right of the critical line implies `RiemannHypothesis`) depends only on `propext`, `Classical.choice`, `Quot.sound`; its conclusion is the constant `RiemannHypothesis`, defined in `Mathlib.NumberTheory.LSeries.RiemannZeta`. With `--deep`, 54,444 constants are visited and no other axiom is reached; the same on a Mac and on Linux | Done | `scripts/08_check_axioms.sh --probe --deep` |
| K3 | Sampled kernel replay passes. By the stock tool `leanchecker`, on modules drawn at random from those compiled at the time: 24 of 24 on a Mac; 565 of 565 and 2,233 of 2,233 on a cloud machine (`records/cloud/pilot/*/check_results.txt.gz`). Separately, all 1,792 compiled files of a rehearsal build (`records/cloud/full-rehearsals/`): those are the first modules built, not a sample of the tree. By `rhv-replay` (M8), on the Mac build: 140 of 140 random compiled modules, 30 of which the stock tool also replayed, with the same verdict on each | Done, samples only; all from the first fifth of the tree | `scripts/09_kernel_replay.sh --sample 24`; for `rhv-replay`, the commands and the result lines are in `records/mac-build/replay-method-comparison.tsv` and the README beside it (a seeded sample on a build that has since grown picks other modules) |
| K4 | Modules compiled so far, with zero failures | In progress; dated counts are in `records/mac-build/` (23,981 of 175,187 at 02:01 UTC on 2026-11-21) | `scripts/05_build.sh start`, `scripts/06_progress.sh` |
| **C1** | **The whole tree compiles with zero errors** | **Not yet known** | `scripts/05_build.sh start` to completion |
| **C2** | **The compiled `riemannHypothesis` has type `RiemannHypothesis` and standard axioms only, by `#print axioms` and by full traversal** | **Not yet possible** | `scripts/08_check_axioms.sh --deep` |
| **C3** | **Every compiled module passes an independent kernel replay** | **Not yet possible** | `scripts/09_kernel_replay.sh` |

C1 to C3 are the pre-registered criteria. Nothing else in this ledger amounts to a verdict.

## Tier M: measurements

| ID | Claim | Record |
|---|---|---|
| M1 | On a 10-core, 24 GB Mac the best setting was 8 parallel jobs at about 3,230 modules per hour on shallow modules; memory was the first limit | `records/mac-build/` |
| M2 | Importing Mathlib alone costs about 6 CPU-seconds per process on macOS and about 2.6 on Linux | `records/mac-build/`, `records/cloud/` |
| M3 | Each compiled module leaves about 0.7 MB of compiled output plus a regenerable setup file of 5 to 6 MB or more. Lake does not need the setup file of a module that is already built: on the real tree, deleting the setup files of 641 and 644 finished modules and restarting the build recompiled none of them | `docs/performance-notes.md` section 4; `scripts/prune_setup_files.sh`; `records/cloud/full-rehearsals/` |
| M4 | A cloud machine with 16 cores and 32 threads compiled 29,633 modules, with import closures up to 17,860, at 3.2 to 3.5 per second, and kernel-checked 2,233 at 3.7 per second, with zero failures in both | `records/cloud/pilot/` |
| M5 | Cloud prices and quota behaviour as read on 2026-11-20 | `records/cloud/`, `docs/cloud-notes.md` |
| M6 | Extrapolated from M4: a full build takes about 16 hours on that machine (14 to 18). No module above 17,860 imports has been compiled anywhere, so the top of the tree is extrapolation | `python3 analysis/pilot_estimate.py records/cloud/pilot/pilot-20261120-162141 records/source/import_graph.json.gz`; `docs/cloud-notes.md` section 8 |
| M8 | With the stock tool, the cost of one kernel check grows with the number of compiled modules, because `leanchecker` lists every compiled file on the search path before each check: 4.4 seconds of wall time per check with 1,792 modules compiled and 8.5 with 29,633 (8.3 CPU seconds), at 32 checks at a time. A line through those two points gives about 30 seconds per check and about 46 hours for the whole tree, against about 5 hours for the same replay without the listing; that last figure is a projection from the stock tool's measurements, not a measurement of `rhv-replay`. An earlier version of M6 said 14 hours; that figure assumed the cost of a check did not depend on the size of the tree | `python3 analysis/replay_cost.py`; `records/cloud/replay_cost.json`; `docs/performance-notes.md` section 10 |
| M9 | A full run is therefore estimated at about 63 billed hours and 118 USD with the stock tool for the whole tree (60 to 73 hours), or about 23 hours and 44 USD with `rhv-replay` followed by the stock tool on a sample (20 to 31 hours). The second counts towards criterion C3 only under a dated amendment to the pre-registration | the same; `docs/cloud-notes.md` section 8.5 |
| M7 | A compiler process maps five files per library module (52,260 before any project module) and about one per project module imported. Private memory grows by about 13 KB per imported project module | `records/mac-build/mapped-files-sample.txt`; `records/cloud/pilot/pilot_estimate.json` |

Throughput on a small machine in the first hours cannot be extrapolated to the whole tree: later modules import far more, and memory runs out before CPU does. See `docs/performance-notes.md`. M6 is an extrapolation too. It rests on measured import costs up to closures of 17,860. A first version of it was reviewed by three AI agents, whose criticism is recorded beside it; the figures here come from the script as revised afterwards. Neither the reviews nor the script caught the error that M8 records; an audit of the full-run driver did, before any full run. M8 and M9 rest on two measurements and a straight line. All three are estimates of cost, not evidence about the proof.

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
- The kernel replay's prefix pass, which covers the 114 modules whose name is a prefix of another module's name, has been run only on a seven-module test project and, by hand, on two such modules of the real tree.
- The kernel replay has not been run on a full tree by either method. The figures in M8 and M9 are a line through two measurements. `rhv-replay` has been compared with the stock tool on 30 real modules and on a seven-module test project with injected faults (`docs/performance-notes.md`, section 10); it has been reviewed twice by AI agents (`records/cloud/replay_method_review.json`, `records/cloud/replay_method_recheck.json`), not by a person.
- Whether a replay by `rhv-replay` can count towards criterion C3. The pre-registration names `leanchecker`, and no amendment has been made.
- The driver for a full cloud run (`cloud/gcp/full_guest.sh`) has been rehearsed on a seven-minute build (`records/cloud/full-rehearsals/`) and not run in full. The rehearsal does not reach a failed build, the second build pass, the completeness check, the axiom check on the final theorem, or the prefix pass.
- The Linux code paths of the numbered scripts have been run only in part (through the cloud pilot); the scripts were developed on macOS.
