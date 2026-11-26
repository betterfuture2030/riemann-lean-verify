# The export check

Records of the one run of [`../../../cloud/gcp/export_guest.sh`](../../../cloud/gcp/export_guest.sh), the launcher's mode `export-check`. It takes the compiled files of the full run ([`../full-run/`](../full-run/)) out of the bucket where that run saved them, exports the proof from them, and gives the export to a kernel that was written independently of Lean's own.

The method is the community's, not this repository's: the challenge file, the list of export targets, the exporter and the kernels are the ones used in Andrew Sutherland's record (<https://math.mit.edu/~drew/grh/>) and in the community repository. What this run adds is that the same steps were carried out on the files of a separate build, on one rented 32-vCPU machine, and gave the same bytes.

`export_facts.json` is a list of facts, not a verdict. Nobody but the script and AI agents has yet checked these files against each other.

| Run | Outcome | Machine time | Recorded cost |
|---|---|---|---|
| `export-check-20261123-180914` | Every step ran; both exports equal the published ones byte for byte; `con-leche` accepted the export; `nanoda` was not run correctly (see below) | 8,084 billed seconds (2.2 hours) | 4.49 USD at the on-demand ledger rate of 2.00 USD an hour |

## `export-check-20261123-180914`

Started on 2026-11-24 at 00:09 UTC and finished at 02:21 UTC, from commit `5eaec0c`, on one `n4d-highmem-32` machine (32 vCPUs, 256 GB) in `us-east1-b`, on demand. It was the first run of this script on a rented machine; there was no rehearsal.

| Step | What `export_facts.json` records |
|---|---|
| Inputs | The tarball with SHA-256 `9631b4f0…49c7fc`; Mathlib at revision `0df444a3`, with its prebuilt cache; the pinned toolchain (Lean 4.33.1) |
| The compiled files | 77 parts fetched from the bucket, each checked against the size and SHA-256 in the full run's manifest, and unpacked in 680 seconds. The result was then hashed file by file and compared with the list the full run wrote when it sealed its build: 875,935 files, 175,187 of them compiled modules, the same (`restored_files_are_the_sealed_files`). These are the files the full run's kernel replay read |
| The exporter | `lean4export` at commit `15f6055e`, built on the machine with the pinned toolchain. The binary has SHA-256 `805ab4cc…e9b5`, the value on Sutherland's page |
| The challenge | The community's `Challenge.lean` (five statements with `sorry` for proofs, importing only Mathlib; SHA-256 of the file as written `a3cebbf3…5e21a5`), compiled and exported: 350,862,311 bytes, SHA-256 `bd484ac9…b2b9`, **equal to the published value** |
| The proof | `lean4export Main` with the community's list of targets, as a user with no network: exit status 0 after 5,718 seconds, 61,570,595,788 bytes, SHA-256 `5ea74b91…244e`, **equal to the published value** |
| `con-leche`, plain (commit `cd2eceab`) | Exit status 0 after 460 seconds. Its last line: `accepted 1468418 declarations (--verified)`. Peak memory 44.5 GiB |
| `con-leche --compare` (commit `5dc36dc1`) | Exit status 0 after 451 seconds. It accepted the 1,468,418 declarations of the proof's export and the 51,692 of the challenge's, and reported each of the five theorems of the challenge as `justified by the solution` |
| `nanoda` | **Not a result.** Exit status 101 at once: the program stopped on its argument (`trailing characters`, line 2). The script handed it the export where, it appears, it expects a configuration file. The mistake is the script's; it says nothing about the proof either way |

The whole output of each kernel is in `logs/` (`*.log.gz`; the `*.tail.txt` files are the same text). `con-leche` was built on the machine with Lean 4.36.0, as in Sutherland's record, and ran as a user with no network access and no write access to the compiled files.

### What this shows

- The compiled files of the full run, exported by the same tool with the same targets, give exactly the file that others published and checked. Every check that anyone has made of that published export is therefore a check of what this repository's run compiled.
- A kernel that shares no code with Lean's accepted every declaration in that export, on this machine, in under eight minutes on 32 vCPUs.
- The five statements proved are the five of the community's challenge file, as compared by `con-leche --compare`.

### What it does not show

- **`lake comparator` was not run.** Comparator also runs Lean's own kernel over the export, under a sandbox; that step takes from 9 to 48 hours on one thread by others' measurements and was left out. What was run is one of the kernels Comparator can be given, by hand.
- **No second independent kernel.** `nanoda` was not run correctly. `con-ron` and `lean4lean` were not tried.
- **The build was not sandboxed.** The files exported are those of the full run, which was built by a dedicated user on a machine made for the run, not inside `bubblewrap` or any other sandbox. That the export is byte for byte the published one is evidence that the build was not interfered with, but it is not the same thing as a sandboxed build.
- **`con-leche` counted 1,468,418 declarations; the dependency walk of criterion C2 counted 1,478,243 constants.** The two count different things by different rules, and the difference has not been reconciled here.
- It is one run. The script has been run once, and its only reviewer so far is the AI agent that wrote it.

### Not copied here

| File | Why | SHA-256 |
|---|---|---|
| `challenge.ndjson.zst` | 46.7 MB; the export of the challenge file, compressed. Its uncompressed SHA-256 is the published one above | `96781100…579e6b` (the compressed file) |
| `solution.ndjson` | 61.6 GB; never left the machine. Its SHA-256 is the published one above | |

The files here were copied through `scripts/dev/scrub.py clean` ([`../../README.md`](../../README.md)); it changed one file. In `pilot.log`, two lines of the package installer's output name a system service in a form that looks like an e-mail address, and now read `<EMAIL>`. Empty files were not copied.
