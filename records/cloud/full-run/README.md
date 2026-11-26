# The full run in the cloud

Records of the one full run of [`../../../cloud/gcp/full_guest.sh`](../../../cloud/gcp/full_guest.sh): the whole tree built from the published tarball on a rented machine, then the pre-registered checks, in the mode `full-spot` ([`../../../docs/cloud-notes.md`](../../../docs/cloud-notes.md), sections 9 and 10).

What is here is what the scripts wrote. `facts.json` is a list of facts, not a verdict: read it against [`../../../PREREGISTRATION.md`](../../../PREREGISTRATION.md), sections 3 to 6. Nobody but AI agents and the scripts themselves has yet checked these files against each other; the hashes below are there so that anyone can.

| Run | Outcome | Machine time | Recorded cost |
|---|---|---|---|
| `full-spot-20261122-150121` | Two attempts, one reclaim by Google; every phase ran on all 175,187 modules; state `DONE` | 93,643 billed seconds (26.0 hours), of which about 4.5 hours were an idle machine waiting to be collected | 31.21 USD at the Spot ledger rate of 1.20 USD an hour |

## `full-spot-20261122-150121`

Started on 2026-11-22 at 21:01 UTC and finished on 2026-11-23 at 18:33 UTC, from commit `e8553dd` of this repository, on `n4d-highmem-32` Spot machines (32 vCPUs, 256 GB) in `us-central1-a`, with 32 parallel jobs. The input was the tarball with SHA-256 `9631b4f0…49c7fc`, the pinned toolchain (Lean 4.33.1) and Mathlib's prebuilt cache for the pinned revision.

| Attempt | Billed | What it did | How it ended |
|---|---|---|---|
| 1 | 4,515 s | Setup in 117 seconds; the two restart tests (0 finished modules compiled again in either); built to 13,899 modules by its last status line, and saved 12,450 of them in six parts | Google took the machine back 4,409 seconds after boot. The guest logged the notice and reported `RECLAIMED` three seconds later |
| 2 | 89,128 s | Restored the six parts in 47 seconds and compiled none of the 12,450 restored modules again; built the rest (12.6 hours on this machine); sealed; both axiom checks; three replay trials; the main replay (7.2 hours); the end check | `DONE`, 72,954 seconds after boot. The machine then idled for about 4.5 hours: see below |

What the facts record, by criterion. The wording of each criterion is in the pre-registration, section 3.

| Criterion | What `facts.json` records |
|---|---|
| C1 | `lake build` exit status 0; 175,187 source modules and 175,187 compiled modules, none without the other; 0 failed job lines in every build log of both attempts; no retry after a failure |
| C2 | Plain and deep checks both `PASS`, with the whole tree compiled. The type of `riemannHypothesis` is the constant `RiemannHypothesis`, which `c2/deep.json` gives as defined in `Mathlib.NumberTheory.LSeries.RiemannZeta`. `#print axioms` lists `propext`, `Classical.choice` and `Quot.sound` for `riemannHypothesis` and for the other four theorems of `Main.lean`. The traversal visited 1,478,243 constants (1,265,279 in 146,440 project modules, 212,964 in 5,254 library modules), found those three axioms and no other, and found no constant missing |
| C3 | 175,187 of 175,187 compiled modules passed by `leanchecker` of the pinned toolchain (one program, SHA-256 `84bc3e7c…486d0`); 0 rejections, 0 crashes, 0 damaged result lines; nothing left unchecked. 175,117 were run with only their import closure on the search path, and the 70 that import modules beneath themselves with those modules there too |
| No change to the artifact (section 4) | Source tree unchanged since extraction; toolchain and Mathlib unchanged from before the first compile to the end check; compiled files unchanged from the seal to the end check; no process of the build user seen after the seal on either attempt |

What carried the work from the first machine to the second, and how it was checked: the second machine's source tree, toolchain and Mathlib hashed the same as the first's (`baselines_same`); each of the 77 parts was checked against its SHA-256 in the manifest; and at the seal the parts were shown to reproduce the sealed files exactly (875,935 files, none missing, different or extra, no repair part). During the replay the compiled files, the toolchain and Mathlib were hashed again before any result was saved: 22 such checks, each "as sealed".

### Times and sizes

| Step | Time |
|---|---|
| Build, both attempts | 4,292 s before the reclaim and 45,285 s after it: 13.8 hours in all, which includes the restart tests and whatever the first machine compiled after its last part |
| Seal | 83 s |
| Axiom check, plain / deep | 59 s / 551 s |
| Replay trials at 16, 24 and 32 at a time | 300 s each; 1,028, 1,233 and 1,391 modules |
| Main replay | 25,840 s (7.2 hours) at 32 at a time |
| End check | 26 s |

The compiled files came to 100.2 GB and the parts that hold them to 30.6 GB, 0.17 MB a module. A confirming hash took 25 seconds with 32 processes on an otherwise idle machine, 39 seconds with four, and 184 to 189 seconds with four while the replay was running.

How this compares with what was forecast is in [`../../../docs/cloud-notes.md`](../../../docs/cloud-notes.md), section 10.8.

### The idle machine

The guest finished at 18:33 UTC. `watch`, which runs on the owner's computer, fetches the results and deletes the machine, had stopped at 16:33 UTC when that computer restarted. It was started again at 23:01 UTC, found the run `DONE`, and deleted the machine, which had been billed for about 16,150 idle seconds in between (about 5.38 USD of the 31.21). Nothing was lost: the results were already in the bucket, and the machine's own time limit would have deleted it by 05:00 UTC the next day. `watch.log` shows the gap.

### Things in the files that look odd

`watch.log` has three lines `fetch-failed … status.json not found`, hours apart. Each is a poll that landed while the guest was replacing that object; the next poll read it. And the gzip files here are not byte-for-byte the machine's: the tool that copies records into this repository writes them again, with the same contents (the uncompressed bytes of `c3/results.tsv.gz` and of both `modules.tsv.gz` were compared with the originals). For that reason the SHA-256 that `facts.json` gives for the results object in the bucket (`fbfb6445…5bf3d`) is not that of `attempt-2/c3/results.tsv.gz`, which is the machine's working copy of the same results.

### What this run does not show

- It is one run, on one kind of machine, of code written with AI assistance and reviewed by AI agents. It has not been repeated. A second build of the same tree, on a Mac, was 69 percent done when this was written and had no failure.
- It rests on the trust assumptions of the pre-registration, section 6: the Lean kernel and the pinned toolchain binary, Mathlib's definitions, Mathlib's prebuilt cache, and the hardware and operating system. None of the optional checks of section 7 has been made.
- Of what the Spot design can meet, it met one reclaim by Google, during the build. It did not meet a reclaim after the seal, an attempt outside the bucket's region, an attempt ending at its own deadline, a pause on the cap, a repair part, or a failed upload or download.

### Files

At the top: `facts.json` and `status.json` as the second attempt wrote them, `watch.log` (what `watch` printed on the owner's machine), and `ckpt/` (the run's final `state.json` and `manifest.tsv`, with the SHA-256 and size of each part). Under each `attempt-N/`: that machine's `env.txt`, `setup.tsv`, `phases.tsv`, `pilot.log`, `spot.log`, `progress.tsv`, `modules.tsv.gz` (one line per build job, with its seconds) and `system.tsv.gz`; from the first, `restart_tests.txt`; from the second, `disk.txt`, `disk_after_build.txt`, the axiom checks under `c2/` (`plain.json`, `deep.json`, their logs, and `deep.modules.tsv.gz`, every module the traversal touched), the replay under `c3/` (`results.tsv.gz`, one line per module and tool, and `summary.*`), and the small output files of each phase under `logs/`.

Each file was written by `scripts/dev/scrub.py clean`; a home-directory path in each `env.txt` and the project, bucket and work-directory names in `watch.log` were replaced by placeholders, and `deep.modules.tsv` was compressed.

Not copied, for size. They are kept with the run's results, and their SHA-256 is given so that a copy can be recognised:

| File | Bytes | SHA-256 |
|---|---|---|
| `attempt-2/lib_sha256.txt.gz`, the SHA-256 of every compiled file at the seal | 41,233,251 | `689e5903bb3f2065b1b0aa93299486896bd9cab844945394468d9adac9be6c77` |
| `attempt-2/libraries_sha256.txt.gz` (Mathlib and the other packages) | 2,397,341 | `044759af9c94ebc680a642082ff37493d47c99c5f0cacc7a150279b1791536a6` |
| `attempt-2/toolchain_sha256.txt.gz` | 788,253 | `2a36c254d739228726cf3206b66ad410b26422e217fbad2525ec4421a6a1cce9` |
| `attempt-2/logs/lake_build_1.log.gz` | 12,289,423 | `c1360f4947399a0c484a0a561fe184926f6df0dc3299152d99f8e96143e3596f` |
| `attempt-1/logs/lake_build_1.log.gz` | 295,975 | `a067a2ea8b1dca669146dbe8a91ae07de8c77b8dc40304775b808c7faed5e1c9` |
| `attempt-1/logs/lake_build_2.log.gz` | 266,871 | `3673c3a5ff19930df0eca1da737b013d6dd5b8b6382b4625726bc8be42a62af1` |
| `attempt-1/logs/lake_build_3.log.gz` | 967,907 | `a88f84a143a1978dcd763745c8cb239a11358ab50c56406a0713a9cc2fea992c` |
| `attempt-2/c3/out.tar.gz`, the replay's output for the modules checked together with those beneath them | 16,710 | `b337236541cb90171a6bcf8df75f391ba22e81c2425b5b7251e8662c173bad33` |

The first of these, uncompressed, has the SHA-256 that `facts.json` records as `seal.compiled_files_manifest_sha256` (`a770548c…03fab3`). The compiled files themselves, as the 77 parts listed in `ckpt/manifest.tsv` (30.6 GB), were still in the project's bucket when this was written; they are not published.
