# Records

Evidence files from the work done so far. Everything here was recorded between 2026-11-20 and 2026-11-26.

Status on 2026-11-26: one full run in the cloud had recorded each of the three pre-registered criteria as holding (`cloud/full-run/`), two later runs had made further checks on the exported proof (`cloud/export-check/`, `cloud/kernel-check/`), and the build on the Mac was still in progress. These records identify the input, document how the local build was run, preserve the research behind the cloud work, and hold what the pilot, the rehearsals and those runs wrote. Apart from `cloud/full-run/`, none of them bears on whether the criteria hold; the two later runs are outside the criteria.

The proof source itself is not here and is not redistributed. Build logs, the archive listing and anything tied to a cloud account are not here either (see "What is left out").

## Index

### The pre-registration

| File | Contents |
|---|---|
| `preregistration_marker.json` | The commit that holds the pre-registration, when it was first pushed to GitHub, the `prereg-v1` release, and the Zenodo record and DOI, as read from GitHub's and Zenodo's own records |

### `source/` - what was downloaded

| File | Contents |
|---|---|
| `source/tarball.sha256` | SHA-256 of the reassembled tarball, as a `hash  filename` line |
| `source/parts.sha256` | SHA-256 of each of the 14 parts, as `hash  filename` lines |
| `source/expected.json` | Reference values for the source, in five sections. `download`: part count, part sizes, total bytes. `tarball`: SHA-256, entry count, uncompressed bytes, `.lean` file count. `source`: line and byte totals. `project`: toolchain, Mathlib revision and tag, package revisions, SHA-256 of `lakefile.toml`, `lake-manifest.json` and `lean-toolchain`. `audit`: the eight text-search categories expected to have no match |
| `source/import_graph_summary.json` | Summary of the static import graph: module and line totals, counts by top-level directory, external imports, most-imported modules, largest files |
| `source/closure_stats.json` | Import depth histogram, import-closure sizes for a random sample of 1,500 modules, and exact closure sizes for seven key modules |
| `source/pilot_targets.json` | The two build targets chosen for the cloud pilot (a deep one and a small rehearsal one), with their closure sizes |
| `source/import_graph.json.gz` | The full static import graph: one JSON object mapping each of the 175,187 modules to the list of modules it imports. 12.9 MB compressed, 84.9 MB uncompressed |

### `mac-build/` - the local build

| File | Contents |
|---|---|
| `mac-build/README.md` | The machine, and what each file below means |
| `mac-build/build-status.txt` | One line for every start and stop of the build, with the parallelism cap in force |
| `mac-build/tuning.tsv` | First comparison of parallelism caps (3 to 7) |
| `mac-build/tuning2.tsv` | Second comparison of parallelism caps (5 to 10) |
| `mac-build/checker-sample-times.txt` | Exit status and timings of `leanchecker` on 24 compiled modules |
| `mac-build/closure-directory-checks.json` | `leanchecker` on 42 compiled modules with only each module's imports on its search path: six by hand, compared with the usual way, and 36 through the replay script |
| `mac-build/mapped-files-sample.txt` | Files memory-mapped by one running compiler process, by type |
| `mac-build/progress-20261120-2001.txt` | Dated snapshot of the build: modules compiled, failures, rate, and space taken by setup files |
| `mac-build/progress-20261121-0931.txt` | A later snapshot: 59,988 modules compiled, no failures, and how deep in the import graph the compiled modules reach |
| `mac-build/progress-20261126-0233.txt` | A snapshot of 2026-11-26: 149,438 modules compiled, no failures |

### `audit/` - static reading of the source

| File | Contents |
|---|---|
| `audit/README.md` | Structure of the audit output and how to read it |
| `audit/audit_results.json` | Output of a structured reading of the source by AI agents, with second readings and adversarial review. Static reading, not kernel output |

### `cloud/` - prices and capacity

| File | Contents |
|---|---|
| `cloud/README.md` | Date and source of the prices, and what each file below is |
| `cloud/cloud_options.json` | Survey of rental options across several providers, with a time model and a sceptical review of it |
| `cloud/gcp_pricing.json` | Google Compute Engine machine, disk and Spot prices, billing rules and quota rules |
| `cloud/gcp_family_rates.json` | Per-vCPU and per-GiB hourly rates by machine family |
| `cloud/gcp_budget.json` | A budget model for six machine options, with low, expected and high scenarios |
| `cloud/gcp_budget_review.json` | Three independent reviews of that budget model |
| `cloud/gcp_candidates.json` | 31 candidate machine types with sizes and the zones that offer them |
| `cloud/gcp_machine_types.csv` | Machine types with at least 96 vCPUs in 19 US zones |
| `cloud/full_run_driver_review.json` | Four reviews of the first draft of the full-run driver, before it had been run |
| `cloud/full_run_driver_recheck.json` | Two reviews of the driver as rewritten after those |
| `cloud/full-rehearsals/` | Records of each rehearsal of the full-run driver, with what it found |
| `cloud/spot-rehearsals/` | Records of the rehearsal of the same driver as a chain of Spot machines |
| `cloud/spot_resume_model.json` | What a full run on Spot machines that resumes is modelled to cost, from `analysis/spot_resume_model.py` |
| `cloud/spot_resume_review.json`, `cloud/spot_resume_recheck.json` | AI review of the code for that Spot run before anything was launched, and the four later looks at it |
| `cloud/full-run/` | Records of the one full run: the facts it recorded for C1, C2 and C3, the per-module replay results, and each machine's logs |
| `cloud/export-check/` | Records of the export check of 2026-11-24: the proof exported from the full run's compiled files and compared with the published export, and an independently written kernel's output on it |
| `cloud/kernel-check/` | Records of the kernel check of 2026-11-25 and 26 and of its rehearsal: a second independent kernel, `lake comparator` with Lean's own kernel in its sandbox, and Lean's paranoid kernel on the exported proof |
| `cloud/kernel_check_review.json` | AI review of the script behind the kernel check, made before it ran |
| `cloud/kernel_check_record_review.json` | AI review of how the kernel check was written up, made before the write-up was committed |
| `cloud/ledger.tsv` | Every launch made for this work, with its machine time and recorded cost |
| `cloud/replay_cost.json` | What a kernel replay of the whole tree is estimated to cost by each of three ways of running it, from `analysis/replay_cost.py` |
| `cloud/replay_method_review.json`, `cloud/replay_method_recheck.json` | Two rounds of AI review of the second replay program and the scripts around it |
| `cloud/closure_replay_review.json`, `cloud/closure_replay_recheck.json` | Two rounds of AI review of the kernel replay as it now runs (the stock tool with import-closure search paths) and of the cloud driver's replay phase |
| `cloud/cap_options_review.json` | Four AI analyses, each independently checked, of what could be done about the full run under a spending cap of 50 USD, and further ways proposed by a ninth agent that no other agent checked; nothing in it has been tried |
| `cloud/rehearsal6_record_review.json` | AI review of how the sixth rehearsal, the replay estimate and the cap were written up: five areas, each re-checked by a sceptic, with what was done about each point |
| `cloud/c3_amendment_draft_review.json` | A draft amendment to the pre-registration that was reviewed and **not made**, with the 51 findings of its review |

### `two-builds/` - the same modules compiled twice

| File | Contents |
|---|---|
| `two-builds/README.md` | What was compared and what it shows |
| `two-builds/mac-vs-cloud.json`, `two-builds/mac-vs-cloud-content.tsv` | 1,796 modules compiled on the Mac and on a rented Linux machine: which compiled files are byte-identical, and a comparison of their contents |
| `two-builds/cloud-vs-cloud.json` | 1,504 modules compiled in two separate cloud rehearsals: byte-identical |

### `cloud/pilot/` - the calibration pilot

| File | Contents |
|---|---|
| `cloud/pilot/README.md` | The two runs, every file they produced, and how to reproduce the estimate |
| `cloud/pilot/pilot-20261120-162141/` | The pilot: per-process and machine-wide measurements over 29,633 compiled modules and 2,233 kernel checks |
| `cloud/pilot/rehearsal-20261120-160322/` | The 17-minute rehearsal that preceded it |
| `cloud/pilot/pilot_estimate.json` | Estimate for a full build and full kernel replay, computed from the pilot by `analysis/pilot_estimate.py` |
| `cloud/pilot/pilot_estimate_review.json` | Three independent reviews of the first version of that estimate |
| `cloud/pilot/pilot_estimate_check.json` | Three checks of the revised estimate and its documentation against the recorded data |
| `cloud/pilot/ledger.tsv` | Machine-time and estimated cost of each run |

## How the records were produced

- **Hashes.** `parts.sha256` and `tarball.sha256` come from the log written when the parts were downloaded and joined. On 2026-11-20 they were checked again against the files on disk with `shasum -a 256 -c`; all 15 lines matched. The file names are bare (`lean.tar.gz`, `lean.tar.gz.part01` ...), so the lists can be checked from inside the download directory. From the repository root, with the default working directory `work/`:

  ```bash
  (cd work/download && shasum -a 256 -c ../../records/source/parts.sha256 ../../records/source/tarball.sha256)
  ```

  On Linux use `sha256sum -c`. `scripts/01_fetch.sh` makes the same comparison.
- **`expected.json`.** Assembled on the build machine by a short one-off script (not kept in this repository) from the download log, the archive listing saved at extraction time, and the extracted project files. The script stopped with an error unless the log, the listing and the files on disk agreed with one another. The line count and byte totals were recomputed from the extracted tree on the same day and matched. The zero counts in `audit` are from a text search of all 175,187 `.lean` files with the category patterns of `scripts/verify/rhv_tools.py`; the file states the matching rule. The sections `tarball`, `project` and `audit` use the key names that tool compares against. On 2026-11-20 its `tar-inspect` and `project-info` comparisons, and its `audit-classify` comparison for these eight categories, each reported a match with this file.
- **Import graph.** Written by a script that reads only the `import` lines at the top of each `.lean` file. Nothing is compiled. It shows which modules import which; it does not show which results are logically used. The order of keys in `import_graph.json.gz` follows the directory listing order of the machine that produced it, so a regenerated file can differ in byte order while describing the same graph.
- **Build and tuning tables.** Copied from the working directory of the local build while the build was running.
- **Audit and cloud research.** Output of AI agent runs, and of the short scripts and catalogue extracts that supported them, copied as written. Each directory's README says what kind of evidence it is.
- **Pilot measurements.** Written on the rented machine by `cloud/gcp/pilot_guest.sh` and its sampler, uploaded to a private bucket, and copied from there. `pilot_estimate.json` can be regenerated from them with one command, given in `cloud/pilot/README.md`.

## Sanitising

Every file in this directory, apart from the README files, was written by `scripts/dev/scrub.py clean` and then verified with `scripts/dev/scrub.py check`. This is a mechanical pass that removes local paths and account identifiers:

| Placeholder | Replaces |
|---|---|
| `<WORKDIR>` | The working directory of the local build (`RH_WORKDIR` in `config.env`) |
| `<HOME>` | A home directory |
| `<VOLUME>` | The path at which a disk is mounted on the machine where a file was written |
| `<SCRATCH>` | A temporary or session scratch directory |
| `<REDACTED>` | A name from a private list, here the name of a local disk |
| `<REPO>` | The directory of this repository on the machine where a file was written |
| `<BUCKET>`, `<PROJECT_ID>` | The names of the storage bucket and of the cloud project (`GCP_BUCKET` and `GCP_PROJECT` in `config.env`) |
| `<EMAIL>` | Anything in the form of an e-mail address other than the public contact address |

When this list was first made, six files had been changed by it: `mac-build/build-status.txt` (15 paths), `mac-build/progress-20261120-2001.txt` (3 paths), `audit/audit_results.json` (846 paths), `cloud/gcp_pricing.json` (1 path), `cloud/gcp_budget_review.json` (2 paths) and `cloud/pilot/pilot_estimate_review.json` (1 path and 1 name of a local disk). Records added since that quote a local path, the bucket or the project carry the same placeholders: most of the review files under `cloud/`, and logs in the directories of the cloud runs. A file with none of these placeholders is a byte-for-byte copy of the original; those whose name ends in `.gz` are byte-for-byte copies before compression. No numbers, hashes, module names or findings were altered.

## What is left out

- The proof source and the archive listing.
- Build logs, local and from the pilot. They are large, and the compiler warnings in them quote the proof source. The pilot's are summarised in `lake_log_summary.tsv` in each run directory.
- The raw price catalogue (about 29 MB; it is public and can be downloaded again from Google).
- Quota responses and the pilot's local state file, which describe one cloud account.

## Contact

Corrections: peter.lowes@sie.life
