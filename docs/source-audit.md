# Static audit of the source

Carried out on 2026-11-20, while the compile was in progress.

Everything on this page comes from reading source text, apart from the two rows marked as kernel results. It is evidence about what the source says. It is not evidence that the proofs are correct, and none of it replaces the three checks in [`verification-criteria.md`](verification-criteria.md). Nothing here says the proof is valid or invalid.

Identifiers quoted in `code` are the source's own names. Some of them contain the names of published theorems. They are quoted so that findings can be located. Names of mathematicians on this page appear only as the standard names of theorems and objects, and do not indicate that anyone has any connection with the formalization.

## Method

Three kinds of work were done.

1. **Whole-tree text scans and an import graph**, run directly on all 175,187 `.lean` files (17,374,215 lines) before the build was started.
2. **Direct reading** of the top of the chain and of every file containing compile-time code.
3. **A structured reading by 43 AI agents**, all read-only, none of which compiled anything:

| Role | Agents | What each did |
|---|---|---|
| Primary readers | 12 | 2 traced the top of the argument declaration by declaration ("spine" maps, 68 and 70 nodes). 6 mapped areas of the tree. 1 compared the tree with the announcement's 20-item outline. 2 read every use site of the kernel-deferring tactics. 1 looked for vacuous or trivially satisfied hypotheses. |
| Second readers | 2 | Each re-opened every node of one spine map in the source and checked the quoted statement, the paraphrase and every dependency edge. |
| Adversarial reviewers | 29 | Each was given one flag raised by a primary reader and asked to try to refute it against the source. |

The primary readers raised 115 flags and rated them: 1 high, 28 medium, 39 low, 47 informational. Every flag rated medium or high, 29 in all, went to a reviewer. None of the 86 low or informational flags was reviewed; where this page reports one of those, it says "one reader".

Limits of the method:

- The readers are language models. They misread things. The second readers found dependency-edge errors in about a quarter of the spine nodes (see [`proof-outline.md`](proof-outline.md)).
- Most "never used", "never constructed" and "only at its definition" findings rest on text search for identifiers, not on a dependency extraction from compiled files. Several reviewers say so explicitly.
- Some whole-tree searches were skipped or limited because the build was using the same disk.
- No reader assessed whether a proof body is correct. Proof bodies below the top few levels were mostly not read at all.

## What was scanned

All rows: direct inspection or text scan on 2026-11-20, not reviewed by a second party.

| Item | Result |
|---|---|
| Archive | 14 parts, 239,275,554 bytes, SHA-256 `9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc` |
| Archive contents | 175,190 regular files; no symlinks; no executables; 175,187 `.lean` files |
| Build configuration | A declarative `lakefile.toml`; Lean `v4.33.1`; Mathlib required from the official repository at commit `0df444a360eaa60ab8c11dca51a86af692955474` |
| Mathlib pin | The commit is the official tag `v4.33.1`, which differs from `v4.33.0` only in the toolchain file |
| `sorry`, `admit` | 0 occurrences |
| `axiom` | 0 occurrences |
| `native_decide` | 0 occurrences |
| `unsafe`, `implemented_by`, `extern` | 0 occurrences |
| `#eval` | 0 occurrences |
| File or process IO | 0 occurrences |
| Import closure of `Main` | 175,187 of 175,187 modules |
| External imports | Mathlib (156,238 import lines); `Lean` itself (12 import lines, all in 7 files of compile-time code described below); `Batteries` (3 import lines) |

Options set in `lakefile.toml`: `autoImplicit = false`, `relaxedAutoImplicit = false`, `maxSynthPendingDepth = 3`, `pp.unicode.fun = true`, `maxHeartbeats = 4000000`, and the compiler argument `--tstack=400000`. One library sets `synthInstance.maxHeartbeats = 400000`. None of these affects kernel checking.

Things near the scan terms that the scans above do not report, recorded for completeness:

| Item | Where | Checked by | Comment |
|---|---|---|---|
| `decide +kernel` | 124 lines in 34 files across the tree (whole-tree scan, 2026-11-20). Six of them, under `Development/AbelianVarietyTheory/Proofs`, were opened and read: a numeric table, a bound `lcm ≤ 4^n` for `n ≤ 100`, Bernoulli numbers, prime factors of small numbers | Count: script-reproducible. Content: one reader, six files only; the other 28 files were not read | The kernel does the evaluation itself; this adds no axiom. It is not `native_decide` |
| `set_option allowUnsafeReducibility true` | 37 lines in 33 files across the tree (whole-tree scan, 2026-11-20). One, `…/Proofs/IwasawaDecomposition/NonemptyLocalPeriodRingsData.lean`, was opened and read | Count: script-reproducible. Content: one file read | A reducibility setting for the elaborator. Not an `unsafe` declaration; it does not affect what the kernel accepts |
| `run_cmd` | 5 files in `BuildAid` | Read in full | See below. A scan for `#eval` does not find `run_cmd` |
| `partial def` | The two metaprogram files below | Read in full | Helper functions of the metaprograms, not used in proofs |
| A search for `debug.skipKernelTC` and any `set_option debug.*` | All 175,187 files | One reviewer | 0 occurrences |

## Results by category

"Reviewer" means an adversarial reviewer tried to refute the finding and could not. Severities are the reviewer's, on the scale high, medium, low, informational. They measure how much a finding changes the way the argument should be described. No finding in this table is a demonstrated error in a proof.

| Category | Finding | Checked by |
|---|---|---|
| Forbidden constructs | None of `sorry`, `admit`, `axiom`, `native_decide`, `unsafe`, `implemented_by`, `extern`, `#eval`, IO | Text scan |
| Kernel-bypass options | No `debug.skipKernelTC` or other `debug` option anywhere | Reviewer |
| Headline statement | `riemannHypothesis : RiemannHypothesis`, Mathlib's definition, stated with no hypotheses | Direct reading |
| Final reduction | `Formalism.VW.rh_of_right` compiles and depends only on `propext`, `Classical.choice`, `Quot.sound` | **Lean kernel** |
| Sample replay | 24 randomly chosen compiled modules replayed with `leanchecker`; 24 passed | **Lean kernel** |
| Compile-time code | 5 `run_cmd` stubs and 3 metaprograms; none performs IO; none adds an axiom | Direct reading |
| Kernel-deferring tactics | About 820 direct use sites in 77 files (definition files included); every one read; all are transports between two versions of the same record; none has goal `False` or does arithmetic | Two readers; one flag reviewed, informational |
| Generated declarations | One command clones a chain of theorems under new names at compile time; at least one clone is used downstream and has no source text | Reviewer, low |
| Hidden hypotheses | Theorems with closed-looking signatures that take a `[Fact P]` instance hypothesis from a `variable` line; 204 files in `Formalism` | Reviewer, medium |
| Statements that are not theorems | Results are routinely written as `def X : Prop` with a separate, often conditional, proof; a `Statement`, or even a declaration named `.proof`, is not an unconditional theorem | Reviewer, medium |
| Hypothesis bundles never supplied | Two large bundles (23 and 62 fields) appear only as hypotheses; about 2,686 files hold theorems conditional on them | Reviewer, medium |
| Duplicate branches | A parallel copy of the endgame, and "fat" and "slim" versions of several hypothesis bundles, coexist; the top-level chain uses one of each | Reviewer, low |
| Literature-named statements | The three fields of the bundle that the final chain consumes carry statements weaker than the published theorems their names cite, and all three are supplied by in-tree theorems | Reviewer, medium (raised independently by several readers) |
| In-tree proofs of published results | About 190 results named after published theorems are each given a hypothesis-free in-tree proof term | Reviewer, medium |
| Structure of the endgame | The decisive inequality is deduced from the existence of a record of real numbers satisfying a system of inequalities; the mathematical weight is upstream | Reviewer, medium |
| New arithmetic input | A bound on Galois cohomology groups on the critical path is not a known theorem and is derived in-tree | Reviewer, medium |
| Names | Directory, file, namespace and declaration names are often unrelated to content, with signs of mechanical renaming | Two reviewers, medium |
| Vacuity | No bundle found whose fields are all trivially true; isolated slots are literally `True`; one index type is empty at an early stage and non-empty later | Reader; one flag reviewed, low |

## The compile-time code

Seven files import `Lean` directly: the five stubs below and the files that define `kexactB` and `kcopy`. The third metaprogram, `cpt_copy_thms`, reaches Lean's internals through Mathlib. All eight files were read in full on 2026-11-20. This is static reading.

**Five stubs.** `BuildAid/D1.lean` to `D5.lean` each consist of one command of the form

```lean
run_cmd Lean.modifyEnv fun env => Lean.LibrarySuggestions.nameDenyListExt.addEntry env "…"
```

Each adds one namespace string to the deny list of Lean's library-suggestion feature. They add and change no declarations.

**Three metaprograms.**

| Name | File (under `src/Formalism`) | Size | What it does |
|---|---|---|---|
| `kexactB` | `LocalToGlobal/IndefiniteReal/HeckeNonvanishing/Imports.lean` | 8 lines | A tactic. Elaborates the given term with no expected type and assigns it to the goal directly. The elaborator therefore never compares the term's type with the goal; the kernel does, when the finished declaration is checked |
| `kcopy` | `LocalToGlobal/NumberFieldFamilies/OwnStruct.lean` | 66 lines | A tactic. Rebuilds a structure value field by field at the goal's type, using raw projections, and assigns the result to the goal. Same deferral as `kexactB`. The file also defines a diagnostic command `#kcopy_probe`, which is not used anywhere |
| `cpt_copy_thms` | `HermitianCurvature/HermitianCurvatureProofs/CutCptCopy.lean` | 91 lines | A command. Starting from six named theorems, finds the declarations that depend on a listed set of constants and adds a copy of each under a name with the suffix `Cpt`, with those constants replaced according to two hand-written tables. Copies are added with `addDecl`, the ordinary interface, which sends each one to the kernel. It handles only definitions and theorems, so it does not itself declare axioms. It is invoked once in the whole tree |

The whole of `kexactB` is:

```lean
elab "kexactB " e:term : tactic => withMainContext do
  let g ← getMainGoal
  let v ← Term.elabTermAndSynthesize e none
  g.assign (← instantiateMVars v)
```

Several term and tactic macros wrap these: `kc%`, `kq%`, `kd%`, `tr_via`, `tr_clause`, `tr_leaves`, `tr_delta`, and the file-local `ksub`, `keq`, `pre_cases`, `tie_cases`, `coef_cases`, `copyDec%`, `copyIsV%`. A search for the tactic names alone undercounts the sites.

What "deferring to the kernel" means, and why it is not a bypass. Lean's elaborator is never part of the trusted base. Every declaration, however its proof term was produced, is checked by the kernel against its independently elaborated statement. A tactic that skips the elaborator's own comparison only removes an early error message. If the two types were not definitionally equal, the kernel would reject the declaration and that file would fail to build. The reviewers who examined this (two flags) both reached that conclusion and rated the pattern informational. It is nonetheless the reason the independent kernel replay matters for this tree: correctness at these sites rests on the kernel alone.

One other piece of metaprogramming was noted by one reader: an ordinary Mathlib `positivity` extension for one function, in `Formalism/SharpRestriction/RamificationFrobenius/TotientGaloisClasses/EvalFrameOrd.lean`.

## The kernel-deferring tactics: all use sites

Two readers divided the tree between them and read every site. Counts exclude the macro definitions.

| | Reader A | Reader B |
|---|---|---|
| Scope | `Development/AbelianVarietyTheory/Proofs` (95,418 files) | Everything else |
| Files matching | 50 (45 with real sites; 5 only define a local macro that is never used) | 27 (4 in `Formalism`, 11 in `…/Definitions/AutomorphicMembership`, 12 in `…/ThetaPairLifts/ThirdPlaceSeries`) |
| Direct `kexactB` | 194 | 38 |
| `kc%` | 162 | 230 |
| `kcopy` | 5 | 0 |
| `tr_via` / `tr_clause` / `tr_leaves` | 15 / 1 / 5 | 33 / 20 / 3 |
| Local wrappers (`ksub`, `keq`, `pre_cases`, `tie_cases`, `coef_cases`, `kq%`, `copyDec%`, `copyIsV%`) | 116 | 0 |
| `cpt_copy_thms` invocations | 0 | 1 |
| Sites examined | 498 | 322 |
| Goal assignments after macro expansion | About 1,090 `kexactB` plus 5 `kcopy` | 354 |
| Elaborator-checked siblings (`with_unfolding_all exact`) in the same files | 1,932 | 920 |

What the sites do, according to both readers:

- Every site is a **transport**. A hypothesis, structure field or reflexivity proof stated over one instance of a large record is used over another instance that shares the same base data and differs only in data added at a later stage of a staged construction.
- No site has goal `False`. No site evaluates arithmetic. None involves quotients, well-founded recursion, large numeric literals, string literals or universe manipulation.
- In the same files, sibling goals with the same kind of type difference are closed by `with_unfolding_all exact`, which the elaborator does check. The deferring tactics look like the fallback where that check was too slow or did not go through. Many of these files raise `maxHeartbeats` to between one and eight million.
- Both readers rated every site "probably" a real definitional equality. Neither could confirm any site by hand at this size, and both say so.

One flag from this work was reviewed. Local macros in three files turn a heterogeneous equality into an ordinary one by asserting to the kernel alone that two types coincide (81 + 5 + 9 direct uses, 667 `kexactB` after expansion; the reviewer reproduced these counts exactly). The reviewer confirmed the description and rated it informational, for the reason given above.

Observations from this work that were **not** reviewed (one reader each):

- `kc%` appears inside the *statements* of four lemmas in one file, so what those lemmas literally assert depends on kernel conversion and not on what a reader sees.
- Fifteen to twenty data-level definitions and structure fields, not only proofs, are typed by the kernel alone.
- Several lemmas consist entirely of a reflexivity proof handed to a goal of a different syntactic shape.
- `kcopy` emits raw projections, including out of proposition-valued structures (5 sites).
- One definition supplies an identity isometry between two nominally different spaces.

None of these is a known problem. They are the places where an independent kernel replay is doing the most work.

**Generated declarations.** `cpt_copy_thms` is invoked once, under `set_option maxHeartbeats 0`. By reading, it re-derives a chain of theorems that was written against a hypothesis for which one reader found only conditional derivations, replacing that hypothesis by a compact-support variant that the tree does state as a theorem. A reviewer confirmed that one generated name is used downstream and is declared nowhere in the source text, and inferred that further generated declarations must exist. The same reviewer, having read the toolchain source, adds that if the kernel rejects a generated declaration, `addDecl` raises an error and the module fails to build. The number generated cannot be known without running the command; the build log reports it. These declarations are invisible to every text scan on this page. For them the evidence has to be `#print axioms` on the compiled theorem and the kernel replay.

## Vacuity and trivial patterns

One reader looked specifically for hypotheses that are trivially satisfied and for statements that hold only vacuously. Two of that reader's flags were reviewed (finding 1 and the "empty index type" row below). The rest of this table is one reader's work.

| Pattern searched for | Count found | Reader's assessment |
|---|---|---|
| Hypothesis bundles on the final chain, checked for whether a proof term supplies them | 11 bundles or groups of bundles | 2 fully supplied by named theorems; 5 supplied, with the supplying theorems followed for some fields only; 2 unclear from text; 2 never supplied (an older full-strength bundle and two leftover structures, none of which the final chain uses) |
| A bundle that is inhabited only because all of its fields are trivially true | 0 | None found. The propositions sampled are substantive in form |
| Definitions of the form `Prop := True` | 8 | 4 are emptied slots on the main chain, with names such as `UnusedSlot72` and `NoCondition`; the reader describes two of the others as honest "no condition" instances of a parameter |
| Definitions of the form `Prop := False` | 1 | Used as a switch: two theorems of an older variant take it as a hypothesis and are therefore conditional on `False`. Not on the final chain |
| Declarations whose type is `True` | 11 | 10 anonymous examples used as scaffolding, 1 local step inside a proof |
| Pairs of `trivial` arguments | 156, besides the top of the endgame | At the top of the endgame, in the live copy and in its unused twin, the pair fills two hypothesis slots that are instantiated to `True` and never used (a second reader confirmed this). About 100 of the 156 were read; each proves membership in a top element or universal set |
| Predicates passed as `fun _ => True` | 2,955 | In every case checked the predicate is a premise or a filter, so `True` is the strongest instance, not the weakest |
| An index type instantiated as empty | 1 on the main chain | Reviewed, low: see the table of low-rated findings |
| Families and windows that could be empty | Checked | Guarded: the family structure carries fields stating that its set of scales is unbounded and its index types are non-empty |

## Flags that survived adversarial review

27 of the 29 reviewed flags were not refuted. After review, 14 were rated medium, 7 low and 6 informational; none was rated high. Several are the same finding raised by different readers and are grouped here. Paths are relative to `src/`.

### Rated medium after review

**1. The "literature" bundle on the final chain carries weakened statements, and none of it is assumed.** (Three readers; five reviewed flags. A fourth reader's flag, counted under finding 2, makes the same point.)

The theorem that assembles the result takes a structure named `OpenLiteratureStatements` with three fields. Reviewers confirmed all of the following against the source.

- The bundle is not an assumption of the final theorem. `MainConclusion.lean` supplies it as `⟨h, UpperTheory.Zero.LLC.recTExists, h⟩`, where `h` and `recTExists` are theorems stated without hypotheses.
- Two of the three fields, the first and the third, have the identical type and are filled by the same term `h`. Their names suggest two different published theorems: the first is named after a published local-global compatibility theorem, and the third is `galoisRepOfPolarizedPairLit`.
- That common type, `Row0b` instantiated with `IsRecT`, asserts existence of Galois representations attached to a class of automorphic representations together with a *restricted* local-global compatibility: away from `l` it gives equal dimension, equality of parameters in a toral case, and agreement of inertial characteristic polynomials in a tame case at places isomorphic to `ℚ_p` with `p > 16n²` (or `n = 1`). The tree also defines the full-strength statements; no theorem concluding them was found.
- The theorem that delivers `h` is named `galoisLocalGlobalStrong_recParameter`. It is obtained from a stronger in-tree statement by a weakening step, so it proves the weaker of the two variants.
- The third field, `localLanglandsExists`, has type `RecTExists`. This is not the local Langlands correspondence for `GL_n`. Its laws have no bijectivity and no epsilon-factor condition, and its twist, central-character, dual, injectivity and depth laws are required only for a restricted class of representations. The map constructed to witness it sends every other cuspidal representation of dimension `n ≥ 2` to a fixed placeholder parameter for that dimension, twisted by a real exponent (the construction uses a lemma named `junkEx`). The tree contains a separate, stronger notion, from which this one is derived by discarding conditions.
- A lemma that appears to derive this field from eleven named classical results is the identity function on its first argument.

Reviewers' assessment: a labelling issue, not an assumption and not a vacuity. The statements have real content in the restricted cases and are supplied by proof terms. The accurate description of the top step is "restricted local-global compatibility and a restricted reciprocity map, both claimed proved in-tree, imply the result", not "published theorems imply the result".

**2. About 190 results named after published theorems are given hypothesis-free in-tree proofs.** (Two readers; two reviewed flags.)

`…/ThirdPlaceSeries/EveryCharacterOfLiteratureOfVWin.lean` (814 lines, 208 imports) has 195 declarations that take the bundle above as an argument `O`; 176 are named `…_of_literature`. In 152 of the 195 the body never mentions `O` and is a direct reference to a closed in-tree theorem. The three fields of `O` are projected at four lines only. Results given this treatment include resolution of singularities in characteristic zero (backed by a 499-file sub-library), vanishing theorems, reciprocity laws, and a least-prime-in-progressions bound.

A reviewer sampled seven of the propositions. Three looked full-strength in shape. Four are specialised or formulated over in-tree definitions that were not audited. One field with a literature-sounding name has type `UnusedSlot72`, which is `True`.

Consequence: a proposition's name is not evidence of what it states. Each would need to be read. If the compile succeeds, the kernel will have checked each as stated, whatever it states.

**3. The decisive inequality is deduced from the existence of a record of real numbers.** (One reader; reviewed.)

The single-scale bound at the centre of the endgame follows from a hypothesis that asserts that *some* record of real numbers exists which satisfies an eleven-part system of real inequalities and whose arithmetic fields are pinned to true quantities, chiefly a weighted sum over inert primes. The key step that uses the system is elementary real algebra; a longer analytic deduction then turns its output into the bound. The geometric ties between that record and lattices, slopes and periods are discarded just before this step. The reviewer found corroboration in the tree itself: a lemma showing that any record with the bare top inequality, and some positivity side conditions, can be completed to one satisfying the whole system. So at this point the system carries essentially the top inequality and nothing more.

Reviewer's assessment: not a soundness defect and nothing vacuous. It means the theorems in the endgame that read like inequalities are conditional reductions, and that the mathematical weight is in whatever produces the tied record upstream. That production was not traced.

**4. A new arithmetic statement sits on the critical path.** (One reader; reviewed.)

The final theorem consumes a proposition `VWin`: a bound on the `log l`-weighted total `ℤ_l`-length of certain Galois cohomology groups (Tate-twisted `Ш¹` over a family of abelian number fields), summed over all primes `l` and a long range of twists. Reviewer and reader both regard this as not a known theorem; the reviewer notes that this cannot be settled from the source. It is not assumed: it is derived in-tree from the same term `h` as in finding 1, through a chain with automorphy inputs that was mapped by name only. No vacuity was found in its statement. This derivation and finding 3 are the two natural places to concentrate further reading.

**5. Hidden instance hypotheses.** (One reader; reviewed.)

Files declare `variable [Fact P]`, so that theorems below it whose visible signature is closed in fact take `P` as an instance-implicit hypothesis. The reviewer confirmed the cited cases, counted 204 files in `Formalism` with such a line, and found one line carrying nine such binders. Instances for the cases traced are supplied in `Development` by named theorems or built locally from explicit hypotheses. The files at the top of the chain contain no `Fact` or `variable` lines. Since the tree has no axioms, any such hypothesis the headline theorem needs must be supplied by a real instance or the build fails. The effect is on reading: a source-level signature can understate what a theorem assumes.

**6. A statement is not a theorem.** (One reader; reviewed.)

Results are routinely encoded as `def X.Statement : Prop` plus theorems that are often conditional on other statements. One library of 6,410 files has about 4,186 such statements, 2,930 theorems named `.proof` and 1,367 named `.full` or `.holds`. A `.proof` is often conditional; the reviewer found two that are conditional on each other's statements, and a substantive statement whose only derivations are never used. The reviewer also corrected the reader: at least 1,269 of the `.proof` theorems are hypothesis-free by signature, so the size of the gap is not known from text.

**7. Hypothesis bundles that are never supplied.** (One reader; reviewed.)

`GlobalTheory.ThK.KP` (23 fields) and `GlobalTheory.FunPr.Hypotheses₂` (62 fields) occur only as hypotheses: by tree-wide text search there is no construction of either. No unconditional theorem concludes 16 of the 22 published-result fields of the first. About 2,686 files contain theorems conditional on these bundles. The modules that define this vocabulary are the three most imported non-Mathlib modules in the tree (3,088, 2,972 and 2,518 direct importers). The top-level chain does not use these bundles: it builds a 53-field sub-bundle from in-tree theorems instead. Reviewer's assessment: nothing hidden, but these results must not be described as established.

**8. Names are unreliable.** (Two readers; two reviewed flags; also noted by most other readers.)

Confirmed examples: a theorem named for a divisibility clause that is the functional equation of the zeta function; one declaration name used for three unrelated theorems in three namespaces; a directory named for an exceptional group whose content, where read, concerns unitary groups; a file named for a base-change result that contains one private lemma; a theorem named for a Riemann–Roch space that is a statement about group invariants, proved by `Iff.rfl`; a root namespace token that is also defined as an unrelated type family, consistent with a global rename. One reviewer added a correction: names are unreliable, not uniformly meaningless; in a sample of five directories, 30 to 60 percent of file names matched a declaration inside the file.

Two readers report that none of the directories they sampled contains a single comment or docstring.

### Rated low after review

| Finding | Reviewer's summary |
|---|---|
| A parallel copy of the endgame (`plugWin`, `plugAll`) is compiled but unreferenced; the live chain uses a near-verbatim clone built on `…Alt` definitions | Confirmed one layer deep by side-by-side comparison. An audit has to be done on the live copy |
| `cpt_copy_thms` generates declarations with no source text | Confirmed; see above |
| "Fat" hypothesis bundles coexist with "slim" ones; the top-level chain instantiates only the slim ones | Confirmed, with corrected field counts. Some slim bundles keep a literature-sounding field name and change its type |
| The directory `Development/WeilBound` contains no Weil bound for curves; "Weil" there means the Weil representation, the Siegel–Weil formula, the Weil group | Confirmed. The argument must not be described as using the Riemann hypothesis for curves on the strength of a directory name |
| `Development/EtaleCohomology/WeilConjectures` states a Weil-conjecture purity statement and a proof scaffold as propositions only (91 proposition definitions, 45 theorems); the statement is never proved or used | Confirmed by a token scan of all 104 importers. The main chain uses only small infrastructure lemmas from that directory |
| Some deep results appear as bare propositions that are unused leftovers | Confirmed. Those that are consumed are discharged elsewhere by theorems stated without hypotheses |
| An index type on the main chain is instantiated as empty for "bare" data, which makes several substantive-sounding predicates vacuous at that stage | Confirmed, and vacuity is used at that stage. The source then moves to a second stage where the type is a set of maximal ideals, the predicates are re-proved, and a lemma asserts non-emptiness. Deliberate staging |

### Rated informational after review

| Finding | Reviewer's summary |
|---|---|
| The analytic chain needs square-root bounds at single scales for auxiliary characters of very large conductor | Description accurate. Not circular: the characters of the level under study are excluded and the auxiliary primes are chosen per scale. The existence theorem is stated without hypotheses and its import closure is 293 modules, about 40,500 lines, organised as a mean-square argument with a zero-density estimate. Those modules were not read |
| Local duality theorems for Galois cohomology are defined as bare propositions and consumed as hypotheses | The definitions the reader had not opened are non-degenerate, and the propositions are discharged by hypothesis-free theorems resting on an 85,000-line cohomology development, which was not audited |
| Every statement concluding `RiemannHypothesis` in the second half of `Formalism` is conditional | Confirmed. They are honestly conditional and the main one is unused by the live chain |
| Non-emptiness of the central record type is reduced to the existence of a package of period rings that `Formalism` does not construct | `Development` constructs it. The witness for the record itself is degenerate apart from those fields, so non-emptiness alone shows little |
| `kexactB` | See above |
| The heterogeneous-equality wrappers | See above |

## Flags that were refuted

"Refuted" means the suspected problem was not present in the source as read. It does not mean the proofs concerned are correct.

| Flag as raised | Why the reviewer rejected it |
|---|---|
| Rated high by the reader: deep theorems such as a Siegel–Weil formula for unitary groups are only stated, and are threaded downstream as hypotheses that nothing proves | The reader had searched direct importers only. A theorem of that type exists in a transitive importer, and the main chain's assembly file plugs it in. Two other listed items are also proved in-tree, and four are dead definitions that are neither assumed nor proved. Residual: one item on the list, a uniqueness statement for Bessel maps, has no unconditional proof that the reviewer could find; the main chain's assembly file does not mention it |
| Rated medium by the reader: in-tree proofs of published theorems are stated over custom structures and carry premises, such as non-emptiness of a tied period-ring package, whose satisfiability is not established | A lemma states and proves that the premise is satisfiable for every prime, and the central record type is shown inhabited. The custom structures are tied by ring isomorphisms to period rings built from Mathlib primitives. The premise is a deliberate normalisation: a file of counterexamples shows the statement fails for an untied package. No statement visibly weaker than its name was found among the nine the reviewer read |

## Caveats

These apply to everything above and to [`proof-outline.md`](proof-outline.md).

1. **Names are unreliable.** No claim on this page was accepted on the strength of a name. Every node in the spine maps was described from its statement.
2. **Literature-named fields carry weakened statements.** Where the source uses the name of a published theorem, read the proposition. In the two cases audited closely, both were materially weaker than the theorem named.
3. **Unused duplicate branches exist.** At least one complete parallel copy of the endgame and several superseded hypothesis bundles are compiled but, by text search, unreferenced by the live chain. A reader who lands on the wrong copy will audit something the final theorem does not use.
4. **Import closure is not logical dependence.** All 175,187 modules are imported, directly or indirectly, by `Main`. That shows nothing about which declarations the proof term of `riemannHypothesis` uses. Used and unused can only be separated at declaration level, by `#print axioms`-style traversal of the compiled theorem. Until the compile finishes, every "on the main chain" statement here is textual.
5. **A statement is not a theorem, and a closed signature may hide a hypothesis.** See findings 5 and 6.
6. **Generated declarations are invisible to text scans.** See the section on `cpt_copy_thms`.
7. **Unresolved by any reader:** the proofs beneath the two inputs in finding 1; the derivation in finding 4; the production of the tied record in finding 3; the 293-module mean-square development; whether every one of the roughly 1,450 deferred goal assignments is accepted by the kernel. The compile decides the last of these and, in the sense of [`verification-criteria.md`](verification-criteria.md), all of them.
