# Using these scripts on another Lean archive

Written on 2026-11-24. **None of this has been tried.** The scripts have been run on one archive only. This page is an inventory, made by reading the code, of what in them is specific to that archive and what is not, so that someone who wants to check a different large Lean 4 project knows what they would have to change. Making that change a matter of one settings file, and trying it on a second archive, is item 3 of the roadmap in [`../README.md`](../README.md).

## What the scripts assume about the archive

Each of these holds for the archive this repository was written for. Where one does not hold for yours, the script named will stop or will check the wrong thing.

| Assumption | Where it is written | What to change |
|---|---|---|
| The archive is one gzipped tarball published as numbered parts (`…part01`, `…part02`, …) that are concatenated | `scripts/01_fetch.sh`; `RH_PART_URL_PREFIX`, `RH_PART_COUNT` and `RH_TARBALL_SHA256` in `config.env` (defaults in `scripts/lib.sh`) | For a single file, set the count to 1 and the prefix so that the prefix followed by `01` is the file's address, or fetch the file by hand to `download/lean.tar.gz` in the work directory and run `01_fetch.sh --check-only`. Record your own SHA-256 first: the scripts compare with it and with nothing else |
| Every entry in the tarball is a regular file under `lean/`, with no links, no absolute paths, no `..`, no executable bits, no duplicates | `scripts/02_inspect_and_extract.sh`; the `tar-inspect` command of `scripts/verify/rhv_tools.py` (its `--prefix` default) | The checks are worth keeping. The prefix is the one thing to change; `RH_PROJ` in `scripts/lib.sh` names the same directory after extraction. An archive made by a hosting site from a repository will have a different top directory and may have executable files |
| The project's sources are under `src/` and its configuration is `lakefile.toml` | `count_sources` in `scripts/common.sh`; `scripts/03_audit_source.sh`; `scripts/09_kernel_replay.sh`; `project-info` and `import-graph` in `rhv_tools.py`; `scripts/04_setup_toolchain.sh` | Many projects keep sources at the top level and use `lakefile.lean`. A `lakefile.lean` is a program that Lake runs: read it before building, which this archive did not require |
| Mathlib is a dependency, pinned in `lake-manifest.json`, and its prebuilt cache can be fetched | `scripts/04_setup_toolchain.sh` (`lake exe cache get`, and the test that no Mathlib module was compiled locally) | Nothing, if your project depends on Mathlib. Otherwise remove the cache step and its test |
| Two named modules exist and compile early (`Statements` and one other) | `SMOKE_TARGETS` and the loop after it in `scripts/04_setup_toolchain.sh`; the probe mode of `scripts/08_check_axioms.sh`; several self-tests in `cloud/gcp/full_guest.sh` | Name two modules of your project that import Mathlib and little else |
| The theorems to check are the five in `Main.lean` | `IMPORT`, `PRIMARY` and `THEOREMS` in `scripts/08_check_axioms.sh` | Your root module and theorem names |
| The headline theorem's statement must be exactly Mathlib's constant `RiemannHypothesis`, defined in one named Mathlib module | `scripts/verify/axioms_check_body.lean` (near its end); `cmd_axioms_summary` and `RH_MODULE` in `rhv_tools.py` | This is the part of criterion C2 that ties the theorem to a statement someone else wrote. For another theorem, decide what its statement should be compared with. The stronger form of this check is a challenge file and Comparator ([`related-work.md`](related-work.md)), which needs no code of this kind |
| The names whose redefinition would be suspicious are `RiemannHypothesis`, `riemannZeta` and `LFunction` | `PROTECTED_NAMES` in `rhv_tools.py`, used by `scripts/03_audit_source.sh` | The Mathlib names your statement is built from |
| The export check's challenge file, targets and published hashes | `cloud/gcp/export_guest.sh` | All of it is specific. For another proof there is nothing published to compare with unless someone else has made the export |

## What does not depend on the archive

Read as code, these make no reference to this proof. They have still only ever been run on it.

- `scripts/00_check_prereqs.sh` (apart from the sizes it prints), `05_build.sh`, `06_progress.sh`, `07_tune_jobs.sh`: starting, stopping, watching and tuning a long `lake build` on a machine short of memory.
- `scripts/09_kernel_replay.sh` and `scripts/verify/kernel_check_*.sh`: `leanchecker` on every compiled module, each given only the modules it imports ([`performance-notes.md`](performance-notes.md), section 10), with results kept so that an interrupted replay carries on.
- The axiom walk of `scripts/08_check_axioms.sh --deep`, once the theorem names are yours.
- The source audit's categories other than the protected names.
- `scripts/spot_checkpoint.sh` and the Spot mode of `cloud/gcp/pilot_local.sh`: saving a build in parts to a bucket and carrying on from them on a fresh machine. The guest script `cloud/gcp/full_guest.sh` runs the numbered scripts and repeats several of the assumptions above in its own self-tests.

## What a second archive would need to show

- That the changes above are all the changes: the list was made by reading, and a run would find what reading missed.
- That the replay with import-closure search paths behaves on a project laid out differently.
- Whether the memory figures in [`performance-notes.md`](performance-notes.md) say anything about other projects. They were measured on one, whose modules are unusually many and unusually alike.
