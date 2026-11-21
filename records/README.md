# Records

Evidence files from the work done so far. Everything here was recorded on 2026-11-20.

Status on that date: the full compile was in progress and the proof had not been verified. These records identify the input, document how the local build was run, preserve the research behind the cloud pilot, and hold the pilot's measurements. None of them shows that the proof is correct, and none shows that it is incorrect.

The proof source itself is not here and is not redistributed. Build logs, the archive listing and anything tied to a cloud account are not here either (see "What is left out").

## Index

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
| `mac-build/mapped-files-sample.txt` | Files memory-mapped by one running compiler process, by type |

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

### `cloud/pilot/` - the calibration pilot

| File | Contents |
|---|---|
| `cloud/pilot/README.md` | The two runs, every file they produced, and how to reproduce the estimate |
| `cloud/pilot/pilot-20261120-162141/` | The pilot: per-process and machine-wide measurements over 29,633 compiled modules and 2,233 kernel checks |
| `cloud/pilot/rehearsal-20261120-160322/` | The 17-minute rehearsal that preceded it |
| `cloud/pilot/pilot_estimate.json` | Estimate for a full build and full kernel replay, computed from the pilot by `analysis/pilot_estimate.py` |
| `cloud/pilot/pilot_estimate_review.json` | Three independent reviews of the first version of that estimate |
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
| `<SCRATCH>` | A temporary or session scratch directory |

Five files were changed by it: `mac-build/build-status.txt` (15 paths), `audit/audit_results.json` (846 paths), `cloud/gcp_pricing.json` (1 path), `cloud/gcp_budget_review.json` (2 paths) and `cloud/pilot/pilot_estimate_review.json` (1 path and 1 name of a local disk). All other files are byte-for-byte copies of the originals; those whose name ends in `.gz` are byte-for-byte copies before compression. No numbers, hashes, module names or findings were altered.

## What is left out

- The proof source and the archive listing.
- Build logs, local and from the pilot. They are large, and the compiler warnings in them quote the proof source. The pilot's are summarised in `lake_log_summary.tsv` in each run directory.
- The raw price catalogue (about 29 MB; it is public and can be downloaded again from Google).
- Quota responses and the pilot's local state file, which describe one cloud account.

## Contact

Corrections: peter.lowes@sie.life
