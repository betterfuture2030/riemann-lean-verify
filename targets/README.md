# Targets: one settings file per archive

The scripts in [`../scripts/`](../scripts/) were written for one Lean 4 archive. Everything in them that is a fact about that archive is now read from a *target profile*, a short settings file in this directory. The archive they were written for is the default target, `alpoge-rh`: with no target named, every script does what it did before profiles existed.

**State of this, on 2026-11-26:** the mechanism is tested offline, in under a minute, by `scripts/dev/test_targets.sh`, on small made-up projects. For the default target that test uses a made-up stand-in for its tarball. On the real tarball, only the archive listing and entry checks have been run with these changes, and their output was the same as before, under Python 3.14 and under macOS's own Python 3.9. Those checks now include one that nothing but zero bytes follows the end of the archive; the real tarball passes it, so the listing recorded for it before saw every entry. The full pipeline (build, axiom check, kernel replay) has not been run again on the default target since profiles were added. The second profile here, `grh-compact`, has not been run on its archive yet. The cloud scripts in `cloud/gcp/` know only the default target, and `cloud/gcp/pilot_local.sh` stops if another is named.

## Choosing a target

```bash
scripts/verify.sh                               # the default target, alpoge-rh
RH_TARGET=grh-compact scripts/verify.sh         # another profile, for one command
```

`RH_TARGET` can also be set in `config.env`. A value in the environment wins over `config.env`. A target's name is the name of its directory here: lower-case letters, digits and `-`, not starting with `-`.

A profile is the file `targets/<name>/target.env`. For any target but the default one it is sourced as shell code by `scripts/lib.sh` and may only assign the variables listed below. A profile for such a target inherits nothing from the default one: it must set every variable marked *required*, or the scripts stop and name the one that is missing, and the others are then empty or as the last column says.

The default target's profile, `alpoge-rh/target.env`, is **not read**. Its values are built into `scripts/lib.sh`, so that the scripts work as they did before profiles existed; the file repeats them for reference, and a test checks that the two agree. To change one of them, change both, or set the variable in `config.env` or in the environment, where it wins over the built-in value: `RH_PART_URL_PREFIX=<a mirror> scripts/01_fetch.sh`, for example.

## One working directory per target

A working directory holds one extracted archive, one build and its logs, and nothing in it used to say whose they were. Three rules now keep targets apart.

- **The directory.** For the default target the working directory is `RH_WORKDIR`, as before. For any other target it is `RH_WORKDIR` with `-<target name>` added (`work` becomes `work-grh-compact`), unless `RH_WORKDIR` was given in the environment for that command, in which case it is used as given.
- **The marker.** The first script that creates anything in a working directory writes the target's name to the file `.rh-target` there. Every script stops if that file names another target. A directory with files in it and no marker is taken to belong to the default target, and any other target refuses to use it.
- **The extracted tree.** For any target but the default one, `02_inspect_and_extract.sh` writes a line naming the source it extracted to `extract.from` in the working directory: the archive's SHA-256 and, for a `git` source, the address, commit, directory and prefix. It writes the line before it moves the tree into place. It uses an extracted tree again only if that line is the one that the archive there now and the profile give, and steps 03, 04, 05, 08 and 09, and `reproduce_findings.sh`, stop if it is not the one the profile gives now. The whole line is compared, pinned or not, so a change to any part of it means extracting again, even one that leaves the archive the same byte for byte (the address of a mirror, or a commit that changes nothing in the directory). Moving the extracted tree aside moves its build with it.

### After a change of commit

1. Empty `TGT_TARBALL_SHA256` in the profile: the value pinned for the old commit is refused for the new one.
2. Move aside, rather than delete if you want to keep the old commit's results, the extracted tree (`extract` in the working directory) and the target's records (`targets/<name>/records`). `--write-expected` writes nothing while a run differs from an existing record, so the old records must be out of the way.
3. Run `scripts/01_fetch.sh`, with `--redownload` if the clone was made before the new commit was published. A change of address also needs `--redownload`: a clone made from another address is not used.
4. Do steps 3 to 6 of [Adding a target](#adding-a-target) again, pinning the SHA-256 that `01_fetch.sh` prints.

## Settings

| Variable | Default target | In another profile | Meaning |
|---|---|---|---|
| `TGT_SOURCE_KIND` | `tarball-parts` | required | How the source is published. `tarball-parts`: one gzipped tarball in numbered parts that are joined. `git`: one commit of a git repository |
| `TGT_PART_URL_PREFIX` | `https://alpo.ge/lean.tar.gz.part` | required for `tarball-parts` | The address of a part is this followed by a two-digit number, `01` for the first. A tarball published as one file at an address that does not end that way is not supported yet. The older name `RH_PART_URL_PREFIX` still works for the default target and wins |
| `TGT_PART_COUNT` | `14` | required for `tarball-parts` | How many parts. `RH_PART_COUNT` still works for the default target and wins |
| `TGT_TARBALL_SHA256` | `9631b4f0…49c7fc` | required for `tarball-parts`; may be empty for `git` | SHA-256 of the archive file that the scripts inspect and extract. `RH_TARBALL_SHA256` still works for the default target and wins. For a `git` source it may be left empty on a first run: `01_fetch.sh` prints the value to put here, and until it is here the scripts say that the archive is identified by its commit only |
| `TGT_GIT_URL` | empty | required for `git` | The repository's address |
| `TGT_GIT_COMMIT` | empty | required for `git` | The commit, as all 40 hexadecimal characters, in lower case. A branch or tag name is refused |
| `TGT_GIT_SUBDIR` | empty | optional, empty | The directory of the repository that holds the Lake project, if it is not the top |
| `TGT_TARBALL_NAME` | `lean.tar.gz` | optional: `source.tar` for `git`, `source.tar.gz` otherwise | Name of the archive file in `download/`. For a `git` source the scripts write an uncompressed tar |
| `TGT_ARCHIVE_PREFIX` | `lean/` | required | The directory every entry of the archive is under, with its closing slash. The Lake project is that directory after extraction |
| `TGT_SRC_DIR` | `src` | required | Where the project's Lean sources are, relative to the project. `.` is the project directory itself, Lake's default when the lakefile names no `srcDir`; Lake's own directory `.lake` is then left out of every count and scan |
| `TGT_ARCHIVE_ALLOW_EXEC` | `0` | optional, `0` | `1` to accept archive entries with an executable bit. Nothing else on the list below can be allowed |
| `TGT_RECORDS_DIR` | `records/source` | required | Directory, relative to the repository, of the recorded facts about this source (`expected.json` and the files beside it). For a new target: `targets/<name>/records` |
| `TGT_ROOT_MODULE` | `Main` | required | The module that states the theorems to check |
| `TGT_THEOREMS` | the five names in `Main.lean` | required | The theorems whose axioms are checked, separated by spaces |
| `TGT_PRIMARY_THEOREM` | `riemannHypothesis` | required | The theorem whose statement is compared with `TGT_STATEMENT_CONST` |
| `TGT_STATEMENT_CONST` | `RiemannHypothesis` | required | The constant the primary theorem's statement must be, exactly |
| `TGT_STATEMENT_CONST_MODULE` | `Mathlib.NumberTheory.LSeries.RiemannZeta` | required | The module that constant must be defined in |
| `TGT_REPORT_CONSTS` | `RiemannHypothesis riemannZeta DirichletCharacter.LFunction` | optional, the statement constant | Constants whose defining module is reported |
| `TGT_PROTECTED_NAMES` | `RiemannHypothesis riemannZeta LFunction` | optional, the last component of the statement constant | Names the source should not declare for itself; the audit lists any declaration of them. The audit matches the last component of a declared name (as the default target lists `LFunction`, not `DirichletCharacter.LFunction`), so give last components |
| `TGT_SMOKE_TARGETS` | `Statements Formalism.GammaFactorNonvanishing.RhOfRight` | required | One or two modules that import little beyond Mathlib, built first to show that Mathlib's cache is accepted |
| `TGT_PROBE_MODULE`, `TGT_PROBE_THEOREM` | `Formalism.GammaFactorNonvanishing.RhOfRight`, `Formalism.VW.rh_of_right` | optional, empty | An early lemma whose conclusion is the statement constant, for `08_check_axioms.sh --probe`. If empty, `--probe` says so and stops |
| `TGT_MATHLIB_TAG` | `v4.33.1` | optional, empty | The official Mathlib tag the pinned revision should be. If empty, that check is reported as not applicable |
| `TGT_S10_PATTERN`, `TGT_S10_COUNT` | six tactic names, `77` | optional, empty | A pattern and the number of source files expected to match it; a check particular to the default target. If either is empty, `reproduce_findings.sh` reports S10 as not applicable |

### What the archive checks refuse

Whatever the profile says, `02_inspect_and_extract.sh` refuses an archive with any of these before it extracts anything:

- an entry that is not a regular file: a directory entry, a symbolic or hard link, a device, a fifo;
- an executable bit (unless `TGT_ARCHIVE_ALLOW_EXEC=1`), or a setuid, setgid or sticky bit;
- an absolute name, an empty, `.` or `..` component, a backslash or a control character in a name, a name outside the prefix;
- a name longer than 1024 bytes, or with a component longer than 255 bytes (macOS's limits);
- two entries with one name, or a file where another entry needs a directory;
- a `.git` or `.lake` component, also when spelled in the other ways git refuses for `.git`: in another case, with characters HFS+ ignores, with dots or spaces at the end, followed by an NTFS stream name, or as `git~1` (`lake~1`);
- two names that are one on a file system that ignores case and Unicode normalisation, as macOS's does by default, or a character the Unicode tables of the Python in use do not know (its folding is then unknown);
- anything but zero bytes after the end of the archive, or an archive that cannot be read to its end (a damaged header, a wrong gzip checksum, bytes after the last gzip member, compression other than gzip). The tar that extracts an archive may carry on past such a place and find entries there that the listing never saw.

For any target but the default one, what `tar` wrote is then compared with the listing before the tree is put in place. Everything in it, `.lake` included, must be an entry the listing checked, or a directory on the way to one, with no links and no other files; otherwise the tree is left in `extract.partial` and nothing in it is used. (The default target's archive is pinned and its listing recorded, so this is not done for it.)

A tarball made with `tar czf x.tar.gz lean` has directory entries in it and is refused. One made from a list of plain files, from a clean copy of the sources, is not: `find lean \( -name .git -o -name .lake \) -prune -o -type f -print | LC_ALL=C sort | COPYFILE_DISABLE=1 tar czf x.tar.gz -T -`. The `-prune` leaves out git's and Lake's directories, which are refused; `COPYFILE_DISABLE=1` stops macOS's tar from adding `._` files. The files must be plain copies, since tar stores a second name of a hard-linked file as a link, and they must have no executable bits unless `TGT_ARCHIVE_ALLOW_EXEC=1`.

## Adding a target

1. Make `targets/<name>/target.env`; `<name>` may use lower-case letters, digits and `-`, and may not start with `-`. Start from [`grh-compact/target.env`](grh-compact/target.env) for a git repository or [`alpoge-rh/target.env`](alpoge-rh/target.env) for a tarball. Every value in the second is the default target's, so in a copy of it change the address, count, SHA-256 and name of the parts and tarball, the prefix and source directory, `TGT_RECORDS_DIR` (to `targets/<name>/records`: kept as it is, the new target would be compared with the default target's records) and the module, theorem and statement names; and empty `TGT_PROBE_MODULE`, `TGT_PROBE_THEOREM`, `TGT_MATHLIB_TAG`, `TGT_S10_PATTERN` and `TGT_S10_COUNT` unless they mean something for your archive. A lakefile that is a program (`lakefile.lean`) is not supported: read it yourself first.
2. Name the target for every command that follows: `export RH_TARGET=<name>` in the shell you use (or put `RH_TARGET=<name>` in `config.env`). A command run without it works on the default target.
3. Fetch the source. This differs by kind.
   - **`git`:** leave `TGT_TARBALL_SHA256` empty and run `scripts/01_fetch.sh`. It writes the tar file and prints its SHA-256 under a line in capitals that says it is NOT PINNED. Put that value into the profile as `TGT_TARBALL_SHA256`, then run `scripts/01_fetch.sh --check-only` to see it compared. Pinned or not, the scripts use the tar file only if `01_fetch.sh`'s record beside it (`download/source.tar.from`) names the address, commit, directory and prefix the profile names: the SHA-256 says which bytes the file has, and only the record says which commit they are.
   - **`tarball-parts`:** the profile must give the SHA-256 of the whole tarball before anything is fetched. Take it from where the tarball is published if it is given there. If you compute it yourself from the parts you downloaded, nothing but your own download vouches for it: say so wherever you report the result. Then run `scripts/01_fetch.sh`. It writes the SHA-256 of each part to `download/parts.sha256`. Copy that file into the records, so that later runs compare every part as well as the whole: `mkdir -p targets/<name>/records && cp "$(bash -c '. scripts/lib.sh && printf %s "$RH_DL"')/parts.sha256" targets/<name>/records/`.
4. `scripts/02_inspect_and_extract.sh --write-expected targets/<name>/records/expected.json`. The first run has nothing recorded to compare with and says so in capitals. Read the listing and the entry check before going on: what is recorded now is what later runs are compared with. `--write-expected` records nothing when a run differs from a record that is already there.
5. `scripts/03_audit_source.sh --write-expected targets/<name>/records/expected.json`. Read what it lists in each category: the record says only that later runs find the same.
6. `python3 analysis/import_graph.py`, then copy the summary it made into the records: `cp "$(bash -c '. scripts/lib.sh && printf %s "$RH_AN"')/import_graph_summary.json" targets/<name>/records/`. With steps 4, 5 and 6 done, `scripts/reproduce_findings.sh` compares everything it can with the records.
7. Level 2 and beyond of [`../docs/replication-guide.md`](../docs/replication-guide.md). That guide is written for the default target. For another one, skip `08_check_axioms.sh --probe` unless the profile sets `TGT_PROBE_MODULE` and `TGT_PROBE_THEOREM`; where it builds or imports the default target's modules by hand, use the modules of `TGT_SMOKE_TARGETS` and `TGT_ROOT_MODULE`; and read its sizes and timings as the default target's.

## What a `git` source becomes

`01_fetch.sh` clones the repository without checking anything out, confirms that the commit named is in it, and writes the files of that commit (or of `TGT_GIT_SUBDIR` in it) to a tar file: every blob byte for byte as git stores it, names in sorted order, no times, no owners. Symbolic links, submodules, `.git` and `.lake` components and names that collide on macOS are refused, and every blob's SHA-1 is computed again from what is written. The same commit gives the same tar file on any machine, so its SHA-256 can be recorded and compared like a published tarball's. Beside it, `01_fetch.sh` writes `<tar file>.from`, a line that names the address, commit, directory and prefix it was written from; the line is removed before the file is written again and put back only once the file is complete. The clone records the address it was made from (`git config rhv.sourceurl`), and a clone made from another address than the profile's is not used. From there on a `git` source is handled exactly as a tarball is: listed and checked entry by entry before anything is extracted.

`git archive` and `git checkout` are not used for this, because both can change file contents according to attribute files inside the repository.

## What is not covered

- The cloud modes (`cloud/gcp/`) and the cost models in `analysis/`.
- A project whose sources are not under one directory, or that is configured by `lakefile.lean`.
- A project that does not depend on Mathlib: `04_setup_toolchain.sh` fetches Mathlib's prebuilt cache and fails if any Mathlib module had to be compiled locally.
- A project whose own files use Lean's module system (a file that starts with `module`). `09_kernel_replay.sh` reports the extra compiled parts such files have (`.olean.server`, `.olean.private`) and never says the replay is complete.
- A statement check other than "the primary theorem's type is exactly this constant". The stronger form is a challenge file and Comparator ([`../docs/related-work.md`](../docs/related-work.md)).
