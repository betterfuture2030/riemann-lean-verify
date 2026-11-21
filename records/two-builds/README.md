# The same modules, built twice

Comparisons of the compiled files that two builds produced for the same modules, made on 2026-11-21 with [`../../analysis/compare_builds/`](../../analysis/compare_builds/). They cover about one module in a hundred, from the bottom of the import graph. They are evidence about the build, and none of them is a verification result for the proof.

| File | What was compared |
|---|---|
| `cloud-vs-cloud.json` | The third and the fifth rehearsal of the cloud driver ([`../cloud/full-rehearsals/`](../cloud/full-rehearsals/)): two separate machines of the same type, Linux on x86-64, each building from the tarball for seven minutes |
| `mac-vs-cloud.json` | The build on the Mac (macOS on Apple silicon) and the fifth cloud rehearsal |
| `mac-vs-cloud-content.tsv` | For each compiled file that differs between those two, a comparison by content: one line per module, from `OleanDiff.lean` |

## What they show

**Two cloud builds agree to the byte.** The two rehearsals have 1,504 modules in common. Every file of every one of them is identical in both: the compiled module, its index file, the hashes the build tool keeps, and the build tool's record of the module's inputs.

**The Mac and the cloud agree on content, and differ in one string.** They have 1,796 compiled files in common.

| Kind of file | Identical | Different |
|---|---|---|
| `.ilean` (the module's index of declarations and references) | 1,795 | 0 |
| `.olean` (the compiled module) | 1,097 | 699 |
| `.trace` (the build tool's record of inputs) | 0 | 1,794 |

- Each of the 699 compiled files that differ is exactly 16 bytes larger on the Mac. The source tree's path is 16 characters longer on the Mac than on the cloud machine, and in each of the 699 the absolute path of the module's own source file is text found in one file and not the other. In 661 of them it is the only such text; in the other 38 the scan also picked up a few bytes of shifted addresses that happen to be printable.
- By content the 699 are the same. `OleanDiff.lean` read each pair with the pinned Lean and compared the imports, the names of the constants and their order, and each constant's kind, universe parameters, type and value: 25,333 constants, all equal. It does not compare the entries of environment extensions, which is presumably where the path sits; it found the same number of entries in both.
- The traces all differ because each records the absolute path of its source file and of the search path. The value the build tool compares to decide whether a module is up to date is the same on both machines for 849 modules, and where it differs, the inputs that differ are the hashes of imported compiled files, the 699 above and what depends on them. No input is the platform.

**What this does not show.** That the path is the whole cause has not been tested by building the same module at the same path on both machines; it is what the evidence above points to. The modules are the first hundredth of the tree. And equal content of compiled files across two platforms says the two compilers agreed, which is a check on the build, not a second opinion on the proof: both use the same kernel.

## To repeat it

```bash
python3 analysis/compare_builds/compare_builds.py LIB_A LIB_B --traces --pairs pairs.tsv
( cd WORKDIR/extract/lean && lean --run REPO/analysis/compare_builds/OleanDiff.lean pairs.tsv )
python3 analysis/compare_builds/compare_builds.py LIB_A lib_sha256.txt.gz      # against a cloud run's manifest
```

`LIB_A` and `LIB_B` are two `.lake/build/lib/lean` directories of the project. A cloud run launched with `GCP_KEEP_OLEANS=1` leaves an archive of its directory in the bucket; every cloud run uploads `lib_sha256.txt.gz`, a SHA-256 of each file in it.
