# What would count as verified

Status on 2026-11-20: **not verified.** The compile is in progress. At 02:01 UTC on 2026-11-21, 23,981 of the 175,187 modules had compiled on the local machine, with zero failures ([`../records/mac-build/progress-20261120-2001.txt`](../records/mac-build/progress-20261120-2001.txt)). The final reduction step has been compiled and its axioms checked by the Lean kernel. The theorem that carries the difficulty has not been reached. Current figures are in [`../records/`](../records/).

This page says which checks decide the question, what each one rules out, and what still has to be trusted after all of them pass. It makes no claim that the proof is correct or incorrect.

The status line above and the dated columns below are kept as they were written. The present state is in [`../README.md`](../README.md) and [`../CLAIMS.md`](../CLAIMS.md).

## The claim being checked

The source tree ends in a file `Main.lean` whose first theorem is

```lean
theorem riemannHypothesis : RiemannHypothesis := rhOfAll
```

`RiemannHypothesis` is not defined in the tree. It is Mathlib's own definition, in `Mathlib/NumberTheory/LSeries/RiemannZeta.lean`:

```lean
def RiemannHypothesis : Prop :=
  ∀ (s : ℂ) (_ : riemannZeta s = 0) (_ : ¬∃ n : ℕ, s = -2 * (n + 1)) (_ : s ≠ 1), s.re = 1 / 2
```

In words: every zero of the Riemann zeta function, other than the trivial zeros at the negative even integers, has real part one half. (Mathlib's `riemannZeta` is a total function and has a value even at the pole `s = 1`; the clause `s ≠ 1` excludes that point.)

`Main.lean` states four further theorems: one more form of the statement about zeros of the zeta function, and three statements about Dirichlet L-functions (non-vanishing to the right of the critical line for every character, and zeros in the critical strip lying on the line, for all characters and for primitive characters). Their propositions are defined in `Statements.lean`, a 16-line file in the tree that imports only Mathlib. The three about Dirichlet L-functions are stronger than the headline statement. All four have to be read in that file, because they are not Mathlib definitions.

The tree pins Lean `v4.33.1` and requires Mathlib from the official repository at commit `0df444a360eaa60ab8c11dca51a86af692955474`, which is the official tag `v4.33.1`.

## The three decisive checks

All three must pass. None of them alone is enough.

| # | Check | How it is done | State on 2026-11-20 |
|---|---|---|---|
| 1 | The whole tree compiles with zero errors | `lake build` of every target in the tree's own `lakefile.toml`, with the pinned toolchain and the pinned Mathlib | In progress: 23,981 of 175,187 modules at the last recorded snapshot, zero failures |
| 2 | The headline theorem has the right type and only the standard axioms | In a new file that imports `Main`: confirm that the type of `riemannHypothesis` is the constant `RiemannHypothesis` and that this constant comes from Mathlib's module; run `#print axioms riemannHypothesis` and require exactly `propext`, `Classical.choice`, `Quot.sound` | Not yet possible. Done for the last lemma of the chain only (see below) |
| 3 | An independent kernel replay of every module agrees | `leanchecker`, the replay tool shipped with the toolchain, run on each compiled module in its own process | Not yet possible. Random samples of 24 compiled modules on a Mac, and of 565 and 2,233 on a cloud machine, were replayed and all passed, as were all 1,792 modules of a rehearsal build |

### Check 1: the whole tree compiles

When Lean compiles a module, every definition and theorem is sent to the kernel, a small type checker, before it is added to the environment. A proof the kernel does not accept is a compile error. So a clean compile means that each of the roughly 17.4 million lines elaborated into terms the kernel accepted, in dependency order, ending with `Main`.

What it rules out: a gap, a wrong step or a type mismatch anywhere in a declaration that was compiled; a file that does not build against the stated Lean and Mathlib versions.

What it does not rule out by itself:

- A theorem that is accepted but rests on an extra axiom or on `sorry`. Lean accepts those and records them. Check 2 looks for them.
- A headline statement that is not what it appears to be, for instance because a local definition shadows a Mathlib name. Check 2 looks at the compiled theorem's actual type.
- Code that runs at compile time and interferes with the normal path from source text to kernel. Check 3 does not depend on that path.

Every one of the 175,187 modules is in the import closure of `Main`, so "the tree compiles" and "`Main` compiles" are the same requirement here.

### Check 2: type and axioms of the compiled theorem

`#print axioms` walks the actual dependency cone of a compiled constant, declaration by declaration, and lists every axiom it reaches. This is logical dependence, not file import: it reports what the proof term uses.

Lean and Mathlib themselves rest on three axioms: `propext` (propositional extensionality), `Classical.choice` (the axiom of choice) and `Quot.sound` (soundness of quotients). Most of Mathlib depends on all three. A proof of `RiemannHypothesis` from exactly these three is a proof in the same logical setting as the rest of Mathlib.

What it rules out:

- `sorry` anywhere beneath the theorem. It would appear as `sorryAx`.
- An axiom declared anywhere beneath the theorem, including in declarations that are generated by a metaprogram at compile time and so never appear in the source text.
- `native_decide` and similar, which would appear as `Lean.ofReduceBool` or `Lean.trustCompiler`.
- A statement that only looks like the Riemann Hypothesis. The check is on the compiled constant's type and on the module the constant `RiemannHypothesis` is defined in.

What it does not rule out: the report is produced by Lean itself, running with the whole project loaded. That is the normal way to do it, and the static audit ([`source-audit.md`](source-audit.md)) found no compile-time code that interferes with commands or performs IO. It is still a reason not to rely on check 2 alone.

Text scans of the source on 2026-11-20 found zero occurrences of `sorry`, `admit`, `axiom`, `native_decide`, `unsafe`, `implemented_by`, `extern` and `#eval`. Those scans are supporting evidence only. They cannot see generated declarations. Check 2 can.

### Check 3: independent kernel replay

`leanchecker` reads a compiled module from disk and passes every declaration in it to the kernel again, in a fresh process, without the elaborator, the tactic framework or any of the project's compile-time code. If a declaration that the kernel would reject had reached the compiled file by some other route, or if a compiled file had been altered or corrupted into something invalid, the replay fails.

Why it matters for this tree in particular. The source contains three small metaprograms: two tactics that defer type checks from the elaborator to the kernel, and one command that adds generated declarations to the environment. By static reading all three work through the ordinary interfaces, so that every resulting declaration is sent to the kernel. The replay is how that reading is confirmed rather than assumed.

What it rules out: reliance on the compile having followed the normal path; damage to the compiled files between compile and check.

What it does not rule out: `leanchecker` uses the same kernel implementation as the compiler. It is independent of the elaborator and of the project's code, not of the kernel. It also accepts axioms, which are legal declarations, so it does not replace check 2. As planned it covers the 175,187 project modules; Mathlib's compiled files are a separate matter (see below).

How it is run. The pre-registration says `leanchecker` from the pinned toolchain; this repository runs it one process per module ([`../scripts/09_kernel_replay.sh`](../scripts/09_kernel_replay.sh) `--c3`). The tool lists every compiled file on its search path before each check, and with the whole library on that path a replay of the tree is estimated at about 46 hours on a 32-thread machine, most of it spent listing and not checking. So each process is given a search path that holds, of this project, only hard links to the compiled files of its module and of what that module imports: the same tool, shown the same files, with nothing else in view. That is projected at about 8.5 hours and has not yet been run on a full tree ([`performance-notes.md`](performance-notes.md), section 10). If the set of imports were ever computed too small, the tool would report a missing file and the module would be recorded as not checked; it could not pass. The script can also run the same replay function through a small program of this repository, `rhv-replay`, as a second replay. That is not the tool the criterion names and it does not count towards the criterion; a module that either tool rejects is not counted as passed.

## What has been checked so far

| Item | Result | Date | Kind of evidence |
|---|---|---|---|
| Archive: 14 parts, 239,275,554 bytes, SHA-256 `9631b4f0…49c7fc`; 175,190 regular files, no symlinks or executables | Recorded | 2026-11-20 | Direct inspection |
| Pinned Mathlib commit is the official tag `v4.33.1`, differing from `v4.33.0` only in the toolchain file | Confirmed | 2026-11-20 | Direct comparison |
| Text scan of all 17,374,215 lines for `sorry`, `admit`, `axiom`, `native_decide`, `unsafe`, `implemented_by`, `extern`, `#eval`, and for file or process IO | Zero occurrences | 2026-11-20 | Text scan |
| `Main.lean` states `riemannHypothesis : RiemannHypothesis` with Mathlib's definition | Confirmed | 2026-11-20 | Static reading; to be repeated on the compiled theorem |
| Every module is in the import closure of `Main` | 175,187 of 175,187 | 2026-11-20 | Import graph computed from the source |
| Reduction from "every Dirichlet L-function is non-vanishing for real part above 1/2" to `RiemannHypothesis` | Read line by line | 2026-11-20 | Static reading |
| `Formalism.VW.rh_of_right`, the last lemma of that reduction | Compiled; axioms are `propext`, `Classical.choice`, `Quot.sound` only | 2026-11-20 | Lean kernel |
| Kernel replay of randomly chosen compiled modules | 24 of 24 passed on a Mac; 565 of 565 and 2,233 of 2,233 on a cloud machine | 2026-11-20 | Lean kernel |
| Whole-tree compile | 23,981 of 175,187 modules at 02:01 UTC on 2026-11-21, zero failures. Separately, a cloud pilot compiled 29,633 with zero failures | 2026-11-20 | Lean kernel, in progress |
| `UpperTheory.FinalTheorems.everyCharacter`, the theorem that carries all the difficulty | Not yet compiled; only a few percent of the modules it imports have been | 2026-11-20 | None yet |

The lemma that has been kernel-checked says: if the zeta function has no zeros with real part above 1/2 other than at `s = 1`, then `RiemannHypothesis` holds. Its file imports only Mathlib and its proof is the functional equation. It is the easy end of the argument. It shows that the last step is accepted by the kernel and, since that file imports nothing but Mathlib, that its conclusion is Mathlib's proposition. It says nothing about the hypothesis it takes.

## Why intermediate definitions cannot weaken the headline theorem

The source defines thousands of its own notions and states a great many intermediate propositions in terms of them. The static audit found that some of these are weaker than their names suggest, that some hypothesis bundles are never used, and that names in general are a poor guide to content. A reasonable worry is that this could make the final theorem mean less than it says. For the headline theorem it cannot, for the following reason.

The proposition `RiemannHypothesis` is fixed by Mathlib. It mentions only Mathlib's complex numbers and Mathlib's `riemannZeta`. Nothing in the tree can change what it says.

A proof is a term whose type is that proposition. The kernel checks each step of the term against the rules of the logic. Inside the term, the tree's own definitions are abbreviations: the kernel can always unfold them to what they stand for, and a definition cannot add an assumption. So:

- If an intermediate proposition is weaker than its name suggests, it is easier to prove and harder to use. Any later step that needs more than it actually says will be rejected by the kernel.
- If an intermediate proposition is vacuous, it proves nothing further. A vacuous lemma cannot be turned into a non-vacuous conclusion.
- If a bundle of hypotheses is never supplied, no theorem without hypotheses can depend on it.
- If a name is misleading, the kernel does not read names.

The only two places where meaning enters are therefore the two ends: the statement, which is Mathlib's, and the axioms, which check 2 lists. Everything in between is scaffolding that either holds the weight or fails to compile.

This is why the audit's findings about weakened and mislabelled intermediate statements are recorded as matters of description, not of soundness. They matter a great deal for understanding what the argument is, and for knowing where to look if the compile fails. They do not bear on whether a kernel-accepted proof of Mathlib's proposition is a proof.

Two limits on this reasoning:

- It applies to `riemannHypothesis`, whose statement is a Mathlib definition. The other four theorems in `Main.lean` are stated through definitions in `Statements.lean`; those 16 lines have to be read, and they are written entirely in Mathlib terms.
- It assumes checks 1 to 3 pass. Until then it is an argument about what a pass would mean.

## What remains outside the three checks

If all three checks pass, the following are still being trusted.

| Trusted | Why it is outside the checks | How the trust could be reduced |
|---|---|---|
| The Lean kernel, version 4.33.1 | Both the compile and the replay use it. A kernel bug that accepted a false proof would be shared by both | Export the proof and check it with an independently written checker. Not attempted when this page was written; done since, by others first and here on 2026-11-24 and 25 ([`../CLAIMS.md`](../CLAIMS.md), X1 to X3) |
| The toolchain binaries | `lean`, `lake` and `leanchecker` are the official release binaries installed by `elan` | Build the toolchain from source |
| The three axioms | They are the foundations of Mathlib, including the axiom of choice | Not reducible; this is the logical setting of the claim |
| Mathlib's definitions | The claim is exactly as meaningful as Mathlib's `riemannZeta`, `ℂ` and `RiemannHypothesis` are faithful to the mathematics | These definitions are public and short enough to read; the pinned commit is the unmodified official tag |
| Mathlib's prebuilt cache | Mathlib's compiled files, and those of the packages it depends on, are downloaded from the Mathlib project's cache instead of being compiled locally, so their kernel checking was done by Mathlib's own build system. Since 2026-11-27 the scripts in `scripts/` run Lake with `LAKE_NO_CACHE=1`, so that it does not download another prebuilt build of those packages on its own (from Reservoir or their GitHub releases; their lakefiles at the pinned commits ask for none). Runs before then did not set it, and the default target's cloud guest scripts in `cloud/gcp/` (its cloud C1 build included) do not, so no cloud run has set it (`target_guest.sh`, for another target, runs the numbered scripts, which set it, and has not been run) | Compile Mathlib from source, or replay Mathlib's modules as well |
| The archive | The checks apply to the bytes with the recorded SHA-256 | Compare the hash of your own download with the recorded one |
| The machine | Hardware and operating system are assumed to work | Repeat on a second machine; the cloud scripts exist partly for this |

## What a pass would and would not mean

A pass would mean: the Lean 4.33.1 kernel accepts a term of type `RiemannHypothesis`, as defined in Mathlib at tag `v4.33.1`, depending on no axioms beyond `propext`, `Classical.choice` and `Quot.sound`, built from the archive with the recorded hash; and an independent replay of every project module agrees.

A pass would not, by itself, explain the argument, establish which intermediate results are new, or confirm that intermediate propositions named after published theorems state those theorems. Those are questions about the mathematics, and reading is the only way to answer them. [`proof-outline.md`](proof-outline.md) is a first map.

A failure of check 1 would be located at a specific declaration in a specific file. A failure of check 2 would name the offending axiom. A failure of check 3 would name a module. In each case the result would be reported as found, with the evidence.
