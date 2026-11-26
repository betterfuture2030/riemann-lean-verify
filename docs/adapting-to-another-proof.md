# Using these scripts on another Lean archive

First written on 2026-11-24 as an inventory, made by reading the code, of what in the scripts is specific to the archive they were written for. Rewritten on 2026-11-26, when that became a matter of one settings file: everything in `scripts/` that is a fact about one archive is now read from a *target profile*, `targets/<name>/target.env`. [`../targets/README.md`](../targets/README.md) lists every setting and says how to add a target.

**What has been tried:** `scripts/dev/test_targets.sh` (offline, under a minute) checks that the mechanism works on small made-up git repositories, and that the default target (the archive this repository was written for) behaves as it did before profiles existed, using a made-up stand-in for its tarball. On the default target's real tarball only the archive listing and entry checks have been run with these changes; their output was the same as before, and the tarball passes the new check that nothing follows the end of the archive. The build, the axiom check and the kernel replay have not been run again on it since profiles were added. **Nothing has been run on a real second archive yet.** The profile `targets/grh-compact/target.env`, for the shorter proof published on 2026-11-25, is written and has not been run. Trying it is item 3 of the roadmap in [`../README.md`](../README.md).

## What a profile covers

Each of these held for the archive the scripts were written for. Where one does not hold for yours, the setting named is where you say so.

| What the scripts assumed | Setting in the profile |
|---|---|
| The source is one gzipped tarball published as numbered parts that are concatenated | `TGT_SOURCE_KIND=tarball-parts`, with `TGT_PART_URL_PREFIX`, `TGT_PART_COUNT` and `TGT_TARBALL_SHA256`; the address of each part is the prefix followed by `01`, `02` and so on, so a tarball published as one file at another address is not supported yet. Or `TGT_SOURCE_KIND=git`, with `TGT_GIT_URL`, `TGT_GIT_COMMIT` (all 40 characters) and `TGT_GIT_SUBDIR`: one commit is written to a tar file byte for byte as git stores it, so it can be pinned by a SHA-256 like a published tarball |
| Every entry is a regular file under `lean/`, with no links, absolute paths, `..`, executable bits or duplicates | `TGT_ARCHIVE_PREFIX` for the top directory. The checks stay on whatever is set, and now also refuse `.git` and `.lake` components, files named `HEAD`, names that collide on macOS, headers that not every tar reads alike and anything after the end of the archive; for any target but the default one, what `tar` wrote is also compared with the listing, names, modes and bytes, before it is used ([the full list](../targets/README.md#what-the-archive-checks-refuse)). Only executable bits can be allowed, with `TGT_ARCHIVE_ALLOW_EXEC=1` |
| The sources are under `src/` | `TGT_SRC_DIR`. `.` means the project directory itself, Lake's default; Lake's `.lake` is then left out of every count and scan |
| Two named modules compile early, and one early lemma can be probed | `TGT_SMOKE_TARGETS`; `TGT_PROBE_MODULE` and `TGT_PROBE_THEOREM` (optional: without them `08_check_axioms.sh --probe` says there is no probe) |
| The theorems to check are the five in `Main.lean` | `TGT_ROOT_MODULE`, `TGT_THEOREMS`, `TGT_PRIMARY_THEOREM` |
| The headline theorem's statement must be exactly Mathlib's `RiemannHypothesis`, defined in one named module | `TGT_STATEMENT_CONST`, `TGT_STATEMENT_CONST_MODULE`, `TGT_REPORT_CONSTS`. This is the part of criterion C2 that ties the theorem to a statement someone else wrote. Decide what yours should be compared with: the stronger form of this check is a challenge file and Comparator ([`related-work.md`](related-work.md)) |
| The names whose redefinition would be suspicious are `RiemannHypothesis`, `riemannZeta` and `LFunction` | `TGT_PROTECTED_NAMES` (last components of names, which is what the audit matches) |
| The recorded facts about the source are in `records/source/` | `TGT_RECORDS_DIR`, normally `targets/<name>/records`. For a target other than the default one, a step with nothing recorded says so in capitals and is reported as not applicable, not as passed |
| The pinned Mathlib revision should be the official tag `v4.33.1`; 77 files use six named tactics | `TGT_MATHLIB_TAG`; `TGT_S10_PATTERN` and `TGT_S10_COUNT`. Leave them empty if they mean nothing for your archive: the checks are then reported as not applicable |

Each target also gets a working directory of its own (`work-<name>` beside `work`, unless you name one), with a marker file that stops a command for one target from using another's files.

## What a profile does not cover

- **A lakefile that is a program.** Only `lakefile.toml` is supported. A `lakefile.lean` is code that Lake runs with your rights before it builds anything: `04_setup_toolchain.sh` refuses to start if there is one. Read it yourself first. It is not the only code the archive chooses: step 04 also installs and runs the toolchain that `lean-toolchain` names (the part before the colon is a GitHub repository), and Lake clones every package at the address in `lake-manifest.json`, runs its lakefile and builds and runs Mathlib's cache tool. For any target but the default one, `02_inspect_and_extract.sh` prints those origins; go on only if the toolchain is `leanprover/lean4` and every address is one you trust.
- **A project that does not depend on Mathlib.** `04_setup_toolchain.sh` fetches Mathlib's prebuilt cache and fails if any Mathlib module had to be compiled locally. For a project without Mathlib, that step and its test have to be removed by hand.
- **The cloud modes.** `cloud/gcp/` (the full run, the export check, the kernel check) knows only the default target: its guest scripts name its theorems, its published export and its memory figures. `cloud/gcp/pilot_local.sh` stops if another target is named.
- **The cost models and memory figures** in `analysis/` and [`performance-notes.md`](performance-notes.md). They were measured on one archive, whose modules are unusually many and unusually alike.
- **A statement check other than "the primary theorem's type is exactly this constant".**
- **A project whose own files use Lean's module system** (a file that starts with `module`). Such a file is compiled to further parts beside its `.olean` (`.olean.server`, `.olean.private`). The archive the scripts were written for has none, and `09_kernel_replay.sh` reports any as a fault and never says the replay is complete. The check looks only at the project's own build directory, so `module` files in Mathlib do not set it off.

## What does not depend on the archive

Read as code, these make no reference to any one proof. They have still only ever been run on the default target.

- `scripts/00_check_prereqs.sh` (apart from the sizes it prints), `05_build.sh`, `06_progress.sh`, `07_tune_jobs.sh`: starting, stopping, watching and tuning a long `lake build` on a machine short of memory.
- `scripts/09_kernel_replay.sh` and `scripts/verify/kernel_check_*.sh`: `leanchecker` on every compiled module, each given only the modules it imports ([`performance-notes.md`](performance-notes.md), section 10), with results kept so that an interrupted replay carries on. This holds for a project with no `module` files (see above).
- The axiom walk of `scripts/08_check_axioms.sh --deep`.
- The source audit's categories other than the protected names.
- `scripts/spot_checkpoint.sh`: saving a build in parts and carrying on from them on a fresh machine.

## What a second archive would need to show

- That the settings in the profile are all the settings: the inventory was made by reading, and the tests use made-up projects. A run on a real archive would find what both missed.
- That the replay with import-closure search paths behaves on a project laid out differently.
- Whether the memory figures in [`performance-notes.md`](performance-notes.md) say anything about other projects.
