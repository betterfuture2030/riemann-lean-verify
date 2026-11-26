# The kernel check

Records of the two runs of [`../../../cloud/gcp/kernel_guest.sh`](../../../cloud/gcp/kernel_guest.sh), the launcher's modes `kernel-check-rehearsal` and `kernel-check`. The script compiles nothing of the proof. It takes the two export files whose hashes the export check recorded ([`../export-check/`](../export-check/)), the challenge and the proof, and gives the proof's export to four checkers: `nanoda`, a kernel written independently of Lean's; `con-ron --compare`; `lake comparator`, which compares the five statements and the axioms with the challenge in its own process and then runs Lean's own kernel over the whole export in its `bubblewrap` sandbox; and Lean's "paranoid" build of that kernel.

The method is the community's, not this repository's. The challenge, the checkers, the allocator setting and the configuration (less two entries, described below) are those of Andrew Sutherland's record (<https://math.mit.edu/~drew/grh/>) and of the community repository as it stood on 2026-11-25, and every one of these checks had been made there first. What these runs add is a measurement: these checks, with the two differences described below, on one rented 32-vCPU machine, in half a day, for about 23 USD.

The file checked is the published copy of the proof's export. This repository's own export, made in the export check, was 61.6 GB and never left the machine that made it; what that run kept was its size and SHA-256, which are the published ones. So the bytes checked here came from the published copy, and they are the bytes this repository's build exports only in the sense that the two have the same SHA-256.

`kernel_facts.json` is a list of facts, not a verdict. Nobody but the script and AI agents has yet checked these files against each other.

| Run | Outcome | Machine time | Recorded cost |
|---|---|---|---|
| `kernel-check-rehearsal-20261125-135136` | Every step ran, on small stand-ins. The proof's export was fetched from the published copy, checked against both hashes and kept in the bucket | 1,364 billed seconds (23 minutes), on a 4-vCPU machine | 0.11 USD at that machine's ledger rate of 0.30 USD an hour |
| `kernel-check-20261125-141623` | Every step ran. All four checkers ended with exit status 0 and accepted the export | 41,349 billed seconds (11.5 hours) | 22.97 USD at the on-demand ledger rate of 2.00 USD an hour |

## `kernel-check-20261125-141623`

Started on 2026-11-25 at 20:16 UTC and reported its final state on 2026-11-26 at 07:42 UTC, from commit `624168b`, on one `n4d-highmem-32` machine (32 vCPUs, 256 GB) in `us-central1-b`, on demand. The machine was deleted three minutes later. It was the second run of this script on a rented machine; the first was the rehearsal below.

| Step | What `kernel_facts.json` and `logs/` record |
|---|---|
| Inputs | The challenge's export, from the export check's files in the bucket: 350,862,311 bytes, SHA-256 `bd484ac9…b2b9`. The proof's export, compressed, from the bucket where the rehearsal had put it (7,699,933,588 bytes, SHA-256 `61a8938a…5381`, the published values), fetched in 52 seconds and unpacked in 102: 61,570,595,788 bytes, SHA-256 `5ea74b91…244e`. Both unpacked hashes are the ones the export check recorded for this repository's own exports (`challenge_is_the_export_checked_before`, `solution_is_the_export_checked_before`); a file with any other hash would have ended the run |
| The checkers | The Lean v4.36.0 toolchain (commit `611c117b`), which carries `lake`, `leanchecker`, `leanchecker-paranoid` and `nanoda_bin`; the SHA-256 of each binary is recorded. `con-ron` at commit `3f22699b`, the commit of the published record, built on the machine with `rustc` 1.100.0 |
| Smoke tests | Before anything long: `lake comparator`, with its sandbox, on a two-line challenge. It accepted the right solution, with the community's two external kernels and a stand-in kernel that passes only if the allocator setting has reached it; it rejected a wrong solution with exit status 1 (`Challenge and solution theorem statement do not match`). Each checker then ran alone on the small solution, exit status 0 each |
| `con-ron --compare` | Exit status 0 after 600 seconds, on 32 workers. `accepted 51692 declarations, 5 axioms justified by the solution … (1468418 declarations accepted) (--verified)`, and each of the five theorems `justified by the solution`. Peak memory 41.8 GiB |
| `nanoda` | Exit status 0 after 2,412 seconds (40 minutes), on 32 threads. It printed three axioms, `propext`, `Quot.sound` and `Classical.choice`, and then `Checked 1484733 declarations with no errors`. Peak memory 79.1 GiB |
| `lake comparator` | Exit status 0 after 36,221 seconds (10 hours 4 minutes). Its whole output: `Running Lean default kernel on solution`, `Lean default kernel accepts the solution`, `Your solution is okay!`; nothing on its error stream. It reached the kernel after 2,091 seconds, which means its comparison of the five statements and of the axioms had passed: a mismatch ends it there, as in the smoke test. The kernel then ran for about 9 hours 29 minutes inside the sandbox, with the allocator setting in its environment (read from the running process) and a peak of 82.6 GiB. Before that, while it read and compared the two exports, `lake`'s own process had peaked at 82.9 GiB (GNU `time`, which does not see the kernel inside the sandbox); it held 1.1 GiB by the time the kernel was seen, so the two peaks did not fall together |
| Lean's paranoid kernel | `leanchecker-paranoid --silent --from-export`, started beside the other once `nanoda` and `con-ron` had ended: exit status 0 after 38,150 seconds (10 hours 36 minutes). With `--silent` it prints nothing; its exit status is the result. Peak memory 98.8 GiB |
| Memory | No process was killed for lack of memory. The 64 GiB of swap set up for the run was untouched in every five-minute sample (`logs/procs.log`), and the least memory available in any of them was 91.6 GiB of 251.7 |

`lake comparator`, as called here, built nothing: with both `--challenge-from-export` and `--solution-from-export` it reads the two files given. The command line, with the time and memory GNU `time` measured, is in `logs/comparator.time`; the configuration is `logs/rh.json`; and `logs/bwrap_calls.log` holds every sandbox command line that `lake` issued, with the one variable added.

### Two things done differently from the published runs

Both were chosen to make the run affordable, and both were decided and written into the script before the run.

- **The allocator setting.** `MIMALLOC_GENERIC_COLLECT=1000000` is an environment variable read by the stock binary. The published record measured Lean's kernel on this export at 48 hours without it and 9 hours with it, same binary, same result. `lake comparator` clears the environment of the checkers it starts, so the setting was passed in by naming, as the sandbox program (`COMPARATOR_BWRAP`), a wrapper that runs the real `bwrap` with `lake`'s own arguments plus that one variable. The sandbox is otherwise as `lake` asked for it. `lake`'s own process, which reads the two exports and compares them before any kernel starts, was also started with the variable in its environment; whether that changed its 35 minutes was not measured.
- **Which kernels ran inside `lake comparator`.** The community's configuration for this formalization (`comparator.json` on Sutherland's page; in the community repository, as read on 2026-11-26, on the branch `alpoge` and no longer on `main`) names two external kernels, the paranoid kernel and `nanoda`, which `lake` runs one after another before Lean's default kernel. Here the configuration is the community's without them (`"enable_nanoda": false` and no `external_kernels`), and those two checkers ran on the same file beside it, as a user with no network access but not inside `bubblewrap`. So the verdict `Your solution is okay!` recorded here covers the comparison of statements and axioms and Lean's default kernel; the paranoid kernel and `nanoda` each accepted the same file in runs of their own.

The published run of `lake comparator` (Lean v4.36.0) with the community's configuration took 122 hours 45 minutes and ended with the same verdict on 2026-11-25 at 21:49 UTC, an hour and a half after this run was started. As read on 2026-11-26, its page gives no allocator setting for that run. The difference between 123 hours and 10 is what those two choices buy; it is consistent with the published times of Lean's two kernels on their own without the setting (72 and 48 hours), which leave a little over two hours for `nanoda` and for `lake`'s own reading of the exports.

One setting of the rented machine was also changed so that `bubblewrap` could work at all: Ubuntu 24.04 stops unprivileged programs from creating user namespaces, and the script lifts that rule (`kernel.apparmor_restrict_unprivileged_userns=0`, `logs/sysctl.log`).

### Beside the published figures

Read from Sutherland's page and the logs it links on 2026-11-25 and 26. The page gives the number of threads each run used and does not describe the machines; the memory figures for `nanoda` and `con-ron` are from the logs.

| Checker | Here, on 32 vCPUs | Published |
|---|---|---|
| `nanoda` | 40 min 12 s on 32 threads; 79.1 GiB | 27 min 42 s on 80 threads; 84.8 GiB |
| `con-ron --compare` | 10 min 0 s on 32 workers; 41.8 GiB | 7 min 6 s on 64; 44.6 GiB |
| Lean's default kernel, with the allocator setting | About 9 h 29 min, inside `lake comparator`'s sandbox; 82.6 GiB | 9 h 8 min, on its own; 82.6 GiB |
| Lean's paranoid kernel, with the allocator setting | 10 h 36 min; 98.8 GiB | 10 h 0 min; 98.8 GiB |
| `lake comparator`, end to end | 10 h 4 min, with one kernel inside it and the allocator setting | 122 h 45 min, with three kernels inside it |

`con-ron` counted the same declarations here as there: 1,468,418 in the proof's export and 51,692 in the challenge's.

### What this shows

- A second kernel written independently of Lean's, `nanoda`, accepted every declaration in the published export, which has the SHA-256 of the export this repository's build produced. The first, `con-leche`, did so in the export check, on that export itself.
- `lake comparator` reported the five theorems of the community's challenge as proved by that file, on the three standard axioms, with Lean's own kernel replaying the whole of it inside the sandbox.
- Lean's paranoid kernel accepted the same file.
- The whole of it fits on one rented machine for half a day. The two long checks each use one core; what the machine's size bought was the memory to run them side by side.

### What it does not show

- **`lake comparator` with stock settings and the community's configuration unchanged was not run.** The run here differs from it in the two ways above. The published record has that run.
- **No checker here read a file of the proof that this repository made.** The proof's export was the published copy; what ties it to this repository's build is the comparison of size and SHA-256 made once, in the export check. Only the challenge's export was this repository's own file.
- **Neither of Lean's kernels was run without the allocator setting.** The published record has both.
- **`lake comparator --paranoid` was not run.** According to the published record, the further checkers it adds do not work on this proof as bundled with Lean v4.36.0: `con-leche` and `con-ron` decline it over one inductive type they do not support, which the record marks as not a rejection, and `lean4lean` cannot read a library of the older Lean version. The published record of this formalization has no such run either.
- **`lean4lean` was not run**, nor the standalone Comparator (v4.33.0), which the published record has end to end.
- **The build was not sandboxed.** Nothing was built here. The files exported are those of the full run, built by a dedicated user on a machine made for the run, not inside `bubblewrap`. The export is byte for byte the published one, which a sandboxed build elsewhere reproduced; that is evidence about this build, not a sandboxed build of it.
- **Only the kernel inside `lake comparator` ran in a sandbox.** `nanoda`, `con-ron` and the paranoid kernel ran as an unprivileged user that could reach no network and could not change the two export files. `lake`'s own comparison of statements and axioms ran as that user too.
- **`con-ron` is not independent of `con-leche`.** It is a port of it to Rust. It is recorded here as a second implementation of the comparison of statements, not as a third kernel.
- **Three counts are not reconciled.** `nanoda` counted 1,484,733 declarations, `con-leche` and `con-ron` 1,468,418, and the dependency walk of criterion C2 visited 1,478,243 constants. They count different things by different rules.
- **One size does not agree with the published page.** The page, as read on 2026-11-26, gives the challenge's export as 350,862,970 bytes beside the SHA-256 above. The file with that SHA-256 was counted at 350,862,311 bytes in the export check and in both runs recorded here. One file cannot have both sizes; the hash is the same, so this is about a figure on a page and not about the file.
- It is one run. The script has been run twice, once as a rehearsal, and reviewed only by AI agents ([`../../../docs/cloud-notes.md`](../../../docs/cloud-notes.md), section 10.10).

## `kernel-check-rehearsal-20261125-135136`

Started on 2026-11-25 at 19:51 UTC from the same commit, on one `n4d-highmem-4` machine (4 vCPUs, 32 GB) in `us-central1-b`, on demand; the guest reported its final state 19 minutes after it began. A rehearsal tests the script and says nothing about the proof.

It did one piece of real work, the slow one that needs no large machine: it fetched the proof's export from the published copy (7.7 GB in 679 seconds), found the compressed file's SHA-256 to be the published one and the unpacked stream's to be the export check's, without writing the 61.6 GB to disk, and kept the compressed file in the bucket for the long run.

Everything else ran on stand-ins. `lake comparator` compared the challenge's export (351 MB) with itself, with `sorry` permitted as an axiom, so that its kernel stage lasted long enough for the script to find the kernel, read its environment and start the paranoid kernel beside it: 69 seconds, exit status 0, the allocator setting present. `nanoda` checked the same file (`Checked 53722 declarations with no errors`), and `con-ron --compare` the small pair of the smoke test. Each step did what it should.

## Files

In each run's directory: `kernel_facts.json` and `facts.tsv` (the same facts, as they were recorded), `status.json`, `phases.tsv` and `setup.tsv` (when each phase began and how long each setup step took), `env.txt` (the machine), `heartbeat` (when the guest last reported, in seconds since 1970), `pilot.log` (the script's own log) and `watch.log` (what `watch` printed on the owner's machine, the teardown included; its clock times, like the time in each run's name, are that machine's local time and not UTC). In `logs/`: for each checker its output, its error stream where it wrote one, and GNU `time`'s report (`*.time`, with three lines of it repeated in `*.time.txt`); the configurations given to `lake comparator` and to `nanoda` (`rh.json`, or `rehearsal.json` in the rehearsal; `nanoda.json`; and those of the smoke tests); `bwrap_calls.log`; `procs.log`, a sample of the checkers' processes and of free memory every five minutes; the logs of installing the toolchain and building `con-ron` (with `con_ron_help.txt`, the help text of the program that was built); what each smoke test printed (`smoke_*`, `tiny_build.log`); and `sysctl.log`.

### Not copied here

| File | Why | SHA-256 |
|---|---|---|
| `solution.ndjson.zst` | 7.7 GB; the published file, kept in the bucket | `61a8938a…5381` |
| `solution.ndjson` | 61.6 GB; unpacked on the machine and deleted with it. Its SHA-256 is the published one | `5ea74b91…244e` |

The files here were copied through `scripts/dev/scrub.py clean` ([`../../README.md`](../../README.md)); it changed four files. In each `pilot.log`, two lines of the package installer's output name a system service in a form that looks like an e-mail address, and now read `<EMAIL>`. In each `watch.log`, the names of a bucket, a project and a local directory were replaced. Empty files were not copied: among them the error stream of `lake comparator`, the output and error stream of the paranoid kernel, and the list of processes killed for lack of memory.
