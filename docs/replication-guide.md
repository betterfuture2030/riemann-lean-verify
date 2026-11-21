# Replication guide

How to check this work yourself, at whatever depth your time and hardware allow. Each level stands alone and is worth doing without the next.

Nothing here needs an AI system. The scripts are short shell and Python and are meant to be read; each level also lists the plain commands the scripts run, so you can do it by hand.

## Levels at a glance

| Level | What you establish | Time | Disk | Needs Lean |
|---|---|---|---|---|
| 0 | What is claimed and on what evidence | Minutes | None | No |
| 1 | The source is the recorded artifact; it contains none of the usual shortcuts; it states the real theorem against the real Mathlib | 5 to 15 minutes | About 2 GB | No |
| 2 | The toolchain and Mathlib cache work; the final reduction step is kernel-checked on standard axioms; a sample of modules passes kernel replay | About an hour | About 10 GB | Yes |
| 3 | The whole tree compiles, or does not | Days on a laptop; an estimated 16 hours on a 32-vCPU cloud machine | 200 GB to 1.5 TB | Yes |
| 4 | The pre-registered verdict: axioms and statement of the compiled theorem, and a full kernel replay | Days more on a laptop; an estimated 15 hours more on that cloud machine | Same | Yes |

## Level 0: read

1. [`PREREGISTRATION.md`](../PREREGISTRATION.md): what would count as verified, fixed before the outcome was known.
2. [`CLAIMS.md`](../CLAIMS.md): every claim, its evidence tier and how to reproduce it.
3. [`records/`](../records/): the hashes, expected values and measurements from the runs so far.

## Level 1: reproduce the no-compile findings

```bash
git clone https://github.com/betterfuture2030/riemann-lean-verify
cd riemann-lean-verify
scripts/reproduce_findings.sh
```

It prints PASS or FAIL for each tier-S claim. By default everything goes under `./work`; to use another disk, copy `config.example.env` to `config.env` and set `RH_WORKDIR`.

By hand, the same checks are:

```bash
# S1: download and hash
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do curl -L -o lean.tar.gz.part$i https://alpo.ge/lean.tar.gz.part$i; done
cat lean.tar.gz.part* > lean.tar.gz
shasum -a 256 lean.tar.gz        # expect 9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc

# S2: inspect before extracting. Every line should start with "-rw" and every path with "lean/".
tar -tvzf lean.tar.gz | awk '{print substr($1,1,1), substr($1,4,1)}' | sort | uniq -c
tar -tzf lean.tar.gz | grep -cE '^/|(^|/)\.\.(/|$)'     # expect 0

# S3, S4: extract and look
tar -xzf lean.tar.gz
find lean/src -name '*.lean' | wc -l                     # expect 175187
cat lean/lean-toolchain lean/lakefile.toml
cat lean/src/Statements.lean lean/src/Main.lean

# S5: the pinned Mathlib revision is the official tag
grep -A3 '"name": "mathlib"' lean/lake-manifest.json; grep '"rev"' lean/lake-manifest.json | head -1
git ls-remote https://github.com/leanprover-community/mathlib4 refs/tags/v4.33.1

# S6: the usual shortcuts (whole words; each should print nothing)
for w in sorry admit axiom native_decide unsafe implemented_by extern; do grep -rlw "$w" lean/src | head -1; done
grep -rl '#eval' lean/src | head -1
```

The server does not honour HTTP range requests, so an interrupted part has to be downloaded again from the start.

## Level 2: toolchain, one kernel-checked step, a sample replay

Install [`elan`](https://github.com/leanprover/elan), the Lean version manager, then:

```bash
scripts/verify.sh                         # levels 0 and 1 again, then the pinned toolchain, Mathlib cache and a smoke build
scripts/08_check_axioms.sh --probe        # axioms and statement of the final reduction lemma
```

`--probe` checks `Formalism.VW.rh_of_right`, which says: if the zeta function has no zeros with real part above 1/2 (other than the pole), then `RiemannHypothesis`. Expect the axioms `propext`, `Classical.choice` and `Quot.sound`, and a conclusion that is exactly Mathlib's constant.

By hand, in the extracted project directory:

```bash
lake exe cache get                                              # Mathlib's compiled files; never run `lake update`
lake build +Statements +Formalism.GammaFactorNonvanishing.RhOfRight
cat > /tmp/probe.lean <<'EOF'
import Formalism.GammaFactorNonvanishing.RhOfRight
#print axioms Formalism.VW.rh_of_right
#check @Formalism.VW.rh_of_right
#print RiemannHypothesis
EOF
lake env lean /tmp/probe.lean
```

A sample kernel replay needs some compiled modules, so start the build (level 3), let it run for a few minutes, and then:

```bash
scripts/09_kernel_replay.sh --sample 24
```

## Level 3: the full compile

```bash
scripts/00_check_prereqs.sh       # prints a recommended number of parallel jobs for your memory
scripts/05_build.sh start         # detached; survives closing the terminal
scripts/06_progress.sh            # whenever you like
scripts/05_build.sh stop          # safe at any time; finished modules are kept
```

What to expect is in [`performance-notes.md`](performance-notes.md). The short version: on a small machine memory, not CPU, is the first limit, at roughly 2 GB per parallel job plus 8 GB; too many jobs makes the build slower; and the last few thousand modules import so much that a machine with little memory will slow down on them.

Two things to do before starting:

- On Linux, raise the limit on memory mappings: `sudo sysctl -w vm.max_map_count=1048576`. At the usual default, modules that import more than about 12,000 project modules are expected to fail. `scripts/00_check_prereqs.sh` reports the current value.
- Check the disk. Lake writes 1.2 to 1.4 TB for the whole tree (allow 1.5 TB), about nine tenths of it regenerable setup files. If you have less, `scripts/prune_setup_files.sh --delete` removes the setup files of finished modules and can be run while the build is going, which brings the need down to about 150 GB (allow 200 GB); read its header first.

A module that fails is not necessarily a failure of the proof. If the compiler process was killed for lack of memory, re-run with fewer jobs. The rule this project uses is in section 4 of the pre-registration: a module counts as failing only when it fails with a Lean error, reproducibly, with enough memory.

On Google Cloud, [`cloud/gcp/`](../cloud/gcp/) has a calibration pilot that measures the cost on a rented machine before you commit to a full run. Its results from 2026-11-20, and the estimates built on them, are in [`cloud-notes.md`](cloud-notes.md), section 8: about 16 hours for a full build, and for the kernel replay after it about 46 hours with the stock tool or about 5 with `rhv-replay` (section 8.5).

## Level 4: the verdict

After the build completes with zero errors:

```bash
scripts/08_check_axioms.sh --deep     # criterion C2: statement, #print axioms, and a full traversal for axioms
scripts/09_kernel_replay.sh           # criterion C3: every module through the kernel again
```

Compare the outcome with the table in section 5 of the pre-registration.

The second command, as written, uses the stock tool `leanchecker`, one process per module. On the whole tree that is slow for a reason that has nothing to do with the proof: the tool lists every compiled file before each check. It is estimated at about 46 hours on a 32-thread machine and at weeks on a laptop ([`performance-notes.md`](performance-notes.md), section 10). The script has a second method that runs the same replay function of the same toolchain without the listing:

```bash
scripts/09_kernel_replay.sh --method rhv-replay    # every module, a few seconds each
scripts/09_kernel_replay.sh --sample 2000          # the stock tool on 2,000 random modules, for comparison
scripts/09_kernel_replay.sh --prefix-modules       # the stock tool on the 114 prefix modules and the modules beneath them
scripts/09_kernel_replay.sh --summary              # counts by method, and any module on which the two disagree
```

Before it runs, the script compares the copy of the replay function in [`../scripts/verify/replay/RhvReplay.lean`](../scripts/verify/replay/RhvReplay.lean) with the toolchain's own source and stops if they differ. You can make the same comparison by eye: the function is 23 lines, and the rest of the file is a loop that calls it. The pre-registration names `leanchecker`; whether a replay by the second method satisfies criterion C3 is governed by the pre-registration and its dated amendments, not by this guide.

## If something does not reproduce

Open an issue with the script's output and the file it names under `RH_WORKDIR/logs`. A claim in this repository that cannot be reproduced as described is a defect in the repository.
