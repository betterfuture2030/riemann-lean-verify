# Rehearsals of the full-run driver

Short runs of [`../../../cloud/gcp/full_guest.sh`](../../../cloud/gcp/full_guest.sh) in its rehearsal mode: a build boxed at seven minutes, then every later phase on what was built. A rehearsal tests the driver. It verifies nothing about the proof.

| Run | Outcome | Machine time | Recorded cost |
|---|---|---|---|
| `full-rehearsal-20261120-211809` | Stopped itself during setup, 109 seconds in | 353 seconds | 0.20 USD |

## `full-rehearsal-20261120-211809`

The first rehearsal ended at the setup step `smoke_build`. That step compiles two files to confirm that Mathlib's prebuilt cache is accepted, and then, as a new safety check, compares a SHA-256 of every file under the packages' compiled-library directories with the record taken just before. The comparison found five files changed, all of them `.hash` files of Mathlib (`pilot.log` lists them).

Those are the build tool's own bookkeeping: beside each compiled file it keeps a small file holding that file's hash, and it rewrites one when it cannot read it. The same five were found rewritten on the local Mac build, each a 16-digit hash made of decimal digits only and starting with zero. Nothing that the checks read had changed, and no Mathlib module was recompiled.

The check was too strict, not wrong to exist. The driver now leaves the build tool's `.hash` and `.trace` files out of that comparison and compares every other file as before. Nothing else in the run was reached.

Files: `setup.tsv` (the setup steps and their durations), `pilot.log` (the guest's log, with the five differences), `env.txt` (the machine, the toolchain and the manifests' hashes), `facts.json` and `status.json` (as the guest wrote them on stopping), `phases.tsv`.

Each file was written by `scripts/dev/scrub.py clean`; one home-directory path in `env.txt` was replaced by a placeholder.
