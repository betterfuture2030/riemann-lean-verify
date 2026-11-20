# Pre-registration of verification criteria

Registered 2026-11-20 (UTC), before the outcome is known.

This document fixes, in advance, what this project will count as a successful verification of a published Lean 4 formalization that claims to prove the Riemann Hypothesis, and what it will report if verification does not succeed. It is committed while the compile is about six percent complete so that the criteria cannot be shaped by the result.

## 1. The artifact under test

| Item | Value |
|---|---|
| Announcement | `https://alpo.ge/remark.pdf`, SHA-256 `3fc97784b71ddd44ff8aa0a177e99622a1c61b13cfa843a0989ee4a7a0cfeb8d` |
| Distribution | 14 parts, `https://alpo.ge/lean.tar.gz.part01` to `part14`, concatenated in order |
| Size | 239,275,554 bytes |
| SHA-256 of the reassembled tarball | `9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc` |
| Contents | 175,190 regular files: 175,187 `.lean` files (17,374,215 lines), `lakefile.toml`, `lake-manifest.json`, `lean-toolchain` |
| Lean toolchain (from `lean-toolchain`) | `leanprover/lean4:v4.33.1` |
| Mathlib (from `lake-manifest.json`) | `leanprover-community/mathlib4` at `0df444a360eaa60ab8c11dca51a86af692955474`, the official tag `v4.33.1` |
| SHA-256 of `lakefile.toml` | `b831ad8cac0babb7bf713433259bdfe5163e58c90734e86d71536d4e30ddec4c` |
| SHA-256 of `lake-manifest.json` | `fee57ee9ed399d0a638ca955e5ad40a37a36eeb9b6dfd9f5964114fa7bbe4774` |
| SHA-256 of `lean-toolchain` | `3aac669c7a910ec2389f4e4f921b605adf6ebf2d1e0c9b9cd0be4d33f3f5db71` |
| SHA-256 of `src/Main.lean` | `017645ca448f2fd1f6fd5c4c2cb2c6e96e472725be13f6e180ca6e1574360939` |
| SHA-256 of `src/Statements.lean` | `79ef7ca776e42abe1f46caee13ea09bd19f1e2d0b1620d8d5d200258f33b47bf` |

The claim under test is the theorem in `src/Main.lean`:

```lean
theorem riemannHypothesis : RiemannHypothesis := rhOfAll
```

together with the four further theorems in the same file about zeros of the Riemann zeta function and of Dirichlet L-functions.

If the files at the distribution address change, this project continues to test the artifact with the hash above and will report the change.

## 2. What was known when this was written

Stated so that a reader can judge how much the criteria could have been influenced by results already seen. The figures are as of 2026-11-20T21:51Z. The compile continued between writing and publication; later progress is recorded in `records/`.

- 11,162 of 175,187 modules had compiled on one machine, with zero compile failures. These are the shallowest modules in the import graph.
- One lemma near the top of the argument, `Formalism.VW.rh_of_right`, had been compiled. The kernel reports that it depends only on `propext`, `Classical.choice` and `Quot.sound`, and that its conclusion is the constant `RiemannHypothesis` defined in `Mathlib.NumberTheory.LSeries.RiemannZeta`.
- The kernel checker `leanchecker` had been run on a random sample of 24 compiled modules. All 24 passed.
- A text scan of the whole source had found no occurrence of `sorry`, `admit`, `axiom`, `native_decide`, `unsafe`, `implemented_by`, `extern` or `#eval`.
- Nothing was known about whether the remaining 164,025 modules compile, and the headline theorem had not been compiled.

## 3. Criteria

The verdict **VERIFIED** will be reported if and only if all three of the following hold for the artifact in section 1, unmodified.

**C1. The whole tree compiles.** `lake build` of the default targets completes with exit status 0 and zero module errors, using the pinned toolchain and the pinned Mathlib revision, with no change to any file in the tarball.

**C2. The compiled theorem is the claimed one, on standard axioms.** In an environment that imports `Main`:

- the type of `riemannHypothesis` is exactly the constant `RiemannHypothesis`;
- that constant is defined in the module `Mathlib.NumberTheory.LSeries.RiemannZeta` of the pinned Mathlib;
- `#print axioms riemannHypothesis` lists no axiom other than `propext`, `Classical.choice` and `Quot.sound`;
- a traversal of every declaration reachable from `riemannHypothesis`, through types, proof terms and constructors as loaded from the compiled files, finds no axiom other than those three;
- the same two axiom conditions hold for the other four theorems in `Main.lean`.

Both axiom checks are required because, in this Lean version, `#print axioms` on an imported theorem reports a list recorded when each file was compiled and does not itself re-walk the proofs.

**C3. An independent kernel replay agrees.** Every compiled module of the project is re-checked by `leanchecker` from the pinned toolchain, and every module passes.

## 4. Rules fixed in advance

**No changes to the artifact.** No source file, the toolchain pin, the Mathlib pin or the lakefile may be changed for a run that counts towards C1 to C3. If the tree compiles only after a change, the verdict is NOT VERIFIED AS DISTRIBUTED, and the change is reported separately as a repair.

**What may vary.** The machine, the operating system, the number of parallel jobs, the per-process thread count, and where files are stored. These do not affect what the kernel accepts. Every such setting used will be recorded.

**Mathlib's prebuilt cache.** Using the official prebuilt Mathlib cache for the pinned revision is permitted for C1. This is a trust assumption and is listed in section 6.

**Distinguishing a failure of the proof from a failure of the machine.** Lean's resource limit for elaboration (`maxHeartbeats`) counts work done, not elapsed time, so it does not depend on machine speed; a module that exceeds it reproducibly has failed. A module whose compiler process is killed by the operating system for lack of memory, or by an interrupted run, has not been tested; it is re-run. A module is recorded as failing only when it fails with a Lean error, reproducibly, on a re-run with enough memory.

**A single failure is enough.** If any module fails under the rule above, C1 fails. The report will give the first failing modules in dependency order, the exact errors, and how many modules depend on them.

**Statement and axioms are read from the compiled environment**, not from the source text.

## 5. Possible outcomes and what will be reported

| Outcome | Verdict | Report |
|---|---|---|
| C1, C2 and C3 all hold | VERIFIED, relative to the trust assumptions in section 6 | The evidence for each criterion and how to reproduce it |
| The tree does not compile as distributed | NOT VERIFIED AS DISTRIBUTED | The failing modules, the errors, the affected dependents, and whether a repair exists |
| It compiles but C2 fails | NOT VERIFIED | The actual type or the non-standard axioms, and where they enter |
| C1 and C2 hold but C3 fails | NOT VERIFIED | The modules the replay rejects and why |
| The build cannot be completed with the resources available | INCONCLUSIVE | How far it got, with zero or more failures, and what would be needed to finish |

Partial progress will always be reported as partial. "No failures so far" is not a verdict.

## 6. What a VERIFIED verdict would and would not establish

It would establish that an independent party, on separate hardware, obtained from the Lean kernel an acceptance of a term whose type is Mathlib's statement of the Riemann Hypothesis, using only the three standard axioms, and that a second pass through the kernel agreed.

It would rest on the following, which this project does not itself prove:

- the soundness of the Lean 4 kernel and the correctness of the pinned toolchain binary;
- that Mathlib's definitions of the Riemann zeta function and of `RiemannHypothesis` say what mathematicians mean by them;
- the integrity of Mathlib's prebuilt cache for the pinned revision;
- the correct operation of the hardware and operating system used.

For that reason the verdict will be described as independently reproduced, kernel-checked evidence, and not as proof beyond any possible doubt.

## 7. Optional strengthening checks

These reduce the trust assumptions above. They are not required for the verdict in section 3 and will be reported separately if done.

- S1. Build Mathlib from source at the pinned revision instead of using the prebuilt cache.
- S2. Re-check the proof with a kernel implementation independent of the Lean 4 reference kernel.
- S3. Reproduce C1 to C3 on a second platform (a different operating system and processor architecture).
- S4. Compute the set of declarations that `riemannHypothesis` actually depends on, as opposed to the modules it imports.

## 8. Amendments

The criteria in sections 3 and 4 will not be edited. If something has to change, it will be added below as a dated amendment stating what changed, why, and whether any result was known at the time.

*No amendments.*
