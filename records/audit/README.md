# Audit output

`audit_results.json` is the output of a structured reading of the proof source carried out on 2026-11-20, while the compile was in progress.

## What kind of evidence this is

**Static reading by AI agents. It is not output of the Lean kernel.**

- The readers were language models with read access to the source text. They report what the source says. Nothing in this file was produced by compiling or checking the proof, and several entries say so themselves.
- 43 agent runs produced the file: 12 primary readers, 2 second readers and 29 adversarial reviewers.
- Language models misread things. The second readers logged 40 errors and 23 paraphrase issues against the 138 nodes of the two "spine" maps. Their corrections are stored next to the original entries; the original entries were not edited.
- Most findings of the form "never used" or "never constructed" rest on text search for an identifier, not on dependencies extracted from compiled files.
- No reader judged whether a proof body is correct. Proof bodies below the top few levels were mostly not read.
- A "red flag" is the readers' term for anything they thought a person should look at. Its severity says how much it would change the way the argument is described. A flag is not a demonstrated error.

Nothing in this file establishes that the proof is correct, and nothing in it establishes that the proof is incorrect. That question is decided by the checks described in [`../../docs/verification-criteria.md`](../../docs/verification-criteria.md).

Identifiers in the file are the source's own names. Many contain the names of published theorems or of mathematicians, and one task (`timeline`) paraphrases the 20-item outline that accompanied the source. They are reproduced so that each finding can be located. They do not indicate that anyone named has any connection with the formalization.

## Structure

The file is a JSON array of 12 task objects, one per primary reader.

| Key | Present in | Contents |
|---|---|---|
| `key` | every task | Short name of the task |
| `kind` | every task | `spine`, `map`, `timeline`, `bypass` or `vacuity` |
| `result` | every task | What the primary reader returned. Its shape depends on `kind` (below) |
| `spineCheck` | the 2 `spine` tasks | What a second reader found when re-opening every node of the map in the source |
| `flagVerdicts` | every task (may be empty) | One entry per flag that was sent to an adversarial reviewer |

### The 12 tasks

| `key` | `kind` | Scope | Size of `result` | Flags raised | Flags reviewed |
|---|---|---|---|---|---|
| `spine-top` | spine | Declarations three to six levels below `MainConclusion.lean`, the file that states the theorem `everyCharacter`, traced one by one | 68 nodes | 11 | 3 |
| `spine-analytic` | spine | The chain from `riemannHypothesis` in `Main.lean` down into the analytic part of the argument, traced the same way | 70 nodes | 9 | 3 |
| `formalism-A` | map | `Formalism`, first half of its subdirectories | 55 components | 10 | 3 |
| `formalism-B` | map | `Formalism`, second half | 54 components | 10 | 4 |
| `dev-avt` | map | `Development/AbelianVarietyTheory` | 10 components | 8 | 3 |
| `dev-aa` | map | `Development/AutomorphicArithmetic` | 14 components | 9 | 3 |
| `dev-rest` | map | The other subdirectories of `Development` | 10 components | 8 | 2 |
| `ground-etc` | map | `GroundTheory`, `ReciprocityTheory`, `CompanionTheory`, `PositivityTheory`, `Lemmata` | 18 components | 9 | 3 |
| `timeline` | timeline | Comparison of the tree with the 20 items of the outline that accompanied the source | 20 items | 8 | 2 |
| `bypass-A` | bypass | Use sites of the tactics that defer a check to the kernel, in `Development/AbelianVarietyTheory/Proofs` | 50 files, 498 sites | 13 | 1 |
| `bypass-B` | bypass | The remaining use sites of the same tactics | 27 files, 322 sites | 10 | 0 |
| `vacuity` | vacuity | Hypothesis bundles and statements that might be trivially satisfied | 11 bundles, 9 patterns | 10 | 2 |

Totals: 115 flags (1 high, 28 medium, 39 low, 47 info). The 29 flags rated high or medium were each sent to a reviewer. The 86 low and info flags were not reviewed.

### `result`, by kind

- **spine**: `narrative`; `nodes`, each with `id`, `file`, `line`, `kind`, `lean_statement`, `plain_math`, `depends_on` and usually `notes`; `red_flags`; `open_questions`.
- **map**: `area`; `summary`; `components`, each with `name`, `path`, `files`, `role`, `connects_to` and `key_declarations` (`name`, `file`, `lean_statement`, `plain_math`); `red_flags`; `open_questions`.
- **timeline**: `items`, each with `n`, `pdf_claim` (the outline item, paraphrased), `found` (`yes`, `partial` or `no`), `confidence`, `explanation` and `locations` (`file`, `declaration`, `lean_statement`); `overall`; `red_flags`.
- **bypass**: `files_in_scope`, `files_examined`, `sites_examined`; `files`, each with `file`, `tactics_used`, `site_count`, `what_is_proved`, `defeq_plausible`, `concern` and `notes`; `overall_assessment`; `red_flags`.
- **vacuity**: `literature_bundles`, each with `name`, `file`, `fields_summary`, `sample_fields_verbatim`, `inhabited_by_real_proof` and `where_inhabited`; `trivial_patterns`, each with `pattern`, `where`, `assessment` and `excerpt`; `overall_assessment`; `red_flags`.

Every entry of `red_flags` has `what`, `where`, `why_it_matters` and `severity` (`high`, `medium`, `low` or `info`), and most have a short `excerpt`.

`lean_statement` is the reader's quotation of a declaration's statement, often with whitespace collapsed and long parts replaced by `…`. `plain_math` is the reader's paraphrase and is the part most likely to be wrong.

### `spineCheck`

`nodes_checked`, `edges_checked`, `verdict`, `errors` (each with `node`, `problem`, `correction`), `paraphrase_issues` and `notes`.

Both spine maps were checked in full (68 nodes and 259 dependency edges; 70 nodes and 135 edges) and both verdicts are `minor_errors`. Read a spine node together with any entry in `errors` or `paraphrase_issues` that names it.

### `flagVerdicts`

Each entry has two parts:

- `flag`: the red-flag entry as it was given to the reviewer.
- `verdict`: `real` (true if the reviewer could not refute the flag), `severity` (the reviewer's own rating), `explanation` and `evidence` (file names, line numbers and short quotations).

Of the 29 reviewed flags, 27 have `real: true` and 2 have `real: false`. The reviewers' severities are 14 medium, 7 low and 8 info. The single flag that a primary reader rated high is one of the two the reviewer rejected.

## Paths and quotations

- `<WORKDIR>/extract/lean/src/` is the root of the extracted source, `$RH_PROJ/src` in this repository's scripts. `<HOME>` appears once, in a path into the Lean toolchain's own source. Both placeholders were put in by the sanitising pass described in [`../README.md`](../README.md). Nothing else was changed.
- The file contains several hundred short quotations from the source (the longest quoted statement is under 900 characters), each attached to a file and usually a line number so that the entry can be checked against the source. It is not a substitute for the source and cannot be used to reconstruct it.

## Using it

Treat it as a map and as a list of things to look at, most usefully after the compile has finished and dependencies can be extracted from the compiled files. Any entry can be checked by opening the named file at the named line. Where an entry and the source disagree, the source is right.

A prose summary is in [`../../docs/source-audit.md`](../../docs/source-audit.md).
