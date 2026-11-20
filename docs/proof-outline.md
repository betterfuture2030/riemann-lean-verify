# An outline of the argument, as read from the source

Written on 2026-11-20, while the compile was in progress.

> **Read this first.**
>
> - This is a reading of **statements**. It describes what the declarations at the top of the source tree say and how they refer to one another. Proof bodies below the top few levels were not read.
> - It was produced by AI agents. The two node-by-node maps it rests on (68 and 70 declarations) were each checked against the source by a second reader. Every declaration was found, and every quoted statement matched the source apart from marked truncations, one unmarked splice and two wrong locations. But the second readers recorded errors on 40 of the 138 nodes. On 35 of the 138, roughly a quarter, the error was in the dependency edges: a dependency listed as direct that is one step removed, an edge pointing at the wrong declaration, or a dependency left out. They also recorded 22 notes where a plain-language paraphrase dropped a hypothesis or simplified the quantifiers. The corrections have been applied below, but the same error rate should be assumed for anything that was not second-read.
> - **None of this says the proofs are correct.** Whether they are is decided by the Lean kernel, and on 2026-11-20, of the chain described here, the kernel had checked only the last step (section 1). See [`verification-criteria.md`](verification-criteria.md).
> - Names in the source are a poor guide to content ([`source-audit.md`](source-audit.md)). Identifiers are quoted here so that declarations can be found, not because their names describe them.
> - Names of mathematicians below appear only as the standard names of theorems and objects, or inside the source's own identifiers. They do not indicate that anyone has any connection with the formalization.

Evidence labels used on this page:

| Label | Meaning |
|---|---|
| kernel | Compiled and checked by the Lean kernel |
| read in full | The whole proof text was read directly, outside the agent audit |
| read twice | Read by one agent, then checked node by node by a second |
| read once | Read by one agent only |
| reviewed | A specific claim that an adversarial reviewer tried and failed to refute |

## 1. The top of the chain

`Main.lean` is twelve lines. Its five theorems are one-line references to four terms defined in a 16-line file `Supplements/Kernels/MainTheorems.lean`. Everything reduces to one theorem.

```
riemannHypothesis : RiemannHypothesis                       Main.lean
  = rhOfAll
  = Formalism.VW.rh_of_every allChi                         functional equation
      allChi = UpperTheory.FinalTheorems.everyCharacter     every Dirichlet L-function is
                                                            non-vanishing for Re s > 1/2
        = everyCharacter_of_row h                           h : a Galois-representation statement
        = every_character_of_literature_of_vWin
              ⟨h, recTExists, h⟩  (vwin_of_row h)
```

| Step | What the statement says | Evidence |
|---|---|---|
| `rh_of_right` | If `riemannZeta s ≠ 0` whenever `Re s > 1/2` and `s ≠ 1`, then Mathlib's `RiemannHypothesis` holds. The file imports only Mathlib. The proof uses the functional equation of the zeta function | kernel (axioms: `propext`, `Classical.choice`, `Quot.sound`); also read in full |
| `rh_of_every` | Specialise the next statement to the trivial character modulo 1, which is the zeta function, and apply `rh_of_right` | read in full |
| `everyCharacter` | For every modulus `N ≥ 1`, every Dirichlet character `χ` modulo `N` and every `s` with `Re s > 1/2`, `L(s, χ) ≠ 0`, except that nothing is asserted at `s = 1` for the principal character. Stated with no hypotheses | read twice |
| `everyCharacter_of_row` | The same conclusion from one hypothesis `h`, which `everyCharacter` supplies from a theorem | read twice |

So the Riemann Hypothesis is obtained here as a special case of the generalised Riemann hypothesis for Dirichlet L-functions, in half-plane form. All the difficulty is beneath `everyCharacter`.

### The three inputs

`everyCharacter_of_row` uses its one hypothesis `h` in three places and adds one further theorem.

| Input | Supplied by | What it says, as read | Evidence |
|---|---|---|---|
| A Galois-representation statement, `Row0b` | `h`, a theorem with no hypotheses named `galoisLocalGlobalStrong_recParameter` | For every CM field, prime `l` and regular algebraic, polarized, cuspidal automorphic representation of `GL_a`, there is a continuous semisimple `l`-adic Galois representation with prescribed Hodge–Tate weights and a *restricted* local-global compatibility | read twice; reviewed |
| A reciprocity map, `RecTExists` | `recTExists`, a theorem with no hypotheses | For every completion of a number field at a finite place there is a map from irreducible smooth representations of `GL_n` to parameters of the Weil group with monodromy satisfying a list of laws, most of which bind only on a restricted class of representations | read twice; reviewed |
| A Galois-cohomology bound, `VWin` | `vwin_of_row h` | Section 4 | read twice (statement); reviewed |

Reviewers confirmed that the first two are materially weaker than the published theorems that the surrounding field names cite, and that nothing here is assumed: each is supplied by a proof term. Details are in [`source-audit.md`](source-audit.md), finding 1. The description that matches the source is: a restricted form of local-global compatibility and a restricted reciprocity map, both claimed proved inside the tree, are the inputs.

Where `Row0b` comes from, by reading of top-level terms only (read twice): it is a weakening of a slightly stronger in-tree statement, which is assembled from a theta-lifting existence theorem between unitary groups, a "geometric realization" statement that is reduced to a Lefschetz fixed-point formula for finite étale correspondences, a congruence statement, a trace-limit statement and two local-global compatibility statements. None of those proofs was read.

## 2. The analytic endgame

This is the part that turns arithmetic input into non-vanishing. It was read twice, and three flags on it were reviewed.

### The smoothed von Mangoldt sums

The basic object is defined exactly as

```lean
def Sz (x : ℝ) : ℝ := ∑ n ∈ Finset.Icc 1 ⌊x⌋₊, Λ n * (x / n - 1)
def Gz (x : ℝ) : ℝ := Sz x - x * Real.log x + (1 + Real.eulerMascheroniConstant) * x
```

that is, `Gz(x) = Σ_{n ≤ x} Λ(n)(x/n − 1) − x log x + (1 + γ)x`: a Riesz-smoothed sum of the von Mangoldt function with its main terms removed. For a non-principal character `χ` there is a twisted version

`gChi(χ, y) = Σ_{n ≤ y} Λ(n) χ(n) (y/n − 1) + y · L′/L(1, χ)`.

For a primitive character `ψ`, the "level" is the set consisting of the zeta function together with the powers of `ψ`. Its test function is

`Gm(y) = Gz(y) + Σ_k w_k · Re gChi(ψ^k, y)`

with positive weights `w_k`. Positivity of the weights is what allows one argument to control every member of the level at once.

### The one-sided bound on windows

The quantity that the whole construction is aimed at is an upper bound, on one side only and only on some scales:

`Gm(x) ≤ x^(1/2 + c·ε)` for all `x` in windows `[Y, Y^(3/2)]`, for arbitrarily large `Y`, for every small `ε`,

where `c` is a constant that does not depend on `ε`. It is not a two-sided estimate, not an explicit formula and not a positivity criterion for a functional.

### The windowed Landau step

A proposition, `FormB`, says: if `Gm(x) ≤ x^θ` holds on whole windows `[Y, Y^λ]` for arbitrarily large `Y` (any fixed `λ > 1`), then no member of the level has a zero with real part above `θ`. This is stronger than the classical lemma of Landau, which needs the bound for all large `x`.

It is stated as proved for every level. The proof is in a directory of 32 files, about 3,260 lines in all. By its statements it works with the Laplace transform of `Gm(e^u)`, which has poles at the zeros with positive residue at real ones, and uses high-order derivatives to localise to a window. It was read at statement level only (read twice).

### The conversion

For a putative zero `s` with `Re s > 1/2`, choose `ε` small enough that the exponent `1/2 + c·ε` is below `Re s`; the windowed bound together with `FormB` gives a contradiction. This yields non-vanishing for primitive characters. A short lemma passes to all characters through the Euler factors at primes dividing the modulus, and `rh_of_every` finishes as in section 1.

The second reader confirmed that the order of quantifiers in this step is as it should be: the constants are fixed before `ε` is chosen.

### Where the bound is claimed to come from

The bound at a single scale `x` is a conditional statement (`core_gm`): if at scale `x` there is a "host" satisfying two sets of conditions, then `Gm(x) ≤ x^(1/2 + c·ε)`. A host is an abelian number field with its character group and some auxiliary primes. Inside, by statements:

| Piece | What it says |
|---|---|
| `ch_balance` | An exact identity by orthogonality of characters on a finite abelian group: a weighted sum of `log p` over powers of inert primes, minus its main term, equals a specific combination of the twisted remainders over all characters of the group |
| `ch_top` | The inert-prime sum is at most its main term plus an error of size `x^(Cε)` times a bracket. Obtained by real arithmetic from a system of inequalities on a record of real numbers |
| `ch_core` | Isolates the characters of the level from that identity |
| `sigA_le` | The other characters contribute at most a constant times `x^(1/2 + ε)`, using a pointwise hypothesis on those characters at the scale `x` |

Two reviewed findings govern how this should be read.

1. **The system of inequalities is carried by an existentially quantified record of real numbers** (reviewed, medium). The names of its components suggest slopes, heights and periods, but at this point they are real numbers constrained only by the inequalities and by being pinned to the true inert-prime sum. The ties to actual lattices and periods are part of a larger predicate, `ChainTied`, and are dropped just before this step. The endgame is therefore a funnel: correct-looking, and with its mathematical weight entirely in whatever produces `ChainTied`.
2. **The pointwise hypothesis on the other characters is a square-root bound for auxiliary characters of very large conductor at single scales** (reviewed, informational). It is supplied by an existence theorem for pairs of auxiliary primes `(q, d)`, stated without hypotheses, whose proof is organised as a mean-square argument over families with a zero-density estimate. The reviewer found it not circular in form. Its 293 modules were not read.

Hosts are claimed to exist on window scales by a lemma (`supplyChi`) that uses the Galois-cohomology bound of section 4 and the auxiliary-prime theorem. Families of hosts carrying `ChainTied` are claimed to exist by a proposition `TopG`: for every `λ > 1`, if suitable hosts exist on window scales and satisfy the cohomology bound, then for every small `ε` there is a family with `ChainTied` on its window scales, with constants uniform in `ε`. `TopG` is obtained from a record of roughly 45 to 50 fields of lattice, theta-series and covolume conditions on families of host data. How that record is established was not traced by any reader. It is where sections 3 and 4 are supposed to meet the analysis.

A parallel copy of this endgame under different names exists in the tree and is, by text search, unused (reviewed, low). The description above is of the copy that the top-level chain refers to.

## 3. The chain of definite Hermitian spaces and theta lifts

Read once, except where noted. This section describes data structures and the shapes of hypotheses. No reader traced how they are discharged.

The central data, defined in `Formalism`, are:

- A CM field `E` over a totally real field, taken inside a tower of fields of 2-power cyclotomic level, with an auxiliary imaginary quadratic field. The level `e` of the tower is tied to the analytic scale by `x^(2+8ε) ≤ 2^e ≤ 2·x^(2+8ε)`.
- **A chain of Hermitian spaces** `X_0, X_1, …, X_m` over `E`, each required to be definite at every embedding, of ranks `k + j(t+1)`.
- **Lifts** indexed by `j = 1, …, m`, with theorems named for a "theta lift chain" giving the step from `j` to `j + 1`.
- **A length that grows with the scale.** A size condition requires `m ≥ x^(1/2 − ε)`. One area reader found a matching two-sided condition, `√(x·δ) ≤ m ≤ 2√(x·δ)`, in the part of the tree that composes exactly `m` kernel operators. So the chain is not of fixed length: it has about `√x` steps at scale `x`.

Around this, statements exist for:

| Ingredient | Form in the source | Proof located? |
|---|---|---|
| Gains at inert primes | A lower bound of the shape `Σ_{i odd} (a/p^i − w)_+` minus logarithmic terms, summed over the lifts | Not traced |
| A divisibility inequality with a factor `m` | An inequality between heights, slopes and `m·(y log y − y)` terms | Not traced |
| A slope inequality for Euclidean lattices, in terms of the slopes of the canonical filtration | A general proposition and a number-field "slope step" | Yes, proof located, not read |
| A Bessel-period identity | Each period functional equals a non-zero scalar times a fixed Bessel functional after unitary changes of variable | Required as an input; not traced |
| An inner product formula for theta lifts | A structure whose main field is the identity between a Petersson product of two lifts and an integral of a doubling function | Unclear |
| Near-orthogonality | Bounds on off-diagonal Hilbert–Schmidt squares, with error parameters required to be at most `exp(−x^(ε/8))` | Not traced |
| Mass formula | Ratio of masses of standard Hermitian lattices of consecutive ranks over a CM field | Yes, proof located, not read. It takes an instance hypothesis that is supplied elsewhere (audit finding 5) |
| Mean log-period formula of Chowla–Selberg type | A 60-module development for imaginary quadratic fields of prime discriminant | Yes, located, not read |
| A large set with no short linear relations | Existence, proved from Mathlib's construction of large sets without three-term progressions; feeds the choice of places in the tower | Yes, located, not read |

How these are meant to combine, in the readers' interpretation: the lifts give a lattice of rank growing like `√x` whose slopes are bounded below through divisibility at inert primes and above through norms of periods, and the slope inequality turns the comparison into the inequality on the inert-prime sum that section 2 consumes. That sentence is interpretation. What the source literally provides is the list of propositions and, at the end, the record of real numbers.

## 4. The Galois-cohomology bound

Read twice at the level of statements; reviewed.

**The statement.** For a number field `E`, a prime `l` and an integer `e`, the source defines the `ℤ_l`-length of a group `Ш¹`: classes in the first cohomology of the Galois group of the maximal extension of `E` unramified outside the places above `l`, with coefficients `ℚ_l/ℤ_l` twisted by the `(−e)`-th power of the cyclotomic character, that are locally trivial at those places. A proposition `VVle E t B` says that these lengths are finite for `0 < e < t` and that

`Σ_l log l · Σ_{1 ≤ e < t} length ≤ B`,

the outer sum being over any finite set of primes `l`. The proposition `VWin` requires this with `t = ⌊x^401⌋` and `B = √(exp(x^ε))` on windows of scales `x`, for a family of subfields of cyclotomic fields cut out by a character and two quadratic symbols. By the reader's inference these fields are not totally real. The quantifiers in the source are more elaborate than this summary; the second reader's note on them is that the window, an auxiliary exponent and the pair of primes are quantified in a specific order that a short paraphrase loses.

Both the reader and the reviewer regard this as not a known theorem. The reviewer points out that this judgement cannot be made from the source. It corresponds to item 17 of the announcement's outline.

**Where it comes from.** It is derived in-tree from the same Galois-representation statement `h` as in section 1. The chain, mapped by name only, runs through base change from definite unitary groups to `GL_n` over CM fields, and then a counting argument that takes as inputs a global duality theorem for Galois cohomology, a theorem on the vanishing of a cyclotomic invariant, a bound on a second cohomology group, and prime-by-prime case counts whose lemma names mention automorphy lifting. No reader audited this derivation. The reviewer found no vacuity in the statement and confirmed that the proposition is consumed, not just carried.

**Where it is used.** Twice: to produce hosts on window scales, and later, through a derived hypothesis along families, to convert one of the "link" conditions into the divisibility inequality of section 3.

## 5. The libraries

File counts are from the import graph computed on 2026-11-20 and sum to 175,187. Descriptions are from the area maps (read once; some points reviewed). The libraries are not layers: the foundational-looking ones import `Development` and `Formalism` heavily, and all of them are in the import closure of `Main`.

| Library | Files | What it contains, as read |
|---|---|---|
| `Development` | 141,928 | See the next table |
| `Formalism` | 18,254 | Statements and reductions. An analytic part (the definition of `Gz`, many propositions of Landau type, a classical zero-free region); a data part defining the central record that almost everything quantifies over; a global assembly part defining the "link" hypotheses; machinery for theta lifts and Weil representations of unitary groups; and about 45 small support directories. Its largest directories are `PeriodIntegrals` (3,615 files) and `HermitianCurvature` (1,922). It also holds the three metaprograms. Every statement concluding `RiemannHypothesis` found in it is conditional |
| `GroundTheory` | 8,507 | A broad arithmetic library. Hecke L-functions by the adelic method with functional equation; idelic global class field theory; local class field theory; global duality for Galois cohomology; period rings of p-adic Hodge theory; and a 6,410-file Arakelov height theory written as statements with separate, often conditional, proofs |
| `ReciprocityTheory` | 3,845 | Mostly degeneration and toroidal compactification of abelian schemes with extra structure, Arakelov volumes and discrete series of real unitary groups (2,799 files); also local reciprocity and L² estimates |
| `CompanionTheory` | 2,027 | Supplies proof terms for many of the propositions named after published results, and about 520 generated target lemmas |
| `PositivityTheory` | 449 | Proof terms for "published inputs" in automorphic forms. The name does not describe it |
| `Lemmata` | 167 | 167 single-file directories of extracted goals, each named `goal1` |
| `BuildAid` | 5 | The five `run_cmd` stubs described in the audit |
| `Supplements` | 3 | The file that defines the four terms used by `Main.lean`, and two files that only import |
| `Main`, `Statements` | 1 + 1 | The five final theorems and the four propositions they are stated with |

Inside `Development`:

| Directory | Files | What it contains, as read |
|---|---|---|
| `AbelianVarietyTheory` | 99,187 | 8.14 million lines in seven folders, of which `Proofs` has 95,418 files. Every large folder mixes theta correspondence for unitary groups over CM fields, automorphic forms, abelian schemes, p-adic Hodge theory, Galois cohomology, complex geometry and plain algebra. 38,696 files are short `…Statement.lean` wrappers that restate a sibling file's theorem under another name. A folder of about 450 propositions named after published results: by text search, roughly 185 to 200 have a hypothesis-free theorem concluding them somewhere in the tree, about 50 are derived only conditionally, and about 195 are never concluded |
| `AutomorphicArithmetic` | 18,431 | Where the final statement is assembled: the Galois-representation statement, the reciprocity map, the derivation of the cohomology bound, and the file that packages about 190 propositions named after published results and concludes `everyCharacter` |
| `AutomorphicSpectrum` | 15,147 | About 7,400 leaf lemmas and 6,220 restatement wrappers; spectral theory of automorphic forms |
| `WeilBound` | 7,051 | Proof terms for propositions named after published results, 89 of them in the tree's namespace for published statements. "Weil" here means the Weil representation and the Siegel–Weil formula. It contains no bound for curves over finite fields (reviewed) |
| `EtaleCohomology` | 1,398 | Leaf lemmas for a torsion étale cohomology with Tate twists. A sub-directory states a purity statement of Weil-conjecture type as propositions only; it is never proved or used (reviewed) |
| `ResolutionOfSingularities` | 499 | Functorial resolution and principalization in characteristic zero. Self-contained and coherently named |
| `DiscreteGroups` | 215 | A local converse theorem for `GL_n` and lemmas used by a trace-formula argument |

Two structural facts matter more than any row:

- `Main` imports everything. The module `MainConclusion` alone has 175,173 other modules in its import closure, out of 175,187 in the tree. Imports therefore cannot show which library the proof term actually uses.
- A large share of the biggest directory is conditional on hypothesis bundles that, by text search, are never supplied (reviewed, medium). The top-level chain routes around them.

## 6. The announcement's outline against the source

The announcement that accompanies the source gives a 20-item outline of the argument. One reader compared each item with the tree on 2026-11-20. The tree has no comments, so an item could be matched only through declaration names and statements. "Found" means a formal counterpart was located and read as a statement. It does not mean the counterpart is proved, and it does not mean the reader's identification is right. The item descriptions are short paraphrases. This table was not second-read item by item; two flags arising from it were reviewed and upheld.

Totals: 9 found, 10 partial, 1 absent.

| # | Outline item, paraphrased | In the source | One line |
|---|---|---|---|
| 1 | A determinant form of the auxiliary-polynomial method for counting points on curves over finite fields | Absent | The outline's name for it occurs nowhere, in content or in names, and no function-field argument by an auxiliary polynomial was found |
| 2 | On a CM elliptic curve at an inert prime, the p-th iterate of the invariant derivation vanishes modulo p; derivatives of a theta function at the origin are divisible by a power of p of about `a/p + a/p³ + …` | Partial | The ingredients exist in abstract form (a formal-group statement on p-th iterates, the constant `1/p + 1/p³ + …` with p-adic norm bounds, a CM-curve setting), not as the single statement described |
| 3 | An identity for point counts on a quadric with a "sign-only" proof of the Riemann hypothesis for varieties over finite fields; theta on a sixfold cover of `GL_5`; a Poincaré bundle on edges | Partial | Not found as described. Point counts for quadrics over finite fields exist, by Gauss sums; a purity proposition exists only conditionally; no sixfold cover |
| 4 | Positivity of a functional of Weil type through a determinant, then bootstrapped | Partial | No such functional and no determinant positivity statement. Its role is played by an upper bound for a weighted sum over inert primes |
| 5 | The smoothed von Mangoldt sum `Σ Λ(n)(X/n − 1)_+ − X log X + (1+γ)X`; an explicit formula; a variance or test-function device | Found | The sum is defined exactly and is on the critical path. Only a truncated explicit formula exists. Weighted-average machinery is the nearest thing to the test-function device |
| 6 | Positivity for a particular test function gives a zero-free half-plane `Re s > 1 − η` | Partial | No statement in that form. The counterpart is a Landau-type implication from a one-sided power bound to non-vanishing; the live chain uses the windowed version of section 2 |
| 7 | Determinants containing Bessel periods for unitary groups, of the kind in the branching conjectures, with interlacing weights | Partial | A Bessel-type period proposition with an explicit interlacing condition is present. The determinant framing is not. No proof of that proposition was located |
| 8 | Iterated theta lifts `U(X_0) → U(X_1) → … → U(X_m)` between totally definite unitary groups, with `m` about `√X` | Found | The central data structure is exactly this chain, with a size condition forcing `m ≥ x^(1/2 − ε)` |
| 9 | Norms of the lifts and cancellation of terms of order `m`, with divisibility through the Chowla–Selberg formula, Weyl's dimension formula and the Siegel mass formula | Found | All three have formal statements, two with located proofs. The "cancellation" was identified with one proposition by interpretation; its proof was not located |
| 10 | A sufficient lower bound on the divisibility of the m-fold lift | Found | Present in the abstract skeleton as inequalities between heights and slopes with a factor `m`. Proofs not traced |
| 11 | An Iwasawa tower, by analogy with a pigeonhole argument over finite fields | Partial | A tower of CM fields indexed by a 2-power level is built into the central data. Nothing is called an Iwasawa tower and there is no Iwasawa-theoretic statement. The analogy has no textual anchor |
| 12 | A seesaw identity making the period of the iterated lift a Bessel period independent of the Hecke characters; the Rallis inner product formula | Found | A Bessel-period identity is a required input; an inner product formula is stated; about 450 modules have "seesaw" in their names. "Independent of the Hecke characters" is the reader's interpretation |
| 13 | The slope inequality of Arakelov geometry, with the slopes of the canonical filtration | Found | A slope inequality for Euclidean lattices is stated and has a located proof. The name the outline gives it never appears |
| 14 | A computation of the cost of each lift showing a barrier at 2/3; a need for "division" | Partial | Cost and loss bookkeeping exists. No statement exhibiting a barrier at 2/3 was found |
| 15 | Gluing an integral structure across Hecke characters for a "gcd", meaning extra averaging | Partial | No statement in those terms. Nearest: one common lattice receiving a lattice for each of a finite set of "words", with a weighted mean over the words |
| 16 | A relative trace formula; a bound on the norm of a projected Poincaré series; approximate orthogonality of columns | Partial | Near-orthogonality bounds and Poincaré-series estimates are present, as are ingredients of a relative trace formula. No global relative trace formula is stated as such |
| 17 | A significant weakening of Vandiver's conjecture, for classes in `H¹(O_E[1/l], ℚ_l/ℤ_l(−e))` | Found | The word never appears, but the statement is on the critical path: it is the bound of section 4 |
| 18 | Covolumes, the index of theta series, congruences between lifts and forms | Partial | Covolume and theta-lattice index computations are present. Congruences between lifts and forms were not found as a clear statement |
| 19 | A precise choice of the tower using Behrend's construction of large sets without three-term progressions | Found | Mathlib's version of that construction is used to prove existence of a large set with no short linear relations, which feeds the central data |
| 20 | The generalised Riemann hypothesis as the conclusion | Found | `Main.lean` states the Riemann Hypothesis and the generalised hypothesis for Dirichlet L-functions. No Dedekind or automorphic L-functions appear in the conclusion |

The reader's summary: correspondence is good for the structural core of the outline (items 5, 8 to 10, 12, 13, 17, 19, 20) and poor for its heuristic and motivational parts.

The same reader noted that several propositions in `Formalism` that read like the headline analytic theorems of the announcement are, by text search, definitions with no proof and no use. The live chain uses different declarations.

## 7. What a reader should look at next

These are the places that every reader and reviewer who got near them pointed to. They are places where the statements are new or carry the weight. They are not places where an error has been found.

| Where | Why |
|---|---|
| The production of `ChainTied` from the large record of family conditions | This is where an upper bound of square-root quality for primes in a Frobenius class would have to come from. Not traced by anyone |
| The derivation of the Galois-cohomology bound `VWin` from the Galois-representation statement | A statement that the readers regard as new, obtained from automorphy inputs. Mapped by name only |
| The in-tree proof of the Galois-representation statement | A hypothesis-free claim of a deep result, even in its restricted form |
| The auxiliary-prime existence theorem and its 293 modules | The heaviest classical analytic load in the chain |
| The windowed Landau lemma | The single step that converts a bound on prime sums into non-vanishing; about 3,260 lines, read at statement level |

After the compile finishes, a declaration-level dependency extraction for `riemannHypothesis` would replace the text-search judgements on this page about what the live chain does and does not use.
