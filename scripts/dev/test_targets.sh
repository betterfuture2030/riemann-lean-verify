#!/bin/bash
# test_targets.sh - an offline test of the target profiles (targets/README.md): scripts/lib.sh, the scripts and the
#   tool that read a profile, and the default target's behaviour compared with the last commit before profiles.
#
# What it does: works in a scratch copy of the repository's scripts, analysis, records/source and targets (the files
#   git tracks there, and targets/ whether git tracks it or not; never a config.env or .private-patterns file), so
#   that it can add made-up profiles and a config.env of its own. The base commit (TARGETS_TEST_BASE; by default
#   5c2cc89, the last commit before profiles, which was main when this was written) is read with git archive. Cases,
#   numbered as in the output:
#    1  targets/alpoge-rh/target.env and the values built into scripts/lib.sh agree for every TGT_ name in the table
#       of targets/README.md; the profile assigns nothing else; read as a profile, it gives the same settings.
#    2  With no target named, lib.sh and common.sh set every variable the base commit's set, to the same value: with
#       no config.env; config.env setting RH_WORKDIR, RH_PART_COUNT and GCP_ values; RH_WORKDIR and
#       RH_TARBALL_SHA256 in the environment over config.env; empty values in the environment; config.example.env.
#    3  Sourcing lib.sh (alone and with common.sh) prints nothing on standard output: the default target, with a
#       config.env, and a made-up target.
#    4  A made-up git source: a repository made here (a Lake project in proj/ with two sources, a name that is not
#       ASCII, an empty file and a name longer than 100 bytes, and a file outside proj/) and a profile for it.
#       01_fetch.sh writes the tar file and says NOT PINNED with the line that pins it; a second run and --redownload
#       give the same SHA-256; the tar holds the commit's files of proj/, sorted, with no times or owners; pinned, it
#       is verified; pinned wrong, status 1. 02 --write-expected (with TAR_READER_OPTIONS and TAR_OPTIONS set to
#       ones bsdtar and GNU tar fail with: 02 unsets them) extracts work-<name>/extract/proj byte for byte as
#       the commit has it and records what it saw; a second run compares with the record; --verify-tree passes and
#       notices a changed file.
#    5  Refusals, each with a non-zero status and a message that names the problem: RH_TARGET with an upper-case
#       letter, a leading '-' or '../x'; a target with no profile; a profile missing a required variable;
#       TGT_GIT_COMMIT a branch name, 39 characters or upper case; TGT_ARCHIVE_PREFIX without its closing slash, with
#       '..', or absolute; an unknown TGT_SOURCE_KIND; a commit with a symbolic link; a commit with a submodule; an
#       executable file (02 refuses it unless TGT_ARCHIVE_ALLOW_EXEC=1); 04 refuses a lakefile.lean before it runs
#       anything.
#    6  The working directory and its marker .rh-target: the first script that writes names the target in it (the
#       default target's too); a default-target command stops in a directory marked for another target; another
#       target refuses a directory that has files and no marker, or another target's marker; RH_WORKDIR given in the
#       environment is used as given; otherwise another target's directory is RH_WORKDIR with -<name> added; the
#       paths derived from it; analysis/rhpaths.py says the same and stops the same way.
#    7  The axiom check file: rhv_tools.py axioms-body with the default names prints the body file byte for byte, and
#       with others differs from it in the four lines that name constants and nowhere else. With a stand-in lean
#       (which only answers --version) and a fake compiled module, 08_check_axioms.sh writes the same .lean file as
#       the base commit's 08 (full, --deep, --probe); for a made-up target, the file is that target's, the log names
#       the target and the summary its commit; --probe with no probe lemma in the profile stops.
#    8  rhv_tools.py tar-inspect with none of its new arguments, against the base commit's, on made-up gzipped
#       tarballs under lean/: the same output and status (a clean one, and one with every kind of entry refused);
#       the same --write-expected JSON; the same --verify-tree report. The one line that says nothing was recorded is
#       in capitals now, on purpose (the interface says so); that line is compared apart. audit-literals is unchanged.
#    9  reproduce_findings.sh for made-up targets: with empty TGT_MATHLIB_TAG and TGT_S10_PATTERN and nothing
#       recorded, S5, S9, S10 (and S2-S4, S6-S8) are n/a, and the run does not fail; with a record,
#       S2-S4 pass; S10 with a pattern and no count is n/a, with the right count passes.
#   10  Values in the environment win over config.env and over the profile (RH_TARGET, RH_WORKDIR, a TGT_ variable);
#       a TGT_ value in config.env does not reach another target's settings.
#   11  The default target's 01 (with the tarball present, and --check-only), 02 (extracting, again, --verify-tree)
#       and 03 on a made-up tarball, against the base commit's: the same output apart from times and paths, the
#       same status, the same extracted files.
#   12  A profile whose sources are the project directory itself (TGT_SRC_DIR=.), which lib.sh accepts and 03 has
#       code for: 01, 02 and 03 work on it, and 03 leaves out .lake.
#   13  No stand-in for the network or the toolchain was called.
#   14  rhv_tools.py git-export on commits made here with git mktree. Each of these is refused with status 1, a
#       message that names it and no file written: a '.git' component (proj/.git/config, one further down, .GIT,
#       '.g<U+200C>it' with a character macOS leaves out of names, git~1, '.git.', '.git '), a '.lake' component
#       (proj/.lake/build/x.olean), and names that are one name on macOS (Foo.lean and foo.lean; e-acute in NFC
#       and in NFD; directories A/ and a/ with different files). Near misses (.gitignore, .github/, git~2,
#       .lakefile, ...) are written. 01_fetch.sh stops on a commit with proj/.git/config and writes no tar file.
#   15  rhv_tools.py tar-inspect on gzipped tarballs under lean/ made here with Python's tarfile: the same
#       refusals (status 1, the reason, nothing recorded). With the arguments 02 now gives it for the default
#       target (--prefix lean/ --src-dir src), the base commit's output, byte for byte, on the clean tarball and on
#       one of near misses. --src-dir . counts the Lean files under the prefix.
#   16  TGT_SRC_DIR=. end to end, with the .lake directory case 12 made after extraction: 01 again; count_sources; 02
#       --write-expected (which creates the records directory) and 02 again; 03 --write-expected, then 03 with rg
#       and with grep against that record; 02 --verify-tree; import_graph.py and closure_stats.py with no
#       arguments; reproduce_findings.sh, whose S10 counts a hidden file and an ignored one and not one in .lake
#       (with rg, and with grep when rg can be left off the PATH).
#   17  lib.sh refuses TGT_SRC_DIR './src', 'src/.', 'src/', '/src', 'a//b', '..' and 'a\b' (and './src' for the
#       default target too), TGT_RECORDS_DIR '.', 'records/./x', '/x' and 'x/', TGT_ARCHIVE_PREFIX 'a/./' and
#       'a//'; it accepts TGT_SRC_DIR '.' (RH_SRC is the project) and 'src/Sub', and TGT_ARCHIVE_PREFIX 'a/b/'.
#   18  extract.from: 02 writes it for a git target. After a change of commit 01 says to use --redownload, and
#       02, with the tree moved aside, does not extract the first commit's tar file, which is still there, for the
#       second commit. After 01 --redownload 02 stops with 'not extracted from the archive' and changes nothing; with
#       the tree moved aside it extracts the new commit; a tree with no extract.from is not used. The default
#       target's 02 writes none.
#   19  cloud/gcp/pilot_local.sh with a made-up target stops before anything else ('launch pilot', 'ledger',
#       'teardown'): a stand-in gcloud first on the PATH is not called and nothing is written. With the default
#       target it gets past that line: 'ledger' shows an empty ledger.
#   20  00_check_prereqs.sh --install-elan, with stand-ins for curl and sh and no elan on the PATH: .rh-target
#       names the target (a made-up one, and the default one), and the installer is fetched into it and run.
#   21  06_progress.sh on a made-up build log with a job line marked U+2139 (information): for the default target
#       it is not counted, and the output is the base commit's; for a made-up target it is counted.
#   22  reproduce_findings.sh for the default target on a made-up tarball, the Mathlib tag answered by a repository
#       made here (url.<path>.insteadOf, so nothing leaves the machine). With records/source/import_graph_summary.json
#       removed: S9 FAIL and status 1, as with the base commit's script. With a record: every claim reproduces. With
#       TGT_S10_PATTERN empty: an S10 row that is n/a, no 'All tier-S claims reproduced.', and none failed.
#   23  TGT_PROTECTED_NAMES defaults to the last component of TGT_STATEMENT_CONST (Foo.Bar gives Bar; a profile's
#       own value is kept), and 03 then lists the 'def Bar' inside 'namespace Foo', with rg and with grep.
#   24  rhv_tools.py axioms-body refuses 'caf<e-acute>' and '<lambda>x' (status 2, nothing on standard output, the
#       name said once). 08_check_axioms.sh with such a statement constant stops before it runs lean.
#   25  analysis/rhpaths.py: with RH_PROJ, RH_AN and RH_LOGS in the environment and RH_TARGET unset,
#       import_graph.py works although RH_WORKDIR is marked for another target, without asking lib.sh (a stand-in
#       bash first on the PATH is not called), and its root module is Main; another target with TGT_SRC_DIR and
#       TGT_ROOT_MODULE in the environment too is not asked either; without RH_PROJ, the stand-in bash is called
#       (and the default layout is refused), and with the real bash lib.sh is asked and stops.
#   26  tar-inspect refuses a file where another entry needs a directory, '.git::$INDEX_ALLOCATION', 'LAKE~1' and an
#       unassigned code point, and '--src-dir src/'; it takes '--src-dir .'. rhv_tools.py import-graph does not walk
#       the .lake directory of a project directory. 01 writes source.tar.from (also when the pinned SHA-256 is wrong);
#       02 and 01 --check-only refuse an unpinned tar file without it, and 02 one whose profile names another
#       directory; extract.from then names the archive, and 09 stops once the profile pins another SHA-256.
#   27  tar-inspect refuses an archive with data after its end (a damaged header or one empty block before more
#       entries, gzipped or not; a second gzip member after the end blocks), one that cannot be read to its end
#       (bytes after the last gzip member, a truncated file), a component over 255 bytes and a name over 1024 (40,000
#       components, refused at once); it accepts zero bytes after the end, and reports directory entries once each.
#       git-export refuses a component over 255 bytes. --check-extracted passes what tar wrote and refuses a file
#       that is not an entry (also in .lake), links, an executable bit, a missing entry, an empty directory and a
#       hard link. 02 with a stand-in tar that plants a file in .lake stops and puts nothing in place. With a pin left
#       over from an earlier commit, 01 --check-only and 02 refuse the old commit's file; a clone made from another
#       address is refused until --redownload.
#   28  tar-inspect refuses headers that Python's tarfile and bsdtar are known to read differently (a pax path ending in '/', a pax
#       size '1_025', a size field '0o2000' or '0_2000', GNU.sparse keys) and a file named HEAD (also 'hEaD.'); it
#       accepts Head.lean, HEADER.md and Python's pax and GNU archives with long names. git-export refuses a file named
#       HEAD, and stops at --max-files and --max-bytes, writing nothing. 02 with a stand-in tar that changes a listed
#       file's bytes stops and puts nothing in place. A TGT_ value in the environment reaches the scripts a script
#       starts (reproduce_findings.sh S1 fails on a wrong pin given that way). lib.sh refuses TGT_GIT_SUBDIR '.',
#       '../x', '-x', 'x/', '/x', 'a//b' and 'a/./b'. An empty .rh-target stops the scripts with the command that
#       writes it; a marker that cannot be written is removed, with an error. .gitignore covers work-<name>. A pin that
#       does not match leaves no .sha256 file; 01 --check-only names a clone that records no address, and refuses a
#       SHA-256 repository, as 01 does. 08 does not expand a file pattern in TGT_THEOREMS; axioms-summary fails a
#       record whose primary theorem is not checked. project-info --show-urls prints the toolchain's origin (marking
#       one that is not leanprover/lean4) and each package's address, escaped, and 02 prints them for fix-git.
#   29  tar-inspect refuses a header checksum that only Python's tarfile reads ('0o', '_', a tab, base 256; each hides
#       an entry from it), bytes where a POSIX header has its name prefix in a GNU one (a v7 one is refused for its format, case
#       30), a global pax header that sets a path (said once), a GNU long name that runs past its size, a mode
#       '0_644', an ACL pax key and an AppleDouble '._' file; it also refuses pax data that is not whole records or
#       has bytes in the rest of its block, two extended headers of one kind before one entry (it accepts a long name
#       with a pax header), and shows an ACL key or a name with an escape character escaped. It stops within 30 s,
#       with status 1, on sizes far beyond the archive (base 256 and pax), on sparse entries (old GNU and pax) and on
#       an 8 MiB pax header, and accepts a signed checksum, Python's ustar long names and a global header with a
#       comment only. --verify-tree says NOT FINISHED for an archive cut short or an entry it refused, 'cannot be read
#       on disk' for a file or directory it cannot read, and names a directory that is a symbolic link on disk; never
#       byte-for-byte. On macOS, an archive macOS's tar makes of a file with an extended attribute is refused, and one
#       made with COPYFILE_DISABLE=1 passes both post-extraction checks. git-export refuses 2^41 directories made of
#       42 objects within 30 s, a directory larger than the entries still allowed or a commit over 1 MiB before
#       reading it, and names a 305-byte name. lib.sh refuses a space in TGT_GIT_SUBDIR or TGT_ARCHIVE_PREFIX, a new
#       line in TGT_GIT_URL and a .rh-target that is a symbolic link (writing nothing through it). A working directory
#       holding only another script's .rh-target.<number> is claimed; 12 scripts claiming one new directory at once,
#       40 times over, all go on and leave no file behind (default target and fix-git); the command printed for an
#       empty marker writes it in a directory whose name has a space and a quote. 01's message for a pin that does not
#       match says the file is kept; project-info escapes control characters in the project files and fails, counting
#       each value once (an address too, with or without --show-urls), shows a path package's directory with a space
#       quoted and refuses the package, and refuses a package name with a space. 02 refuses to extract another target's archive as root, and stops
#       before placing a tree whose project files do not match the records, leaving it in extract.partial.
#   30  tar-inspect refuses an archive in the v7 format (a header in neither POSIX ustar nor GNU tar's format), a
#       number field that tars read differently (a user id with a tab, a time with a new line, a device number with an
#       underscore), a text field with a control character or bytes after its NUL (name, link name, user name), a
#       first header that begins as a bzip2 stream does, more than 8 extended headers in a row (it accepts 8 global
#       comments), 250 long names in a row, sparse files in pax form (a version 1.0 map that claims a billion pieces,
#       a map that is not numbers, SCHILY.realsize), Solaris's SUN.holesdata and a name that is not UTF-8, each within
#       30 s with status 1 and no traceback; it reads 20 pax headers of about 500 KB each within 30 s, shows a size in
#       base 256 in hexadecimal, and --check-extracted shows a name with an escape character escaped. --verify-tree
#       says 'cannot be read on disk' for the files of a directory it can list and not search. project-info refuses a
#       package name that looks blank (U+2800) and a host with a Cyrillic letter in it (with or without --show-urls),
#       a git package with no address (with --show-urls) and a manifest of another shape (status 1, no traceback),
#       20,000 names with a tab within 30 s, and reads the form Lake wrote before manifest version 7. lib.sh refuses a
#       .rh-target that is a directory; for one that is a link it prints a command that puts a plain file in its place
#       and leaves the file the link pointed to as it was; it refuses a TGT_GIT_URL with a C1 control character, a
#       Cyrillic letter or a tab, in the C locale and in a UTF-8 one. 00, in a UTF-8 locale, shows the toolchain line
#       with '?' for each byte that is not printable ASCII, and one that ends with CRLF as the line alone. git-export
#       refuses 2^41 directories made of 42 objects at its default limits within 60 s, and its message for a name
#       over 255 bytes shows the start of the name.
#   31  tar-inspect, under this Python and the system's where that is another version, refuses bytes 345 to 499 of
#       a GNU header (atime, old sparse map, isextended, realsize) and a time in base 256 below -2^63, and accepts
#       times before 1970 as Python's GNU and pax formats write them, an empty archive and an archive in two gzip
#       members or with zero bytes after the last; it refuses zero bytes between gzip members, the reserved gzip
#       flags (in the first member or a later one), other bytes after a member, and a first header (here a pax
#       header) that begins as an xz stream does. An archive bsdtar made in its pax format of two files from 1960
#       passes, both its entries having times before 1970 (on macOS; bsdtar's ustar format leaves such files out
#       and its gnutar format writes the time 0). A name in NFC extracted by the system's tar passes both checks of
#       the tree, whatever form the file system stores; a second file with the name in the other form is refused
#       where the file system can hold both. project-info accepts project files in the forms of the default
#       target's, the default target's manifest in the form of version 6 ({"git": {...}} entries, with inputRev?
#       and subDir?), a manifest of schemaVersion 7, a package name in guillemets (and a requirement of that name),
#       every Lean option the check allows (with 'weak.' or not, in leanOptions, in a library's and with -D), a
#       toolchain that is a release candidate, names no origin or has no 'v' (leanprover/lean4:4.33.1, 4.33.1), an
#       address with a port, roots and globs with '!' and '?', srcDir './src/' and a lean-toolchain with CRLF;
#       with --src-dir . (the sources in the project's own directory), the lakefile.toml 'lake new proj math' and
#       'lake new 2proj math' write (Mathlib pinned by a tag, which the manifest has as the entry's inputRev, or
#       inputRev? in the form of version 6, and
#       shown so, with no Reservoir line), one whose library is named Proj! and srcDir './'; and refuses, with status 1
#       and no traceback: names with guillemets around nothing, around a character that is not ASCII, unbalanced, or
#       around an identifier ('\u00abmathlib\u00bb', beside mathlib or alone), a name Lake cannot read ('doc-gen4'
#       bare), a name with '/' or '.' between guillemets ('../x', '../build', '/x', '.x', 'b/c' after 'a.'), two packages of one name, a manifest with no package named mathlib or no packages at all; a
#       configFile, subDir, subDir?, packagesDir or manifestFile other than Lake writes, any subDir but '.' (one of
#       '.' is accepted), a file or a dangling link named https: in the project; a path package; a git
#       package with no revision, with no address (also without --show-urls) or with no type, whose revision is not
#       a full commit hash (a branch, a short hash or a hash in capitals, Mathlib's or another package's), or whose
#       address is not https://<host>/<path> (none: also listed as refused without --show-urls; file://, ssh://,
#       user@host:path, a user name before the host, a leading '-', http://, '..' and '.' parts, '%2e%2e', '?',
#       '#', an empty part); a lean-toolchain that names a nightly (after an origin or alone) or stable, an origin
#       with no '/', or whose first part is a file of the project (a lean at the line's path, with an origin or not,
#       or a dangling link): these refusals of toolchains, revisions, types and addresses (a requirement's too), of
#       a subDir, of a file named https: and of such names, also without --show-urls, with the same first REFUSED
#       line;
#       a manifest with no version Lake reads ('1.0.0-' among them) or with packages in the other version's form; a lakefile.toml with an executable, the name of a package it depends on (in any case), a
#       library outside TGT_SRC_DIR (accepted with --src-dir .; under srcDir './', one in './other/', and under
#       srcDir 'src', one in '../other', each shown as other), a library srcDir with a part that starts with a dot
#       or an absolute one, a backslash, an unknown key, an argument to lean that loads code, a key given twice, two
#       requirements of one name, a requirement the manifest has no entry for, a requirement's address with no
#       scheme, http:// or '..' parts, or with a letter that is not ASCII, a root with '-' in a part (the message
#       naming guillemets), the Lean options sat.solver, weak.trace.profiler.output (with -D) and
#       debug.skipKernelTC (for a library) or a multi-line string; a lakefile naming another Mathlib tag than
#       the manifest's entry was made from (a WARNING naming both); files that are not UTF-8, a lean-toolchain with
#       U+3000 before its line end, a manifest that is not JSON, has a 40-digit number (whole or not) or NaN, or
#       nests 40 or 100,000 deep. With --lib-outside-src (TGT_LIBS_OUTSIDE_SRC) naming it, project-info accepts a
#       library whose srcDir '..' is the project's own directory, beside src, and which defaultTargets does not
#       name, and prints it under 'libraries outside src' (two such libraries too); with none named it accepts a
#       library srcDir '../src/Sub', which comes back under src; and it refuses, with status 1 and no traceback: that
#       library when it is not named, when defaultTargets names it or a module of it (with guillemets too), when
#       the lakefile gives no defaultTargets or an empty list, when it has globs or a root that is not of plain
#       parts or is not its own name or a name under it, or when src has a file or a directory that reads as one of
#       its roots (Challenge.Evil.lean and CHALLENGE.lean too); a library named, or under the name of, a package the
#       project depends on or a library of the toolchain (Mathlib, Mathlib.Tactic, Init, Lean.Elab), or whose own name
#       puts its files at or under src (src, src.Evil); a library named Chal'; the second of two such libraries when
#       only the first is named; a library in '../srcx', a directory that only starts as src does; a lakefile with two
#       libraries of one name. It accepts, with the library named: sources and a default target whose names only start
#       as its name does (ChallengeX.lean, Sub/Challenge.lean, Challenger), a library MathlibExtras, roots under its
#       own name, and roots = []; and with --src-dir Sources it accepts the library whatever a directory called src
#       holds, says 'libraries outside Sources', and refuses it when Sources has a module of its root; a library srcDir '../..', which leaves the
#       project, named or not; a name that is no library of the lakefile, or whose sources are under src (with
#       --src-dir ., the library itself). A value that is not a library's name ('a/b') is an error of usage (status
#       2, nothing on standard output), and the project files are not read. lib.sh refuses a TGT_LIBS_OUTSIDE_SRC
#       with ';', '*', '?', '[', '/', guillemets or a tab in it, with '-' at its start, or with a part that is empty
#       or starts with a digit (';' for the default target too), and accepts 'A B.C'; for the default target the
#       setting is set to nothing.
#       lib.sh sets LAKE_NO_CACHE=1 over 0 in the environment or config.env (for the
#       default target and another), gives it to the programs it runs when config.env makes it an array, and stops
#       when config.env makes it read-only (also with the environment's value, a 1 with a line end after it); it
#       unsets GIT_DIR, the other variables that point git at another repository and LAKE_PKG_URL_MAP, and stops when
#       config.env makes GIT_DIR read-only. 04 refuses a lakefile.toml changed since 02, and a package name that is not
#       one directory name, before it runs lake or clones anything; stops
#       before it runs lean or lake, or clones anything, when elan (a stand-in) would run a lean other than the
#       release's own (also where elan's directory has no such release) or chooses none (its log and the terminal
#       show what elan said, with '?' for an escape), or when ELAN_HOME is relative or empty (saying why on the
#       terminal); takes the release's own lean for the lines leanprover/lean4:4.33.1, v4.33.1
#       and 4.33.1; and with files it accepts clones each package (from a made-up repository, through git's
#       url.<base>.insteadOf) and checks it out at the commit the manifest names before it runs 'lake exe
#       mathlib/cache get', with LAKE_NO_CACHE=1. With a stand-in lake, 04 goes on to the smoke build when each
#       package is at its commit (with a manifest of version 6 too, and when a package's repository has a default
#       branch named as the commit and pointing at another, which 'git checkout --detach <hash>' takes, as checked
#       first, from a checkout at the commit, with status 0 and a detached HEAD), and with GIT_DIR and GIT_WORK_TREE
#       naming another clone, which it leaves as it was; removes a clone an earlier run left half made under the
#       name it gives one, and, when a checkout fails, leaves the clone under that name and not as the package's
#       directory (the next run removes it and goes on); stops before lake at a package directory there already at
#       another commit (saying how to clone it again), that is a link, that is a clone with no files checked out or
#       with a file changed, or at a .lake/package-overrides.json (a file or a dangling link); stops before the
#       smoke build at a package Lake left at another commit (also with version 6) or with a file changed, at a
#       package-overrides.json Lake wrote, or at a release build's trace or archive or a barrel in a package's .lake
#       (in its config directory too) or the project's (deep in it, hidden or not), but not at the traces Lake keeps
#       in build and config, at lakefile.olean.trace at the top of a .lake or at a package's source file named so;
#       after a stand-in smoke build that writes the compiled files of the modules named, reaches 'setup complete',
#       and stops at a release build's trace, a package at another commit or a package-overrides.json that the smoke
#       build left. 09, with no elan and no lean on PATH, says so before it runs anything. git clone, run in a
#       directory with a git bundle at https:/example.invalid/plausible, clones it for https://example.invalid/
#       plausible (the premise of the refusal of a file named https:). A made-up git target whose lakefile has two
#       libraries outside its sources (one a challenge file beside src with a 'sorry' in it): with
#       TGT_LIBS_OUTSIDE_SRC empty, 02 refuses both and puts no tree in place, and 04 stops at its own check before
#       it clones anything; with the two named, 02 extracts the project and shows them (again on the tree in place),
#       03 says that it does not read them and counts nothing in their files, and 04's log lists them and 04 goes on
#       to 'lake exe mathlib/cache get'; with a smoke module that has no source under src, 04 stops before it clones
#       anything or runs lake (and so does 04 for the default target). replay-summary, on made-up compiled files and
#       results for it, says complete
#       with its two sources compiled, and with the module Challenge compiled too 'compiled modules with no source
#       file: 1' and not complete (status 3); a source Challenge.Evil.lean is not taken for the source of a compiled
#       Challenge/Evil.olean; and two files of one module name (Lib/X.Y and Lib/X/Y, sources and compiled alike) are
#       counted as files with an ambiguous name, and the summary does not say complete. 00, with a stand-in df that gives 100 GB free: for the default target it
#       prints that target's sizes and its WARNING, and from its Machine section on what the base commit's prints,
#       byte for byte; for a made-up target it says that it does not know the sizes, prints none of the default
#       target's and no WARNING, and on macOS (a stand-in sysctl giving a files-in-use limit of 263168) gives the
#       rule for that limit where the default target gets its figure.
#   32  Cases 14 to 31 called no stand-in for the network or the toolchain either (nor gcloud).
# What it changes on disk: only a temporary directory of its own under TMPDIR, removed at the end (kept with
#   TARGETS_TEST_KEEP=1). The repository is only read.
# No network and no Lean: every command runs with a clean environment (env -i) whose PATH starts with stand-ins for
#   curl, wget, lean, lake, elan, leanchecker, ps and lsof, and git may use local repositories only
#   (GIT_ALLOW_PROTOCOL=file). The stand-in lean answers --version and runs nothing; the others log the call and fail.
#   From case 14 on, some commands get a narrower PATH in which python3 and git are reached through small wrappers
#   and their own directories are left out, so that an elan, gcloud or rg installed beside them is not found; cases
#   19, 20 and 25 put further stand-ins (gcloud; curl and sh; bash) first on the PATH, and cases 27 and 28 a tar that
#   runs the real one and then changes what it wrote. Case 29 runs macOS's own tar and xattr, on macOS only. Case 31
#   has stand-ins of its own for elan and lake, and for df and sysctl (a fixed free space and limit of files in use).
# How long it takes: about three minutes (longer while the machine is busy).
# Requires: bash 3.2 or later, git, python3, tar, gzip.
# Usage: scripts/dev/test_targets.sh        Prints ok or FAIL for each check, with its case number, then the count.
#   TARGETS_TEST_BASE=<commit>  compare the default target with this commit instead
# Exit status: 0 if every check passed, 1 otherwise.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
BASE="${TARGETS_TEST_BASE:-5c2cc8957e93cfb2f2ad2f07177ed8e570efdb04}"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/targets_test.XXXXXX") || exit 1
TMPD=$(cd "$TMPD" && pwd -P) || exit 1
if [ "${TARGETS_TEST_KEEP:-0}" = 1 ]; then trap 'echo "kept $TMPD"' EXIT; else trap 'rm -rf "${TMPD:?}"' EXIT; fi
START=$(date +%s)
N=0; FAILS=0; SKIPS=0; C=0
section() { C=$1; echo "-- $1. $2"; }
ok()   { N=$((N + 1)); printf 'ok    %-3s %s\n' "$C" "$1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); printf 'FAIL  %-3s %s\n' "$C" "$1${2:+: $2}"; }
skip() { SKIPS=$((SKIPS + 1)); printf 'SKIP  %-3s %s\n' "$C" "$1"; }
res()  { if [ "$2" = 0 ]; then ok "$1"; else fail "$1" "${3:-}"; fi; }    # res <description> <status of the test> [detail]
# (Arguments are expanded left to right, so a $(...) in the description runs before $? is read: then pass the status
# in a variable. A $(...) in the detail, after $?, is harmless.)
sha()  { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
tailof() { tail -n "${2:-3}" "$1" 2>/dev/null | tr '\n' ' ' | cut -c1-400; }     # the last lines of a file, on one line

PY3=$(command -v python3) || { echo "python3 is needed"; exit 2; }
GIT=$(command -v git) || { echo "git is needed"; exit 2; }

# ---------------------------------------------------------------- stand-ins and the clean environment
STUB="$TMPD/stub"; STUBLOG="$TMPD/stub.log"; mkdir -p "$STUB" "$TMPD/home" "$TMPD/tmp"; : > "$STUBLOG"
for t in curl wget lake elan leanchecker; do
  printf '#!/bin/sh\n# stand-in made by test_targets.sh: logs the call and fails\necho "%s $*" >> "%s"\nexit 1\n' "$t" "$STUBLOG" > "$STUB/$t"
done
printf '#!/bin/sh\n# stand-in: no processes, so that nothing running on this machine is looked at\nexit 0\n' > "$STUB/ps"
printf '#!/bin/sh\nexit 1\n' > "$STUB/lsof"
cat > "$STUB/lean" <<EOF
#!/bin/sh
# stand-in made by test_targets.sh: answers --version as the pinned lean does, and runs nothing
if [ "\${1:-}" = --version ]; then echo "Lean (version 4.33.1, test stand-in, Release)"; exit 0; fi
echo "lean \$*" >> "$STUBLOG.lean"
exit 0
EOF
chmod +x "$STUB"/*
CPATH="$STUB:$(dirname "$PY3"):$(dirname "$GIT"):/usr/bin:/bin:/usr/sbin:/sbin"
cenv() { env -i HOME="$TMPD/home" PATH="$CPATH" TMPDIR="$TMPD/tmp" GIT_ALLOW_PROTOCOL=file GIT_CONFIG_NOSYSTEM=1 \
           GIT_TERMINAL_PROMPT=0 PYTHONDONTWRITEBYTECODE=1 "$@"; }

# dump.sh <file to source>... -- <name>...: sources the files, then prints NAME=[value], or NAME unset, for each name.
DUMP="$TMPD/dump.sh"
cat > "$DUMP" <<'EOF'
while [ $# -gt 0 ] && [ "$1" != -- ]; do . "$1" || exit 99; shift; done
[ $# -gt 0 ] && shift
for _n in "$@"; do
  if eval "[ -n \"\${$_n+x}\" ]"; then eval "printf '%s=[%s]\n' \"\$_n\" \"\$$_n\""; else printf '%s unset\n' "$_n"; fi
done
EOF
# libvar <NAME> [VAR=value ...]: the value the scratch copy's lib.sh gives NAME with these variables in the environment
libvar() { local n=$1; shift; cenv "$@" /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- "$n" 2>/dev/null | sed -n "s/^$n=\[\(.*\)\]\$/\1/p"; }
# record <target> <sha256>: the line lib.sh's source_record gives for that target's profile as it is now
record() { cenv RH_TARGET="$1" /bin/bash -c '. "$1/scripts/lib.sh" && source_record "$2"' _ "$NEW" "$2" 2>&1; }
# refused <description> <text the output must contain> [VAR=value ...] <command...>: a non-zero status and that text
refused() {
  local d=$1 want=$2 rc; shift 2
  cenv "$@" > "$TMPD/refused.out" 2>&1; rc=$?
  [ "$rc" != 0 ] && grep -q -- "$want" "$TMPD/refused.out"
  res "$d" $? "status $rc: $(tailof "$TMPD/refused.out")"
}
# norm <file> <path>=<word> ...: the file without the times at the start of log lines, with each path replaced
norm() {
  local f=$1 a s=""; shift
  for a in "$@"; do s="$s -e s#${a%%=*}#${a#*=}#g"; done
  # shellcheck disable=SC2086
  sed -e 's/^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]  //' $s "$f"
}

# ---------------------------------------------------------------- the scratch copy and the base commit
NEW="$TMPD/new"; MAIN="$TMPD/base"; mkdir -p "$NEW" "$MAIN"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ( cd "$ROOT" && { git ls-files -z -- scripts analysis records/source config.example.env; [ -d targets ] && find targets -type f -print0; } )
else
  ( cd "$ROOT" && find scripts analysis records/source targets config.example.env -type f -print0 2>/dev/null )
fi | "$PY3" -I -B -c '
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
names = [n for n in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\0") if n]
for n in sorted(set(names)):
    if os.path.basename(n) in ("config.env", ".private-patterns"):
        continue
    s = os.path.join(src, n)
    if not os.path.isfile(s) or os.path.islink(s):
        continue
    d = os.path.join(dst, n)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    shutil.copy2(s, d)
' "$ROOT" "$NEW"
for f in scripts/lib.sh scripts/common.sh scripts/verify/rhv_tools.py targets/README.md targets/alpoge-rh/target.env; do
  [ -f "$NEW/$f" ] || { echo "the scratch copy has no $f; is $ROOT this repository?"; exit 2; }
done
HAVE_BASE=0
if git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 \
   && git -C "$ROOT" archive --format=tar "$BASE" -- scripts analysis records/source 2>/dev/null | tar -xf - -C "$MAIN" 2>/dev/null \
   && [ -f "$MAIN/scripts/lib.sh" ]; then
  HAVE_BASE=1
  echo "INFO  base commit for the comparisons: $(git -C "$ROOT" rev-parse --short "$BASE")"
  grep -q RH_TARGET "$MAIN/scripts/lib.sh" && echo "INFO  that commit already has target profiles: the comparisons with it do not show behaviour from before them"
else
  echo "INFO  the base commit $BASE cannot be read from $ROOT: the comparisons with it are skipped"
fi
setcfg() { printf '%s\n' "$1" > "$NEW/config.env"; }      # the scratch copy's config.env
nocfg() { rm -f "$NEW/config.env"; }

# ---------------------------------------------------------------- made-up sources
FX="$TMPD/fx"; REPO="$FX/repo"; mkdir -p "$REPO"
g() { cenv GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 git -C "$REPO" -c user.name=test -c user.email=test@example.com \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
MLREV=0123456789abcdef0123456789abcdef01234567
NONASCII=$(printf 'caf\303\251.md')
LONGNAME="src/Deep/$(printf '%070d' 0 | tr 0 d)/$(printf '%040d' 0 | tr 0 e).lean"
mkproject() { # mkproject <dir> <sources dir, or . >: a small Lake project
  local p=$1 s=$2
  mkdir -p "$p/$s/B" "$p/notes"
  printf 'name = "fixture"\ndefaultTargets = ["A"]\n\n[[require]]\nname = "mathlib"\ngit = "https://example.invalid/mathlib4"\nrev = "%s"\n\n[[lean_lib]]\nname = "A"\nsrcDir = "%s"\n' "$MLREV" "$s" > "$p/lakefile.toml"
  printf '{"version": "1.1.0",\n "packagesDir": ".lake/packages",\n "packages":\n [{"url": "https://example.invalid/mathlib4",\n   "type": "git",\n   "rev": "%s",\n   "name": "mathlib",\n   "inherited": false}],\n "name": "fixture",\n "lakeDir": ".lake"}\n' "$MLREV" > "$p/lake-manifest.json"
  echo 'leanprover/lean4:v4.33.1' > "$p/lean-toolchain"
  printf 'import B.C\n\n-- the root module of the made-up project\ntheorem a_thm : True := trivial\n' > "$p/$s/A.lean"
  printf 'def c : Nat := 1\ntheorem c_thm : c = 1 := rfl\n' > "$p/$s/B/C.lean"
  printf 'a note whose name is not ASCII\n' > "$p/notes/$NONASCII"
  : > "$p/EMPTY"
}
mkproject "$REPO/proj" src
mkdir -p "$REPO/proj/$(dirname "$LONGNAME")"; printf -- '-- a file whose name is longer than 100 bytes\n' > "$REPO/proj/$LONGNAME"
mkproject "$REPO/proj2" .
echo 'not part of the project' > "$REPO/README.md"
g init -q -b main . >/dev/null 2>&1 || { g init -q . && g symbolic-ref HEAD refs/heads/main; }
g add -A && g commit -q -m fixture || { echo "could not make the fixture repository"; exit 2; }
C_MAIN=$(g rev-parse HEAD)
# branch <name> <mode> <path> <contents or object id>: a commit on top of main with one more entry, made without a checkout
branch() {
  local obj=$2 t c
  case "$2" in 160000) obj=$4 ;; *) obj=$(printf '%s' "$4" | g hash-object -w --stdin) ;; esac
  g read-tree "$C_MAIN" && g update-index --add --cacheinfo "$2,$obj,$3" && t=$(g write-tree) \
    && c=$(g commit-tree "$t" -p "$C_MAIN" -m "$1") && g update-ref "refs/heads/$1" "$c" && g read-tree "$C_MAIN" && echo "$c"
}
C_LINK=$(branch link 120000 proj/src/Link.lean A.lean)
C_SUB=$(branch sub 160000 proj/sub 1111111111111111111111111111111111111111)
C_EXEC=$(branch exec 100755 proj/run.sh "$(printf '#!/bin/sh\necho run\n')")
[ -n "$C_LINK" ] && [ -n "$C_SUB" ] && [ -n "$C_EXEC" ] || { echo "could not make the fixture branches"; exit 2; }

fixprof() { # the made-up target's profile: a git source, the Lake project in proj/
  cat <<EOF
TGT_SOURCE_KIND=git
TGT_GIT_URL="$REPO"
TGT_GIT_COMMIT=$C_MAIN
TGT_GIT_SUBDIR=proj
TGT_TARBALL_SHA256=
TGT_ARCHIVE_PREFIX=proj/
TGT_SRC_DIR=src
TGT_RECORDS_DIR=targets/$1/records
TGT_ROOT_MODULE=A
TGT_THEOREMS="a_thm c_thm"
TGT_PRIMARY_THEOREM=a_thm
TGT_STATEMENT_CONST=Fixture.Statement
TGT_STATEMENT_CONST_MODULE=Fixture.Defs
TGT_SMOKE_TARGETS="A"
TGT_MATHLIB_TAG=
EOF
}
# prof <name> [VAR=value | VAR-] ...: write targets/<name>/target.env, the made-up profile with these lines set or removed
prof() {
  local name=$1 a f; shift
  f="$NEW/targets/$name/target.env"; mkdir -p "$NEW/targets/$name"
  fixprof "$name" > "$f.tmp"
  for a in "$@"; do
    case "$a" in
      *=*) grep -v "^${a%%=*}=" "$f.tmp" > "$f.tmp2"; printf '%s\n' "$a" >> "$f.tmp2" ;;
      *-) grep -v "^${a%-}=" "$f.tmp" > "$f.tmp2" ;;
    esac
    mv "$f.tmp2" "$f.tmp"
  done
  { echo "# made by scripts/dev/test_targets.sh"; cat "$f.tmp"; } > "$f"; rm -f "$f.tmp"
}
prof fix-git

# Made-up gzipped tarballs under lean/ (cases 6, 8, 11): a clean one (and the same uncompressed), and one with every
# kind of entry tar-inspect refuses.
TB="$FX/tarballs"; mkdir -p "$TB"
"$PY3" -I -B - "$TB" "$MLREV" <<'PY'
import gzip, io, os, sys, tarfile
out, rev = sys.argv[1], sys.argv[2]
files = [
    ("lean/lakefile.toml", 'name = "rh"\n\n[[require]]\nname = "mathlib"\ngit = "https://example.invalid/mathlib4"\nrev = "%s"\n' % rev),
    ("lean/lake-manifest.json", '{"version": "1.1.0", "packages": [{"name": "mathlib", "rev": "%s", "type": "git", "url": "https://example.invalid/mathlib4"}], "name": "rh"}\n' % rev),
    ("lean/lean-toolchain", "leanprover/lean4:v4.33.1\n"),
    ("lean/src/Main.lean", "import Statements\n-- sorry is only a word in this comment\ntheorem riemannHypothesis : True := trivial\n"),
    ("lean/src/Statements.lean", "set_option maxHeartbeats 400000\ndef S : Prop := True\n"),
    ("lean/src/B/C.lean", "def c : Nat := 1\n"),
    ("lean/README.md", "made up\n"),
    ("lean/docs/notes.txt", ""),
]
def add(tf, name, data, mode=0o644, kind=tarfile.REGTYPE, link=""):
    ti = tarfile.TarInfo(name); ti.mode = mode; ti.mtime = 1700000000; ti.type = kind; ti.linkname = link
    b = data.encode()
    ti.size = len(b) if kind == tarfile.REGTYPE else 0
    tf.addfile(ti, io.BytesIO(b) if kind == tarfile.REGTYPE else None)
def write(path, extra):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for n, d in files:
            add(tf, n, d)
        for e in extra:
            add(tf, *e)
    raw = buf.getvalue()
    if path.endswith(".gz"):
        with open(path, "wb") as fh:
            fh.write(gzip.compress(raw, mtime=0))
    else:
        with open(path, "wb") as fh:
            fh.write(raw)
write(os.path.join(out, "good.tar.gz"), [])
write(os.path.join(out, "good.tar"), [])
write(os.path.join(out, "bad.tar.gz"), [
    ("lean/src/Link.lean", "", 0o644, tarfile.SYMTYPE, "Main.lean"),
    ("lean/run.sh", "#!/bin/sh\n", 0o755),
    ("other/x.txt", "outside\n"),
    ("lean/src/../escape.txt", "dots\n"),
    ("lean/README.md", "a second entry of this name\n"),
    ("lean/dir/", "", 0o755, tarfile.DIRTYPE),
    ("lean/suid", "s\n", 0o4644),
    ("lean/a\\b.txt", "backslash\n"),
])
PY
GOODSHA=$(sha "$TB/good.tar.gz")
[ -n "$GOODSHA" ] && [ -f "$TB/bad.tar.gz" ] || { echo "could not make the fixture tarballs"; exit 2; }

# ================================================================ 1
section 1 "targets/alpoge-rh/target.env and the values built into scripts/lib.sh"
TABLE=$(awk -F'|' '/^\| *`TGT_/ { print $2 }' "$NEW/targets/README.md" | grep -o 'TGT_[A-Z0-9_]*' | LC_ALL=C sort -u | tr '\n' ' ')
ntab=$(echo $TABLE | wc -w | tr -d ' ')
[ "$ntab" -ge 20 ]; res "the table of targets/README.md names $ntab TGT_ settings" $? "$TABLE"
nocfg
# shellcheck disable=SC2086
cenv /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- $TABLE > "$TMPD/c1.lib" 2>&1
# shellcheck disable=SC2086
cenv /bin/bash "$DUMP" "$NEW/targets/alpoge-rh/target.env" -- $TABLE > "$TMPD/c1.prof" 2>&1
differ=""
for v in $TABLE; do
  a=$(grep "^$v[= ]" "$TMPD/c1.lib"); b=$(grep "^$v[= ]" "$TMPD/c1.prof")
  [ -n "$a" ] && [ "$a" = "$b" ] || differ="$differ $v (lib.sh: ${a:-nothing}; profile: ${b:-nothing});"
done
[ -z "$differ" ]; res "every one of them has the same value in lib.sh and in targets/alpoge-rh/target.env, variable by variable" $? "$differ"
assigned=$(cenv /bin/bash -c 'a=$(compgen -v | LC_ALL=C sort); . "$1" || exit 9; compgen -v | LC_ALL=C sort | LC_ALL=C comm -13 <(printf "%s\n" "$a") -' _ "$NEW/targets/alpoge-rh/target.env" \
           | grep -v -x -e a -e '_' -e 'BASH.*' -e PIPESTATUS | tr '\n' ' ')
stray=""; for v in $assigned; do case " $TABLE " in *" $v "*) ;; *) stray="$stray $v" ;; esac; done
[ -n "$assigned" ] && [ -z "$stray" ]; res "the profile assigns no variable that is not in the table" $? "not in the table:$stray"
builtin=$(cenv /bin/bash -c '. "$1" && compgen -v TGT_' _ "$NEW/scripts/lib.sh" 2>/dev/null | LC_ALL=C sort -u | tr '\n' ' ')
[ "$builtin" = "$TABLE" ]; res "lib.sh sets exactly the TGT_ variables of the table" $? "lib.sh: $builtin"
cp -R "$NEW/targets/alpoge-rh" "$NEW/targets/alpoge-copy"
C1N="$TABLE RH_PART_URL_PREFIX RH_PART_COUNT RH_TARBALL_SHA256"
# shellcheck disable=SC2086
cenv /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- $C1N > "$TMPD/c1.a" 2>&1
# shellcheck disable=SC2086
cenv RH_TARGET=alpoge-copy /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- $C1N > "$TMPD/c1.b" 2>&1
cmp -s "$TMPD/c1.a" "$TMPD/c1.b"; res "read as the profile of another target, the file gives the same settings" $? "$(diff "$TMPD/c1.a" "$TMPD/c1.b" | grep '^[<>]' | head -4 | tr '\n' ' ')"
rm -rf "${NEW:?}/targets/alpoge-copy"

# ================================================================ 2
section 2 "with no target named, lib.sh and common.sh set what the base commit's set"
C2NAMES="RH_WORKDIR RH_DL RH_PROJ RH_LOGS RH_AN RECORDS RH_TARBALL RH_PART_BASENAME RH_EXPECTED RH_PARTS_RECORD RH_TOOLS
 RH_PART_URL_PREFIX RH_PART_COUNT RH_TARBALL_SHA256 RH_JOBS GCP_PROJECT GCP_BUCKET GCP_REGION GCP_ZONES GCP_MACHINE_TYPE
 GCP_SPEND_CAP_USD GCP_RATE_USD_PER_HOUR GCP_SECOND_REPLAY GCP_KEEP_OLEANS RH_REPLAY_METHOD REPO_ROOT MARK_OK MARK_WARN MARK_FAIL"
inv() { # inv <description> [VAR=value ...]: the base commit's lib.sh and common.sh against the new ones, same inputs
  local d=$1 names; shift
  names=$(cenv "$@" /bin/bash -c '. "$1" && . "$2" && compgen -v' _ "$NEW/scripts/base_lib.sh" "$NEW/scripts/base_common.sh" 2>/dev/null | grep -E '^(RH_|GCP_)')
  # shellcheck disable=SC2086
  names=$(printf '%s\n' $C2NAMES $names | LC_ALL=C sort -u | tr '\n' ' ')
  # shellcheck disable=SC2086
  cenv "$@" /bin/bash "$DUMP" "$NEW/scripts/base_lib.sh" "$NEW/scripts/base_common.sh" -- $names > "$TMPD/c2.base" 2>&1
  # shellcheck disable=SC2086
  cenv "$@" /bin/bash "$DUMP" "$NEW/scripts/lib.sh" "$NEW/scripts/common.sh" -- $names > "$TMPD/c2.new" 2>&1
  cmp -s "$TMPD/c2.base" "$TMPD/c2.new"; rc=$?    # the status first: a $(...) in the description would reset $?
  res "$d: the same $(echo $names | wc -w | tr -d ' ') variables, the same values" "$rc" "$(diff "$TMPD/c2.base" "$TMPD/c2.new" | grep '^[<>]' | head -6 | tr '\n' ' ')"
}
if [ "$HAVE_BASE" = 1 ]; then
  # The base commit's files sit beside the new ones, so that both see the same REPO_ROOT and the same config.env.
  cp "$MAIN/scripts/lib.sh" "$NEW/scripts/base_lib.sh"; cp "$MAIN/scripts/common.sh" "$NEW/scripts/base_common.sh"
  nocfg
  inv "no config.env, nothing in the environment"
  t=$(cenv /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- RH_TARGET RH_TARGET_IS_DEFAULT 2>&1 | tr '\n' ' ')
  [ "$t" = "RH_TARGET=[alpoge-rh] RH_TARGET_IS_DEFAULT=[1] " ]; res "and the target is the default one" $? "$t"
  setcfg 'RH_WORKDIR="$REPO_ROOT/cfgwork"
RH_PART_COUNT=3
RH_JOBS=6
GCP_PROJECT=proj-x
GCP_ZONES="z-a z-b"
GCP_SPOT_MAX_ATTEMPTS=3'
  inv "config.env setting RH_WORKDIR, RH_PART_COUNT, RH_JOBS and GCP_ values"
  printf 'RH_TARBALL_SHA256=%s\nRH_PART_URL_PREFIX=https://example.invalid/cfg.part\n' "$(printf '%064d' 1)" >> "$NEW/config.env"
  inv "RH_WORKDIR and RH_TARBALL_SHA256 in the environment over config.env" RH_WORKDIR="$TMPD/envwork" RH_TARBALL_SHA256="$(printf '%064d' 2)"
  inv "empty values in the environment over config.env" RH_WORKDIR= RH_PART_COUNT= RH_TARBALL_SHA256= RH_PART_URL_PREFIX=
  cp "$NEW/config.example.env" "$NEW/config.env"
  inv "config.env copied from config.example.env"
  nocfg
  rm -f "$NEW/scripts/base_lib.sh" "$NEW/scripts/base_common.sh"
else
  skip "no base commit to compare with"
fi

# ================================================================ 3
section 3 "sourcing lib.sh prints nothing on standard output"
quiet() { # quiet <description> <files to source...> -- [VAR=value ...]
  local d=$1 files="" rc; shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do files="$files $1"; shift; done; [ $# -gt 0 ] && shift
  # shellcheck disable=SC2086
  cenv "$@" /bin/bash -c 'for f in "$@"; do . "$f" || exit 9; done' _ $files > "$TMPD/c3.out" 2> "$TMPD/c3.err"; rc=$?
  [ "$rc" = 0 ] && [ ! -s "$TMPD/c3.out" ]; res "$d" $? "status $rc; stdout: $(tailof "$TMPD/c3.out") stderr: $(tailof "$TMPD/c3.err")"
}
nocfg
quiet "the default target, no config.env" "$NEW/scripts/lib.sh" --
quiet "the default target, lib.sh and common.sh" "$NEW/scripts/lib.sh" "$NEW/scripts/common.sh" --
setcfg "RH_WORKDIR=\"$TMPD/c3work\""
quiet "the default target, with a config.env" "$NEW/scripts/lib.sh" "$NEW/scripts/common.sh" --
nocfg
quiet "a made-up target (git source)" "$NEW/scripts/lib.sh" -- RH_TARGET=fix-git
quiet "a made-up target, lib.sh and common.sh" "$NEW/scripts/lib.sh" "$NEW/scripts/common.sh" -- RH_TARGET=fix-git
quiet "the profile grh-compact of this repository" "$NEW/scripts/lib.sh" -- RH_TARGET=grh-compact

# ================================================================ 4
section 4 "a made-up git source: 01_fetch.sh and 02_inspect_and_extract.sh"
W4="$NEW/work-fix-git"; TAR4="$W4/download/source.tar"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c4.a" 2>&1; rc=$?
H1=""; [ -f "$TAR4" ] && H1=$(sha "$TAR4")
[ "$rc" = 0 ] && [ -n "$H1" ]; res "01: status 0 and the tar file is written to work-fix-git/download/source.tar" $? "status $rc: $(tailof "$TMPD/c4.a")"
grep -q 'NOT PINNED' "$TMPD/c4.a"; res "01: says in capitals that the SHA-256 is NOT PINNED" $? "$(tailof "$TMPD/c4.a" 5)"
pin=$(sed -n 's/^TGT_TARBALL_SHA256=\([0-9a-f]\{64\}\)$/\1/p' "$TMPD/c4.a")
[ -n "$H1" ] && [ "$pin" = "$H1" ]; res "01: prints the line TGT_TARBALL_SHA256=<the file's SHA-256>" $? "printed '$pin', file $H1"
nfiles=$(g ls-tree -r --name-only "$C_MAIN" -- proj/ | wc -l | tr -d ' ')
grep -q "^sha256 $H1 entries $nfiles\$" "$TMPD/c4.a"; res "01: git-export's closing line gives that SHA-256 and the $nfiles files of proj/" $? "$(grep '^sha256 ' "$TMPD/c4.a")"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c4.b" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sha "$TAR4")" = "$H1" ] && grep -q 'clone already present' "$TMPD/c4.b"; res "01 again: the clone is used as it is, and the same SHA-256" $? "status $rc: $(tailof "$TMPD/c4.b")"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" --redownload > "$TMPD/c4.c" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sha "$TAR4")" = "$H1" ] && grep -q 'cloning ' "$TMPD/c4.c"; res "01 --redownload: a new clone, and the same SHA-256" $? "status $rc: $(tailof "$TMPD/c4.c")"
cenv "$PY3" -I -B - "$TAR4" "$REPO" "$C_MAIN" <<'PY' > "$TMPD/c4.tar" 2>&1
import subprocess, sys, tarfile
tar, repo, commit = sys.argv[1:4]
want = [p for p in subprocess.run(["git", "-C", repo, "ls-tree", "-r", "-z", "--name-only", commit, "--", "proj/"],
                                  stdout=subprocess.PIPE, check=True).stdout.split(b"\0") if p]
bad = []
with tarfile.open(tar, mode="r:") as tf:
    ms = tf.getmembers()
names = [m.name.encode("utf-8", "surrogateescape") for m in ms]
if names != want:
    bad.append("names %r, want %r" % (names[:4], want[:4]))
if names != sorted(names):
    bad.append("not in sorted order")
for m in ms:
    if not m.isreg() or m.mtime != 0 or m.uid != 0 or m.gid != 0 or m.uname or m.gname or m.mode != 0o644:
        bad.append("%s: type %r mode %o time %d owner %d/%d %r/%r" % (m.name, m.type, m.mode, m.mtime, m.uid, m.gid, m.uname, m.gname))
for m in ms:
    with tarfile.open(tar, mode="r:") as tf:
        data = tf.extractfile(m.name).read()
    blob = subprocess.run(["git", "-C", repo, "cat-file", "blob", "%s:%s" % (commit, m.name)], stdout=subprocess.PIPE, check=True).stdout
    if data != blob:
        bad.append("contents of %s" % m.name)
print("\n".join(bad) or "same")
sys.exit(1 if bad else 0)
PY
res "the tar holds the files of proj/ in the commit, sorted, under proj/, with their bytes, time 0, owner 0, mode 644" $? "$(tailof "$TMPD/c4.tar")"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" --check-only > "$TMPD/c4.d" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'not pinned' "$TMPD/c4.d"; res "01 --check-only: status 0, the archive is there and not pinned" $? "status $rc: $(tailof "$TMPD/c4.d")"
prof fix-git "TGT_TARBALL_SHA256=$H1"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c4.e" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'archive verified' "$TMPD/c4.e" && ! grep -q 'NOT PINNED' "$TMPD/c4.e"; res "01 with that SHA-256 pinned in the profile: verified, status 0" $? "status $rc: $(tailof "$TMPD/c4.e")"
first=${H1%"${H1#?}"}; if [ "$first" = 0 ]; then WRONG="1${H1#?}"; else WRONG="0${H1#?}"; fi
prof fix-git "TGT_TARBALL_SHA256=$WRONG"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c4.f" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'but TGT_TARBALL_SHA256' "$TMPD/c4.f"; res "01 with another SHA-256 pinned: status 1, and the message says so" $? "status $rc: $(tailof "$TMPD/c4.f")"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" --check-only > "$TMPD/c4.g" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'MISMATCH' "$TMPD/c4.g"; res "01 --check-only with another SHA-256 pinned: status 1, MISMATCH" $? "status $rc: $(tailof "$TMPD/c4.g")"
# 02, first with nothing pinned (the first run of a new target), then pinned.
prof fix-git
REC4="$NEW/targets/fix-git/records/expected.json"
# TAR_READER_OPTIONS is bsdtar's and TAR_OPTIONS GNU tar's; with these, each fails ("iconv_open failed", an unknown
# option), so the extraction shows 02 unset them, whichever tar this system has
cenv RH_TARGET=fix-git TAR_READER_OPTIONS=hdrcharset=BINARY TAR_OPTIONS=--no-such-option /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --write-expected "$REC4" > "$TMPD/c4.h" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$W4/extract/proj/lakefile.toml" ]; res "02 --write-expected <records>/expected.json, TAR_READER_OPTIONS and TAR_OPTIONS set to ones bsdtar and GNU tar fail with: status 0, extracted under work-fix-git/extract/proj" $? "status $rc: $(tailof "$TMPD/c4.h")"
grep -q 'THE ARCHIVE IS NOT PINNED' "$TMPD/c4.h" && grep -q 'NO RECORDED VALUES TO COMPARE WITH' "$TMPD/c4.h"
res "02: says in capitals that the archive is not pinned and that nothing was recorded to compare with" $? "$(grep -i 'pinned\|recorded' "$TMPD/c4.h" | tr '\n' ' ')"
cenv "$PY3" -I -B - "$REPO" "$C_MAIN" proj "$W4/extract" <<'PY' > "$TMPD/c4.x" 2>&1
import os, subprocess, sys
repo, commit, sub, ext = sys.argv[1:5]
out = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "-z", commit, "--", sub + "/"], stdout=subprocess.PIPE, check=True).stdout
want, bad = set(), []
for rec in out.split(b"\0"):
    if not rec:
        continue
    meta, path = rec.split(b"\t", 1)
    want.add(path)
    blob = subprocess.run(["git", "-C", repo, "cat-file", "blob", meta.split()[2].decode()], stdout=subprocess.PIPE, check=True).stdout
    p = os.path.join(os.fsencode(ext), path)
    if not os.path.isfile(p):
        bad.append("missing: %r" % path)
    elif open(p, "rb").read() != blob:
        bad.append("differs: %r" % path)
have = set()
for d, dirs, files in os.walk(os.fsencode(ext)):
    for f in files:
        have.add(os.path.relpath(os.path.join(d, f), os.fsencode(ext)))
bad += ["not in the commit: %r" % p for p in sorted(have - want)]
print("%d files; " % len(want) + ("; ".join(bad[:5]) or "all the same"))
sys.exit(1 if bad else 0)
PY
res "the extracted files are the commit's files of proj/, byte for byte, and nothing else" $? "$(tailof "$TMPD/c4.x")"
[ -f "$REC4" ] && "$PY3" -I -B -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "tarball" in d and "project" in d else 1)' "$REC4"
res "02 recorded the tarball and project sections in targets/fix-git/records/expected.json" $? "$(head -c 300 "$REC4" 2>/dev/null)"
prof fix-git "TGT_TARBALL_SHA256=$H1"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c4.i" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'tarball SHA-256 ok' "$TMPD/c4.i" && grep -q 'tarball listing: matches the recorded values' "$TMPD/c4.i" \
  && grep -q 'project files: matches the recorded values' "$TMPD/c4.i" && ! grep -q 'NO RECORDED VALUES' "$TMPD/c4.i"
res "02 again, pinned: the SHA-256 checked, and the listing and the project files compared with the record" $? "status $rc: $(grep -i 'recorded\|sha-256' "$TMPD/c4.i" | tr '\n' ' ')"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --verify-tree > "$TMPD/c4.j" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'byte-for-byte' "$TMPD/c4.j"; res "02 --verify-tree: the extracted files are the archive's" $? "status $rc: $(tailof "$TMPD/c4.j")"
cp "$W4/extract/proj/src/A.lean" "$TMPD/A.lean.saved"; echo '-- changed' >> "$W4/extract/proj/src/A.lean"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --verify-tree > "$TMPD/c4.k" 2>&1; rc=$?
cp "$TMPD/A.lean.saved" "$W4/extract/proj/src/A.lean"
[ "$rc" = 1 ] && grep -q 'content differs: proj/src/A.lean' "$TMPD/c4.k"; res "02 --verify-tree notices a changed file (status 1)" $? "status $rc: $(tailof "$TMPD/c4.k")"

# ================================================================ 5
section 5 "refusals"
nocfg
refused "RH_TARGET with an upper-case letter" "RH_TARGET names a directory" RH_TARGET=Fix-git /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
refused "RH_TARGET with a leading '-'" "RH_TARGET names a directory" RH_TARGET=-fix /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
refused "RH_TARGET '../x'" "RH_TARGET names a directory" RH_TARGET=../x /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
refused "a target with no profile" "has no profile" RH_TARGET=no-such-target /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad TGT_STATEMENT_CONST-
refused "a profile without TGT_STATEMENT_CONST" "TGT_STATEMENT_CONST is required" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad TGT_GIT_COMMIT-
refused "a git profile without TGT_GIT_COMMIT" "TGT_GIT_COMMIT is required" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad TGT_ARCHIVE_PREFIX-
refused "a profile without TGT_ARCHIVE_PREFIX" "TGT_ARCHIVE_PREFIX is required" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad TGT_GIT_COMMIT=main
refused "TGT_GIT_COMMIT a branch name" "TGT_GIT_COMMIT must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad "TGT_GIT_COMMIT=${C_MAIN%?}"
refused "TGT_GIT_COMMIT of 39 characters" "TGT_GIT_COMMIT must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad "TGT_GIT_COMMIT=$(printf '%s' "$C_MAIN" | tr 'a-f' 'A-F')"
refused "TGT_GIT_COMMIT in upper case" "TGT_GIT_COMMIT must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
for p in proj ../proj/ proj/../x/ /proj/ ./proj/; do
  prof fix-bad "TGT_ARCHIVE_PREFIX=$p"
  refused "TGT_ARCHIVE_PREFIX '$p'" "TGT_ARCHIVE_PREFIX must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
done
prof fix-bad TGT_SOURCE_KIND=zip
refused "TGT_SOURCE_KIND unknown" "TGT_SOURCE_KIND must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad TGT_ARCHIVE_ALLOW_EXEC=yes
refused "TGT_ARCHIVE_ALLOW_EXEC not 0 or 1" "TGT_ARCHIVE_ALLOW_EXEC must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
[ ! -e "$NEW/work-fix-bad" ]; res "none of these refusals left a working directory behind" $? "$(ls "$NEW/work-fix-bad" 2>&1)"
prof fix-link "TGT_GIT_COMMIT=$C_LINK"
refused "01 on a commit with a symbolic link" "symbolic link" RH_TARGET=fix-link /bin/bash "$NEW/scripts/01_fetch.sh"
[ ! -e "$NEW/work-fix-link/download/source.tar" ] && [ ! -e "$NEW/work-fix-link/download/source.tar.tmp" ]; res "...and no tar file was written" $?
prof fix-sub "TGT_GIT_COMMIT=$C_SUB"
refused "01 on a commit with a submodule (a gitlink entry)" "submodule" RH_TARGET=fix-sub /bin/bash "$NEW/scripts/01_fetch.sh"
[ ! -e "$NEW/work-fix-sub/download/source.tar" ]; res "...and no tar file was written" $?
prof fix-exec "TGT_GIT_COMMIT=$C_EXEC"
cenv RH_TARGET=fix-exec /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c5.a" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '1 of the files with an executable bit' "$TMPD/c5.a"; res "01 on a commit with an executable file: written, and the bit counted" $? "status $rc: $(tailof "$TMPD/c5.a")"
refused "02 refuses the executable file" "executable bit set" RH_TARGET=fix-exec /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
[ ! -e "$NEW/work-fix-exec/extract" ]; res "...and extracts nothing" $?
cenv RH_TARGET=fix-exec TGT_ARCHIVE_ALLOW_EXEC=1 /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c5.b" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'accepted because of --allow-exec: 1' "$TMPD/c5.b" && [ -x "$NEW/work-fix-exec/extract/proj/run.sh" ]
res "02 with TGT_ARCHIVE_ALLOW_EXEC=1 accepts it, says so, and extracts it executable" $? "status $rc: $(tailof "$TMPD/c5.b")"
lakes=$(grep -c '^lake ' "$STUBLOG")
: > "$W4/extract/proj/lakefile.lean"
refused "04 refuses a project that has a lakefile.lean" "lakefile.lean exists" RH_TARGET=fix-git /bin/bash "$NEW/scripts/04_setup_toolchain.sh"
rm -f "$W4/extract/proj/lakefile.lean"
[ "$(grep -c '^lake ' "$STUBLOG")" = "$lakes" ] && [ ! -e "$W4/logs/setup-"* ] 2>/dev/null; res "...before it runs lake or writes a log" $?

# ================================================================ 6
section 6 "the working directory and its marker .rh-target"
[ "$(cat "$W4/.rh-target" 2>/dev/null)" = fix-git ]; res "01, the first script that wrote in work-fix-git, wrote .rh-target naming fix-git" $? "$(cat "$W4/.rh-target" 2>&1)"
W6="$TMPD/w6default"; mkdir -p "$W6/download"; cp "$TB/good.tar.gz" "$W6/download/lean.tar.gz"
cenv RH_WORKDIR="$W6" RH_TARBALL_SHA256="$GOODSHA" /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c6.a" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'tarball already present with the expected SHA-256' "$TMPD/c6.a" && [ "$(cat "$W6/.rh-target" 2>/dev/null)" = alpoge-rh ]
res "the default target's 01 (tarball present) writes .rh-target naming alpoge-rh in a directory that had none" $? "status $rc: $(tailof "$TMPD/c6.a") marker: $(cat "$W6/.rh-target" 2>&1)"
refused "a default-target command (01 --check-only) in work-fix-git stops" "belongs to target 'fix-git'" RH_WORKDIR="$W4" /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
refused "so does a read-only one (06_progress.sh)" "belongs to target 'fix-git'" RH_WORKDIR="$W4" /bin/bash "$NEW/scripts/06_progress.sh"
setcfg "RH_WORKDIR=\"$W4\""
refused "and with the directory named in config.env instead" "belongs to target 'fix-git'" /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
nocfg
refused "target fix-git in the default target's marked directory stops" "belongs to target 'alpoge-rh'" RH_TARGET=fix-git RH_WORKDIR="$W6" /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
mkdir -p "$TMPD/w6unmarked"; echo old > "$TMPD/w6unmarked/a-file"
refused "target fix-git refuses a directory with files and no marker" "no .rh-target file" RH_TARGET=fix-git RH_WORKDIR="$TMPD/w6unmarked" /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
mkdir -p "$TMPD/w6other"; echo fix-other > "$TMPD/w6other/.rh-target"
refused "target fix-git refuses a directory marked for another made-up target" "belongs to target 'fix-other'" RH_TARGET=fix-git RH_WORKDIR="$TMPD/w6other" /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
E6="$TMPD/w6given"
cenv RH_TARGET=fix-git RH_WORKDIR="$E6" /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c6.b" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -d "$E6/download/repo.git" ] && [ "$(cat "$E6/.rh-target" 2>/dev/null)" = fix-git ] && [ ! -e "$E6-fix-git" ] && grep -q "work directory: $E6\$" "$TMPD/c6.b"
res "RH_WORKDIR given in the environment is used as given by another target, and marked for it" $? "status $rc: $(tailof "$TMPD/c6.b")"
t=$(libvar RH_WORKDIR RH_TARGET=fix-git); [ "$t" = "$NEW/work-fix-git" ]; res "with no RH_WORKDIR anywhere, target fix-git works in <repository>/work-fix-git" $? "$t"
setcfg "RH_WORKDIR=\"$TMPD/cfgw\""
t=$(libvar RH_WORKDIR RH_TARGET=fix-git); [ "$t" = "$TMPD/cfgw-fix-git" ]; res "with RH_WORKDIR from config.env, it is that with -fix-git added" $? "$t"
t=$(libvar RH_WORKDIR); [ "$t" = "$TMPD/cfgw" ]; res "...while the default target's is RH_WORKDIR itself" $? "$t"
setcfg "RH_WORKDIR=\"$TMPD/cfgw/\""
t=$(libvar RH_WORKDIR RH_TARGET=fix-git); [ "$t" = "$TMPD/cfgw-fix-git" ]; res "...also when config.env writes it with a closing slash" $? "$t"
nocfg
cenv RH_TARGET=fix-git /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- RH_TARGET_IS_DEFAULT RH_DL RH_PROJ RH_SRC RH_TARBALL RH_GIT_DIR RH_RECORDS_SRC RH_EXPECTED RH_PARTS_RECORD > "$TMPD/c6.c" 2>&1
printf '%s\n' "RH_TARGET_IS_DEFAULT=[0]" "RH_DL=[$W4/download]" "RH_PROJ=[$W4/extract/proj]" "RH_SRC=[$W4/extract/proj/src]" \
  "RH_TARBALL=[$W4/download/source.tar]" "RH_GIT_DIR=[$W4/download/repo.git]" "RH_RECORDS_SRC=[$NEW/targets/fix-git/records]" \
  "RH_EXPECTED=[$NEW/targets/fix-git/records/expected.json]" "RH_PARTS_RECORD=[$NEW/targets/fix-git/records/parts.sha256]" > "$TMPD/c6.c.want"
cmp -s "$TMPD/c6.c" "$TMPD/c6.c.want"; res "the paths derived for target fix-git" $? "$(diff "$TMPD/c6.c.want" "$TMPD/c6.c" | grep '^[<>]' | tr '\n' ' ')"
RHP='import sys; sys.path.insert(0, sys.argv[1]); import rhpaths; print(rhpaths.src_dir()); print(rhpaths.analysis_dir()); print(rhpaths.logs_dir())'
t=$(cenv RH_TARGET=fix-git "$PY3" -I -B -c "$RHP" "$NEW/analysis" 2>&1 | tr '\n' ' ')
[ "$t" = "$W4/extract/proj/src $W4/analysis $W4/logs " ]; res "analysis/rhpaths.py gives the same directories for target fix-git" $? "$t"
t=$(cenv "$PY3" -I -B -c "$RHP" "$NEW/analysis" 2>&1 | tr '\n' ' ')
[ "$t" = "$NEW/work/extract/lean/src $NEW/work/analysis $NEW/work/logs " ]; res "...and for the default target" $? "$t"
cenv RH_WORKDIR="$W4" "$PY3" -I -B -c "$RHP" "$NEW/analysis" > "$TMPD/c6.d" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "belongs to target 'fix-git'" "$TMPD/c6.d"; res "...and stops, with lib.sh's message, for the default target in work-fix-git" $? "status $rc: $(tailof "$TMPD/c6.d")"

# ================================================================ 7
section 7 "the axiom check file (rhv_tools.py axioms-body, 08_check_axioms.sh with a stand-in lean)"
BODY="$NEW/scripts/verify/axioms_check_body.lean"; TOOLS="$NEW/scripts/verify/rhv_tools.py"
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" > "$TMPD/c7.a" 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$TMPD/c7.a" "$BODY"; res "axioms-body with the default names prints the body file byte for byte" $? "status $rc $(cmp "$TMPD/c7.a" "$BODY" 2>&1)"
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const RiemannHypothesis --report-consts "RiemannHypothesis riemannZeta DirichletCharacter.LFunction" > "$TMPD/c7.b" 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$TMPD/c7.b" "$BODY"; res "...and with the default names given explicitly" $? "status $rc"
sed -e 's/mkConst `RiemannHypothesis$/mkConst `GRH/' -e 's/statement_is_constant_RiemannHypothesis /statement_is_constant_GRH /' \
    -e 's/for c in \[`RiemannHypothesis, `riemannZeta, `DirichletCharacter.LFunction\] do/for c in [`GRH, `Foo.bar] do/' \
    -e 's/if c == `RiemannHypothesis then/if c == `GRH then/' "$BODY" > "$TMPD/c7.want"
ndiff=$(diff "$BODY" "$TMPD/c7.want" | grep -c '^>')
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const GRH --report-consts "GRH Foo.bar" > "$TMPD/c7.c" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$ndiff" = 4 ] && cmp -s "$TMPD/c7.c" "$TMPD/c7.want"; res "with another constant: the body with those four lines changed and nothing else" $? "status $rc, $ndiff lines; $(diff "$TMPD/c7.want" "$TMPD/c7.c" | head -4 | tr '\n' ' ')"
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const GRH --report-consts "Foo.bar" > "$TMPD/c7.d" 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$TMPD/c7.d" "$TMPD/c7.want"; res "...and the statement constant is put in front of a list that lacks it" $? "status $rc"
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const 'GRH x' > "$TMPD/c7.e" 2> "$TMPD/c7.e2"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$TMPD/c7.e" ]; res "a name that is not a plain Lean name: status 2, nothing printed" $? "status $rc"
lean_file() { ls "$1"/logs/axioms-"$2"-*.lean 2>/dev/null | head -n 1; }    # lean_file <workdir> <mode>
mk08() { # mk08 <workdir> <project dir under extract/> <root module> [more modules]: a made-up extracted project, compiled
  local w=$1 p="$1/extract/$2" m; shift 2
  mkdir -p "$p/src" "$p/.lake/build/lib/lean"; echo 'leanprover/lean4:v4.33.1' > "$p/lean-toolchain"
  for m in "$@"; do
    mkdir -p "$(dirname "$p/src/$(printf '%s' "$m" | tr . /).lean")" "$(dirname "$p/.lake/build/lib/lean/$(printf '%s' "$m" | tr . /)")"
    echo 'theorem t : True := trivial' > "$p/src/$(printf '%s' "$m" | tr . /).lean"
    echo 'not a compiled module' > "$p/.lake/build/lib/lean/$(printf '%s' "$m" | tr . /).olean"
  done
}
if [ "$HAVE_BASE" = 1 ]; then
  for mode in full deep probe; do
    case "$mode" in full) arg="" ;; deep) arg=--deep ;; probe) arg=--probe ;; esac
    for side in base new; do
      w="$TMPD/w7-$mode-$side"; mk08 "$w" lean Main Formalism.GammaFactorNonvanishing.RhOfRight
      if [ "$side" = base ]; then s="$MAIN/scripts"; else s="$NEW/scripts"; fi
      # shellcheck disable=SC2086
      cenv RH_WORKDIR="$w" /bin/bash "$s/08_check_axioms.sh" $arg > "$TMPD/c7.$mode.$side" 2>&1
    done
    m=full; [ "$mode" = probe ] && m=probe
    fb=$(lean_file "$TMPD/w7-$mode-base" "$m"); fn=$(lean_file "$TMPD/w7-$mode-new" "$m")
    [ -n "$fb" ] && [ -n "$fn" ] && cmp -s "$fb" "$fn"; res "08 ${arg:-(full)}: the generated .lean file is the base commit's, byte for byte" $? "base: ${fb:-none} ($(tailof "$TMPD/c7.$mode.base" 2)) new: ${fn:-none} ($(tailof "$TMPD/c7.$mode.new" 2))"
  done
  fn=$(lean_file "$TMPD/w7-full-new" full)
  { echo "import Main"; cat "$BODY"; echo; echo "-- Footer generated by scripts/08_check_axioms.sh (full mode)."
    for t in riemannHypothesis riemannZeta_eq_zero_re LFunction_ne_zero_of_half_lt_re LFunction_eq_zero_re LFunction_eq_zero_re_of_isPrimitive; do echo "#print axioms $t"; done
    echo 'run_cmd RHVerifyCheck.run "full" false `riemannHypothesis [`riemannHypothesis, `riemannZeta_eq_zero_re, `LFunction_ne_zero_of_half_lt_re, `LFunction_eq_zero_re, `LFunction_eq_zero_re_of_isPrimitive]'
  } > "$TMPD/c7.full.want"
  [ -n "$fn" ] && cmp -s "$fn" "$TMPD/c7.full.want"; res "...and it is the import, the body file as it is, and the footer for the five theorems" $? "$(diff "$TMPD/c7.full.want" "$fn" 2>&1 | head -3 | tr '\n' ' ')"
else
  skip "08 against the base commit's: no base commit"
fi
mk08 "$W4" proj A
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/08_check_axioms.sh" > "$TMPD/c7.fix" 2>&1
fn=$(lean_file "$W4" full)
{ echo "import A"; cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const Fixture.Statement --report-consts Fixture.Statement
  echo; echo "-- Footer generated by scripts/08_check_axioms.sh (full mode)."; echo "#print axioms a_thm"; echo "#print axioms c_thm"
  echo 'run_cmd RHVerifyCheck.run "full" false `a_thm [`a_thm, `c_thm]'; } > "$TMPD/c7.fix.want"
[ -n "$fn" ] && cmp -s "$fn" "$TMPD/c7.fix.want" && grep -q 'Fixture.Statement' "$fn" && ! grep -q 'RiemannHypothesis' "$fn"
res "08 for target fix-git: its root module, theorems and statement constant, and no default name" $? "$(tailof "$TMPD/c7.fix") $(diff "$TMPD/c7.fix.want" "$fn" 2>&1 | head -3 | tr '\n' ' ')"
fl="${fn%.lean}.log"; fj="${fn%.lean}.json"
grep -q '^### target=fix-git$' "$fl" 2>/dev/null; res "...its log names the target" $? "$(head -n 3 "$fl" 2>&1 | tr '\n' ' ')"
"$PY3" -I -B -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("source_id") == sys.argv[2] and d.get("target") == "fix-git" else 1)' "$fj" "$REPO commit $C_MAIN directory proj" 2>/dev/null
res "...and its summary names the target and is identified by repository, commit and directory (source_id)" $? "$(head -c 200 "$fj" 2>&1)"
refused "08 --probe for a target whose profile names no probe lemma stops" "names no probe lemma" RH_TARGET=fix-git /bin/bash "$NEW/scripts/08_check_axioms.sh" --probe
[ -s "$STUBLOG.lean" ]; res "(the stand-in lean was what ran)" $?

# ================================================================ 8
section 8 "rhv_tools.py tar-inspect with no new argument, against the base commit's"
if [ "$HAVE_BASE" = 1 ]; then
  OLDT="$MAIN/scripts/verify/rhv_tools.py"
  ti() { # ti <label> <arguments...>: tar-inspect with both tools; outputs in c8.<label>.base / .new, statuses in RB, RN
    local l=$1; shift
    cenv "$PY3" -I -B "$OLDT" tar-inspect "$@" > "$TMPD/c8.$l.base" 2>&1; RB=$?
    cenv "$PY3" -I -B "$TOOLS" tar-inspect "$@" > "$TMPD/c8.$l.new" 2>&1; RN=$?
  }
  same() { # same <description> <label>: the same output and status
    cmp -s "$TMPD/c8.$2.base" "$TMPD/c8.$2.new" && [ "$RB" = "$RN" ]
    res "$1 (status $RN)" $? "status $RB/$RN; $(diff "$TMPD/c8.$2.base" "$TMPD/c8.$2.new" | grep '^[<>]' | head -4 | tr '\n' ' ')"
  }
  ti plain "$TB/good.tar.gz"
  grep -v -i 'no recorded values' "$TMPD/c8.plain.base" > "$TMPD/c8.p.b"; grep -v -i 'no recorded values' "$TMPD/c8.plain.new" > "$TMPD/c8.p.n"
  cmp -s "$TMPD/c8.p.b" "$TMPD/c8.p.n" && [ "$RB" = "$RN" ] && [ "$(grep -c -i 'no recorded values' "$TMPD/c8.plain.base")" = 1 ] \
    && [ "$(grep -c 'NO RECORDED VALUES TO COMPARE WITH' "$TMPD/c8.plain.new")" = 1 ]
  res "a clean tarball, no record: the same output and status ($RN) but for the line that says nothing was recorded" $? "$(diff "$TMPD/c8.plain.base" "$TMPD/c8.plain.new" | grep '^[<>]' | head -4 | tr '\n' ' ')"
  echo "INFO  that line was: $(grep -i 'no recorded values' "$TMPD/c8.plain.base")"
  echo "INFO  and now is:    $(grep 'NO RECORDED VALUES' "$TMPD/c8.plain.new")"
  cenv "$PY3" -I -B "$OLDT" tar-inspect "$TB/good.tar.gz" --sha256 "$GOODSHA" --write-expected "$TMPD/c8.expected.base" > /dev/null 2>&1; RB=$?
  cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/good.tar.gz" --sha256 "$GOODSHA" --write-expected "$TMPD/c8.expected.new" > /dev/null 2>&1; RN=$?
  [ "$RB" = 0 ] && [ "$RN" = 0 ] && cmp -s "$TMPD/c8.expected.base" "$TMPD/c8.expected.new"; res "--write-expected: the same JSON" $? "status $RB/$RN; $(diff "$TMPD/c8.expected.base" "$TMPD/c8.expected.new" 2>&1 | head -4 | tr '\n' ' ')"
  ti rec "$TB/good.tar.gz" --sha256 "$GOODSHA" --expected "$TMPD/c8.expected.base"
  same "--expected (a record that matches): the same output" rec
  ti other "$TB/good.tar.gz" --sha256 "$(printf '%064d' 7)" --expected "$TMPD/c8.expected.base"
  same "--expected (a record that does not match): the same output" other
  ti bad "$TB/bad.tar.gz" --expected "$TMPD/c8.expected.base"
  same "a tarball with every kind of entry that is refused: the same output" bad
  mkdir -p "$TMPD/c8x"; tar -xzf "$TB/good.tar.gz" -C "$TMPD/c8x"
  ti tree "$TB/good.tar.gz" --expected "$TMPD/c8.expected.base" --verify-tree "$TMPD/c8x"
  same "--verify-tree on a matching extraction: the same output" tree
  echo changed >> "$TMPD/c8x/lean/src/B/C.lean"; echo extra > "$TMPD/c8x/lean/extra.txt"
  ti tree2 "$TB/good.tar.gz" --expected "$TMPD/c8.expected.base" --verify-tree "$TMPD/c8x"
  same "--verify-tree on a changed extraction: the same output" tree2
  ti quiet "$TB/good.tar.gz" --quiet --expected "$TMPD/c8.expected.base" --verify-tree "$TMPD/c8x"
  same "--quiet --verify-tree: the same output" quiet
  cenv "$PY3" -I -B "$OLDT" audit-literals > "$TMPD/c8.lit.base" 2>&1; RB=$?
  cenv "$PY3" -I -B "$TOOLS" audit-literals > "$TMPD/c8.lit.new" 2>&1; RN=$?
  same "audit-literals with no argument: the same strings" lit
else
  skip "no base commit to compare with"
fi
cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/good.tar.gz" --sha256 x > "$TMPD/c8.gz" 2>&1
cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/good.tar" --sha256 x > "$TMPD/c8.tar" 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$TMPD/c8.gz" "$TMPD/c8.tar"; res "the same tarball uncompressed gives the same listing" $? "status $rc $(diff "$TMPD/c8.gz" "$TMPD/c8.tar" | head -2 | tr '\n' ' ')"

# ================================================================ 9
section 9 "reproduce_findings.sh for made-up targets"
nocfg
row() { sed -n "s/^$2  *\([^ ]*\)  .*/\1/p" "$1" | head -n 1; }    # row <output> <claim>: that claim's result
prof fix-repro
cenv RH_TARGET=fix-repro /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c9.a" 2>&1; rc=$?
[ "$rc" = 0 ]; res "a target with nothing recorded, no Mathlib tag and no S10 pattern: status 0" $? "status $rc: $(tailof "$TMPD/c9.a" 4)"
t="S1=$(row "$TMPD/c9.a" S1) S2-S4=$(row "$TMPD/c9.a" S2-S4) S5=$(row "$TMPD/c9.a" S5) S6-S8=$(row "$TMPD/c9.a" S6-S8) S9=$(row "$TMPD/c9.a" S9) S10=$(row "$TMPD/c9.a" S10)"
[ "$t" = "S1=PASS S2-S4=n/a S5=n/a S6-S8=n/a S9=n/a S10=n/a" ]; res "S1 passes; S5, S9 and S10 (and S2-S4, S6-S8, with nothing recorded) are n/a" $? "$t"
grep -q 'not applicable' "$TMPD/c9.a" && grep -q 'None failed' "$TMPD/c9.a" && ! grep -q 'did NOT reproduce' "$TMPD/c9.a"
res "...and the closing line says they were not applicable, and that none failed" $? "$(tailof "$TMPD/c9.a" 1)"
grep -q 'TGT_MATHLIB_TAG is empty' "$TMPD/c9.a" && grep -q 'import graph: nothing recorded' "$TMPD/c9.a"; res "...with the reason for S5 and for S9" $? "$(grep 'n/a' "$TMPD/c9.a" | tr '\n' ' ')"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c9.b" 2>&1; rc=$?
t="S1=$(row "$TMPD/c9.b" S1) S2-S4=$(row "$TMPD/c9.b" S2-S4) S5=$(row "$TMPD/c9.b" S5) S6-S8=$(row "$TMPD/c9.b" S6-S8) S9=$(row "$TMPD/c9.b" S9) S10=$(row "$TMPD/c9.b" S10)"
[ "$rc" = 0 ] && [ "$t" = "S1=PASS S2-S4=PASS S5=n/a S6-S8=n/a S9=n/a S10=n/a" ]; res "target fix-git, pinned and with its record from case 4: S1 and S2-S4 pass" $? "status $rc: $t"
cenv RH_TARGET=fix-git TGT_S10_PATTERN='trivial|rfl' TGT_S10_COUNT= /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c9.c" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(row "$TMPD/c9.c" S10)" = "n/a" ]; res "an S10 pattern with no count: S10 is n/a" $? "status $rc: $(grep '^S10' "$TMPD/c9.c")"
cenv RH_TARGET=fix-git TGT_S10_PATTERN='trivial|rfl' TGT_S10_COUNT=2 /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c9.d" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(row "$TMPD/c9.d" S10)" = "PASS" ]; res "an S10 pattern with the right count (2 files): S10 passes" $? "status $rc: $(grep '^S10' "$TMPD/c9.d")"
cenv RH_TARGET=fix-git TGT_S10_PATTERN='trivial|rfl' TGT_S10_COUNT=5 /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c9.e" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(row "$TMPD/c9.e" S10)" = "FAIL" ]; res "...with a wrong count: S10 fails, status 1" $? "status $rc: $(grep '^S10' "$TMPD/c9.e")"

# ================================================================ 10
section 10 "values in the environment win over config.env and over the profile"
setcfg 'RH_TARGET=no-such-target'
t=$(libvar RH_TARGET RH_TARGET=fix-git); [ "$t" = fix-git ]; res "RH_TARGET in the environment over RH_TARGET in config.env" $? "$t"
setcfg 'RH_TARGET=fix-git'
t=$(libvar RH_TARGET); [ "$t" = fix-git ]; res "RH_TARGET in config.env alone names the target" $? "$t"
t=$(libvar RH_PROJ RH_TARGET=alpoge-rh); [ "$t" = "$NEW/work/extract/lean" ]; res "RH_TARGET=alpoge-rh in the environment over another target in config.env" $? "$t"
setcfg "RH_TARGET=fix-git
RH_WORKDIR=\"$TMPD/cfg10\""
t=$(libvar RH_WORKDIR RH_WORKDIR="$TMPD/env10"); [ "$t" = "$TMPD/env10" ]; res "RH_WORKDIR in the environment over config.env, used as given" $? "$t"
nocfg
t=$(libvar TGT_ROOT_MODULE RH_TARGET=fix-git); [ "$t" = A ]; res "the profile's TGT_ROOT_MODULE (A)" $? "$t"
t=$(libvar TGT_ROOT_MODULE RH_TARGET=fix-git TGT_ROOT_MODULE=Env.Root); [ "$t" = Env.Root ]; res "TGT_ROOT_MODULE in the environment over the profile" $? "$t"
setcfg 'TGT_ROOT_MODULE=Cfg.Root'
t=$(libvar TGT_ROOT_MODULE RH_TARGET=fix-git); [ "$t" = A ]; res "TGT_ROOT_MODULE in config.env does not reach another target's settings" $? "$t"
t=$(libvar TGT_ROOT_MODULE RH_TARGET=fix-git TGT_ROOT_MODULE=Env.Root); [ "$t" = Env.Root ]; res "...and the environment wins over both" $? "$t"
nocfg
t=$(libvar TGT_TARBALL_SHA256 RH_TARGET=fix-git "TGT_TARBALL_SHA256=$(printf '%064d' 3)"); [ "$t" = "$(printf '%064d' 3)" ]; res "TGT_TARBALL_SHA256 in the environment over the profile's" $? "$t"
t=$(libvar TGT_STATEMENT_CONST TGT_STATEMENT_CONST=Env.Const); [ "$t" = Env.Const ]; res "a TGT_ value in the environment for the default target too" $? "$t"
t=$(cenv RH_PART_COUNT=5 /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- TGT_PART_COUNT RH_PART_COUNT 2>&1 | tr '\n' ' ')
[ "$t" = "TGT_PART_COUNT=[5] RH_PART_COUNT=[5] " ]; res "the old name RH_PART_COUNT still works for the default target, and both names hold it" $? "$t"
t=$(libvar TGT_PART_COUNT RH_TARGET=fix-git RH_PART_COUNT=5); [ -z "$t" ]; res "...and does nothing for another target" $? "TGT_PART_COUNT=[$t]"

# ================================================================ 11
section 11 "the default target's 01, 02 and 03 on a made-up tarball, against the base commit's"
if [ "$HAVE_BASE" = 1 ]; then
  nocfg
  # The made-up tarball's own record, made with the base commit's 02 and 03, is the record of both trees.
  for t in "$MAIN" "$NEW"; do mv "$t/records/source/expected.json" "$t/records/source/expected.json.real" 2>/dev/null; done
  WX="$TMPD/w11-record"; mkdir -p "$WX/download"; cp "$TB/good.tar.gz" "$WX/download/lean.tar.gz"
  cenv RH_WORKDIR="$WX" RH_TARBALL_SHA256="$GOODSHA" /bin/bash "$MAIN/scripts/02_inspect_and_extract.sh" --write-expected "$TMPD/c11.rec" > "$TMPD/c11.rec.out" 2>&1 \
    && cenv RH_WORKDIR="$WX" RH_TARBALL_SHA256="$GOODSHA" /bin/bash "$MAIN/scripts/03_audit_source.sh" --write-expected "$TMPD/c11.rec" > "$TMPD/c11.rec.out3" 2>&1
  res "(the base commit's 02 and 03 recorded the made-up tarball)" $? "$(tailof "$TMPD/c11.rec.out") $(tailof "$TMPD/c11.rec.out3")"
  cp "$TMPD/c11.rec" "$MAIN/records/source/expected.json"; cp "$TMPD/c11.rec" "$NEW/records/source/expected.json"
  WB="$TMPD/w11-base"; WN="$TMPD/w11-new"
  for w in "$WB" "$WN"; do mkdir -p "$w/download"; cp "$TB/good.tar.gz" "$w/download/lean.tar.gz"; done
  cmp11() { # cmp11 <description> <label> <script and arguments...>: both trees, RH_WORKDIR and RH_TARBALL_SHA256 given
    local d=$1 l=$2 rb rn; shift 2
    cenv RH_WORKDIR="$WB" RH_TARBALL_SHA256="$GOODSHA" ${C11ENV:-} /bin/bash "$MAIN/scripts/$@" > "$TMPD/c11.$l.base" 2>&1; rb=$?
    cenv RH_WORKDIR="$WN" RH_TARBALL_SHA256="$GOODSHA" ${C11ENV:-} /bin/bash "$NEW/scripts/$@" > "$TMPD/c11.$l.new" 2>&1; rn=$?
    norm "$TMPD/c11.$l.base" "$WB=<WD>" "$MAIN=<REPO>" > "$TMPD/c11.$l.b"; norm "$TMPD/c11.$l.new" "$WN=<WD>" "$NEW=<REPO>" > "$TMPD/c11.$l.n"
    cmp -s "$TMPD/c11.$l.b" "$TMPD/c11.$l.n" && [ "$rb" = "$rn" ]
    res "$d: the same output and status ($rn)" $? "status $rb/$rn; $(diff "$TMPD/c11.$l.b" "$TMPD/c11.$l.n" | grep '^[<>]' | head -6 | tr '\n' ' ')"
  }
  C11ENV=""
  cmp11 "01 with the tarball present" 01 01_fetch.sh
  C11ENV="RH_PART_COUNT=2"
  cmp11 "01 --check-only, RH_PART_COUNT=2 and no parts on disk" 01c 01_fetch.sh --check-only
  C11ENV=""
  cmp11 "02 (lists, extracts, checks the project files)" 02 02_inspect_and_extract.sh
  ( cd "$WB/extract" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do echo "$(sha "$f") $f"; done ) > "$TMPD/c11.tree.b"
  ( cd "$WN/extract" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do echo "$(sha "$f") $f"; done ) > "$TMPD/c11.tree.n"
  [ -s "$TMPD/c11.tree.b" ] && cmp -s "$TMPD/c11.tree.b" "$TMPD/c11.tree.n"; res "...the same extracted files, with the same bytes" $? "$(diff "$TMPD/c11.tree.b" "$TMPD/c11.tree.n" | head -4 | tr '\n' ' ')"
  cmp11 "02 again (already extracted)" 02b 02_inspect_and_extract.sh
  cmp11 "02 --verify-tree" 02v 02_inspect_and_extract.sh --verify-tree
  cmp11 "03 --show 2" 03 03_audit_source.sh --show 2
  grep -q 'matches the recorded values' "$TMPD/c11.02.new"; res "(02 compared with the record there)" $? "$(tailof "$TMPD/c11.02.new")"
  for t in "$MAIN" "$NEW"; do mv "$t/records/source/expected.json.real" "$t/records/source/expected.json" 2>/dev/null; done
else
  skip "no base commit to compare with"
fi

# ================================================================ 12
section 12 "a profile whose sources are the project directory itself (TGT_SRC_DIR=.)"
prof fix-flat TGT_GIT_SUBDIR=proj2 TGT_ARCHIVE_PREFIX=proj2/ TGT_SRC_DIR=.
W12="$NEW/work-fix-flat"
t=$(libvar RH_SRC RH_TARGET=fix-flat); [ "$t" = "$W12/extract/proj2" ]; res "lib.sh accepts TGT_SRC_DIR=. (RH_SRC is the project directory)" $? "$t"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c12.a" 2>&1; rc=$?
[ "$rc" = 0 ]; res "01 writes its tar file" $? "status $rc: $(tailof "$TMPD/c12.a")"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c12.b" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$W12/extract/proj2/A.lean" ] && grep -q 'Lean files under proj2/: 2' "$TMPD/c12.b"
res "02 lists, counts 2 Lean sources under proj2/, and extracts" $? "status $rc: $(tailof "$TMPD/c12.b" 2)"
if [ ! -d "$W12/extract/proj2" ]; then      # so that 03 can be tried all the same
  mkdir -p "$W12/extract" && tar -xmf "$W12/download/source.tar" -C "$W12/extract"
  echo "INFO  (extracted with tar for the next check, since 02 did not)"
fi
mkdir -p "$W12/extract/proj2/.lake/packages/dep"; printf 'theorem d : True := sorry\n' > "$W12/extract/proj2/.lake/packages/dep/D.lean"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 > "$TMPD/c12.c" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'scanning 2 Lean files' "$TMPD/c12.c" && grep -q 'its .lake directory is not scanned' "$TMPD/c12.c" && ! grep -q '^sorry  *[1-9]' "$TMPD/c12.c"
res "03 scans the 2 sources and leaves out .lake" $? "status $rc: $(grep -i 'scanning\|lake\|^sorry' "$TMPD/c12.c" | tr '\n' ' ')"

# ================================================================ 13
section 13 "nothing reached for the network or the toolchain"
[ ! -s "$STUBLOG" ]; res "no stand-in of curl, wget, lake, elan or leanchecker was called" $? "$(tailof "$STUBLOG" 5)"

# ---------------------------------------------------------------- helpers for the cases from 14 on
nocfg
# A narrower PATH: the stand-ins, python3 and git through wrappers, and the system's directories. The directories
# python3 and git come from are left out, so that an elan, gcloud or rg installed there is not found.
PYBIN="$TMPD/pybin"; mkdir -p "$PYBIN"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$PY3" > "$PYBIN/python3"; printf '#!/bin/sh\nexec "%s" "$@"\n' "$GIT" > "$PYBIN/git"
chmod +x "$PYBIN"/*
NPATH="$STUB:$PYBIN:/usr/bin:/bin:/usr/sbin:/sbin"
HAVE_RG=0; cenv /bin/sh -c 'command -v rg' > /dev/null 2>&1 && HAVE_RG=1
NPATH_RG=0; cenv PATH="$NPATH" /bin/sh -c 'command -v rg' > /dev/null 2>&1 && NPATH_RG=1
# PYRUN: run one of the scripts in analysis/ with python3 -I -B, which leaves the script's own directory off
# sys.path; it is put back, as running the script plainly would. Usage: "$PY3" -I -B -c "$PYRUN" <script> [args]
PYRUN='import os, runpy, sys; s = sys.argv[1]; sys.path.insert(0, os.path.dirname(os.path.abspath(s))); sys.argv = sys.argv[1:]; runpy.run_path(s, run_name="__main__")'
# jsonok <file> <python expression on d>: true if the file is JSON and the expression holds for it
jsonok() { "$PY3" -I -B -c 'import json, sys; d = json.load(open(sys.argv[1], encoding="utf-8")); sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2" 2>/dev/null; }
TAB=$(printf '\t')
OK_MARK=$(printf '\342\234\224'); WARN_MARK=$(printf '\342\232\240'); INFO_MARK=$(printf '\342\204\271')
NFC_E=$(printf '\303\251'); NFD_E=$(printf 'e\314\201'); ZWNJ=$(printf '\342\200\214')

# ================================================================ 14
section 14 "rhv_tools.py git-export refuses .git and .lake components and names that are one on macOS"
blob() { printf '%s' "$1" | g hash-object -w --stdin; }
tree() { printf '%s\n' "$@" | g mktree; }      # tree <'mode type object<TAB>name'>...: git does not check the names
# withproj <branch> <entry>...: a commit on top of main whose proj/ has these entries as well; sets LASTC to it
withproj() {
  local b=$1 p r; shift; LASTC=""
  p=$( { g ls-tree "$C_MAIN:proj"; printf '%s\n' "$@"; } | g mktree ) || return 1
  r=$( { g ls-tree "$C_MAIN" | awk -F'\t' '$2 != "proj"'; printf '040000 tree %s\tproj\n' "$p"; } | g mktree ) || return 1
  LASTC=$(g commit-tree "$r" -p "$C_MAIN" -m "$b") && g update-ref "refs/heads/$b" "$LASTC"
}
ge() { # ge <label> <commit>: git-export of proj/ of the commit, as 01_fetch.sh asks for it; the status in GE
  cenv "$PY3" -I -B "$TOOLS" git-export --git-dir "$REPO/.git" --commit "$2" --subdir proj --prefix proj/ \
    --out "$TMPD/c14.$1.tar" > "$TMPD/c14.$1.out" 2>&1; GE=$?
}
gexp() { # gexp <description> <label> <text of the message> <entry>...: refused, with that text, and no file written
  local d=$1 l=$2 want=$3; shift 3
  if ! withproj "c14-$l" "$@" || [ -z "$LASTC" ]; then fail "$d" "could not make the commit"; return; fi
  ge "$l" "$LASTC"
  [ "$GE" = 1 ] && grep -q 'git-export: REFUSED: ' "$TMPD/c14.$l.out" && grep -q -F -- "$want" "$TMPD/c14.$l.out" \
    && grep -q 'nothing was written to' "$TMPD/c14.$l.out" && [ ! -e "$TMPD/c14.$l.tar" ] && [ ! -e "$TMPD/c14.$l.tar.tmp" ]
  res "$d: status 1, the message, no file" $? "status $GE: $(tailof "$TMPD/c14.$l.out" 3)"
}
B14a=$(blob one); B14b=$(blob two)
CFG14=$(tree "100644 blob $B14a${TAB}config")
DOTGIT="a '.git' component"
gexp "proj/.git/config" dotgit "$DOTGIT (git's own directory, refused in any spelling): '.git'" "040000 tree $CFG14${TAB}.git"
C14DOT=$LASTC
gexp "proj/deep/.git/config, further down" deep "$DOTGIT (git's own directory, refused in any spelling): 'deep/.git'" \
  "040000 tree $(tree "040000 tree $CFG14${TAB}.git")${TAB}deep"
gexp "proj/.GIT/x" upper "$DOTGIT" "040000 tree $(tree "100644 blob $B14a${TAB}x")${TAB}.GIT"
gexp "proj/.g<U+200C>it/config (a character macOS leaves out of names)" hfs "$DOTGIT" "040000 tree $CFG14${TAB}.g${ZWNJ}it"
gexp "proj/git~1/config (the short name Windows may give .git)" short "$DOTGIT" "040000 tree $CFG14${TAB}git~1"
gexp "proj/.git./config" dot "$DOTGIT" "040000 tree $CFG14${TAB}.git."
gexp "'proj/.git /config' (a space at the end)" space "$DOTGIT" "040000 tree $CFG14${TAB}.git "
gexp "proj/.lake/build/x.olean" lake "a '.lake' component (Lake's directory of build products and packages): '.lake'" \
  "040000 tree $(tree "040000 tree $(tree "100644 blob $B14a${TAB}x.olean")${TAB}build")${TAB}.lake"
NAMES_ONE="two names that are one where case and Unicode normalisation are ignored, as on macOS"
gexp "Foo.lean and foo.lean" case "$NAMES_ONE: Foo.lean and foo.lean" "100644 blob $B14a${TAB}Foo.lean" "100644 blob $B14b${TAB}foo.lean"
gexp "e-acute.lean in NFC and in NFD" nfd "$NAMES_ONE" "100644 blob $B14a${TAB}$NFC_E.lean" "100644 blob $B14b${TAB}$NFD_E.lean"
gexp "directories A/ and a/ with different files" dirs "$NAMES_ONE: A and a" \
  "040000 tree $(tree "100644 blob $B14a${TAB}x.lean")${TAB}A" "040000 tree $(tree "100644 blob $B14b${TAB}y.lean")${TAB}a"
n14=$(g ls-tree -r --name-only "$C_MAIN" -- proj/ | wc -l | tr -d ' ')
if withproj c14-near "100644 blob $B14a${TAB}.gitignore" "040000 tree $(tree "100644 blob $B14a${TAB}ci.yml")${TAB}.github" \
     "100644 blob $B14a${TAB}git~2" "040000 tree $(tree "100644 blob $B14a${TAB}y")${TAB}.gitx" \
     "040000 tree $(tree "100644 blob $B14a${TAB}z")${TAB}lake" "100644 blob $B14a${TAB}.lakefile" \
     "100644 blob $B14a${TAB}$NFC_E.lean" "100644 blob $B14b${TAB}Foo.lean" && [ -n "$LASTC" ]; then
  ge near "$LASTC"
  [ "$GE" = 0 ] && grep -q "^sha256 [0-9a-f]\{64\} entries $((n14 + 8))\$" "$TMPD/c14.near.out" && [ -s "$TMPD/c14.near.tar" ]
  res "near misses (.gitignore, .github/, git~2, .gitx/, lake/, .lakefile, e-acute.lean once, Foo.lean alone): written, $((n14 + 8)) files" $? "status $GE: $(tailof "$TMPD/c14.near.out" 3)"
else
  fail "near misses" "could not make the commit"
fi
prof fix-dotgit "TGT_GIT_COMMIT=$C14DOT"
refused "01 on the commit with proj/.git/config stops" "$DOTGIT" RH_TARGET=fix-dotgit /bin/bash "$NEW/scripts/01_fetch.sh"
[ ! -e "$NEW/work-fix-dotgit/download/source.tar" ] && [ ! -e "$NEW/work-fix-dotgit/download/source.tar.tmp" ]; res "...and writes no tar file" $?

# ================================================================ 15
section 15 "rhv_tools.py tar-inspect: the same refusals in tarballs, and the base commit's output on clean ones"
"$PY3" -I -B - "$TB/good.tar" "$TB" <<'PY'
import gzip, io, os, sys, tarfile
src, out = sys.argv[1], sys.argv[2]
with tarfile.open(src) as tf:
    base = [(m, tf.extractfile(m).read()) for m in tf.getmembers()]
def write(label, extra):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for m, d in base:
            tf.addfile(m, io.BytesIO(d))
        for name, data in extra:
            ti = tarfile.TarInfo(name); ti.mode = 0o644; ti.mtime = 1700000000
            b = data.encode(); ti.size = len(b)
            tf.addfile(ti, io.BytesIO(b))
    with open(os.path.join(out, "c15-%s.tar.gz" % label), "wb") as fh:
        fh.write(gzip.compress(buf.getvalue(), mtime=0))
write("dotgit", [("lean/.git/config", "x\n")])
write("deep", [("lean/src/deep/.git/config", "x\n")])
write("upper", [("lean/.GIT/x", "x\n")])
write("hfs", [("lean/.g‌it/config", "x\n")])
write("short", [("lean/git~1/config", "x\n")])
write("dot", [("lean/.git./config", "x\n")])
write("space", [("lean/.git /config", "x\n")])
write("lake", [("lean/.lake/build/x.olean", "x\n")])
write("case", [("lean/src/Foo.lean", "one\n"), ("lean/src/foo.lean", "two\n")])
write("nfd", [("lean/src/é.lean", "one\n"), ("lean/src/é.lean", "two\n")])
write("dirs", [("lean/A/x.lean", "one\n"), ("lean/a/y.lean", "two\n")])
write("near", [("lean/.gitignore", "x\n"), ("lean/.github/ci.yml", "x\n"), ("lean/git~2", "x\n"), ("lean/.gitx/y", "x\n"),
               ("lean/lake/z", "x\n"), ("lean/.lakefile", "x\n"), ("lean/src/é.lean", "one\n"), ("lean/src/Foo.lean", "two\n")])
PY
[ -f "$TB/c15-near.tar.gz" ]; res "(the tarballs were made)" $?
tinsp() { # tinsp <description> <label> <text>: tar-inspect as 02 runs it refuses c15-<label>: status 1, the reason, no record
  local d=$1 l=$2 want=$3 rc
  cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/c15-$l.tar.gz" --prefix lean/ --src-dir src --write-expected "$TMPD/c15.$l.json" \
    > "$TMPD/c15.$l.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q '^UNSAFE OR UNEXPECTED ENTRIES: 1 ' "$TMPD/c15.$l.out" && grep -q -F -- "$want" "$TMPD/c15.$l.out" && [ ! -e "$TMPD/c15.$l.json" ]
  res "$d: status 1, the reason, nothing recorded" $? "status $rc: $(grep -A2 '^UNSAFE' "$TMPD/c15.$l.out" | tr '\n' ' ')"
}
TGIT="a '.git' component (git's own directory, refused in any spelling): lean/"
tinsp "lean/.git/config" dotgit "${TGIT}.git/config"
tinsp "lean/src/deep/.git/config" deep "${TGIT}src/deep/.git/config"
tinsp "lean/.GIT/x" upper "${TGIT}.GIT/x"
tinsp "lean/.g<U+200C>it/config (the name shown escaped)" hfs "${TGIT%lean/}'lean/.g\\u200cit/config'"
tinsp "lean/git~1/config" short "${TGIT}git~1/config"
tinsp "lean/.git./config" dot "${TGIT}.git./config"
tinsp "'lean/.git /config'" space "${TGIT}.git /config"
tinsp "lean/.lake/build/x.olean" lake "a '.lake' component (Lake's directory of build products and packages): lean/.lake/build/x.olean"
TONE="one name where case and Unicode normalisation are ignored, as on macOS"
tinsp "lean/src/Foo.lean and lean/src/foo.lean" case "$TONE: lean/src/Foo.lean and lean/src/foo.lean"
tinsp "lean/src/e-acute.lean in NFC and in NFD" nfd "$TONE: lean/src/"
tinsp "directories lean/A/ and lean/a/ with different files" dirs "$TONE: lean/A and lean/a"
if [ "$HAVE_BASE" = 1 ]; then
  OLDT="$MAIN/scripts/verify/rhv_tools.py"
  c15same() { # c15same <description> <tarball> <record>: the base tool without the new arguments, the new one with them
    local d=$1 t=$2 r=$3 rb rn
    cenv "$PY3" -I -B "$OLDT" tar-inspect "$t" --sha256 "$(sha "$t")" --expected "$r" > "$TMPD/c15.same.base" 2>&1; rb=$?
    cenv "$PY3" -I -B "$TOOLS" tar-inspect "$t" --prefix lean/ --src-dir src --sha256 "$(sha "$t")" --expected "$r" > "$TMPD/c15.same.new" 2>&1; rn=$?
    [ "$rb" = 0 ] && [ "$rn" = 0 ] && cmp -s "$TMPD/c15.same.base" "$TMPD/c15.same.new" && grep -q 'tarball listing: matches the recorded values' "$TMPD/c15.same.new"
    res "$d: the base commit's output, byte for byte" $? "status $rb/$rn; $(diff "$TMPD/c15.same.base" "$TMPD/c15.same.new" | grep '^[<>]' | head -4 | tr '\n' ' ')"
  }
  c15same "the clean gzipped tarball under lean/, with --prefix lean/ --src-dir src" "$TB/good.tar.gz" "$TMPD/c8.expected.base"
  cenv "$PY3" -I -B "$OLDT" tar-inspect "$TB/c15-near.tar.gz" --sha256 "$(sha "$TB/c15-near.tar.gz")" --write-expected "$TMPD/c15.near.rec" > /dev/null 2>&1
  c15same "the tarball of near misses (.gitignore, .github/, git~2, .gitx/, lake/, .lakefile, e-acute.lean once)" "$TB/c15-near.tar.gz" "$TMPD/c15.near.rec"
  cenv "$PY3" -I -B "$OLDT" tar-inspect "$TB/bad.tar.gz" > "$TMPD/c15.bad.base" 2>&1; rb=$?
  cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/bad.tar.gz" --prefix lean/ --src-dir src > "$TMPD/c15.bad.new" 2>&1; rn=$?
  # With nothing to compare with, the one accepted change: that line is now in capitals (see case 8).
  grep -v -i 'no recorded values' "$TMPD/c15.bad.base" > "$TMPD/c15.bad.b"; grep -v -i 'no recorded values' "$TMPD/c15.bad.new" > "$TMPD/c15.bad.n"
  cmp -s "$TMPD/c15.bad.b" "$TMPD/c15.bad.n" && [ "$rb" = "$rn" ] && [ "$(grep -c -i 'no recorded values' "$TMPD/c15.bad.base")" = 1 ] \
    && [ "$(grep -c 'NO RECORDED VALUES TO COMPARE WITH' "$TMPD/c15.bad.new")" = 1 ]
  res "the tarball of case 8 with every older refusal, with the new arguments: the same output but for the line in capitals (status $rn)" $? "$(diff "$TMPD/c15.bad.b" "$TMPD/c15.bad.n" | grep '^[<>]' | head -4 | tr '\n' ' ')"
else
  skip "comparisons with the base commit's tar-inspect: no base commit"
fi
cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/good.tar.gz" --prefix lean/ --src-dir . > "$TMPD/c15.dot" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Lean files under lean/: 3$' "$TMPD/c15.dot"; res "--src-dir . counts the Lean files under the prefix itself (3)" $? "status $rc: $(grep 'Lean files' "$TMPD/c15.dot")"

# ================================================================ 16
section 16 "TGT_SRC_DIR=. end to end: the records, the counts and the import graph leave out .lake"
W16P="$W12/extract/proj2"; REC16="$NEW/targets/fix-flat/records/expected.json"
if [ ! -f "$W16P/.lake/packages/dep/D.lean" ]; then
  mkdir -p "$W16P/.lake/packages/dep"; printf 'theorem d : True := sorry\n' > "$W16P/.lake/packages/dep/D.lean"
fi
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c16.0" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'clone already present' "$TMPD/c16.0" && grep -q 'the clone holds commit' "$TMPD/c16.0"
res "01 again (case 12 ran it first): the clone is used, and the tar file written again" $? "status $rc: $(tailof "$TMPD/c16.0" 2)"
t=$(cenv RH_TARGET=fix-flat /bin/bash -c '. "$1" && . "$2" && count_sources' _ "$NEW/scripts/lib.sh" "$NEW/scripts/common.sh" 2>&1)
[ "$t" = 2 ]; res "count_sources: 2, not the .lean file in the .lake directory made after extraction" $? "$t"
rm -rf "${NEW:?}/targets/fix-flat/records"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --write-expected "$REC16" > "$TMPD/c16.a" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q "created $NEW/targets/fix-flat/records" "$TMPD/c16.a" && grep -q 'already extracted: .* (2 Lean source files)' "$TMPD/c16.a" \
  && jsonok "$REC16" 'd["tarball"]["source_lean_files"] == 2 and "project" in d'
res "02 --write-expected: creates the records directory, records 2 sources; 'already extracted' counts 2" $? "status $rc: $(grep -i 'created\|already\|recorded' "$TMPD/c16.a" | tr '\n' ' ')"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 --write-expected "$REC16" > "$TMPD/c16.b" 2>&1; rc=$?
[ "$rc" = 0 ] && jsonok "$REC16" 'd["audit"]["lean_files"] == 2 and d["audit"]["categories"]["sorry"]["lines"] == 0 and "tarball" in d'
res "03 --write-expected: records 2 files and no sorry (the one in .lake is left out), keeping 02's sections" $? "status $rc: $(tailof "$TMPD/c16.b" 2)"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 > "$TMPD/c16.c" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'scanning 2 Lean files' "$TMPD/c16.c" && grep -q 'comparison: matches the recorded values' "$TMPD/c16.c"
res "03 again ($( [ "$HAVE_RG" = 1 ] && echo rg || echo grep )): 2 files, and it matches that record" $? "status $rc: $(tailof "$TMPD/c16.c" 2)"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/03_audit_source.sh" --tool grep --show 0 > "$TMPD/c16.d" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'scanning 2 Lean files with grep' "$TMPD/c16.d" && grep -q 'comparison: matches the recorded values' "$TMPD/c16.d"
res "03 --tool grep leaves .lake out the same way and matches the record" $? "status $rc: $(tailof "$TMPD/c16.d" 2)"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --verify-tree > "$TMPD/c16.e" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'byte-for-byte' "$TMPD/c16.e" && grep -q 'tarball listing: matches the recorded values' "$TMPD/c16.e"
res "02 --verify-tree with .lake there: the files are the archive's, and the listing matches the record" $? "status $rc: $(tailof "$TMPD/c16.e" 3)"
cenv RH_TARGET=fix-flat "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" > "$TMPD/c16.f" 2>&1; rc=$?
[ "$rc" = 0 ] && jsonok "$W12/analysis/import_graph_summary.json" 'd["modules_total"] == 2 and d["root"] == "A" and d["main_closure_modules"] == 2' \
  && jsonok "$W12/analysis/import_graph.json" 'sorted(d) == ["A", "B.C"]'
res "import_graph.py with no arguments: the target's sources and root module A; 2 modules, none from .lake" $? "status $rc: $(tailof "$TMPD/c16.f" 2)"
cenv RH_TARGET=fix-flat "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/closure_stats.py" > "$TMPD/c16.g" 2>&1; rc=$?
[ "$rc" = 0 ] && jsonok "$W12/analysis/closure_stats.json" 'd["key_module_closures"] == {"A": 1}'
res "closure_stats.py with no --key reports the root module A" $? "status $rc: $(tailof "$TMPD/c16.g" 2)"
cp "$W12/analysis/import_graph_summary.json" "$NEW/targets/fix-flat/records/"
# For S10: only .lean files are searched, and not those in .lake. Below: hidden ones, and ones that ignore files name,
# are searched too.
printf 'zzmark\n' > "$W16P/.lake/packages/dep/marker.lean"; printf 'zzmark\n' > "$W16P/notes.txt"
rows16() { echo "S1=$(row "$1" S1) S2-S4=$(row "$1" S2-S4) S5=$(row "$1" S5) S6-S8=$(row "$1" S6-S8) S9=$(row "$1" S9) S10=$(row "$1" S10)"; }
cenv RH_TARGET=fix-flat TGT_S10_PATTERN=zzmark TGT_S10_COUNT=0 /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c16.h" 2>&1; rc=$?
t=$(rows16 "$TMPD/c16.h")
[ "$rc" = 0 ] && [ "$t" = "S1=PASS S2-S4=PASS S5=n/a S6-S8=PASS S9=PASS S10=PASS" ]
res "reproduce_findings.sh ($( [ "$HAVE_RG" = 1 ] && echo rg || echo grep )): S2-S4, S6-S8 and S9 pass against the record; S10 counts neither the .lean file in .lake nor a .txt file" $? "status $rc: $t; $(grep '^S10' "$TMPD/c16.h")"
printf 'zzmark\n' > "$W16P/.hidden.lean"; printf 'zzmark\n' > "$W16P/ignored.lean"
for f in .ignore .rgignore .gitignore; do printf 'ignored.lean\n.hidden.lean\n' > "$W16P/$f"; done
cenv RH_TARGET=fix-flat TGT_S10_PATTERN=zzmark TGT_S10_COUNT=2 /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c16.h2" 2>&1
t=$(row "$TMPD/c16.h2" S10); [ "$t" = PASS ]
res "...and S10 counts a hidden .lean file and one that the ignore files name (2)" $? "$(grep '^S10' "$TMPD/c16.h2")"
if [ "$NPATH_RG" = 0 ]; then
  cenv PATH="$NPATH" RH_TARGET=fix-flat TGT_S10_PATTERN=zzmark TGT_S10_COUNT=2 /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c16.i" 2>&1
  t=$(row "$TMPD/c16.i" S10); [ "$t" = PASS ]
  res "...and the same with grep (no rg on the PATH)" $? "$(grep '^S10' "$TMPD/c16.i")"
else
  skip "S10 with grep: rg is on the narrower PATH too"
fi
rm -f "$W16P/.hidden.lean" "$W16P/ignored.lean" "$W16P/notes.txt" "$W16P/.ignore" "$W16P/.rgignore" "$W16P/.gitignore" "$W16P/.lake/packages/dep/marker.lean"

# ================================================================ 17
section 17 "lib.sh: the paths of a profile, component by component"
for v in ./src src/. src/ /src a//b .. src/../x -x a/-b a..b; do
  prof fix-bad "TGT_SRC_DIR=$v"
  refused "TGT_SRC_DIR '$v' is refused" "TGT_SRC_DIR must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
done
prof fix-bad "TGT_SRC_DIR='a\\b'"
refused "TGT_SRC_DIR 'a\\b' (a backslash) is refused" "TGT_SRC_DIR must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
refused "TGT_SRC_DIR './src' in the environment is refused for the default target too" "TGT_SRC_DIR must be" \
  RH_WORKDIR="$TMPD/w17" TGT_SRC_DIR=./src /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
for v in . records/./x /x x/; do
  prof fix-bad "TGT_RECORDS_DIR=$v"
  refused "TGT_RECORDS_DIR '$v' is refused" "TGT_RECORDS_DIR must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
done
for v in a/./ a//; do
  prof fix-bad "TGT_ARCHIVE_PREFIX=$v"
  refused "TGT_ARCHIVE_PREFIX '$v' is refused" "TGT_ARCHIVE_PREFIX must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
done
WB17="$NEW/work-fix-bad/extract"
prof fix-bad TGT_SRC_DIR=.
t=$(cenv RH_TARGET=fix-bad /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- RH_PROJ RH_SRC 2>&1 | tr '\n' ' ')
[ "$t" = "RH_PROJ=[$WB17/proj] RH_SRC=[$WB17/proj] " ]; res "TGT_SRC_DIR '.' is accepted, and RH_SRC is the project directory" $? "$t"
prof fix-bad TGT_SRC_DIR=src/Sub
t=$(cenv RH_TARGET=fix-bad /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- RH_SRC 2>&1 | tr '\n' ' ')
[ "$t" = "RH_SRC=[$WB17/proj/src/Sub] " ]; res "TGT_SRC_DIR 'src/Sub' is accepted" $? "$t"
prof fix-bad TGT_ARCHIVE_PREFIX=a/b/
t=$(cenv RH_TARGET=fix-bad /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- RH_PROJ 2>&1 | tr '\n' ' ')
[ "$t" = "RH_PROJ=[$WB17/a/b] " ]; res "TGT_ARCHIVE_PREFIX 'a/b/' is accepted" $? "$t"
[ ! -e "$NEW/work-fix-bad" ] && [ ! -e "$TMPD/w17" ]; res "none of these left a working directory behind" $?

# ================================================================ 18
section 18 "extract.from: which archive an extracted tree came from (every target but the default one)"
prof fix-from; W18="$NEW/work-fix-from"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c18.a" 2>&1 \
  && cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.b" 2>&1; rc=$?
H18=""; [ -f "$W18/download/source.tar" ] && H18=$(sha "$W18/download/source.tar")
R18=$(record fix-from "$H18")
[ "$rc" = 0 ] && [ -n "$H18" ] && [ "$(cat "$W18/extract.from" 2>/dev/null)" = "$R18" ] \
  && [ "$R18" = "sha256 $H18 git $REPO commit $C_MAIN subdir proj prefix proj/" ] && [ "$(cat "$W18/download/source.tar.from" 2>/dev/null)" = "$R18" ]
res "01 and 02 for a git target: 01 writes source.tar.from and 02 extract.from, 'sha256 <SHA-256> git <address> commit <commit> subdir proj prefix proj/'" $? \
  "status $rc: $(cat "$W18/extract.from" 2>&1) $(tailof "$TMPD/c18.b")"
refused "03 stops if the tree has no extract.from" "is not recorded as extracted from the source that the profile" \
  RH_TARGET=fix-from /bin/bash -c 'mv "$1/extract.from" "$1/x"; /bin/bash "$2/scripts/03_audit_source.sh" --show 0; rc=$?; mv "$1/x" "$1/extract.from"; exit $rc' _ "$W18" "$NEW"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 > "$TMPD/c18.a3" 2>&1; rc=$?
res "...and goes on when it names the archive the profile names" $rc "$(tailof "$TMPD/c18.a3")"
C18=$(branch from-second 100644 proj/src/B/D.lean "$(printf 'def d : Nat := 2\n')")
prof fix-from "TGT_GIT_COMMIT=$C18"
refused "a second commit, made after the clone: 01 stops and says to use --redownload" "run this script again with --redownload" \
  RH_TARGET=fix-from /bin/bash "$NEW/scripts/01_fetch.sh"
refused "with the profile at the second commit, 03 stops: the tree is the first commit's" "is not recorded as extracted from the source that the profile" \
  RH_TARGET=fix-from /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0
refused "...and so does 08 (before it looks for lean or a build)" "is not recorded as extracted from the source that the profile" \
  RH_TARGET=fix-from /bin/bash "$NEW/scripts/08_check_axioms.sh"
# targets/README.md: "After a change of commit, move extract aside and run 02 again." Done before 01 has written the
# second commit's tar file, the tar file in download/ is still the first commit's; no SHA-256 is pinned, and 02 says
# the file "is identified only by the commit that 01_fetch.sh wrote it from", so it should not be taken for the second.
mv "$W18/extract" "$W18/extract.kept"; cp "$W18/extract.from" "$W18/extract.from.kept"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.s" 2>&1; rc=$?
[ "$rc" != 0 ] && [ ! -e "$W18/extract" ]
res "the commit changed, 01 stopped, extract moved aside: 02 does not extract the first commit's tar file for the second commit" $? \
  "status $rc; extract.from now '$(cat "$W18/extract.from" 2>&1)'; $(grep -c . "$TMPD/c18.s") lines, the last: $(tailof "$TMPD/c18.s" 1)"
rm -rf "${W18:?}/extract" "$W18/extract.partial"; mv "$W18/extract.kept" "$W18/extract"; mv "$W18/extract.from.kept" "$W18/extract.from"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/01_fetch.sh" --redownload > "$TMPD/c18.c" 2>&1; rc=$?
H18b=""; [ -f "$W18/download/source.tar" ] && H18b=$(sha "$W18/download/source.tar")
[ "$rc" = 0 ] && [ -n "$H18b" ] && [ "$H18b" != "$H18" ]; res "01 --redownload: a new clone, and the second commit's tar file (another SHA-256)" $? "status $rc: $(tailof "$TMPD/c18.c")"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.d" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'and the archive with the profile gives' "$TMPD/c18.d" && [ ! -e "$W18/extract/proj/src/B/D.lean" ] \
  && [ "$(cat "$W18/extract.from" 2>/dev/null)" = "$R18" ]
res "02 then stops (status 1): the tree was not extracted from the archive there now; tree and extract.from unchanged" $? "status $rc: $(tailof "$TMPD/c18.d" 2)"
mv "$W18/extract" "$W18/extract.first"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.e" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$W18/extract/proj/src/B/D.lean" ] && [ "$(cat "$W18/extract.from" 2>/dev/null)" = "$(record fix-from "$H18b")" ] \
  && [ "$(record fix-from "$H18b")" = "sha256 $H18b git $REPO commit $C18 subdir proj prefix proj/" ]
res "with the tree moved aside, 02 extracts the second commit and names it in extract.from" $? "status $rc: $(cat "$W18/extract.from" 2>&1) $(tailof "$TMPD/c18.e" 2)"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.f" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'already extracted' "$TMPD/c18.f"; res "02 again: that tree is used as it is" $? "status $rc: $(tailof "$TMPD/c18.f" 2)"
mv "$W18/extract.from" "$W18/extract.from.saved"
refused "a tree with no extract.from beside it is not used" "says 'nothing'" RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
mv "$W18/extract.from.saved" "$W18/extract.from"
W18d="$TMPD/w18default"; mkdir -p "$W18d/download"; cp "$TB/good.tar.gz" "$W18d/download/lean.tar.gz"
cenv RH_WORKDIR="$W18d" RH_TARBALL_SHA256="$GOODSHA" TGT_RECORDS_DIR=records/c18-nothing \
  /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.g" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$W18d/extract/lean/lakefile.toml" ] && [ ! -e "$W18d/extract.from" ]
res "the default target's 02 extracts and writes no extract.from" $? "status $rc: $(ls -A "$W18d" | tr '\n' ' ') $(tailof "$TMPD/c18.g" 2)"
if [ "$HAVE_BASE" = 1 ]; then
  [ -d "$TMPD/w11-new/extract" ] && [ ! -e "$TMPD/w11-new/extract.from" ]; res "...nor did it in case 11" $? "$(ls -A "$TMPD/w11-new" 2>&1 | tr '\n' ' ')"
fi

# ================================================================ 19
section 19 "cloud/gcp/pilot_local.sh knows only the default target"
mkdir -p "$NEW/cloud/gcp"; cp "$ROOT/cloud/gcp/pilot_local.sh" "$NEW/cloud/gcp/pilot_local.sh"
SGC="$TMPD/stub-gcloud"; GLOG="$TMPD/gcloud.log"; mkdir -p "$SGC"; : > "$GLOG"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: logs the call and fails\necho "gcloud $*" >> "%s"\nexit 1\n' "$GLOG" > "$SGC/gcloud"
chmod +x "$SGC/gcloud"
for sub in "launch pilot" ledger teardown; do
  W19="$TMPD/w19-$(printf '%s' "$sub" | tr ' ' -)"
  # shellcheck disable=SC2086
  cenv PATH="$SGC:$NPATH" RH_TARGET=fix-git RH_WORKDIR="$W19" GCP_PROJECT=made-up-project GCP_BUCKET=made-up-bucket \
    /bin/bash "$NEW/cloud/gcp/pilot_local.sh" $sub > "$TMPD/c19.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q "the cloud scripts know only the default target, alpoge-rh, and RH_TARGET is 'fix-git'" "$TMPD/c19.out" \
    && [ ! -s "$GLOG" ] && [ ! -e "$W19" ]
  res "RH_TARGET=fix-git, '$sub': stops at once (status 1), gcloud is not called, nothing is written" $? "status $rc: $(tailof "$TMPD/c19.out" 2) gcloud: $(tailof "$GLOG" 2)"
done
W19d="$TMPD/w19default"
cenv PATH="$SGC:$NPATH" RH_WORKDIR="$W19d" GCP_PROJECT=made-up-project GCP_BUCKET=made-up-bucket \
  /bin/bash "$NEW/cloud/gcp/pilot_local.sh" ledger > "$TMPD/c19.d" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'estimated spend so far: \$0.00 of \$40 cap' "$TMPD/c19.d" && [ -f "$W19d/analysis/pilot_ledger.tsv" ] && [ ! -s "$GLOG" ]
res "the default target gets past that line: 'ledger' shows an empty ledger, without gcloud" $? "status $rc: $(tailof "$TMPD/c19.d" 2) gcloud: $(tailof "$GLOG" 2)"

# ================================================================ 20
section 20 "00_check_prereqs.sh --install-elan marks the working directory"
S20="$TMPD/stub20"; L20="$TMPD/c20.log"; mkdir -p "$S20"; : > "$L20"
{ printf '#!/bin/sh\n# stand-in made by test_targets.sh: logs the call and writes a made-up installer where -o says\nlog="%s"\n' "$L20"
  cat <<'EOF'
echo "curl $*" >> "$log"
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
[ -n "$out" ] && printf '#!/bin/sh\necho made-up installer\n' > "$out"
exit 0
EOF
} > "$S20/curl"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: logs the call\necho "sh $*" >> "%s"\nexit 0\n' "$L20" > "$S20/sh"
chmod +x "$S20"/*
P20="$S20:$PYBIN:/usr/bin:/bin:/usr/sbin:/sbin"
if cenv PATH="$P20" /bin/sh -c 'command -v elan || command -v lake' > /dev/null 2>&1; then
  skip "00 --install-elan: an elan or lake is on the narrower PATH"
else
  W20="$TMPD/w20"
  cenv PATH="$P20" RH_TARGET=fix-git RH_WORKDIR="$W20" /bin/bash "$NEW/scripts/00_check_prereqs.sh" --install-elan > "$TMPD/c20.a" 2>&1; rc=$?
  [ "$(cat "$W20/.rh-target" 2>/dev/null)" = fix-git ]; res "a made-up target: .rh-target names fix-git (00 ended with status $rc, elan being a stand-in)" $? "$(cat "$W20/.rh-target" 2>&1) $(tailof "$TMPD/c20.a" 2)"
  grep -q "^curl .* -o $W20/download/elan-init.sh " "$L20" && grep -q "^sh $W20/download/elan-init.sh -y --default-toolchain none\$" "$L20" \
    && [ -f "$W20/download/elan-init.sh" ]
  res "...and the installer was fetched into its download/ and run (stand-ins for curl and sh)" $? "$(tailof "$L20" 2)"
  W20d="$TMPD/w20default"
  cenv PATH="$P20" RH_WORKDIR="$W20d" /bin/bash "$NEW/scripts/00_check_prereqs.sh" --install-elan > "$TMPD/c20.b" 2>&1
  [ "$(cat "$W20d/.rh-target" 2>/dev/null)" = alpoge-rh ]; res "the default target: .rh-target names alpoge-rh" $? "$(cat "$W20d/.rh-target" 2>&1) $(tailof "$TMPD/c20.b" 2)"
  n20=$(wc -l < "$L20" | tr -d ' ')
  mkdir -p "$TMPD/w20unmarked"; echo old > "$TMPD/w20unmarked/a-file"
  cenv PATH="$P20" RH_TARGET=fix-git RH_WORKDIR="$TMPD/w20unmarked" /bin/bash "$NEW/scripts/00_check_prereqs.sh" --install-elan > "$TMPD/c20.c" 2>&1; rc=$?
  [ "$rc" != 0 ] && grep -q 'no .rh-target file' "$TMPD/c20.c" && [ "$(wc -l < "$L20" | tr -d ' ')" = "$n20" ] && [ ! -e "$TMPD/w20unmarked/download" ]
  res "a made-up target in a directory with files and no marker: stops before it downloads anything" $? "status $rc: $(tailof "$TMPD/c20.c" 2)"
fi

# ================================================================ 21
section 21 "06_progress.sh and a job line with the information mark (U+2139)"
mklog21() { # mklog21 <workdir>: a made-up build log and status file
  mkdir -p "$1/logs"
  { echo "$OK_MARK [1/4] Built A (1.0s)"
    echo "$WARN_MARK [2/4] Built B.C (2.0s)"; echo 'warning: B/C.lean:1:0: a made-up warning'
    echo "$INFO_MARK [3/4] Built B.D (0.5s)"; echo 'info: B/D.lean:1:0: 1'; } > "$1/logs/build-20261126-000000.log"
  printf 'START epoch=1700000000 threads=4\nEND epoch=1700003600 status=0\n' > "$1/logs/build-status.txt"
}
win21() { sed -n '2,/^== Compiler processes/p' "$1"; }   # what 06 prints that depends on the directory, not on the machine
W21d="$TMPD/w21default"; mklog21 "$W21d"
cenv RH_WORKDIR="$W21d" RH_MODULE_TOTAL=4 /bin/bash "$NEW/scripts/06_progress.sh" > "$TMPD/c21.new" 2>&1; rn=$?
[ "$rn" = 0 ] && grep -q '^  compiled in this run: 2 ' "$TMPD/c21.new" && grep -q -F "  last job line: $WARN_MARK [2/4] Built B.C" "$TMPD/c21.new" && ! grep -q '^target:' "$TMPD/c21.new"
res "the default target: the information mark is not counted (2 compiled; the last job line is the warning one)" $? "status $rn: $(grep 'compiled in this run\|last job' "$TMPD/c21.new" | tr '\n' ' ')"
if [ "$HAVE_BASE" = 1 ]; then
  cenv RH_WORKDIR="$W21d" RH_MODULE_TOTAL=4 /bin/bash "$MAIN/scripts/06_progress.sh" > "$TMPD/c21.base" 2>&1; rb=$?
  win21 "$TMPD/c21.base" > "$TMPD/c21.b"; win21 "$TMPD/c21.new" > "$TMPD/c21.n"
  [ "$rb" = "$rn" ] && [ -s "$TMPD/c21.b" ] && cmp -s "$TMPD/c21.b" "$TMPD/c21.n"
  res "...and its output, to the list of processes, is the base commit's line for line" $? "status $rb/$rn; $(diff "$TMPD/c21.b" "$TMPD/c21.n" | grep '^[<>]' | head -4 | tr '\n' ' ')"
else
  skip "06 against the base commit's: no base commit"
fi
W21f="$TMPD/w21fix"; mklog21 "$W21f"; echo fix-git > "$W21f/.rh-target"
cenv RH_TARGET=fix-git RH_WORKDIR="$W21f" RH_MODULE_TOTAL=4 /bin/bash "$NEW/scripts/06_progress.sh" > "$TMPD/c21.fix" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^target: fix-git$' "$TMPD/c21.fix" && grep -q '^  compiled in this run: 3 ' "$TMPD/c21.fix" \
  && grep -q -F "  last job line: $INFO_MARK [3/4] Built B.D" "$TMPD/c21.fix"
res "a made-up target: it is counted (3 compiled; the last job line is the information one), and the target is named" $? "status $rc: $(grep 'target:\|compiled in this run\|last job' "$TMPD/c21.fix" | tr '\n' ' ')"

# ================================================================ 22
section 22 "reproduce_findings.sh for the default target: S9 without its record, and S10 without a pattern"
nocfg
MLR="$FX/mathlib"; mkdir -p "$MLR"
gml() { cenv GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 git -C "$MLR" -c user.name=test -c user.email=test@example.com \
          -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
C_ML=""
{ gml init -q . && printf 'a made-up Mathlib\n' > "$MLR/README" && gml add -A && gml commit -q -m mathlib && gml tag v4.33.1; } > /dev/null 2>&1 \
  && C_ML=$(gml rev-parse HEAD)
# The official repository's address, answered by the one made here: git rewrites it before it connects to anything.
MLENV22="GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.file://$MLR.insteadOf GIT_CONFIG_VALUE_0=https://github.com/leanprover-community/mathlib4"
# shellcheck disable=SC2086
t=$(cenv $MLENV22 git ls-remote https://github.com/leanprover-community/mathlib4 refs/tags/v4.33.1 2>/dev/null | cut -f1)
if [ -z "$C_ML" ] || [ "$t" != "$C_ML" ] || case "$MLR" in *' '*) true ;; *) false ;; esac; then
  skip "reproduce_findings.sh for the default target: the made-up Mathlib repository cannot stand in for the official one here"
else
  ok "(the address of the official Mathlib repository is answered by the one made here: tag v4.33.1 is ${C_ML%"${C_ML#???????}"})"
  "$PY3" -I -B - "$TB/good.tar" "$TB/ml.tar.gz" "$MLREV" "$C_ML" <<'PY'
import gzip, io, sys, tarfile
src, out, old, new = sys.argv[1:5]
buf = io.BytesIO()
with tarfile.open(src) as tin, tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tout:
    for m in tin.getmembers():
        d = tin.extractfile(m).read().replace(old.encode(), new.encode())
        m.size = len(d)
        tout.addfile(m, io.BytesIO(d))
with open(out, "wb") as fh:
    fh.write(gzip.compress(buf.getvalue(), mtime=0))
PY
  MLSHA=$(sha "$TB/ml.tar.gz")
  # The made-up tarball's own records, made with the new scripts in a directory of their own.
  W22r="$TMPD/w22-record"; mkdir -p "$W22r/download"; cp "$TB/ml.tar.gz" "$W22r/download/lean.tar.gz"
  cenv RH_WORKDIR="$W22r" RH_TARBALL_SHA256="$MLSHA" TGT_RECORDS_DIR=records/c22-nothing \
    /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --write-expected "$TMPD/c22.rec" > "$TMPD/c22.rec.out" 2>&1 \
    && cenv RH_WORKDIR="$W22r" RH_TARBALL_SHA256="$MLSHA" TGT_RECORDS_DIR=records/c22-nothing \
         /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 --write-expected "$TMPD/c22.rec" >> "$TMPD/c22.rec.out" 2>&1 \
    && cenv "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" "$W22r/extract/lean/src" "$TMPD/c22.an" >> "$TMPD/c22.rec.out" 2>&1
  res "(the made-up tarball's expected.json and import graph summary were made)" $? "$(tailof "$TMPD/c22.rec.out" 3)"
  TREES22="$NEW"; [ "$HAVE_BASE" = 1 ] && TREES22="$NEW
$MAIN"
  printf '%s\n' "$TREES22" | while IFS= read -r t; do
    for f in expected.json import_graph_summary.json; do [ -f "$t/records/source/$f" ] && mv "$t/records/source/$f" "$t/records/source/$f.c22real"; done
    cp "$TMPD/c22.rec" "$t/records/source/expected.json"
  done
  rf22() { # rf22 <label> <scripts directory> [VAR=value ...]: reproduce_findings.sh in a new working directory with the tarball
    local l=$1 s=$2 w="$TMPD/w22-$1"; shift 2
    mkdir -p "$w/download"; cp "$TB/ml.tar.gz" "$w/download/lean.tar.gz"
    # shellcheck disable=SC2086
    cenv RH_WORKDIR="$w" RH_TARBALL_SHA256="$MLSHA" $MLENV22 "$@" /bin/bash "$s/reproduce_findings.sh" > "$TMPD/c22.$l" 2>&1
  }
  rf22 a-new "$NEW/scripts"; rn=$?
  t=$(rows16 "$TMPD/c22.a-new")
  [ ! -e "$NEW/records/source/import_graph_summary.json" ] && [ "$rn" = 1 ] && [ "$(row "$TMPD/c22.a-new" S9)" = FAIL ]
  res "records/source/import_graph_summary.json removed: S9 FAIL, status 1" $? "status $rn: $t"
  [ "$t" = "S1=PASS S2-S4=PASS S5=PASS S6-S8=PASS S9=FAIL S10=FAIL" ]
  res "...the other claims as they should be (S10 fails: no file of the made-up tarball matches the six tactics, not 77)" $? "$t"
  if [ "$HAVE_BASE" = 1 ]; then
    rf22 a-base "$MAIN/scripts"; rb=$?
    tb=$(rows16 "$TMPD/c22.a-base")
    [ "$rb" = "$rn" ] && [ "$tb" = "$t" ] && grep -q 'At least one claim did NOT reproduce' "$TMPD/c22.a-base" && grep -q 'At least one claim did NOT reproduce' "$TMPD/c22.a-new"
    res "...as with the base commit's script: the same results and the same status" $? "base: status $rb, $tb; new: status $rn, $t"
  else
    skip "reproduce_findings.sh against the base commit's: no base commit"
  fi
  cp "$TMPD/c22.an/import_graph_summary.json" "$NEW/records/source/import_graph_summary.json"
  rf22 b "$NEW/scripts" TGT_S10_COUNT=0; rc=$?
  t=$(rows16 "$TMPD/c22.b")
  [ "$rc" = 0 ] && [ "$t" = "S1=PASS S2-S4=PASS S5=PASS S6-S8=PASS S9=PASS S10=PASS" ] && grep -q '^All tier-S claims reproduced\.$' "$TMPD/c22.b"
  res "with the record (and TGT_S10_COUNT=0): every claim passes, 'All tier-S claims reproduced.', status 0" $? "status $rc: $t; $(tailof "$TMPD/c22.b" 1)"
  rf22 c "$NEW/scripts" TGT_S10_PATTERN=; rc=$?
  t=$(rows16 "$TMPD/c22.c")
  [ "$rc" = 0 ] && [ "$t" = "S1=PASS S2-S4=PASS S5=PASS S6-S8=PASS S9=PASS S10=n/a" ] && grep -q '^S10  .*TGT_S10_PATTERN is empty' "$TMPD/c22.c" \
    && ! grep -q 'All tier-S claims reproduced' "$TMPD/c22.c" && grep -q '5 of 6 tier-S claims reproduced\. 1 claim was not applicable .* None failed\.' "$TMPD/c22.c"
  res "TGT_S10_PATTERN= in the environment: an S10 row that is n/a, no 'All tier-S claims reproduced.', none failed, status 0" $? "status $rc: $t; $(tailof "$TMPD/c22.c" 1)"
  printf '%s\n' "$TREES22" | while IFS= read -r t; do
    rm -f "$t/records/source/expected.json" "$t/records/source/import_graph_summary.json"
    for f in expected.json import_graph_summary.json; do [ -f "$t/records/source/$f.c22real" ] && mv "$t/records/source/$f.c22real" "$t/records/source/$f"; done
  done
  [ -f "$NEW/records/source/expected.json" ] && [ -f "$NEW/records/source/import_graph_summary.json" ] && [ ! -e "$NEW/records/source/expected.json.c22real" ]
  res "(the repository's records were put back in the scratch copy)" $?
fi

# ================================================================ 23
section 23 "TGT_PROTECTED_NAMES: by default the last component of TGT_STATEMENT_CONST"
prof fix-prot TGT_STATEMENT_CONST=Foo.Bar
t=$(libvar TGT_PROTECTED_NAMES RH_TARGET=fix-prot); [ "$t" = Bar ]; res "TGT_STATEMENT_CONST=Foo.Bar and no TGT_PROTECTED_NAMES: the protected name is Bar" $? "'$t'"
prof fix-prot2 TGT_STATEMENT_CONST=Bar
t=$(libvar TGT_PROTECTED_NAMES RH_TARGET=fix-prot2); [ "$t" = Bar ]; res "...and Bar for TGT_STATEMENT_CONST=Bar" $? "'$t'"
prof fix-prot2 TGT_STATEMENT_CONST=Foo.Bar 'TGT_PROTECTED_NAMES="Baz Qux"'
t=$(libvar TGT_PROTECTED_NAMES RH_TARGET=fix-prot2); [ "$t" = "Baz Qux" ]; res "a profile's own TGT_PROTECTED_NAMES is kept" $? "'$t'"
W23="$TMPD/w23"; mkdir -p "$W23/extract/proj/src/B"; echo fix-prot > "$W23/.rh-target"
printf 'namespace Foo\n\ndef Bar : Prop := True\n\nend Foo\n' > "$W23/extract/proj/src/A.lean"
printf 'def c : Nat := 1\n' > "$W23/extract/proj/src/B/C.lean"
# The record 02 would have written (03 stops without it): any SHA-256 if none is pinned.
cenv RH_TARGET=fix-prot RH_WORKDIR="$W23" /bin/bash -c '. "$1/scripts/lib.sh" && source_record "${RH_TARBALL_SHA256:-$2}"' _ "$NEW" "$(printf '%064d' 0)" > "$W23/extract.from"
for tool in rg grep; do
  if [ "$tool" = rg ] && [ "$HAVE_RG" = 0 ]; then skip "03 with rg: rg is not installed"; continue; fi
  cenv RH_TARGET=fix-prot RH_WORKDIR="$W23" /bin/bash "$NEW/scripts/03_audit_source.sh" --tool "$tool" --show 0 > "$TMPD/c23.$tool" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q '^Declarations named Bar: 1$' "$TMPD/c23.$tool" && grep -q '^  A.lean:3: def Bar : Prop := True$' "$TMPD/c23.$tool" \
    && grep -q '^local_def  *1  *1  *declarations named Bar$' "$TMPD/c23.$tool"
  res "03 ($tool) lists the 'def Bar' inside 'namespace Foo'" $? "status $rc: $(grep -A1 '^Declarations named' "$TMPD/c23.$tool" | tr '\n' ' ')"
done
cenv RH_TARGET=fix-prot RH_WORKDIR="$W23" TGT_PROTECTED_NAMES="RiemannHypothesis riemannZeta LFunction" \
  /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 > "$TMPD/c23.default" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Declarations named RiemannHypothesis, riemannZeta, LFunction: 0$' "$TMPD/c23.default"
res "(with the default target's names given instead it is not listed: the name is what finds it)" $? "status $rc: $(grep '^Declarations named' "$TMPD/c23.default")"

# ================================================================ 24
section 24 "rhv_tools.py axioms-body accepts only ASCII Lean names"
CAFE=$(printf 'caf\303\251'); LAMX=$(printf '\316\273x')
for n in "$CAFE" "$LAMX"; do
  cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const "$n" > "$TMPD/c24.out" 2> "$TMPD/c24.err"; rc=$?
  [ "$rc" = 2 ] && [ ! -s "$TMPD/c24.out" ] && grep -q -F "not a plain Lean name" "$TMPD/c24.err" && grep -q -F "'$n'" "$TMPD/c24.err"
  res "--statement-const '$n': status 2, nothing on standard output, the name in the message" $? "status $rc: $(tailof "$TMPD/c24.err" 2)"
done
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const GRH --report-consts "GRH Foo.$LAMX" > "$TMPD/c24.out" 2> "$TMPD/c24.err"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$TMPD/c24.out" ] && grep -q -F "'Foo.$LAMX'" "$TMPD/c24.err"; res "--report-consts 'GRH Foo.<lambda>x': status 2, nothing printed" $? "status $rc: $(tailof "$TMPD/c24.err" 2)"
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const "$CAFE" --report-consts "$CAFE $CAFE" > "$TMPD/c24.out" 2> "$TMPD/c24.err"; rc=$?
[ "$rc" = 2 ] && [ "$(grep -o 'caf' "$TMPD/c24.err" | wc -l | tr -d ' ')" = 1 ]; res "the same name as the constant and twice in the list: said once" $? "status $rc: $(tailof "$TMPD/c24.err" 2)"
nl24=$(cat "$STUBLOG.lean" 2>/dev/null | wc -l | tr -d ' '); nf24=$(ls "$W4"/logs/axioms-full-*.lean 2>/dev/null | wc -l | tr -d ' ')
refused "08 for a target whose statement constant is '$CAFE' stops" "could not write the check" RH_TARGET=fix-git "TGT_STATEMENT_CONST=$CAFE" /bin/bash "$NEW/scripts/08_check_axioms.sh"
[ "$(cat "$STUBLOG.lean" 2>/dev/null | wc -l | tr -d ' ')" = "$nl24" ] && [ "$(ls "$W4"/logs/axioms-full-*.lean 2>/dev/null | wc -l | tr -d ' ')" = "$nf24" ]
res "...before it runs lean, and leaves no .lean file" $?

# ================================================================ 25
section 25 "analysis/rhpaths.py: directories from the environment, without asking lib.sh"
W25="$TMPD/w25"; mkdir -p "$W25/proj/src/B"
printf 'import B.C\n\ntheorem m : True := trivial\n' > "$W25/proj/src/Main.lean"
printf 'def c : Nat := 1\n' > "$W25/proj/src/B/C.lean"; printf 'def o : Nat := 2\n' > "$W25/proj/src/Other.lean"
SB="$TMPD/stub-bash"; BLOG="$TMPD/bash.log"; mkdir -p "$SB"; : > "$BLOG"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: logs the call and fails\necho "bash $*" >> "%s"\nexit 1\n' "$BLOG" > "$SB/bash"; chmod +x "$SB/bash"
[ "$(cat "$W4/.rh-target" 2>/dev/null)" = fix-git ]; res "(RH_WORKDIR for these runs is work-fix-git, marked for fix-git)" $?
cenv PATH="$SB:$CPATH" RH_WORKDIR="$W4" RH_PROJ="$W25/proj" RH_AN="$W25/an" RH_LOGS="$W25/logs" \
  "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" > "$TMPD/c25.a" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$BLOG" ] && jsonok "$W25/an/import_graph_summary.json" 'd["root"] == "Main" and d["modules_total"] == 3 and d["main_closure_modules"] == 2'
res "RH_TARGET unset, RH_PROJ, RH_AN and RH_LOGS given: import_graph.py works, root Main, and the stand-in bash is not called" $? "status $rc: $(tailof "$TMPD/c25.a" 2) bash: $(tailof "$BLOG" 1)"
cenv PATH="$SB:$CPATH" RH_TARGET=fix-git RH_WORKDIR="$TMPD/w6other" RH_PROJ="$W25/proj" RH_AN="$W25/an2" RH_LOGS="$W25/logs" \
  TGT_SRC_DIR=src TGT_ROOT_MODULE=B.C "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" > "$TMPD/c25.b" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$BLOG" ] && jsonok "$W25/an2/import_graph_summary.json" 'd["root"] == "B.C" and d["main_closure_modules"] == 1'
res "another target with TGT_SRC_DIR and TGT_ROOT_MODULE in the environment as well: not asked either, root B.C" $? "status $rc: $(tailof "$TMPD/c25.b" 2) bash: $(tailof "$BLOG" 1)"
cenv PATH="$SB:$CPATH" RH_WORKDIR="$W4" RH_AN="$W25/an3" "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" > "$TMPD/c25.s" 2>&1; rc=$?
[ "$rc" != 0 ] && [ -s "$BLOG" ] && grep -q "belongs to target 'fix-git'" "$TMPD/c25.s" && [ ! -e "$W25/an3" ]
res "(control: without RH_PROJ the stand-in bash is called, and the default layout it falls back to is refused too)" $? "status $rc: $(tailof "$TMPD/c25.s" 1) bash: $(tailof "$BLOG" 1)"
: > "$BLOG"
cenv RH_WORKDIR="$W4" RH_AN="$W25/an3" "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" > "$TMPD/c25.c" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "belongs to target 'fix-git'" "$TMPD/c25.c" && [ ! -e "$W25/an3" ]
res "without RH_PROJ, lib.sh is asked, and it stops (the directory is another target's)" $? "status $rc: $(tailof "$TMPD/c25.c" 2)"

# ================================================================ 26
section 26 "archive names, .lake under the sources, and the record beside a git source's tar file"
T26="$TMPD/c26"; mkdir -p "$T26"
cenv "$PY3" -I -B - "$T26" <<'PY'
import io, os, sys, tarfile
out = sys.argv[1]
def tar(path, names):
    with tarfile.open(path, "w", format=tarfile.GNU_FORMAT, encoding="utf-8") as tf:
        for n in names:
            ti = tarfile.TarInfo(n); ti.mode = 0o644; ti.size = 2
            tf.addfile(ti, io.BytesIO(b"x\n"))
tar(os.path.join(out, "filedir.tar"), ["lean/lakefile.toml", "lean/src/A.lean", "lean/src/A.lean/B.lean"])
tar(os.path.join(out, "ntfs.tar"), ["lean/lakefile.toml", "lean/.git::$INDEX_ALLOCATION/config"])
tar(os.path.join(out, "lake1.tar"), ["lean/lakefile.toml", "lean/LAKE~1/x.olean"])
tar(os.path.join(out, "cn.tar"), ["lean/lakefile.toml", "lean/src/͸.lean"])
PY
for c in "filedir|a file where this entry needs a directory" "ntfs|a '.git' component" "lake1|a '.lake' component" "cn|a character unassigned in Unicode"; do
  f=${c%%|*}; want=${c#*|}
  refused "tar-inspect refuses $f.tar: $want" "$want" "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$T26/$f.tar"
done
refused "tar-inspect refuses --src-dir 'src/' (only '.' is accepted as a directory that is not a plain path)" "--src-dir 'src/'" \
  "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$TB/good.tar" --src-dir src/
cenv "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$TB/good.tar" --src-dir . > "$T26/dot.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Lean files under lean/: 3$' "$T26/dot.out"; res "...and accepts --src-dir . (the .lean files under the prefix: 3)" $? "status $rc: $(tailof "$T26/dot.out")"
P26="$T26/flat"; mkdir -p "$P26/.lake/packages/dep" "$P26/B"
printf 'import B.C\n' > "$P26/A.lean"; printf 'def c := 1\n' > "$P26/B/C.lean"; printf 'def d := 1\n' > "$P26/.lake/packages/dep/D.lean"
cenv "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" import-graph --src "$P26" --out "$T26/ig.json" > "$T26/ig.out" 2>&1; rc=$?
[ "$rc" = 0 ] && jsonok "$T26/ig.json" 'd["modules"] == ["A", "B.C"] and d["imports"] == [[1], []]'
res "rhv_tools.py import-graph on a project directory: the .lake directory under it is not walked" $? "status $rc: $(tailof "$T26/ig.out")"
prof fix-rec; W26="$NEW/work-fix-rec"
cenv RH_TARGET=fix-rec /bin/bash "$NEW/scripts/01_fetch.sh" > "$T26/f.a" 2>&1; rc=$?
H26=""; [ -f "$W26/download/source.tar" ] && H26=$(sha "$W26/download/source.tar"); R26=$(record fix-rec "$H26")
[ "$rc" = 0 ] && [ -n "$H26" ] && [ "$(cat "$W26/download/source.tar.from" 2>/dev/null)" = "$R26" ]
res "01 writes source.tar.from beside the tar file" $? "status $rc: $(cat "$W26/download/source.tar.from" 2>&1)"
cenv RH_TARGET=fix-rec /bin/bash "$NEW/scripts/01_fetch.sh" --check-only > "$T26/f.b" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^record:   written from this address, commit, directory and prefix' "$T26/f.b"; res "01 --check-only: the record names this file and the profile's commit" $? "status $rc: $(tailof "$T26/f.b")"
mv "$W26/download/source.tar.from" "$T26/from.saved"
refused "02 does not use a tar file with no SHA-256 pinned and no record beside it" "is not known to be the archive" RH_TARGET=fix-rec /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
refused "...and 01 --check-only says so (status 1)" "DOES NOT NAME THIS FILE" RH_TARGET=fix-rec /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
[ ! -e "$W26/extract" ]; res "...nothing was extracted" $?
mv "$T26/from.saved" "$W26/download/source.tar.from"
prof fix-rec TGT_GIT_SUBDIR=proj2 TGT_ARCHIVE_PREFIX=proj2/
refused "02 does not use it for a profile that now names another directory of the commit" "is not known to be the archive" RH_TARGET=fix-rec /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
prof fix-rec "TGT_TARBALL_SHA256=$(printf '%064d' 0)"
cenv RH_TARGET=fix-rec /bin/bash "$NEW/scripts/01_fetch.sh" > "$T26/f.c" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$W26/download/source.tar.from" 2>/dev/null)" = "$R26" ]
res "pinned wrong: 01 stops (status 1), and its record still says what the file was written from" $? "status $rc: $(cat "$W26/download/source.tar.from" 2>&1)"
prof fix-rec "TGT_TARBALL_SHA256=$H26"
cenv RH_TARGET=fix-rec /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$T26/f.d" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$W26/extract.from" 2>/dev/null)" = "$R26" ]; res "pinned right: 02 extracts and names the archive in extract.from" $? "status $rc: $(tailof "$T26/f.d" 2)"
cenv RH_TARGET=fix-rec /bin/bash -c '. "$1/scripts/lib.sh" && . "$1/scripts/common.sh" && require_extract_from && echo passed' _ "$NEW" > "$T26/f.e" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^passed$' "$T26/f.e"; res "require_extract_from passes for that tree" $? "status $rc: $(tailof "$T26/f.e")"
prof fix-rec "TGT_TARBALL_SHA256=$(printf '%064d' 1)"
refused "...and 09 stops once the profile pins another SHA-256" "is not recorded as extracted from the source that the profile" RH_TARGET=fix-rec /bin/bash "$NEW/scripts/09_kernel_replay.sh" --summary

# ================================================================ 27
section 27 "the end of an archive, long names, what tar wrote, and the commit and address a tar file is from"
T27="$TMPD/c27"; mkdir -p "$T27"
cenv "$PY3" -I -B - "$T27" <<'PY'
import gzip, os, sys, tarfile
out = sys.argv[1]
def member(name, data=b"x\n", mode=0o644, kind=tarfile.REGTYPE, link=""):
    ti = tarfile.TarInfo(name); ti.mode = mode; ti.type = kind; ti.linkname = link
    ti.size = len(data) if kind == tarfile.REGTYPE else 0
    b = ti.tobuf(tarfile.GNU_FORMAT, "utf-8", "surrogateescape")
    return b + (data + b"\0" * (-len(data) % 512) if kind == tarfile.REGTYPE else b"")
END = b"\0" * 1024
good = member("lean/lakefile.toml") + member("lean/src/A.lean")
# What a tar that carries on past a damaged place would extract: a file in .lake, an executable, a link out.
hidden = (member("lean/.lake/build/lib/lean/A.olean") + member("lean/src/run.sh", b"#!/bin/sh\n", 0o755)
          + member("lean/src/link", kind=tarfile.SYMTYPE, link="/etc"))
def write(name, data):
    with open(os.path.join(out, name), "wb") as fh:
        fh.write(data)
gz = lambda b: gzip.compress(b, mtime=0)
write("damaged.tar.gz", gz(good + b"\x01" * 512 + hidden + END))
write("damaged.tar", good + b"\x01" * 512 + hidden + END)
write("zeroblock.tar.gz", gz(good + b"\0" * 512 + hidden + END))
# Two gzip members. Without end blocks in the first, the two hold one archive; with them, the second comes after the end.
write("multi.tar.gz", gz(good) + gz(hidden + END))
write("multi_end.tar.gz", gz(good + END) + gz(hidden + END))
write("trailing.tar.gz", gz(good + END) + b"not gzip")
whole = gz(good + END)
write("truncated.tar.gz", whole[:len(whole) // 2])
write("zeros.tar.gz", whole + b"\0" * 4096)                 # zero bytes after the last member, which gzip allows
write("padded.tar", good + END + b"\0" * 9216)              # filled up to a whole record, as tar does
write("component.tar", member("lean/src/%s.lean" % ("x" * 300)) + END)
write("deep.tar.gz", gz(member("lean/src/" + "a/" * 40000 + "x.lean") + END))
write("dirs.tar", member("lean/", kind=tarfile.DIRTYPE) + member("lean/src/", kind=tarfile.DIRTYPE) + good + END)
PY
for c in "damaged.tar.gz|data after the end of the archive" "damaged.tar|data after the end of the archive" \
         "zeroblock.tar.gz|data after the end of the archive" "multi.tar.gz|not a regular file (symbolic link): lean/src/link" \
         "multi_end.tar.gz|data after the end of the archive" "trailing.tar.gz|cannot be read to its end" \
         "truncated.tar.gz|cannot be read to its end" "component.tar|a component of the name longer than 255 bytes" \
         "deep.tar.gz|a name longer than 1024 bytes"; do
  f=${c%%|*}; want=${c#*|}
  refused "tar-inspect refuses $f: $want" "$want" "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$T27/$f"
done
if [ "$HAVE_BASE" = 1 ]; then
  cenv "$PY3" -I -B "$MAIN/scripts/verify/rhv_tools.py" tar-inspect "$T27/damaged.tar.gz" > "$T27/base.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q '^tarball entries: *2$' "$T27/base.out"
  res "(the base commit's tar-inspect passed damaged.tar.gz, seeing 2 entries of 5: what this case guards against)" $? "status $rc: $(tailof "$T27/base.out")"
fi
for f in zeros.tar.gz padded.tar; do
  cenv "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$T27/$f" > "$T27/$f.out" 2>&1; rc=$?
  [ "$rc" = 0 ]; res "tar-inspect accepts $f: only zero bytes follow the end" $? "status $rc: $(tailof "$T27/$f.out")"
done
cenv "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$T27/dirs.tar" > "$T27/dirs.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'not a regular file (directory): lean/src$' "$T27/dirs.out" && ! grep -q 'needs a directory' "$T27/dirs.out"
res "tar-inspect on directory entries: refused as such, with no 'file where a directory is needed'" $? "status $rc: $(tailof "$T27/dirs.out" 4)"
C_LONG=$(branch long 100644 "proj/src/$(printf '%0300d' 0 | tr 0 x).lean" 'def x := 1')
refused "git-export refuses a component longer than 255 bytes" "a name longer than 255 bytes" \
  "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" git-export --git-dir "$REPO/.git" --commit "$C_LONG" --subdir proj --prefix proj/ --out "$T27/long.tar"
[ ! -e "$T27/long.tar" ]; res "...and writes nothing" $?

# --check-extracted: what is on disk against the listing
X27="$T27/x"; mkdir -p "$X27"; tar -xf "$TB/good.tar" -C "$X27"
ce() { cenv "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$TB/good.tar" --quiet --check-extracted "$X27" "$@" > "$T27/ce.out" 2>&1; }
ce; rc=$?
[ "$rc" = 0 ] && grep -q '^extracted tree: 8 files under ' "$T27/ce.out"; res "--check-extracted on what tar wrote: status 0, 8 files" $? "status $rc: $(tailof "$T27/ce.out")"
# cex <description> <text> <command that changes the tree> <command that undoes it>
cex() {
  local rc
  eval "$3"; ce; rc=$?; eval "$4"
  [ "$rc" = 1 ] && grep -q -- "$2" "$T27/ce.out"; res "--check-extracted refuses $1" $? "status $rc: $(tailof "$T27/ce.out" 3)"
}
cex "a file that is not an entry" "a file that is not an entry of the archive: lean/src/Extra.lean" \
  'echo x > "$X27/lean/src/Extra.lean"' 'rm -f "$X27/lean/src/Extra.lean"'
cex "a file in .lake" "a file that is not an entry of the archive: lean/.lake/build/x.olean" \
  'mkdir -p "$X27/lean/.lake/build" && : > "$X27/lean/.lake/build/x.olean"' 'rm -rf "${X27:?}/lean/.lake"'
cex "a link to a file" "a symbolic link: lean/src/Link.lean" 'ln -s Main.lean "$X27/lean/src/Link.lean"' 'rm -f "$X27/lean/src/Link.lean"'
cex "a link to a directory" "a symbolic link: lean/etc" 'ln -s /etc "$X27/lean/etc"' 'rm -f "$X27/lean/etc"'
cex "an executable bit" "an executable bit (mode 755): lean/src/Main.lean" 'chmod 755 "$X27/lean/src/Main.lean"' 'chmod 644 "$X27/lean/src/Main.lean"'
cex "an entry that is missing" "an entry of the archive that is not on disk: lean/src/Main.lean" \
  'mv "$X27/lean/src/Main.lean" "$T27/Main.lean.aside"' 'mv "$T27/Main.lean.aside" "$X27/lean/src/Main.lean"'
cex "an empty directory" "a directory with no entry of the archive in it: lean/empty" 'mkdir "$X27/lean/empty"' 'rmdir "$X27/lean/empty"'
cex "a file with a second name" "a file with more than one name (a hard link): lean/README.md" \
  'ln "$X27/lean/README.md" "$T27/README.second"' 'rm -f "$T27/README.second"'
chmod 755 "$X27/lean/src/Main.lean"; ce --allow-exec; rc=$?; chmod 644 "$X27/lean/src/Main.lean"
[ "$rc" = 0 ]; res "...and accepts the executable bit with --allow-exec" $? "status $rc: $(tailof "$T27/ce.out")"

# 02 with a tar that writes one file the archive does not have (a stand-in for a tar that reads an archive otherwise)
STUB27="$TMPD/stub27"; mkdir -p "$STUB27"; REALTAR=$(command -v tar)
cat > "$STUB27/tar" <<EOF
#!/bin/sh
# stand-in made by test_targets.sh: extracts with the real tar, then leaves a file in .lake that the archive does not have
"$REALTAR" "\$@" || exit
for a; do last=\$a; done
mkdir -p "\$last/proj/.lake/build" && echo planted > "\$last/proj/.lake/build/planted.olean"
EOF
chmod +x "$STUB27/tar"
prof fix-plant; W27="$NEW/work-fix-plant"
cenv RH_TARGET=fix-plant /bin/bash "$NEW/scripts/01_fetch.sh" > "$T27/p.a" 2>&1; rc=$?
[ "$rc" = 0 ]; res "fix-plant: 01 writes the tar file" $? "status $rc: $(tailof "$T27/p.a")"
refused "02 with a tar that writes more than the listing showed: stops" "what tar extracted is not what the listing showed" \
  PATH="$STUB27:$CPATH" RH_TARGET=fix-plant /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
grep -q 'a file that is not an entry of the archive: proj/.lake/build/planted.olean' "$TMPD/refused.out" && [ ! -e "$W27/extract" ] \
  && [ ! -e "$W27/extract.from" ] && [ -f "$W27/extract.partial/proj/.lake/build/planted.olean" ]
res "...names the file; no extract and no extract.from; the tree is left in extract.partial" $? "$(tailof "$TMPD/refused.out" 3)"
cenv RH_TARGET=fix-plant /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$T27/p.b" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'extracted tree: [0-9]* files under .*extract.partial' "$T27/p.b" && [ -f "$W27/extract.from" ] \
  && [ ! -e "$W27/extract/proj/.lake" ]
res "02 with the real tar: what it wrote is the listing's, and the tree is put in place" $? "status $rc: $(tailof "$T27/p.b" 3)"

# A pin left over from an earlier commit, and a clone made from another address
C_NEXT=$(branch next 100644 proj/src/B/D.lean 'def d : Nat := 2')
prof fix-pin; W27p="$NEW/work-fix-pin"
cenv RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh" > "$T27/s.a" 2>&1
H27=""; [ -f "$W27p/download/source.tar" ] && H27=$(sha "$W27p/download/source.tar")
prof fix-pin "TGT_TARBALL_SHA256=$H27"
cenv RH_TARGET=fix-pin /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$T27/s.b" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -n "$H27" ] && [ -d "$W27p/extract" ]; res "fix-pin: pinned, fetched and extracted" $? "status $rc: $(tailof "$T27/s.b")"
mv "$W27p/extract" "$T27/extract.first"
prof fix-pin "TGT_TARBALL_SHA256=$H27" "TGT_GIT_COMMIT=$C_NEXT"
refused "a pin left over from the first commit: 01 --check-only finds that the record names that commit (status 1)" \
  "DOES NOT NAME THIS FILE" RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
grep -q '^archive:  .*  ok$' "$TMPD/refused.out"; res "...although the file's SHA-256 is the pinned one" $? "$(tailof "$TMPD/refused.out" 4)"
refused "...and 02 does not extract the first commit's file as the second's" "is not known to be the archive" \
  RH_TARGET=fix-pin /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
[ ! -e "$W27p/extract" ]; res "...nothing was extracted" $?
cenv RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh" > "$T27/s.c" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q "commit $C_NEXT " "$W27p/download/source.tar.from"
res "01 writes the second commit's file: status 1 on the pin, and the record names the second commit" $? "status $rc: $(cat "$W27p/download/source.tar.from" 2>&1)"
refused "...and 02 stops on the pin" "tarball SHA-256 is" RH_TARGET=fix-pin /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
prof fix-pin "TGT_TARBALL_SHA256=$H27" "TGT_GIT_URL=$REPO/."
refused "a clone made from another address than the profile's: 01 stops" "was made from '$REPO'" \
  RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh"
refused "...and 01 --check-only says so (status 1)" "NOT MADE FROM THE PROFILE'S ADDRESS" RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
cenv RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh" --redownload > "$T27/s.d" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(cenv git --git-dir="$W27p/download/repo.git" config --get rhv.sourceurl)" = "$REPO/." ] \
  && [ "$(cat "$W27p/download/source.tar.from" 2>/dev/null)" = "$(record fix-pin "$H27")" ]
res "...01 --redownload clones from the profile's address, which the clone and the record then name" $? "status $rc: $(tailof "$T27/s.d")"

# ================================================================ 28
section 28 "headers tars read differently, HEAD files, export limits, overrides in child scripts, markers, globs"
T28="$TMPD/c28"; mkdir -p "$T28"
cenv "$PY3" -I -B - "$T28" <<'PY'
import gzip, io, os, sys, tarfile
out = sys.argv[1]
def hdr(name, size, typeflag=b"0", mode=0o644, sizefield=None):
    h = bytearray(512)
    h[0:len(name)] = name
    h[100:108] = b"%07o\0" % mode
    h[108:116] = b"0000000\0"; h[116:124] = b"0000000\0"
    h[124:136] = sizefield.ljust(12, b"\0") if sizefield is not None else b"%011o\0" % size
    h[136:148] = b"00000000000\0"
    h[148:156] = b"        "
    h[156:157] = typeflag
    h[257:265] = b"ustar\x0000"
    h[148:156] = b"%06o\0 " % sum(h)
    return bytes(h)
pad = lambda b: b + b"\0" * (-len(b) % 512)
reg = lambda name, data: hdr(name, len(data)) + pad(data)
def pax(records):
    body = b""
    for k, v in records:
        rec = b" " + k + b"=" + v + b"\n"
        d = 1
        while len(str(len(rec) + d)) != d:
            d += 1
        body += str(len(rec) + d).encode() + rec
    return hdr(b"PaxHeader/x", len(body), typeflag=b"x") + pad(body)
P = b"lean/"
base = reg(P + b"lakefile.toml", b'name = "t"\n') + reg(P + b"src/Main.lean", b"-- what the listing reads\n")
hidden = reg(P + b"src/Main.lean", b"-- what another tar would write\n")
# Each hides the entry 'hidden' from Python's tarfile where bsdtar reads it (the review's four vectors), or names
# a file HEAD; 'near' has names and a pax path that are fine.
vectors = {
    "pax_slash": base + pax([(b"path", P + b"foo/")]) + hdr(P + b"foo", len(hidden)) + hidden,
    "pax_size": base + pax([(b"size", b"1_025")]) + hdr(P + b"bar", 1) + pad(b"x") + hidden,
    "size_0o": base + hdr(P + b"bar", 0, sizefield=b"0o2000") + hidden,
    "size_us": base + hdr(P + b"bar", 0, sizefield=b"0_2000") + hidden,
    "sparse": base + pax([(b"size", b"1"), (b"GNU.sparse.realsize", b"1536")]) + hdr(P + b"bar", 1) + pad(b"x") + hidden,
    "head": base + reg(P + b"HEAD", b"ref: refs/heads/main\n") + reg(P + b"objects/x", b"x") + reg(P + b"refs/x", b"x"),
    "head_spelled": base + reg(P + b"src/hEaD.", b"x"),
    "near": base + reg(P + b"src/Head.lean", b"x") + reg(P + b"HEADER.md", b"x") + pax([(b"path", P + b"paxname.lean")])
            + reg(P + b"short", b"z"),
}
for name, body in vectors.items():
    data = body + b"\0" * 1024
    data += b"\0" * (-len(data) % 10240)
    with open(os.path.join(out, name + ".tar.gz"), "wb") as fh:
        fh.write(gzip.compress(data, mtime=0))
# Ordinary archives from Python's tarfile: pax (a long name, a name that is not ASCII) and GNU (a long name).
for fmt, nm in ((tarfile.PAX_FORMAT, "py_pax"), (tarfile.GNU_FORMAT, "py_gnu")):
    with tarfile.open(os.path.join(out, nm + ".tar"), "w", format=fmt, encoding="utf-8") as tf:
        for n in ("lean/lakefile.toml", "lean/src/" + "d" * 120 + "/B.lean", "lean/src/café.lean"):
            ti = tarfile.TarInfo(n); ti.mode = 0o644; ti.size = 2
            tf.addfile(ti, io.BytesIO(b"x\n"))
PY
TOOLS28="$NEW/scripts/verify/rhv_tools.py"
for c in "pax_slash|a pax path that ends with a slash" "pax_size|a pax size ('1_025') that not every tar reads as the same number" \
         "size_0o|a size in its header ('0o2000') that not every tar reads" "size_us|a size in its header ('0_2000') that not every tar reads" \
         "sparse|pax keys of a sparse file (GNU.sparse.realsize)" "head|a file named 'HEAD'" "head_spelled|a file named 'HEAD'"; do
  f=${c%%|*}; want=${c#*|}
  refused "tar-inspect refuses $f.tar.gz: $want" "$want" "$PY3" -I -B "$TOOLS28" tar-inspect "$T28/$f.tar.gz"
done
for f in near.tar.gz py_pax.tar py_gnu.tar; do
  cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T28/$f" > "$T28/$f.out" 2>&1; rc=$?
  [ "$rc" = 0 ]; res "tar-inspect accepts $f (Head.lean, HEADER.md, pax and GNU long names)" $? "status $rc: $(tailof "$T28/$f.out")"
done

# git-export: files named HEAD, and its limits
C_HEADF=$(branch headfile 100644 proj/HEAD 'ref: refs/heads/main')
C_HEADS=$(branch headspelled 100644 proj/src/hEaD. 'x')
for c in "headfile|$C_HEADF" "headspelled|$C_HEADS"; do
  refused "git-export refuses a file named HEAD ($(printf '%s' "${c%%|*}"))" "a file named 'HEAD'" \
    "$PY3" -I -B "$TOOLS28" git-export --git-dir "$REPO/.git" --commit "${c#*|}" --subdir proj --prefix proj/ --out "$T28/${c%%|*}.tar"
  [ ! -e "$T28/${c%%|*}.tar" ] && [ ! -e "$T28/${c%%|*}.tar.tmp" ]; res "...and writes nothing" $?
done
refused "git-export --max-files 2 refuses a commit with more files" "git-export stops at 2 (--max-files)" \
  "$PY3" -I -B "$TOOLS28" git-export --git-dir "$REPO/.git" --commit "$C_MAIN" --subdir proj --prefix proj/ --out "$T28/max.tar" --max-files 2
[ ! -e "$T28/max.tar" ] && [ ! -e "$T28/max.tar.tmp" ]; res "...and writes nothing" $?
refused "git-export --max-bytes 10 refuses a commit with more contents" "git-export stops at 10 (--max-bytes)" \
  "$PY3" -I -B "$TOOLS28" git-export --git-dir "$REPO/.git" --commit "$C_MAIN" --subdir proj --prefix proj/ --out "$T28/max.tar" --max-bytes 10
[ ! -e "$T28/max.tar" ] && [ ! -e "$T28/max.tar.tmp" ]; res "...and writes nothing" $?

# 02 with a tar that writes other bytes into a listed file (what the four header vectors make bsdtar do)
STUB28="$TMPD/stub28"; mkdir -p "$STUB28"; REALTAR=$(command -v tar)
cat > "$STUB28/tar" <<EOF
#!/bin/sh
# stand-in made by test_targets.sh: extracts with the real tar, then puts other bytes into a file the archive has
"$REALTAR" "\$@" || exit
for a; do last=\$a; done
printf -- '-- not what the listing read\n' > "\$last/proj/src/A.lean"
EOF
chmod +x "$STUB28/tar"
prof fix-subst; W28s="$NEW/work-fix-subst"
cenv RH_TARGET=fix-subst /bin/bash "$NEW/scripts/01_fetch.sh" > "$T28/sub.a" 2>&1; rc=$?
[ "$rc" = 0 ]; res "fix-subst: 01 writes the tar file" $? "status $rc: $(tailof "$T28/sub.a")"
refused "02 with a tar that changes a listed file's bytes: stops" "what tar extracted is not what the listing showed" \
  PATH="$STUB28:$CPATH" RH_TARGET=fix-subst /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
grep -q 'proj/src/A.lean' "$TMPD/refused.out" && [ ! -e "$W28s/extract" ] && [ ! -e "$W28s/extract.from" ] \
  && [ -f "$W28s/extract.partial/proj/src/A.lean" ]
res "...names the file; no extract and no extract.from; the tree is left in extract.partial" $? "$(tailof "$TMPD/refused.out" 4)"

# TGT_ values given in the environment reach the scripts that a script starts (reproduce_findings.sh runs 01)
t=$(cenv RH_TARGET=fix-git TGT_ROOT_MODULE=Env.Root /bin/bash -c '. "$1/scripts/lib.sh" && /bin/bash "$2" "$1/scripts/lib.sh" -- TGT_ROOT_MODULE' _ "$NEW" "$DUMP" 2>&1)
[ "$t" = "TGT_ROOT_MODULE=[Env.Root]" ]; res "a TGT_ value in the environment reaches a script started by a script of a non-default target" $? "$t"
# (A target with nothing extracted yet, pinned right in its profile: fix-git's commit, directory and prefix.)
prof fix-s1 "TGT_TARBALL_SHA256=$H1"
# The wrong value first: a run with the right one extracts a tree, which a later run with another pin refuses.
cenv RH_TARGET=fix-s1 "TGT_TARBALL_SHA256=$(printf '%064d' 5)" /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$T28/rf.b" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(row "$T28/rf.b" S1)" = FAIL ]
res "reproduce_findings.sh with a wrong TGT_TARBALL_SHA256 in the environment, which its 01 sees too: S1 fails, status 1" $? "status $rc: $(grep '^S1' "$T28/rf.b") $(tailof "$T28/rf.b" 2)"
cenv RH_TARGET=fix-s1 /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$T28/rf.a" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(row "$T28/rf.a" S1)" = PASS ]; res "...and with the profile's own, right, value: S1 passes" $? "status $rc: $(grep '^S1' "$T28/rf.a") $(tailof "$T28/rf.a" 2)"

# lib.sh checks TGT_GIT_SUBDIR before anything is fetched
for v in . ../x -x x/ /x a//b a/./b; do
  prof fix-bad "TGT_GIT_SUBDIR=$v"
  refused "TGT_GIT_SUBDIR '$v' is refused by lib.sh" "TGT_GIT_SUBDIR must be empty" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh"
done
[ ! -e "$NEW/work-fix-bad" ]; res "...and none of these left a working directory behind" $?

# The marker: empty, and a write that fails
W28m="$T28/wm"; mkdir -p "$W28m/logs"; : > "$W28m/.rh-target"
refused "an empty .rh-target: the scripts stop and say how to write the target's name into it" "is empty or cannot be read" \
  RH_WORKDIR="$W28m" /bin/bash "$NEW/scripts/06_progress.sh"
grep -q "printf '%s.n' alpoge-rh > $W28m/.rh-target" "$TMPD/refused.out"; res "...with the command that writes it" $? "$(tailof "$TMPD/refused.out" 2)"
W28c="$T28/wc"
cenv RH_WORKDIR="$W28c" /bin/bash -c 'trap "" XFSZ; ulimit -f 0; . "$1/scripts/lib.sh" && claim_workdir && echo claimed' _ "$NEW" 2>&1 | cat > "$T28/claim.out"
rc=${PIPESTATUS[0]}
[ "$rc" != 0 ] && grep -q 'could not write' "$T28/claim.out" && [ -d "$W28c" ] && [ ! -e "$W28c/.rh-target" ]
res "a marker that cannot be written (no room for it: ulimit -f 0): an error, and no empty .rh-target left behind" $? "status $rc: $(tailof "$T28/claim.out")"

# .gitignore: the working directories of other targets too
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cenv git -C "$ROOT" check-ignore -q --no-index work-fix-git/download/source.tar && cenv git -C "$ROOT" check-ignore -q --no-index work/x
  res ".gitignore covers work-<target name> as well as work" $?
else
  skip ".gitignore: $ROOT is not a git checkout"
fi

# A pin that does not match leaves no .sha256 file; a clone that records no address
prof fix-pm; W28p="$NEW/work-fix-pm"
cenv RH_TARGET=fix-pm /bin/bash "$NEW/scripts/01_fetch.sh" > "$T28/pm.a" 2>&1
[ -f "$W28p/download/source.tar.sha256" ]; res "fix-pm: unpinned, 01 writes source.tar.sha256" $? "$(tailof "$T28/pm.a")"
prof fix-pm "TGT_TARBALL_SHA256=$(printf '%064d' 7)"
cenv RH_TARGET=fix-pm /bin/bash "$NEW/scripts/01_fetch.sh" > "$T28/pm.b" 2>&1; rc=$?
[ "$rc" = 1 ] && [ -f "$W28p/download/source.tar" ] && [ -f "$W28p/download/source.tar.from" ] && [ ! -e "$W28p/download/source.tar.sha256" ]
res "pinned wrong: 01 stops (status 1), and no .sha256 file describes the tar file it wrote" $? "status $rc: $(ls "$W28p/download" 2>&1 | tr '\n' ' ')"
cenv git --git-dir="$W28p/download/repo.git" config --unset rhv.sourceurl
refused "01 --check-only with a clone that records no address says so" "DOES NOT RECORD THE ADDRESS IT WAS MADE FROM" \
  RH_TARGET=fix-pm /bin/bash "$NEW/scripts/01_fetch.sh" --check-only

# A repository that names its objects by SHA-256
R256="$FX/repo256"; mkdir -p "$R256"
if cenv git -C "$R256" init -q --object-format=sha256 . >/dev/null 2>&1; then
  mkproject "$R256/proj" src
  cenv GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 git -C "$R256" -c user.name=test -c user.email=test@example.com \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null add -A >/dev/null 2>&1
  cenv GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 git -C "$R256" -c user.name=test -c user.email=test@example.com \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m sha256 >/dev/null 2>&1
  C256=$(cenv git -C "$R256" rev-parse HEAD 2>/dev/null)
  prof fix-256 "TGT_GIT_URL=$R256" "TGT_GIT_COMMIT=$(printf '%s' "$C256" | cut -c1-40)"
  refused "a repository that names its objects by SHA-256 (the commit given by its first 40 characters): 01 stops" "not by SHA-1" \
    RH_TARGET=fix-256 /bin/bash "$NEW/scripts/01_fetch.sh"
  [ ! -e "$NEW/work-fix-256/download/source.tar" ]; res "...and writes no tar file" $?
  refused "...and 01 --check-only says so" "NOT SHA-1, WHICH IS NOT SUPPORTED" RH_TARGET=fix-256 /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
else
  skip "a SHA-256 repository: this git cannot make one"
fi

# 08 splits the theorem list on spaces but does not expand file patterns in it (it runs in the extracted tree)
: > "$W4/extract/proj/c_planted"
cenv RH_TARGET=fix-git "TGT_THEOREMS=a_thm c_*" /bin/bash "$NEW/scripts/08_check_axioms.sh" > "$T28/glob.out" 2>&1
fn=$(ls "$W4"/logs/axioms-full-*.lean 2>/dev/null | tail -n 1); fj="${fn%.lean}.json"
grep -q '^#print axioms c_\*$' "$fn" 2>/dev/null && ! grep -q 'c_planted' "$fn" \
  && jsonok "$fj" 'd["theorems"] and sorted(d["theorems"]) == ["a_thm", "c_*"]' 2>/dev/null
res "08 with TGT_THEOREMS 'a_thm c_*' and a file c_planted in the project: the name is used as written" $? "$(grep 'print axioms' "$fn" 2>&1 | tr '\n' ' ') $(tailof "$T28/glob.out" 2)"
rm -f "$W4/extract/proj/c_planted"
: > "$T28/empty.log"
cenv "$PY3" -I -B "$TOOLS28" axioms-summary --output "$T28/empty.log" --mode full --primary a_thm --theorem c_thm --lean-status 0 \
  --json "$T28/s.json" > "$T28/s.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'a_thm, the theorem whose statement is compared, is not one of the theorems checked' "$T28/s.out"
res "axioms-summary fails a record whose primary theorem is not among those checked" $? "status $rc: $(tailof "$T28/s.out")"

# Where 04 fetches and runs code from: printed for any target but the default one
cenv "$PY3" -I -B "$TOOLS28" project-info "$W4/extract/proj" --expected "$T28/none.json" --show-urls > "$T28/pi.a" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^where step 04 fetches and runs code from' "$T28/pi.a" && grep -q '^  toolchain  *leanprover/lean4$' "$T28/pi.a" \
  && grep -q '^  mathlib  *https://example.invalid/mathlib4$' "$T28/pi.a"
res "project-info --show-urls: the toolchain's origin and each package's address" $? "status $rc: $(tailof "$T28/pi.a" 3)"
P28="$T28/proj"; mkdir -p "$P28"; printf 'name = "x"\n' > "$P28/lakefile.toml"; echo 'evil/lean4:v4.33.1' > "$P28/lean-toolchain"
printf '{"version": "1.1.0", "packages": [{"name": "mathlib", "type": "git", "url": "https://attacker.example/m", "rev": "%s"}]}\n' "$MLREV" > "$P28/lake-manifest.json"
cenv "$PY3" -I -B "$TOOLS28" project-info "$P28" --expected "$T28/none.json" --show-urls > "$T28/pi.b" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^  toolchain  *evil/lean4   <- NOT leanprover/lean4$' "$T28/pi.b" && grep -q '^  mathlib  *https://attacker.example/m$' "$T28/pi.b"
res "...marks a toolchain that is not leanprover/lean4 (control characters and path packages: case 29)" $? "status $rc: $(tailof "$T28/pi.b" 4)"
grep -q '^  mathlib  *https://example.invalid/mathlib4$' "$TMPD/c4.h"; res "02 for target fix-git printed them (its first run, in case 4)" $? "$(tailof "$TMPD/c4.h" 4)"

# ================================================================ 29
section 29 "checksums, prefix fields, global and ACL headers, ._ files, huge sizes, unreadable files, export limits, markers"
T29="$TMPD/c29"; mkdir -p "$T29"
# within <seconds> <output file> <command...>: the command in the clean environment, stopped after that many seconds
# (its status is then 124)
within() {
  local s=$1 o=$2; shift 2
  cenv "$PY3" -I -B -c '
import subprocess, sys
try:
    with open(sys.argv[2], "wb") as out:
        sys.exit(subprocess.run(sys.argv[3:], stdout=out, stderr=subprocess.STDOUT, timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)' "$s" "$o" "$@"
}
cenv "$PY3" -I -B - "$T29" <<'PY'
import gzip, io, os, sys, tarfile
out = sys.argv[1]
def hdr(name, size, typeflag=b"0", mode=b"0000644\0", sizefield=None, cks=None, magic=b"ustar\x0000", prefix=b"", extra=()):
    h = bytearray(512)
    h[0:len(name)] = name
    h[100:108] = mode.ljust(8, b"\0")
    h[108:116] = b"0000000\0"; h[116:124] = b"0000000\0"
    h[124:136] = sizefield.ljust(12, b"\0") if sizefield is not None else b"%011o\0" % size
    h[136:148] = b"00000000000\0"
    h[148:156] = b"        "
    h[156:157] = typeflag
    h[257:265] = magic.ljust(8, b"\0")
    h[345:345 + len(prefix)] = prefix
    for at, b in extra:
        h[at:at + len(b)] = b
    s = sum(h)
    h[148:156] = cks(s, h) if cks else b"%06o\0 " % s
    assert len(h) == 512
    return bytes(h)
pad = lambda b: b + b"\0" * (-len(b) % 512)
reg = lambda name, data: hdr(name, len(data)) + pad(data)
def rec(k, v):
    r = b" " + k + b"=" + v + b"\n"
    d = 1
    while len(str(len(r) + d)) != d:
        d += 1
    return str(len(r) + d).encode() + r
def pax(records, typeflag=b"x"):
    body = b"".join(rec(k, v) for k, v in records)
    return hdr(b"PaxHeader/x", len(body), typeflag=typeflag) + pad(body)
# A pax header that gives a size of its own for its data, whatever the data holds
paxraw = lambda body, size: hdr(b"PaxHeader/x", size, typeflag=b"x") + pad(body)
longhdr = lambda n: hdr(b"././@LongLink", len(n) + 1, typeflag=b"L") + pad(n + b"\0")
huge = b"\x80" + (1 << 62).to_bytes(11, "big")
def underscore(s, h):
    d = b"%o" % s
    return (d[:1] + b"_" + d[1:] + b"\0").ljust(8, b" ")
signed = lambda s, h: b"%06o\0 " % (s - 256 * sum(1 for c in h if c > 127))
P = b"lean/"
base = reg(P + b"lakefile.toml", b'name = "t"\n') + reg(P + b"src/Main.lean", b"-- what the listing reads\n")
hidden = reg(P + b"src/Main.lean", b"-- what another tar would write\n")
longname = P + b"src/" + b"x" * 150 + b".lean"
vectors = {
    # checksums that Python's tarfile reads and libarchive does not: bsdtar skips the header and finds 'hidden'
    "cks_0o": base + hdr(P + b"bar", len(hidden), cks=lambda s, h: b"0o%05o\0" % s) + hidden,
    "cks_us": base + hdr(P + b"bar", len(hidden), cks=underscore) + hidden,
    "cks_tab": base + hdr(P + b"bar", len(hidden), cks=lambda s, h: b"\t%05o\0 " % s) + hidden,
    "cks_b256": base + hdr(P + b"bar", len(hidden), cks=lambda s, h: b"\x80" + s.to_bytes(7, "big")) + hidden,
    # name-prefix bytes in a header that is not POSIX ustar: tarfile reads lean/src/X.lean, bsdtar X.lean
    "prefix_gnu": base + hdr(b"X.lean", 2, magic=b"ustar  \0", prefix=b"lean/src") + pad(b"x\n"),
    "prefix_v7": base + hdr(b"X.lean", 2, magic=b"", prefix=b"lean/src") + pad(b"x\n"),
    "gpax_path": base + pax([(b"path", P + b"src/Main.lean")], typeflag=b"g") + reg(P + b"src/Other.lean", b"x")
                 + reg(P + b"src/Third.lean", b"y"),
    # a GNU long name whose header gives a size of 20: tarfile reads on to the NUL, other tars stop at 20 bytes
    "gnu_long_past": base + hdr(b"././@LongLink", 20, typeflag=b"L") + pad(longname + b"\0") + reg(b"placeholder", b"x\n"),
    "mode_us": base + hdr(P + b"src/M.lean", 2, mode=b"0_644\0") + pad(b"x\n"),
    "acl": base + pax([(b"SCHILY.acl.access", b"user::rw-,group::r--,other::rw-")]) + reg(P + b"src/Acl.lean", b"x"),
    "appledouble": base + reg(P + b"src/._Main.lean", b"\x00\x05\x16\x07"),
    # sizes far beyond the archive: one too large for every tar to read alike, one below 2**63, one in a pax header
    "b256_huge": base + hdr(P + b"src/Big.lean", 0, sizefield=b"\x80" + (1 << 80).to_bytes(11, "big")) + pad(b"x"),
    "b256_big": base + hdr(P + b"src/Big.lean", 0, sizefield=b"\x80" + (1 << 62).to_bytes(11, "big")) + pad(b"x"),
    "pax_huge": base + pax([(b"size", b"1" + b"0" * 30)]) + hdr(P + b"src/Big.lean", 1) + pad(b"x"),
    # accepted: a signed checksum (some old tars) of a header with bytes above 127
    "cks_signed": base + hdr(P + "src/café.lean".encode(), 2, cks=signed) + pad(b"x\n"),
    # pax records after the size the header gives, in the rest of its block: tarfile reads the second one (size
    # 2048), libarchive does not; and data within the size that is not whole records
    "pax_pad": base + paxraw(rec(b"mtime", b"1") + rec(b"size", b"2048"), len(rec(b"mtime", b"1")))
               + hdr(P + b"src/A2.lean", 0) + pad(b"x" * 2048),
    "pax_nul_in_size": base + paxraw(rec(b"mtime", b"1") + b"\0\0\0", len(rec(b"mtime", b"1")) + 3) + reg(P + b"src/G.lean", b"x"),
    # two extended headers of one kind before one entry: tarfile uses the first, bsdtar the last
    "two_L": base + longhdr(P + b"src/L0.lean") + longhdr(P + b"src/L1.lean") + reg(b"placeholder", b"x\n"),
    "two_x": base + pax([(b"path", P + b"src/X0.lean")]) + pax([(b"path", P + b"src/X1.lean")]) + reg(b"placeholder", b"x\n"),
    # accepted: a long name and a pax header before one entry
    "L_and_x": base + longhdr(longname) + pax([(b"mtime", b"1")]) + reg(b"placeholder", b"x\n"),
    # sparse entries, which tarfile would read as zero bytes up to the size they give, without reading the archive
    "sparse_S_hdr": base + hdr(P + b"src/S.lean", 0, typeflag=b"S", sizefield=huge) + pad(b"x"),
    "sparse_S_real": base + hdr(P + b"src/S.lean", 1, typeflag=b"S", extra=((386, b"%011o\0" % 0), (398, b"%011o\0" % 1), (483, huge)))
                     + pad(b"x"),
    "pax_sparse_real": base + pax([(b"GNU.sparse.map", b"0,1"), (b"GNU.sparse.realsize", b"1" + b"0" * 30)])
                       + hdr(P + b"src/S.lean", 1) + pad(b"x"),
    # an extended header whose size is far beyond the archive, followed by 8 MiB of zeros
    "pax_bomb": base + hdr(b"PaxHeader/x", 0, typeflag=b"x", sizefield=huge) + b"\0" * (8 << 20),
    # text from the archive that would move a terminal's cursor
    "acl_esc": base + pax([(b"SCHILY.acl.\x1b[2Kx", b"u")]) + reg(P + b"src/E.lean", b"x"),
    "name_esc": base + reg(P + b"src/A\x1b[2K.lean", b"x"),
}
for name, body in vectors.items():
    data = body + b"\0" * 1024
    data += b"\0" * (-len(data) % 10240)
    with open(os.path.join(out, name + ".tar.gz"), "wb") as fh:
        fh.write(gzip.compress(data, mtime=0))
# Accepted: Python's ustar format (a long name split into the prefix field) and a global header with a comment only
with tarfile.open(os.path.join(out, "py_ustar.tar"), "w", format=tarfile.USTAR_FORMAT) as tf:
    for n in ("lean/lakefile.toml", "lean/src/" + "d" * 120 + "/B.lean"):
        ti = tarfile.TarInfo(n); ti.mode = 0o644; ti.size = 2
        tf.addfile(ti, io.BytesIO(b"x\n"))
with tarfile.open(os.path.join(out, "py_gcomment.tar"), "w", format=tarfile.PAX_FORMAT, pax_headers={"comment": "x"}) as tf:
    for n in ("lean/lakefile.toml", "lean/src/A.lean"):
        ti = tarfile.TarInfo(n); ti.mode = 0o644; ti.size = 2
        tf.addfile(ti, io.BytesIO(b"x\n"))
# For --verify-tree: an archive, and the same cut short in the data of its last file
with tarfile.open(os.path.join(out, "vt.tar"), "w", format=tarfile.PAX_FORMAT) as tf:
    for n, size in (("lean/lakefile.toml", 11), ("lean/src/A.lean", 1000), ("lean/src/B.lean", 6000)):
        ti = tarfile.TarInfo(n); ti.mode = 0o644; ti.size = size
        tf.addfile(ti, io.BytesIO(b"y" * size))
data = open(os.path.join(out, "vt.tar"), "rb").read()
open(os.path.join(out, "vt_cut.tar"), "wb").write(data[:data.index(b"y" * 6000) + 3000])
# For --verify-tree with an entry the listing refuses (an executable bit)
with tarfile.open(os.path.join(out, "vt_exec.tar"), "w", format=tarfile.PAX_FORMAT) as tf:
    for n, mode in (("lean/lakefile.toml", 0o644), ("lean/src/A.lean", 0o755)):
        ti = tarfile.TarInfo(n); ti.mode = mode; ti.size = 600
        tf.addfile(ti, io.BytesIO(b"a" * 600))
PY
for c in "cks_0o|a header checksum ('0o" "cks_us|a header checksum ('" "cks_tab|a header checksum ('.t" "cks_b256|a header checksum ('" \
         "prefix_gnu|bytes where a POSIX header has its name prefix, in a header in GNU tar's format: Python's tarfile puts them in front of the name" \
         "prefix_v7|a header in neither POSIX ustar format nor GNU tar's" \
         "gpax_path|a global pax header that sets path" "gnu_long_past|a GNU long name (type L) that runs past the size" \
         "mode_us|a mode in its header ('0_644') that not every tar reads" "acl|pax keys of an access control list (SCHILY.acl.access)" \
         "appledouble|an AppleDouble file ('._' in front of the name): .* to the entry that follows it in the archive" \
         "pax_pad|bytes after the end of a pax header's data, in the rest of its block" \
         "pax_nul_in_size|a pax header whose data is not whole records" \
         "two_L|two extended headers of one kind (type L) before one entry" "two_x|two extended headers of one kind (type x) before one entry" \
         "acl_esc|pax keys of an access control list ('SCHILY.acl.\\\\x1b\[2Kx')" "name_esc|backslash or control character in name: 'lean/src/A\\\\x1b"; do
  f=${c%%|*}; want=${c#*|}
  refused "tar-inspect refuses $f.tar.gz: $want" "$want" "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/$f.tar.gz"
  [ "$f" = gpax_path ] && { [ "$(grep -c 'a global pax header' "$TMPD/refused.out")" = 1 ]; res "...said once, not for each entry after it" $? "$(grep 'global pax' "$TMPD/refused.out" | head -n 3 | tr '\n' ' ')"; }
  case $f in *_esc) ! LC_ALL=C grep -q "$(printf '\033')" "$TMPD/refused.out"; res "...with the archive's text escaped: no escape character reaches the terminal" $? ;; esac
done
for c in "cks_signed.tar.gz|a signed checksum of a header with bytes above 127" "py_ustar.tar|Python's ustar format, a long name in the prefix field" \
         "py_gcomment.tar|a global pax header with a comment only" "vt.tar|Python's pax format" \
         "L_and_x.tar.gz|a GNU long name and a pax header before one entry"; do
  f=${c%%|*}; cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/$f" > "$T29/$f.out" 2>&1; rc=$?
  [ "$rc" = 0 ]; res "tar-inspect accepts $f: ${c#*|}" $? "status $rc: $(tailof "$T29/$f.out")"
done
for c in "b256_huge|a size in its header" "b256_big|cannot be read to its end" "pax_huge|cannot be read to its end" \
         "sparse_S_hdr|a sparse entry (GNU tar's type S)" "sparse_S_real|a sparse entry (GNU tar's type S)" "pax_sparse_real|pax keys of a sparse file" \
         "pax_bomb|an extended header (type x) of 4611686018427387904 bytes; tar-inspect reads at most 524288"; do
  f=${c%%|*}; within 30 "$T29/$f.out" "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/$f.tar.gz"; rc=$?
  [ "$rc" = 1 ] && grep -q -- "${c#*|}" "$T29/$f.out"
  res "tar-inspect on $f.tar.gz (a size far beyond the archive) stops within 30 s, status 1: ${c#*|}" $? "status $rc: $(tailof "$T29/$f.out")"
done

# --verify-tree: a file on disk that cannot be read, and an archive that cannot be read to its end
X29="$T29/vt"; mkdir -p "$X29"; cenv tar -xf "$T29/vt.tar" -C "$X29"
cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/vt_cut.tar" --verify-tree "$X29" > "$T29/vtc.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'tree comparison: NOT FINISHED' "$T29/vtc.out" && ! grep -q 'byte-for-byte' "$T29/vtc.out"
res "--verify-tree with an archive cut short: NOT FINISHED, not byte-for-byte, status 1" $? "status $rc: $(tailof "$T29/vtc.out" 4)"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$X29/lean/src/A.lean"
  cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/vt.tar" --verify-tree "$X29" > "$T29/vtu.out" 2>&1; rc=$?
  chmod 644 "$X29/lean/src/A.lean"
  [ "$rc" = 1 ] && grep -q 'cannot be read on disk' "$T29/vtu.out" && grep -q 'files that cannot be read on disk: *1' "$T29/vtu.out" \
    && ! grep -q 'byte-for-byte' "$T29/vtu.out" && ! grep -q 'content differs: lean/src/A.lean' "$T29/vtu.out"
  res "--verify-tree with a file on disk that cannot be read: said so, not 'content differs', not byte-for-byte" $? "status $rc: $(tailof "$T29/vtu.out" 4)"
else
  skip "--verify-tree with a file that cannot be read: run as root, which reads any file"
fi
# --verify-tree: an entry the listing refuses is not compared, so the comparison is not finished
X29e="$T29/vte"; mkdir -p "$X29e"; cenv tar -xf "$T29/vt_exec.tar" -C "$X29e"; chmod 644 "$X29e/lean/src/A.lean"; printf 'other\n' > "$X29e/lean/src/A.lean"
cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/vt_exec.tar" --verify-tree "$X29e" > "$T29/vte.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'tree comparison: NOT FINISHED: 1 entries the listing refused were not compared' "$T29/vte.out" \
  && grep -q 'entries refused above, not compared: *1' "$T29/vte.out" && ! grep -q 'byte-for-byte' "$T29/vte.out"
res "--verify-tree with an entry the listing refused, and other bytes on disk: NOT FINISHED, not byte-for-byte" $? "status $rc: $(tailof "$T29/vte.out" 4)"
# --verify-tree: a directory of the tree that is a link, and one that cannot be read, are reported
X29s="$T29/vts"; mkdir -p "$X29s"; cenv tar -xf "$T29/vt.tar" -C "$X29s"
mv "$X29s/lean/src" "$T29/vts_src"; ln -s "$T29/vts_src" "$X29s/lean/src"; printf 'x\n' > "$T29/vts_src/Evil.lean"
cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/vt.tar" --verify-tree "$X29s" > "$T29/vts.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'not in tarball: lean/src (a symbolic link to a directory)' "$T29/vts.out" && grep -q 'tree comparison: DIFFERENT' "$T29/vts.out"
res "--verify-tree with lean/src a link to a directory outside the tree: reported, DIFFERENT" $? "status $rc: $(tailof "$T29/vts.out" 4)"
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$X29/lean/evil"; printf 'x\n' > "$X29/lean/evil/E.lean"; chmod 000 "$X29/lean/evil"
  cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/vt.tar" --verify-tree "$X29" > "$T29/vtd.out" 2>&1; rc=$?
  chmod 755 "$X29/lean/evil"
  [ "$rc" = 1 ] && grep -q 'directory cannot be listed on disk (Permission denied): lean/evil' "$T29/vtd.out" \
    && grep -q 'directories that cannot be listed: *1' "$T29/vtd.out" && grep -q 'tree comparison: DIFFERENT' "$T29/vtd.out"
  res "--verify-tree with a directory that cannot be read: reported, DIFFERENT" $? "status $rc: $(tailof "$T29/vtd.out" 4)"
else
  skip "--verify-tree with a directory that cannot be read: run as root, which reads any directory"
fi

# macOS's own tar: a file with an extended attribute gets a ._ file unless COPYFILE_DISABLE=1 is set
if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/tar ] && [ -x /usr/bin/xattr ]; then
  M29="$T29/mac"; mkdir -p "$M29/lean/src"; printf 'name = "m"\n' > "$M29/lean/lakefile.toml"; printf -- '-- m\n' > "$M29/lean/src/A.lean"
  /usr/bin/xattr -w user.rhv.test 1 "$M29/lean/src/A.lean"
  (cd "$M29" && cenv /usr/bin/tar -czf "$T29/mac_plain.tar.gz" lean/lakefile.toml lean/src/A.lean)
  refused "an archive macOS's tar made of a file with an extended attribute: refused, with what to do" "unless COPYFILE_DISABLE=1 is set" \
    "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/mac_plain.tar.gz"
  (cd "$M29" && cenv COPYFILE_DISABLE=1 /usr/bin/tar --format pax -czf "$T29/mac_cd.tar.gz" lean/lakefile.toml lean/src/A.lean)
  XM29="$T29/macx"; mkdir -p "$XM29"; cenv /usr/bin/tar -xzf "$T29/mac_cd.tar.gz" -C "$XM29"
  cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/mac_cd.tar.gz" --check-extracted "$XM29" --verify-tree "$XM29" > "$T29/mac_cd.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q 'byte-for-byte' "$T29/mac_cd.out"
  res "...and with COPYFILE_DISABLE=1 (pax format): accepted, and what macOS's tar extracts from it passes both checks" $? "status $rc: $(tailof "$T29/mac_cd.out" 4)"
else
  skip "macOS's tar and ._ files: not macOS"
fi

# git-export: directories counted, trees and commits not read past what the limits allow
E29=$(g mktree < /dev/null); t=$E29; i=0
while [ "$i" -lt 40 ]; do t=$(tree "040000 tree $t${TAB}a" "040000 tree $t${TAB}b"); i=$((i + 1)); done
C29b=$(g commit-tree "$(tree "040000 tree $t${TAB}proj")" -m bomb)
within 30 "$T29/bomb.out" "$PY3" -I -B "$TOOLS28" git-export --git-dir "$REPO/.git" --commit "$C29b" --subdir proj --prefix proj/ \
  --out "$T29/bomb.tar" --max-files 1000; rc=$?
[ "$rc" = 1 ] && grep -q 'more than 1000 entries, files and directories' "$T29/bomb.out" && [ ! -e "$T29/bomb.tar" ] && [ ! -e "$T29/bomb.tar.tmp" ]
res "git-export of 2^41 directories made of 42 objects, --max-files 1000: refused within 30 s, nothing written" $? "status $rc: $(tailof "$T29/bomb.out")"
B29=$(blob x)
big=$(i=0; while [ "$i" -lt 3000 ]; do printf '100644 blob %s\tf%05d.lean\n' "$B29" "$i"; i=$((i + 1)); done | g mktree)
C29t=$(g commit-tree "$(tree "040000 tree $big${TAB}proj")" -m wide)
refused "git-export --max-files 100 and a directory of 3000 files: refused before the tree is read" \
  "is 117000 bytes, more than the 100 entries still allowed can take (at most 284 bytes each): it has more entries than git-export reads (100 in all, --max-files), or a name longer than 255 bytes" \
  "$PY3" -I -B "$TOOLS28" git-export --git-dir "$REPO/.git" --commit "$C29t" --subdir proj --prefix proj/ --out "$T29/wide.tar" --max-files 100
cenv "$PY3" -I -B -c 'import sys; sys.stdout.write("x" * 1100000 + "\n")' > "$T29/msg"
C29c=$(g commit-tree "$C_MAIN^{tree}" -F "$T29/msg")
refused "git-export refuses a commit of more than 1 MiB before reading it" "bytes, and git-export reads at most 1048576 bytes of a commit" \
  "$PY3" -I -B "$TOOLS28" git-export --git-dir "$REPO/.git" --commit "$C29c" --subdir proj --prefix proj/ --out "$T29/bigc.tar"
long=$(tree "100644 blob $B29${TAB}$(printf '%0300d' 0 | tr 0 n).lean")
C29l=$(g commit-tree "$(tree "040000 tree $long${TAB}proj")" -m long)
refused "git-export --max-files 1 and one file with a name of 300 bytes: the reason given names the long name too" \
  "more than the 1 entries still allowed can take .*, or a name longer than 255 bytes" \
  "$PY3" -I -B "$TOOLS28" git-export --git-dir "$REPO/.git" --commit "$C29l" --subdir proj --prefix proj/ --out "$T29/long1.tar" --max-files 1
refused "...and with the default limit: a name longer than 255 bytes" "a name longer than 255 bytes (305)" \
  "$PY3" -I -B "$TOOLS28" git-export --git-dir "$REPO/.git" --commit "$C29l" --subdir proj --prefix proj/ --out "$T29/long2.tar"
[ ! -e "$T29/wide.tar" ] && [ ! -e "$T29/bigc.tar" ] && [ ! -e "$T29/long1.tar" ] && [ ! -e "$T29/long2.tar" ]; res "...and none of them wrote a tar file" $?

# lib.sh: no space in a git source's directory or prefix (the record that names the source is one line of words)
for v in "TGT_GIT_SUBDIR='a b'" "TGT_ARCHIVE_PREFIX='p q/'"; do
  prof fix-bad "$v"
  refused "lib.sh refuses $v" "may not contain a space" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh"
done
refused "lib.sh refuses a new line in TGT_GIT_URL (two sources could give one record)" "TGT_GIT_URL may hold printable ASCII characters only" \
  RH_TARGET=fix-git "TGT_GIT_URL=$(printf 'file:///x\ny')" /bin/bash "$NEW/scripts/01_fetch.sh"
[ ! -e "$NEW/work-fix-bad" ]; res "...and neither left a working directory behind" $?

# The marker: a directory with only another script's file for it, scripts started at once, the repair command
W29m="$T29/wonly"; mkdir -p "$W29m"; : > "$W29m/.rh-target.12345"
t=$(cenv RH_TARGET=fix-git RH_WORKDIR="$W29m" /bin/bash -c '. "$1/scripts/lib.sh" && claim_workdir && cat "$RH_WORKDIR/.rh-target"' _ "$NEW" 2>&1)
[ "$t" = fix-git ]; res "a working directory holding only another script's .rh-target.<number>: a non-default target claims it" $? "$t"
for tg in alpoge-rh fix-git; do
  W29l="$T29/wlink-$tg"; mkdir -p "$W29l"; ln -s "$T29/no-such-marker" "$W29l/.rh-target"
  refused "$tg: a .rh-target that is a symbolic link (to nothing): the scripts stop" "is a symbolic link; it must be a plain file" \
    RH_TARGET=$tg RH_WORKDIR="$W29l" /bin/bash -c '. "$1/scripts/lib.sh" && claim_workdir' _ "$NEW"
  [ ! -e "$T29/no-such-marker" ]; res "...and nothing was written through the link" $?
done
cat > "$T29/claim1.sh" <<'EOF'
# claim1.sh <lib.sh> <target> <working directory> <file to make when ready> <file to wait for> <file for failures>:
# one script that claims a working directory (sources lib.sh, says it is ready, waits, then calls claim_workdir)
RH_TARGET=$2 RH_WORKDIR=$3; export RH_TARGET RH_WORKDIR
. "$1" > /dev/null 2>&1 || { echo "$3: lib.sh failed" >> "$6"; exit 1; }
: > "$4"
while [ ! -e "$5" ]; do :; done
out=$( (claim_workdir) 2>&1 ) || echo "$3 (process $$): $out" >> "$6"
EOF
cat > "$T29/race.sh" <<'EOF'
# race.sh <claim1.sh> <lib.sh> <target> <rounds> <scripts> <dir>: in each round, that many scripts, each a process of
# its own, claim one new working directory <dir>/w<round> at the same moment
c1=$1 lib=$2 tgt=$3 rounds=$4 n=$5 d=$6 r=0
while [ "$r" -lt "$rounds" ]; do
  i=0
  while [ "$i" -lt "$n" ]; do
    /bin/bash "$c1" "$lib" "$tgt" "$d/w$r" "$d/ready.$r.$i" "$d/go.$r" "$d/fails" &
    i=$((i + 1))
  done
  while :; do set -- "$d"/ready.$r.*; [ "$#" -ge "$n" ] && [ -e "$1" ] && break; done
  : > "$d/go.$r"
  wait
  r=$((r + 1))
done
EOF
for tg in alpoge-rh fix-git; do
  RD="$T29/race-$tg"; mkdir -p "$RD"
  cenv /bin/bash "$T29/race.sh" "$T29/claim1.sh" "$NEW/scripts/lib.sh" "$tg" 40 12 "$RD" > "$RD.log" 2>&1
  bad=0; for w in "$RD"/w*; do [ "$(cat "$w/.rh-target" 2>/dev/null)" = "$tg" ] || bad=$((bad + 1)); done
  left=$(ls -A "$RD"/w* 2>/dev/null | grep -c '^\.rh-target\.')
  [ ! -s "$RD/fails" ] && [ "$bad" = 0 ] && [ "$left" = 0 ] && [ "$(ls -d "$RD"/w* | wc -l | tr -d ' ')" = 40 ]
  res "$tg: 12 scripts claiming one new working directory at once, 40 times: none stops, each marker names $tg, no file left over" $? \
    "$(head -n 3 "$RD/fails" 2>/dev/null | tr '\n' ' ' | cut -c1-300) bad markers: $bad, left over: $left"
done
W29q="$T29/w x'q"; mkdir -p "$W29q/logs"; : > "$W29q/.rh-target"
refused "an empty .rh-target in a directory whose name has a space and a quote: the scripts stop" "is empty or cannot be read" \
  RH_WORKDIR="$W29q" /bin/bash "$NEW/scripts/06_progress.sh"
cmd=$(sed -n "s/.*(\(printf '%s.n' alpoge-rh > .*\)) and run the command again.*/\1/p" "$TMPD/refused.out")
[ -n "$cmd" ] && cenv /bin/bash -c "$cmd" && [ "$(cat "$W29q/.rh-target")" = alpoge-rh ]
res "...and the command it prints writes the name into that file" $? "command: $cmd"
[ -z "$(ls -A "$W28c" | grep '^\.rh-target\.')" ]; res "the marker that could not be written (case 28) left no .rh-target.<number> behind" $? "$(ls -A "$W28c" | tr '\n' ' ')"
grep -q 'The file just written is kept at' "$T28/pm.b"; res "01 with a pin that does not match says the file it wrote is kept" $? "$(tailof "$T28/pm.b" 3)"

# project-info: values that are not plain printable text are escaped, and the run fails
P29="$T29/proj"; mkdir -p "$P29"; printf 'name = "x"\n' > "$P29/lakefile.toml"; printf 'leanprover/lean4:v4.33.1\033[2K\r\n' > "$P29/lean-toolchain"
printf '%s\n' '{"version": "1.1.0", "packages": [{"name": "ma\u001b[2Kth", "type": "git", "url": "https://example.invalid/m\r", "rev": "\u001b[31m0123"}]}' > "$P29/lake-manifest.json"
for opt in "" --show-urls; do
  # shellcheck disable=SC2086
  cenv "$PY3" -I -B "$TOOLS28" project-info "$P29" --expected "$T28/none.json" $opt > "$T29/pi$opt.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q "^REFUSED: 4 value(s) in the project files are missing, are not printable ASCII text, or have a space in them" "$T29/pi$opt.out" \
    && ! LC_ALL=C grep -q "$(printf '\033')" "$T29/pi$opt.out" && ! LC_ALL=C grep -q "$(printf '\r')" "$T29/pi$opt.out"
  res "project-info ${opt:-(without --show-urls)} with control characters in the toolchain, a name, an address and a revision: escaped, REFUSED, each value counted once, status 1" $? "status $rc: $(tailof "$T29/pi$opt.out" 3 | LC_ALL=C tr -d '\033\r')"
done
P29s="$T29/projs"; mkdir -p "$P29s"; printf 'name = "x"\n' > "$P29s/lakefile.toml"; echo 'leanprover/lean4:v4.33.1' > "$P29s/lean-toolchain"
printf '{"version": "1.1.0", "packages": [{"name": "local", "type": "path", "dir": "../my dir"}]}\n' > "$P29s/lake-manifest.json"
cenv "$PY3" -I -B "$TOOLS28" project-info "$P29s" --expected "$T28/none.json" --show-urls > "$T29/pis.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q "^  local  *path '../my dir'\$" "$T29/pis.out" \
  && grep -q "^REFUSED: lake-manifest.json: the package 'local' is a 'path' package: Lake runs the lakefile in its directory" "$T29/pis.out" \
  && ! grep -q 'REFUSED: [0-9]* value' "$T29/pis.out"
res "project-info --show-urls with a path package whose directory has a space: the directory shown quoted, the package refused" $? "status $rc: $(tailof "$T29/pis.out" 3)"
printf '{"version": "1.1.0", "packages": [{"name": "a b", "type": "git", "url": "https://example.invalid/m", "rev": "%s"}]}\n' "$MLREV" > "$P29s/lake-manifest.json"
refused "...but a package name with a space is refused" "^REFUSED: 1 value(s)" "$PY3" -I -B "$TOOLS28" project-info "$P29s" --expected "$T28/none.json" --show-urls

# 02 for a target other than the default one: not as root; and the project files are checked before the tree is in place
STUB29="$TMPD/stub29"; mkdir -p "$STUB29"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: says the user is root\nif [ "$1" = -u ]; then echo 0; else /usr/bin/id "$@"; fi\n' > "$STUB29/id"
chmod +x "$STUB29/id"
prof fix-root; W29r="$NEW/work-fix-root"
cenv RH_TARGET=fix-root /bin/bash "$NEW/scripts/01_fetch.sh" > "$T29/r.a" 2>&1
refused "fix-root: 02 run as root stops before extracting" "does not extract the archive of target 'fix-root' as root" \
  PATH="$STUB29:$CPATH" RH_TARGET=fix-root /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
[ ! -e "$W29r/extract" ] && [ ! -e "$W29r/extract.partial" ]; res "...and nothing was extracted" $?
prof fix-pi; W29p="$NEW/work-fix-pi"
cenv RH_TARGET=fix-pi /bin/bash "$NEW/scripts/01_fetch.sh" > "$T29/q.a" 2>&1
mkdir -p "$NEW/targets/fix-pi/records"; printf '{"project": {"lean_toolchain": "leanprover/lean4:v0.0.0"}}\n' > "$NEW/targets/fix-pi/records/expected.json"
prof fix-pi "TGT_RECORDS_DIR=targets/fix-pi/records"
refused "fix-pi: 02 with project files that do not match the records stops" "the project files were refused, or do not match what was expected" \
  RH_TARGET=fix-pi /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
[ ! -e "$W29p/extract" ] && [ ! -e "$W29p/extract.from" ] && [ -d "$W29p/extract.partial" ]
res "...before the tree is put in place: no extract, no extract.from, the tree left in extract.partial" $? "$(tailof "$TMPD/refused.out" 3)"

# ================================================================ 30
section 30 "header formats and fields, sparse and Solaris entries, header chains, names, project files, markers, addresses"
T30="$TMPD/c30"; mkdir -p "$T30"
cenv "$PY3" -I -B - "$T30" "$MLREV" <<'PY30'
import gzip, json, os, sys
out, mlrev = sys.argv[1], sys.argv[2]
def hdr(name, size, typeflag=b"0", magic=b"ustar\x0000", extra=()):
    h = bytearray(512)
    h[0:len(name)] = name
    h[100:108] = b"0000644\0"; h[108:116] = b"0000000\0"; h[116:124] = b"0000000\0"
    h[124:136] = b"%011o\0" % size
    h[136:148] = b"00000000000\0"
    h[148:156] = b"        "
    h[156:157] = typeflag
    h[257:265] = magic.ljust(8, b"\0")
    for at, b in extra:
        h[at:at + len(b)] = b
    h[148:156] = b"%06o\0 " % sum(h)
    assert len(h) == 512
    return bytes(h)
pad = lambda b: b + b"\0" * (-len(b) % 512)
reg = lambda name, data, **k: hdr(name, len(data), **k) + pad(data)
def rec(k, v):
    r = b" " + k + b"=" + v + b"\n"
    d = 1
    while len(str(len(r) + d)) != d:
        d += 1
    return str(len(r) + d).encode() + r
def pax(records, typeflag=b"x"):
    body = b"".join(rec(k, v) for k, v in records)
    return hdr(b"PaxHeader/x", len(body), typeflag=typeflag) + pad(body)
longhdr = lambda n: hdr(b"././@LongLink", len(n) + 1, typeflag=b"L") + pad(n + b"\0")
P = b"lean/"
base = reg(P + b"lakefile.toml", b'name = "t"\n') + reg(P + b"src/Main.lean", b"-- m\n")
comment = pax([(b"comment", b"x")], typeflag=b"g")
vectors = {
    # number fields that not every tar reads as the same number
    "uid_tab": base + reg(P + b"src/U.lean", b"x", extra=((108, b"\t000000\0"),)),
    "mtime_nl": base + reg(P + b"src/T.lean", b"x", extra=((136, b"0000000000\n\0"),)),
    "devminor_us": base + reg(P + b"src/D.lean", b"x", extra=((337, b"0_00000\0"),)),
    # text fields with a control character, or with bytes after the NUL that ends them
    "name_junk": base + reg(P + b"src/N.lean\0junk", b"x"),
    "linkname_junk": base + reg(P + b"src/K.lean", b"x", extra=((157, b"\0abc"),)),
    "uname_esc": base + reg(P + b"src/O.lean", b"x", extra=((265, b"r\x1b[2Koot\0"),)),
    # the v7 format, whose headers have no mark of their format
    "v7": reg(P + b"lakefile.toml", b'name = "t"\n', magic=b"") + reg(P + b"src/Main.lean", b"-- m\n", magic=b""),
    # a first header that begins as a bzip2 stream does
    "bzip2_first": reg(b"BZh91AY&SY" + b"x" * 20, b"x") + base,
    # extended headers in a row: eight global comments are read, nine are not; 250 long names stop at once
    "g8": base + comment * 8 + reg(P + b"src/G.lean", b"x"),
    "g9": base + comment * 9 + reg(P + b"src/G.lean", b"x"),
    "L250": base + b"".join(longhdr(P + b"src/L%05d.lean" % i) for i in range(250)) + reg(b"placeholder", b"x"),
    # sparse files in pax form: a version 1.0 map that claims a billion pieces, a map that is not numbers, and the
    # key star and bsdtar use
    "sparse10": base + pax([(b"GNU.sparse.major", b"1"), (b"GNU.sparse.minor", b"0"), (b"GNU.sparse.name", P + b"src/S.lean"),
                            (b"GNU.sparse.realsize", b"1")]) + reg(b"GNUSparseFile.0/S.lean", b"999999999\n0\n0\n"),
    "sparse01_bad": base + pax([(b"GNU.sparse.map", b"0,1,a"), (b"GNU.sparse.realsize", b"1")]) + reg(P + b"src/S.lean", b"x"),
    "realsize": base + pax([(b"SCHILY.realsize", b"1" + b"0" * 20)]) + reg(P + b"src/S.lean", b"x"),
    # Solaris's holes, which bsdtar makes and tarfile does not
    "sun_holes": base + pax([(b"SUN.holesdata", b" 0 1 4 8")]) + reg(P + b"src/H.lean", b"x" * 12),
    "not_utf8": base + reg(P + b"src/\xff\xfe.lean", b"x"),
    # twenty pax headers of about 500 KB each, each of many records
    "pax20": base + b"".join(pax([(b"comment", b"x" * 10)] * 23000) + reg(P + b"src/P%02d.lean" % i, b"x") for i in range(20)),
}
for name, body in vectors.items():
    data = body + b"\0" * 1024
    data += b"\0" * (-len(data) % 10240)
    if name in ("v7", "bzip2_first"):
        with open(os.path.join(out, name + ".tar"), "wb") as fh:
            fh.write(data)
    else:
        with open(os.path.join(out, name + ".tar.gz"), "wb") as fh:
            fh.write(gzip.compress(data, mtime=0))
# Project files
def project(name, m):
    d = os.path.join(out, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "lakefile.toml"), "w") as fh:
        fh.write('name = "x"\n')
    with open(os.path.join(d, "lean-toolchain"), "w") as fh:
        fh.write("leanprover/lean4:v4.33.1\n")
    with open(os.path.join(d, "lake-manifest.json"), "w") as fh:
        fh.write(m if isinstance(m, str) else json.dumps(m if "version" in m else dict(m, version="1.1.0")))
git = lambda name, url="https://example.invalid/m": {"name": name, "type": "git", "url": url, "rev": mlrev}
project("pi_blank", {"packages": [git("⠀")]})
project("pi_homoglyph", {"packages": [git("mathlib", "https://gіthub.com/m")]})
project("pi_nourl", {"packages": [{"name": "mathlib", "type": "git", "rev": mlrev}]})
project("pi_v6", {"version": 6, "packages": [{"git": {"name": "mathlib", "url": "https://example.invalid/m6", "rev": mlrev}}]})
project("pi_shape1", "[]")
project("pi_shape2", '{"packages": {}}')
project("pi_shape3", '{"packages": [1]}')
project("pi_tabs", {"packages": [git("a\tb%05d" % i) for i in range(20000)]})
PY30
for c in "v7.tar|a header in neither POSIX ustar format nor GNU tar's (its magic and version are" \
         "uid_tab.tar.gz|a user id in its header ('\\\\t000000') that not every tar reads as the same number" \
         "mtime_nl.tar.gz|a time in its header ('0000000000\\\\n') that not every tar reads as the same number" \
         "devminor_us.tar.gz|a device minor number in its header ('0_00000') that not every tar reads as the same number" \
         "name_junk.tar.gz|a name field in a header with a control character in it, or bytes after the NUL that ends it" \
         "linkname_junk.tar.gz|a link name field in a header with a control character in it, or bytes after the NUL" \
         "uname_esc.tar.gz|a user name field in a header with a control character in it" \
         "bzip2_first.tar|a first header that begins as a bzip2, xz or zstd stream does" \
         "g9.tar.gz|more than 8 extended headers (pax headers and GNU long names) in a row" "L250.tar.gz|extended headers" \
         "sparse10.tar.gz|pax keys of a sparse file" "sparse01_bad.tar.gz|pax keys of a sparse file" \
         "realsize.tar.gz|pax keys of a sparse file (SCHILY.realsize)" \
         "sun_holes.tar.gz|pax keys of Solaris's tar (SUN.holesdata), which bsdtar applies and Python's tarfile does not" \
         "not_utf8.tar.gz|a name that is not UTF-8"; do
  f=${c%%|*}; want=${c#*|}
  within 30 "$T30/$f.out" "$PY3" -I -B "$TOOLS28" tar-inspect "$T30/$f"; rc=$?
  [ "$rc" = 1 ] && grep -q -- "$want" "$T30/$f.out" && ! grep -q Traceback "$T30/$f.out" && ! LC_ALL=C grep -q "$(printf '\033')" "$T30/$f.out"
  res "tar-inspect refuses $f within 30 s, status 1, no traceback, nothing unescaped: $want" $? "status $rc: $(tailof "$T30/$f.out")"
done
for c in "g8.tar.gz|8 global pax headers with a comment only" "pax20.tar.gz|20 pax headers of about 500 KB each"; do
  f=${c%%|*}; within 30 "$T30/$f.out" "$PY3" -I -B "$TOOLS28" tar-inspect "$T30/$f"; rc=$?
  [ "$rc" = 0 ]; res "tar-inspect accepts $f within 30 s: ${c#*|}" $? "status $rc: $(tailof "$T30/$f.out")"
done
grep -q 'a size in its header (0x800100000000000000000000) that not every tar reads as the same number' "$T29/b256_huge.out"
res "a size in base 256 (2^80, case 29) is shown in hexadecimal" $? "$(tailof "$T29/b256_huge.out")"
X30="$T30/vtx"; mkdir -p "$X30"; cenv tar -xf "$T29/vt.tar" -C "$X30"; printf 'x\n' > "$X30/lean/src/A$(printf '\033')[2K.lean"
cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/vt.tar" --check-extracted "$X30" > "$T30/cx.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q -F "a file that is not an entry of the archive: 'lean/src/A\\x1b[2K.lean'" "$T30/cx.out" \
  && ! LC_ALL=C grep -q "$(printf '\033')" "$T30/cx.out"
res "--check-extracted with a file on disk whose name has an escape character: named, escaped, status 1" $? "status $rc: $(tailof "$T30/cx.out" 3)"
if [ "$(id -u)" != 0 ]; then
  X30u="$T30/vtu"; mkdir -p "$X30u"; cenv tar -xf "$T29/vt.tar" -C "$X30u"; chmod 644 "$X30u/lean/src"
  cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T29/vt.tar" --verify-tree "$X30u" > "$T30/vtu.out" 2>&1; rc=$?
  chmod 755 "$X30u/lean/src"
  [ "$rc" = 1 ] && grep -q 'cannot be read on disk (Permission denied): lean/src/A.lean' "$T30/vtu.out" && ! grep -q 'missing on disk.*: lean/' "$T30/vtu.out" \
    && grep -q 'files that cannot be read on disk: *2' "$T30/vtu.out" && ! grep -q 'byte-for-byte' "$T30/vtu.out"
  res "--verify-tree with a directory it can list and not search: its files 'cannot be read on disk', not missing, not byte-for-byte" $? "status $rc: $(tailof "$T30/vtu.out" 4)"
else
  skip "--verify-tree with a directory that cannot be searched: run as root, which searches any directory"
fi

# project-info: values that look like others or like nothing, missing values, other shapes, many values
for opt in "" --show-urls; do
  for c in "pi_blank|a package name that is U+2800, which looks blank" "pi_homoglyph|an address whose host has a Cyrillic i (U+0456) in it" \
           "pi_nourl|a git package with no address"; do
    f=${c%%|*}
    [ "$f$opt" = pi_nourl ] && continue     # a missing address is refused when the addresses are listed
    # shellcheck disable=SC2086
    cenv "$PY3" -I -B "$TOOLS28" project-info "$T30/$f" --expected "$T28/none.json" $opt > "$T30/$f$opt.out" 2>&1; rc=$?
    [ "$rc" = 1 ] && grep -q '^REFUSED: 1 value(s) in the project files are missing, are not printable ASCII text, or have a space in them' "$T30/$f$opt.out" \
      && { [ -n "$opt" ] || [ "$f" = pi_blank ] || grep -q '^addresses and directories refused (--show-urls lists every one):$' "$T30/$f$opt.out"; }
    res "project-info ${opt:-(without --show-urls)} refuses ${c#*|}: status 1, the value printed escaped" $? "status $rc: $(tailof "$T30/$f$opt.out" 3)"
  done
done
cenv "$PY3" -I -B "$TOOLS28" project-info "$T30/pi_v6" --expected "$T28/none.json" --show-urls > "$T30/pi_v6.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^  mathlib  *https://example.invalid/m6$' "$T30/pi_v6.out"
res "project-info --show-urls reads a package in the form Lake wrote before manifest version 7 and shows its address" $? "status $rc: $(tailof "$T30/pi_v6.out" 3)"
for f in pi_shape1 pi_shape2 pi_shape3; do
  cenv "$PY3" -I -B "$TOOLS28" project-info "$T30/$f" --expected "$T28/none.json" > "$T30/$f.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q '^REFUSED: lake-manifest.json is not an object whose "packages" is a list of objects' "$T30/$f.out" && ! grep -q Traceback "$T30/$f.out"
  res "project-info refuses a manifest of another shape ($(head -c 40 "$T30/$f/lake-manifest.json")): status 1, no traceback" $? "status $rc: $(tailof "$T30/$f.out" 3)"
done
within 30 "$T30/pi_tabs.out" "$PY3" -I -B "$TOOLS28" project-info "$T30/pi_tabs" --expected "$T28/none.json"; rc=$?
[ "$rc" = 1 ] && grep -q '^REFUSED: 20000 value(s)' "$T30/pi_tabs.out"
res "project-info with 20,000 package names with a tab: refused within 30 s, each counted" $? "status $rc: $(tailof "$T30/pi_tabs.out" 2)"

# lib.sh: a marker that is a link or a directory; addresses with characters outside printable ASCII
W30k="$T30/wlink"; mkdir -p "$W30k"; printf 'fix-git\n' > "$T30/other-marker"; ln -s "$T30/other-marker" "$W30k/.rh-target"
refused "a .rh-target that is a link to another directory's marker: the scripts stop and say how to put a plain file in its place" \
  "Remove the link and write the file in its place" RH_WORKDIR="$W30k" /bin/bash -c '. "$1/scripts/lib.sh" && claim_workdir' _ "$NEW"
cmd=$(sed -n 's/.*(\(rm -- .*\)), then run the command again.*/\1/p' "$TMPD/refused.out" | sed 's/<target>/alpoge-rh/')
[ -n "$cmd" ] && cenv /bin/bash -c "$cmd" && [ ! -L "$W30k/.rh-target" ] && [ "$(cat "$W30k/.rh-target")" = alpoge-rh ] \
  && [ "$(cat "$T30/other-marker")" = fix-git ] && cenv RH_WORKDIR="$W30k" /bin/bash -c '. "$1/scripts/lib.sh" && claim_workdir' _ "$NEW" > /dev/null 2>&1
res "...and the command it prints, with the target named, puts a plain file in place, leaves the other marker as it was, and the scripts go on" $? "command: $cmd"
W30d="$T30/wdir"; mkdir -p "$W30d/.rh-target"
refused "a .rh-target that is a directory: the scripts stop" "is not a plain file (it is a directory, or another kind of file)" \
  RH_TARGET=fix-git RH_WORKDIR="$W30d" /bin/bash -c '. "$1/scripts/lib.sh" && claim_workdir' _ "$NEW"
U8=$(locale -a 2>/dev/null | grep -i -E -m 1 '^(C|en_US)\.utf-?8$')
for loc in C $U8; do
  for u in "$(printf 'file:///x\302\205y')" "$(printf 'file:///g\321\226thub')" "$(printf 'file:///x\ty')"; do
    refused "lib.sh, LC_ALL=$loc, refuses TGT_GIT_URL $(printf '%q' "$u" | LC_ALL=C tr -c '[:print:]' '?')" "TGT_GIT_URL may hold printable ASCII characters only" \
      LC_ALL=$loc RH_TARGET=fix-git "TGT_GIT_URL=$u" /bin/bash "$NEW/scripts/01_fetch.sh"
  done
done
[ -n "$U8" ] || skip "lib.sh and TGT_GIT_URL in a UTF-8 locale: none installed"
if [ -n "$U8" ] && ! cenv PATH="$P20" /bin/sh -c 'command -v elan || command -v lake' > /dev/null 2>&1; then
  W30t="$T30/w00"; mkdir -p "$W30t/extract/lean"; printf 'alpoge-rh\n' > "$W30t/.rh-target"
  printf 'leanprover/lean4:v4.33.1\342\200\256\033[2K\377\n' > "$W30t/extract/lean/lean-toolchain"
  cenv PATH="$P20" LC_ALL="$U8" RH_WORKDIR="$W30t" /bin/bash "$NEW/scripts/00_check_prereqs.sh" > "$T30/p00.out" 2>&1
  grep -q -x -F '  pinned toolchain (from the extracted project): leanprover/lean4:v4.33.1????[2K?' "$T30/p00.out" && ! LC_ALL=C grep -q "$(printf '\033')" "$T30/p00.out"
  res "00, LC_ALL=$U8, shows the archive's toolchain line with '?' for each byte that is not printable ASCII" $? "$(grep 'pinned toolchain' "$T30/p00.out" | LC_ALL=C tr -c '[:print:]\n' '?')"
else
  skip "00 and the toolchain line in a UTF-8 locale: no UTF-8 locale, or an elan or lake on the narrower PATH"
fi
if ! cenv PATH="$P20" /bin/sh -c 'command -v elan || command -v lake' > /dev/null 2>&1; then
  W30r="$T30/w00crlf"; mkdir -p "$W30r/extract/lean"; printf 'alpoge-rh\n' > "$W30r/.rh-target"
  printf 'leanprover/lean4:v4.33.1\r\n' > "$W30r/extract/lean/lean-toolchain"
  cenv PATH="$P20" RH_WORKDIR="$W30r" /bin/bash "$NEW/scripts/00_check_prereqs.sh" > "$T30/p00crlf.out" 2>&1
  grep -q -x -F '  pinned toolchain (from the extracted project): leanprover/lean4:v4.33.1' "$T30/p00crlf.out"
  res "00 shows a toolchain line that ends with CRLF as the line alone, with no '?' for the CR" $? "$(grep 'pinned toolchain' "$T30/p00crlf.out" | LC_ALL=C tr -c '[:print:]\n' '?')"
else
  skip "00 and a toolchain line with CRLF: an elan or lake on the narrower PATH"
fi

# git-export at its default limits
within 60 "$T30/bomb.out" "$PY3" -I -B "$TOOLS28" git-export --git-dir "$REPO/.git" --commit "$C29b" --subdir proj --prefix proj/ --out "$T30/bomb.tar"; rc=$?
[ "$rc" = 1 ] && grep -q -E 'more than 2000000 entries|more than 268435456 bytes' "$T30/bomb.out" && [ ! -e "$T30/bomb.tar" ] && [ ! -e "$T30/bomb.tar.tmp" ]
res "git-export of 2^41 directories made of 42 objects, at its default limits: refused within 60 s, nothing written" $? "status $rc: $(tailof "$T30/bomb.out")"
cenv "$PY3" -I -B "$TOOLS28" git-export --git-dir "$REPO/.git" --commit "$C29l" --subdir proj --prefix proj/ --out "$T30/long.tar" > "$T30/long.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'a name longer than 255 bytes (305) .*n\{200\}\.\.\.' "$T30/long.out" && [ ! -e "$T30/long.tar" ]
res "git-export's message for a name of 305 bytes shows its first 200" $? "status $rc: $(tailof "$T30/long.out" | cut -c1-200)"

# ================================================================ 31
section 31 "GNU header tails, times before 1970, empty archives, gzip members, Unicode forms on disk, manifest forms, names and paths, Mathlib pins, lakefile limits and Lean options, libraries outside the sources, 04's own check, 00's sizes"
T31="$TMPD/c31"; mkdir -p "$T31"
cenv "$PY3" -I -B - "$T31" "$MLREV" <<'PY31'
import gzip, io, json, os, sys, tarfile
out, mlrev = sys.argv[1], sys.argv[2]
def hdr(name, size, typeflag=b"0", magic=b"ustar  \0", extra=()):
    h = bytearray(512)
    h[0:len(name)] = name
    h[100:108] = b"0000644\0"; h[108:116] = b"0000000\0"; h[116:124] = b"0000000\0"
    h[124:136] = b"%011o\0" % size
    h[136:148] = b"00000000000\0"
    h[148:156] = b"        "
    h[156:157] = typeflag
    h[257:265] = magic.ljust(8, b"\0")
    for at, b in extra:
        h[at:at + len(b)] = b
    h[148:156] = b"%06o\0 " % sum(h)
    assert len(h) == 512
    return bytes(h)
pad = lambda b: b + b"\0" * (-len(b) % 512)
reg = lambda name, data, **k: hdr(name, len(data), **k) + pad(data)
end = lambda b: b + b"\0" * 1024 + b"\0" * (-(len(b) + 1024) % 10240)
P = b"lean/"
base = reg(P + b"lakefile.toml", b'name = "t"\n') + reg(P + b"src/Main.lean", b"-- m\n")
# Headers in GNU tar's format (the magic above) with bytes where a POSIX header has its name prefix: bsdtar reads
# GNU tar's access time, old sparse map, isextended flag and real size there, for an entry of any kind
tars = {
    "gnu_atime": base + reg(P + b"src/A.lean", b"x", extra=((345, b"14000000000\0"),)),
    "gnu_sparsemap": base + reg(P + b"src/S.lean", b"x", extra=((386, b"00000000000\0" b"00000000001\0"),)),
    "gnu_isextended": base + reg(P + b"src/E.lean", b"x", extra=((482, b"\x01"),)),
    "gnu_realsize": base + reg(P + b"src/R.lean", b"x", extra=((483, b"77777777777\0"),)),
    # a time in base 256 below -2^63
    "t_neg_huge": base + reg(P + b"src/T.lean", b"x", extra=((136, b"\xff" + b"\0" * 11),)),
    "empty": b"",
}
for name, body in tars.items():
    with open(os.path.join(out, name + ".tar"), "wb") as fh:
        fh.write(end(body))
# Times before 1970, as Python writes them: in base 256 in GNU's format, in a pax record in pax format
for fmt, label in ((tarfile.GNU_FORMAT, "gnu"), (tarfile.PAX_FORMAT, "pax")):
    with tarfile.open(os.path.join(out, "t1960_%s.tar" % label), "w", format=fmt) as tf:
        for n in ("lean/lakefile.toml", "lean/src/A.lean"):
            ti = tarfile.TarInfo(n); ti.mode = 0o644; ti.size = 2; ti.mtime = -315619200
            tf.addfile(ti, io.BytesIO(b"x\n"))
# gzip members: two that hold one archive; zero bytes between them; zero bytes after the last; a reserved flag set
# (in the first member or the second); bytes after the last that are not a member
data = end(base)
m1, m2 = gzip.compress(data[:1024], mtime=0), gzip.compress(data[1024:], mtime=0)
flag = lambda m: m[:3] + bytes([m[3] | 0x20]) + m[4:]
gz = {"gz_two": m1 + m2, "gz_zeropad": m1 + b"\0" * 16 + m2, "gz_zerotail": m1 + m2 + b"\0" * 512,
      "gz_flag_first": flag(m1) + m2, "gz_flag_second": m1 + flag(m2), "gz_junk": m1 + m2 + b"junk"}
for name, body in gz.items():
    with open(os.path.join(out, name + ".tar.gz"), "wb") as fh:
        fh.write(body)
# A name in NFC, for the tree a tar writes on a file system that may store it in NFD
with tarfile.open(os.path.join(out, "nfc.tar"), "w", format=tarfile.PAX_FORMAT) as tf:
    for n in ("lean/lakefile.toml", "lean/src/Caf\u00e9.lean"):
        ti = tarfile.TarInfo(n); ti.mode = 0o644; ti.size = 2
        tf.addfile(ti, io.BytesIO(b"x\n"))
# Project files: a lakefile and a manifest in the forms the default target's have, then one change in each case
LAKEFILE = '''name = "tree"
version = "0.1.0"
srcDir = "src"
defaultTargets = ["Statements", "Main"]
moreLeanArgs = ["--tstack=400000"]

[leanOptions]
pp.unicode.fun = true
autoImplicit = false
maxHeartbeats = 4000000

[[require]]
name = "mathlib"
git = "https://example.invalid/mathlib4"
rev = "%s"

[[lean_lib]]
name = "Formalism"
globs = ["Formalism.+"]
leanOptions = {synthInstance.maxHeartbeats = 400000}

[[lean_lib]]
name = "Statements"
roots = ["Statements", "Main"]
''' % mlrev
def pkg(name, inherited=False, cfg="lakefile.toml", **k):
    p = {"url": "https://example.invalid/" + name.strip("\u00ab\u00bb"), "type": "git", "subDir": None, "scope": "",
         "rev": mlrev, "name": name, "manifestFile": "lake-manifest.json", "inputRev": "main", "inherited": inherited,
         "configFile": cfg}
    p.update(k)
    return p
def manifest(packages=None, **k):
    m = {"version": "1.2.0", "packagesDir": ".lake/packages",
         "packages": packages if packages is not None else [pkg("mathlib", cfg="lakefile.lean"), pkg("plausible", True)],
         "name": "tree", "lakeDir": ".lake"}
    m.update(k)
    return m
def project(name, m=None, lakefile=LAKEFILE, toolchain="leanprover/lean4:v4.33.1\n"):
    d = os.path.join(out, name)
    os.makedirs(d, exist_ok=True)
    m = manifest() if m is None else m
    m = m if isinstance(m, (str, bytes)) else json.dumps(m, indent=2)
    for f, v in (("lakefile.toml", lakefile), ("lean-toolchain", toolchain), ("lake-manifest.json", m)):
        with open(os.path.join(d, f), "wb") as fh:
            fh.write(v if isinstance(v, bytes) else v.encode("utf-8"))
G = lambda s: "\u00ab" + s + "\u00bb"
project("ok")
project("guillemets", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg(G("doc-gen4"))]),
        lakefile=LAKEFILE + '\n[[require]]\nname = "doc-gen4"\ngit = "https://example.invalid/doc-gen4"\nrev = "main"\n')
U = "https://example.invalid/x"
project("guillemets_bad", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg(G("a\u2800"), url=U), pkg(G(""), url=U), pkg("doc-gen4\u00bb", url=U)]))
project("schema7", {"schemaVersion": 7, "packages": [pkg("mathlib", cfg="lakefile.lean")]})
project("cfg", manifest([pkg("mathlib", cfg="../../x/lakefile.lean")]))
project("sub", manifest([pkg("mathlib", cfg="lakefile.lean", subDir="../x")]))
project("v6sub", {"version": 6, "packages": [{"git": {"name": "mathlib", "url": "https://example.invalid/m", "rev": mlrev, "subDir?": "../x"}}]})
project("pkgsdir", manifest(packagesDir="../pk"))
project("mfile", manifest([pkg("mathlib", cfg="lakefile.lean", manifestFile="../m.json")]))
project("path", manifest([pkg("mathlib", cfg="lakefile.lean"), {"type": "path", "name": "local", "dir": "../x", "inherited": False, "scope": ""}]))
project("nover", {"packages": [pkg("mathlib", cfg="lakefile.lean")]})
project("v4", {"version": 4, "packages": [{"git": {"name": "mathlib", "url": "https://example.invalid/m", "rev": mlrev}}]})
project("v2major", manifest(version="2.0.0"))
project("v6flat", {"version": 6, "packages": [pkg("mathlib", cfg="lakefile.lean")]})
project("v7tagged", {"version": 7, "packages": [{"git": {"name": "mathlib", "url": "https://example.invalid/m", "rev": mlrev}}]})
add = lambda extra: LAKEFILE + extra
project("lean_exe", lakefile=add('\n[[lean_exe]]\nname = "cache"\nroot = "Cache"\n'))
project("root_lower", lakefile=LAKEFILE.replace('name = "tree"', 'name = "mathlib"', 1))
project("root_upper", lakefile=LAKEFILE.replace('name = "tree"', 'name = "Mathlib"', 1))
project("lib_outside", lakefile=add('\n[[lean_lib]]\nname = "Other"\nsrcDir = "../other"\n'))
project("lib_elsewhere", lakefile=LAKEFILE.replace('srcDir = "src"', 'srcDir = "."', 1) + '\n[[lean_lib]]\nname = "Other"\nsrcDir = "other"\n')
# A library's srcDir that is not a directory of plain parts and '..' parts: a part that starts with a dot, an absolute one
project("lib_hidden", lakefile=add('\n[[lean_lib]]\nname = "Other"\nsrcDir = ".hidden/x"\n'))
project("lib_abs", lakefile=add('\n[[lean_lib]]\nname = "Other"\nsrcDir = "/other"\n'))
# Libraries outside the sources 03 reads, for --lib-outside-src (TGT_LIBS_OUTSIDE_SRC): a library Challenge whose srcDir
# '..' is the project's own directory, beside src, and which defaultTargets does not name; then one change in each case
CH = '\n[[lean_lib]]\nname = "Challenge"\nsrcDir = ".."\n'
DT = 'defaultTargets = ["Statements", "Main"]\n'
assert DT in LAKEFILE
def made(name, path):
    """A file of the project name, or with a closing slash a directory."""
    p = os.path.join(out, name, path)
    os.makedirs(p if path.endswith("/") else os.path.dirname(p), exist_ok=True)
    if not path.endswith("/"):
        with open(p, "w") as fh:
            fh.write("-- made up\n")
project("libs_out", lakefile=add(CH))
made("libs_out", "src/Statements.lean"); made("libs_out", "Challenge.lean")
project("libs_two", lakefile=add(CH + '\n[[lean_lib]]\nname = "Notes.Extra"\nsrcDir = "../notes"\n'))
project("libs_back", lakefile=add('\n[[lean_lib]]\nname = "Back"\nsrcDir = "../src/Sub"\n'))
project("libs_default", lakefile=add(CH).replace(DT, 'defaultTargets = ["Statements", "Main", "Challenge"]\n', 1))
project("libs_default_g", lakefile=add(CH).replace(DT, 'defaultTargets = ["Statements", "Main", "%s"]\n' % G("Challenge"), 1))
project("libs_nodefaults", lakefile=add(CH).replace(DT, "", 1))
project("libs_emptydefaults", lakefile=add(CH).replace(DT, "defaultTargets = []\n", 1))
project("libs_globs", lakefile=add(CH + 'globs = ["Challenge.+"]\n'))
project("libs_root_bang", lakefile=add(CH + 'roots = ["Challenge", "Proj!"]\n'))
project("libs_src_module", lakefile=add(CH)); made("libs_src_module", "src/Challenge.lean")
project("libs_src_dir", lakefile=add(CH)); made("libs_src_dir", "src/Challenge/")
project("libs_src_root", lakefile=add(CH + 'roots = ["Challenge", "Challenge.Deep"]\n')); made("libs_src_root", "src/Challenge/Deep.lean")
# A source whose file name has a dot in it has, read as the later steps read a path (dots for the separators), the name
# of a module of the library; so has a directory of that kind, and a name in another case. One that only starts alike
# has not, nor has a file of the library's name deeper in the sources
project("libs_src_dotted", lakefile=add(CH)); made("libs_src_dotted", "src/Challenge.Evil.lean")
project("libs_src_dotdir", lakefile=add(CH)); made("libs_src_dotdir", "src/Challenge.Sub/X.lean")
project("libs_src_case", lakefile=add(CH)); made("libs_src_case", "src/CHALLENGE.lean")
project("libs_src_near", lakefile=add(CH)); made("libs_src_near", "src/ChallengeX.lean"); made("libs_src_near", "src/Sub/Challenge.lean")
# defaultTargets that name a module of the library, which Lake builds as a module; and one that only starts alike
project("libs_default_mod", lakefile=add(CH).replace(DT, 'defaultTargets = ["Statements", "Main", "Challenge.Extra"]\n', 1))
project("libs_default_modg", lakefile=add(CH).replace(DT, 'defaultTargets = ["Statements", "Main", "%s.Extra"]\n' % G("Challenge"), 1))
project("libs_default_root", lakefile=add(CH + 'roots = ["Challenge", "Challenge.Deep"]\n').replace(DT, 'defaultTargets = ["Statements", "Main", "Challenge.Deep.X"]\n', 1))
project("libs_default_near", lakefile=add(CH).replace(DT, 'defaultTargets = ["Statements", "Main", "Challenger"]\n', 1))
# Roots that are not the library's own name or a name under it (a package's module; a name that only starts alike),
# roots that are, and no roots at all; a library name that is not of plain parts; two libraries of one name
project("libs_root_stray", lakefile=add(CH + 'roots = ["Challenge", "Mathlib"]\n'))
project("libs_root_near", lakefile=add(CH + 'roots = ["ChallengeX"]\n'))
project("libs_root_under", lakefile=add(CH + 'roots = ["Challenge", "Challenge.Deep"]\n'))
project("libs_root_none", lakefile=add(CH + 'roots = []\n'))
project("libs_name_quote", lakefile=add(CH.replace('"Challenge"', '"Chal' + "'" + '"', 1)))
project("libs_dup", lakefile=add(CH + '\n[[lean_lib]]\nname = "%s"\nroots = ["Main"]\n' % G("Challenge")))
# A library named, or under the name of, a package the project depends on or a library of the toolchain; one whose name
# only starts alike; and one whose own name puts its files at or under the directory 03 reads
for _n, _lib in (("libs_name_pkg", "Mathlib"), ("libs_name_pkg_under", "Mathlib.Tactic"), ("libs_name_core", "Init"),
                 ("libs_name_core_under", "Lean.Elab"), ("libs_name_near", "MathlibExtras"), ("libs_name_src", "src"),
                 ("libs_name_src_under", "src.Evil")):
    project(_n, lakefile=add(CH.replace('"Challenge"', '"%s"' % _lib, 1)))
# A source directory that is not called src (a directory called src is then nothing special), and a library in a
# directory whose name only starts as the source directory's does
SRCS = lambda text: text.replace('srcDir = "src"', 'srcDir = "Sources"', 1)
assert SRCS(LAKEFILE) != LAKEFILE
project("libs_srcname", lakefile=SRCS(add(CH))); made("libs_srcname", "Sources/Statements.lean"); made("libs_srcname", "src/Challenge.lean")
project("libs_srcname_module", lakefile=SRCS(add(CH))); made("libs_srcname_module", "Sources/Challenge.lean")
project("lib_srcx", lakefile=add('\n[[lean_lib]]\nname = "Other"\nsrcDir = "../srcx"\n'))
project("libs_up", lakefile=add('\n[[lean_lib]]\nname = "Up"\nsrcDir = "../.."\n'))
project("backslash", lakefile=LAKEFILE.replace('rev = "%s"' % mlrev, 'rev = "\\u0030%s"' % mlrev[1:], 1))
project("unknown_key", lakefile=LAKEFILE.replace('srcDir = "src"\n', 'srcDir = "src"\nprecompileModules = true\n', 1))
project("plugin", lakefile=LAKEFILE.replace('["--tstack=400000"]', '["--tstack=400000", "--plugin=x.so"]', 1))
project("lib_dynlib", lakefile=add('weakLeanArgs = ["--load-dynlib=x.so"]\n'))
project("dup_key", lakefile=LAKEFILE.replace('version = "0.1.0"\n', 'version = "0.1.0"\nversion = "0.2.0"\n', 1))
project("two_requires", lakefile=add('\n[[require]]\nname = "mathlib"\ngit = "https://example.invalid/other"\n'))
project("multiline", lakefile=LAKEFILE.replace('version = "0.1.0"', 'version = """0.1.0"""', 1))
project("toolchain_not_utf8", toolchain=b"leanprover/lean4:v4.33.1\xff\n")
project("lakefile_not_utf8", lakefile=LAKEFILE.encode() + b"# \xff\n")
project("manifest_not_utf8", json.dumps(manifest()).encode() + b"\xff")
project("not_json", "{")
project("big_number", '{"version": 1%s, "packages": []}' % ("0" * 40))
project("deep", '{"version": "1.2.0", "packages": [], "x": %s1%s}' % ("[" * 40, "]" * 40))
project("deeper", "[" * 100000 + "]" * 100000)
# A first header (a pax header, whose name is not read as a name) that begins as an xz stream does
def pax(records):
    body = b""
    for k, v in records:
        r = b" %s=%s\n" % (k, v)
        n = len(r) + 1
        while n != len(r) + len(b"%d" % n):
            n = len(r) + len(b"%d" % n)
        body += b"%d%s" % (n, r)
    return body
xzbody = pax([(b"path", b"lean/lakefile.toml")])
with open(os.path.join(out, "xz_first.tar"), "wb") as fh:
    fh.write(end(hdr(b"\xfd7zXZ", len(xzbody), typeflag=b"x", magic=b"ustar\x0000") + pad(xzbody)
                 + reg(P + b"lakefile.toml", b'name = "t"\n') + reg(P + b"src/Main.lean", b"-- m\n")))
# What 'lake new <name> math' writes (Lake 4.33.1's template), with the manifest Lake makes from it: Mathlib pinned
# by a tag, which the manifest keeps as the entry's inputRev beside the commit
MATH = '''name = %s
version = "0.1.0"
keywords = ["math"]
defaultTargets = [%s]

[leanOptions]
pp.unicode.fun = true # pretty-prints `fun a \u21a6 b`
relaxedAutoImplicit = false
weak.linter.mathlibStandardSet = true
maxSynthPendingDepth = 3

[[require]]
name = "mathlib"
scope = "leanprover-community"
rev = "v4.33.1"

[[lean_lib]]
name = %s
'''
SC = "leanprover-community"
MM = manifest([pkg("mathlib", cfg="lakefile.lean", scope=SC, inputRev="v4.33.1"), pkg("plausible", True, scope=SC)])
project("lake_new", MM, lakefile=MATH % ('"proj"', '"Proj"', '"Proj"'))
project("lake_new_2proj", MM, lakefile=MATH % ('"2proj"', '"\u00ab2proj\u00bb"', '"\u00ab2proj\u00bb"'))
project("tag_other", MM, lakefile=(MATH % ('"proj"', '"Proj"', '"Proj"')).replace('rev = "v4.33.1"', 'rev = "v4.33.0"'))
project("srcdir_spellings", lakefile=LAKEFILE.replace('srcDir = "src"', 'srcDir = "./src/"', 1))
project("toolchain_crlf", toolchain="leanprover/lean4:v4.33.1\r\n")
project("toolchain_ws", toolchain="leanprover/lean4:v4.33.1\u3000\n")
# Names as Lake reads them: mathlib in guillemets beside mathlib, or alone; two of one name; a name Lake cannot read
project("mathlib_twice", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg(G("mathlib"), cfg="lakefile.lean", rev="0" * 40)]))
project("mathlib_escaped", manifest([pkg(G("mathlib"), cfg="lakefile.lean")]))
project("dup_names", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg("mathlib", cfg="lakefile.lean")]))
project("bare_hyphen", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg("doc-gen4")]))
project("no_mathlib", manifest([pkg("plausible")]))
project("no_packages", {"version": "1.2.0", "name": "tree"})
def without(p, k):
    del p[k]
    return p
project("no_rev", manifest([without(pkg("mathlib", cfg="lakefile.lean"), "rev")]))
project("no_url", manifest([pkg("mathlib", cfg="lakefile.lean"), without(pkg("plausible", True), "url")]))
project("req_missing", lakefile=add('\n[[require]]\nname = "extra"\ngit = "https://example.invalid/extra"\nrev = "main"\n'))
project("req_cyrillic", lakefile=LAKEFILE.replace("https://example.invalid/mathlib4", "https://example.invalid/math\u0456ib4", 1))
project("float_big", '{"version": "1.2.0", "packages": [], "x": 1.%s}' % ("0" * 40))
project("nan", '{"version": "1.2.0", "packages": [], "x": NaN}')
project("ver_dash", manifest(version="1.0.0-"))
# Lean options that make lean run a program, write a file, or add declarations with no check by the kernel
project("sat_solver", lakefile=LAKEFILE.replace("autoImplicit = false\n", 'autoImplicit = false\nsat.solver = "/bin/sh"\n', 1))
project("trace_arg", lakefile=LAKEFILE.replace('["--tstack=400000"]', '["--tstack=400000", "-Dweak.trace.profiler.output=lakefile.toml"]', 1))
project("debug_lib", lakefile=LAKEFILE.replace("{synthInstance.maxHeartbeats = 400000}", "{synthInstance.maxHeartbeats = 400000, debug.skipKernelTC = true}", 1))
# Every Lean option the check allows, with 'weak.' before it or not: in the package's leanOptions, in a library's,
# and with -D in moreLeanArgs
OPTS = ('autoImplicit = false\nrelaxedAutoImplicit = false\nmaxHeartbeats = 4000000\nmaxRecDepth = 2000\n'
        'maxSynthPendingDepth = 3\nsynthInstance.maxHeartbeats = 400000\nsynthInstance.maxSize = 256\n'
        'warningAsError = true\nElab.async = false\npp.proofs = true\nlinter.unusedVariables = false\n'
        'backward.synthInstance.canonInstances = false\nweak.linter.mathlibStandardSet = true\nweak.maxRecDepth = 4000\n')
LF = LAKEFILE.replace("pp.unicode.fun = true\nautoImplicit = false\nmaxHeartbeats = 4000000\n", "pp.unicode.fun = true\n" + OPTS, 1)
LF = LF.replace("{synthInstance.maxHeartbeats = 400000}", "{synthInstance.maxHeartbeats = 400000, maxRecDepth = 2000, "
                "pp.proofs = true, weak.linter.style.longLine = false, Elab.async = false}", 1)
LF = LF.replace('["--tstack=400000"]', '["--tstack=400000", "-DmaxHeartbeats=4000000", "-Dpp.proofs=true", '
                '"-Dweak.linter.unusedVariables=false", "-DElab.async=false", "-Dbackward.synthInstance.canonInstances=false", '
                '"-DsynthInstance.maxSize=256", "-DwarningAsError=true"]', 1)
assert "weak.maxRecDepth" in LF and "Elab.async = false}" in LF and "-DwarningAsError=true" in LF
project("options_all", lakefile=LF)
# Revisions that are not full commit hashes, addresses that are not https://<host>/<path>, a package with no type
project("rev_branch", manifest([pkg("mathlib", cfg="lakefile.lean", rev="master"), pkg("plausible", True)]))
project("rev_short", manifest([pkg("mathlib", cfg="lakefile.lean", rev="0123456"), pkg("plausible", True)]))
project("rev_dep", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg("plausible", True, rev="main")]))
for label, url in (("noscheme", "github.com/leanprover-community/mathlib4"), ("file", "file:///x"),
                   ("ssh", "ssh://git@example.com/x"), ("scp", "git@example.com:x/y"),
                   ("userinfo", "https://github.com@example.com/m"), ("dash", "-uhttps://x")):
    project("url_" + label, manifest([pkg("mathlib", cfg="lakefile.lean", url=url), pkg("plausible", True)]))
project("req_git_noscheme", lakefile=LAKEFILE.replace("https://example.invalid/mathlib4", "github.com/leanprover-community/mathlib4", 1))
project("type_missing", manifest([pkg("mathlib", cfg="lakefile.lean"), without(pkg("plausible", True), "type")]))
# Toolchains that are not release tags, and two that are
for label, tc in (("nightly", "leanprover/lean4:nightly-2025-11-01"), ("bare_nightly", "nightly-2025-11-01"),
                  ("stable", "leanprover/lean4:stable"), ("rc", "leanprover/lean4:v4.22.0-rc3"), ("bare", "v4.33.1")):
    project("toolchain_" + label, toolchain=tc + "\n")
# A library named with '!', which Lean writes with no guillemets; srcDir './', alone and with a library in './other/'
project("lib_bang", MM, lakefile=MATH % ('"proj"', '"Proj!"', '"Proj!"'))
project("srcdir_dotslash", lakefile=LAKEFILE.replace('srcDir = "src"', 'srcDir = "./"', 1))
project("srcdir_dotslash_out", lakefile=LAKEFILE.replace('srcDir = "src"', 'srcDir = "./"', 1) + '\n[[lean_lib]]\nname = "Other"\nsrcDir = "./other/"\n')
# A revision in capitals, which Lake does not read as a commit; addresses with '..' or '.' parts (git's https transport
# takes them out), a percent-escape, a query, a fragment, an empty part or http://; and an address with a port
project("rev_upper", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg("plausible", True, rev=mlrev.upper())]))
for label, url in (("dotdot", "https://github.com/leanprover-community/mathlib4/../../attacker/mathlib4"),
                   ("dot", "https://example.invalid/./mathlib4"), ("pct", "https://example.invalid/%2e%2e/mathlib4"),
                   ("query", "https://example.invalid/mathlib4?x=1"), ("frag", "https://example.invalid/mathlib4#x"),
                   ("empty", "https://example.invalid//mathlib4"), ("http", "http://example.invalid/mathlib")):
    project("url_" + label, manifest([pkg("mathlib", cfg="lakefile.lean", url=url), pkg("plausible", True)]))
for label, url in (("http", "http://example.invalid/mathlib4"), ("dotdot", "https://example.invalid/mathlib4/../other")):
    project("req_" + label, lakefile=LAKEFILE.replace("https://example.invalid/mathlib4", url, 1))
PORT = "https://example.invalid:8443/mathlib"
project("url_port", manifest([pkg("mathlib", cfg="lakefile.lean", url=PORT), pkg("plausible", True)]),
        lakefile=LAKEFILE.replace("https://example.invalid/mathlib4", PORT, 1))
# Toolchains with no 'v' (elan puts it in), an origin with no '/', and a file of the project at the line's path,
# which elan 4.2 would run in place of the release (with an origin, with none, and a dangling link as the first part)
for label, tc in (("nov", "leanprover/lean4:4.33.1"), ("bare_nov", "4.33.1"), ("origin_noslash", "lean4:v4.33.1"),
                  ("path", "leanprover/lean4:v4.33.1"), ("path_bare", "v4.33.1")):
    project("toolchain_" + label, toolchain=tc + "\n")
for label, tc in (("path", "leanprover/lean4:v4.33.1"), ("path_bare", "v4.33.1")):
    os.makedirs(os.path.join(out, "toolchain_" + label, tc, "bin"))
    with open(os.path.join(out, "toolchain_" + label, tc, "bin", "lean"), "w") as fh:
        fh.write("#!/bin/sh\necho planted\n")
project("toolchain_path_link")
os.symlink("elsewhere", os.path.join(out, "toolchain_path_link", "leanprover"))
# A file, and a dangling link, named https:, as every address starts: git clone reads https://example.invalid/x as the
# path https:/example.invalid/x in the directory it runs in first. A package with a subDir, and one whose subDir is '.'
project("https_bundle")
os.makedirs(os.path.join(out, "https_bundle", "https:", "example.invalid"))
with open(os.path.join(out, "https_bundle", "https:", "example.invalid", "plausible"), "w") as fh:
    fh.write("not a bundle\n")
project("https_link")
os.symlink("elsewhere", os.path.join(out, "https_link", "https:"))
project("subdir_x", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg("plausible", True, subDir="x")]))
project("subdir_dot", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg("plausible", True, subDir=".")]))
project("name_dotdot", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg(G("../x"), True, url=U)]))
project("name_build", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg(G("../build"), True, url=U)]))
project("name_abs", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg(G("/x"), True, url=U)]))
project("name_slash", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg("a." + G("b/c"), True, url=U)]))
project("name_dot", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg(G(".x"), True, url=U)]))
project("name_numstr", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg("1", True, url=U), pkg(G("1"), True, url=U)]))
project("name_case", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg("Mathlib", True, url=U)]))
project("name_long", manifest([pkg("mathlib", cfg="lakefile.lean"), pkg("a" * 243, True, url=U)]))
project("v6subx", {"version": 6, "packages": [{"git": {"name": "mathlib", "url": "https://example.invalid/m", "rev": mlrev, "subDir?": "x"}}]})
def v6(m):
    """m in the form Lake wrote up to version 6: each package {"git": {...}}, with inputRev? and subDir?"""
    ps = [{p["type"]: {"url": p["url"], "subDir?": p["subDir"], "rev": p["rev"], "name": p["name"],
                       "inputRev?": p["inputRev"], "inherited": p["inherited"]}} for p in m["packages"]]
    return {"version": 6, "packagesDir": m["packagesDir"], "packages": ps}
project("v6pin", v6(manifest()))
project("lake_new_v6", v6(MM), lakefile=MATH % ('"proj"', '"Proj"', '"Proj"'))
# roots and globs with '!' and '?' in their parts, and a root with a part that is not an identifier
RB = LAKEFILE.replace('roots = ["Statements", "Main"]', 'roots = ["Statements", "Main", "Proj!", "Proj.A?"]', 1)
RB = RB.replace('globs = ["Formalism.+"]', 'globs = ["Formalism.+", "Proj!.+", "Proj.B?.*"]', 1)
assert RB.count("Proj") == 4
project("roots_bang", lakefile=RB)
project("roots_bad", lakefile=LAKEFILE.replace('roots = ["Statements", "Main"]', 'roots = ["Statements", "a-b"]', 1))
PY31
# The Pythons tar-inspect and project-info are run with: this one and, where it runs and is another version, the
# system's (on macOS, Python 3.9)
pyv() { cenv "$1" -I -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null; }
PY31B=""; V31A=$(pyv "$PY3"); V31B=$( [ -x /usr/bin/python3 ] && pyv /usr/bin/python3 )
[ -n "$V31B" ] && [ "$V31B" != "$V31A" ] && PY31B=/usr/bin/python3
[ -n "$PY31B" ] || skip "tar-inspect and project-info under a second Python: /usr/bin/python3 is missing, does not run or is $V31A too"
for py in "$PY3" ${PY31B:+"$PY31B"}; do
  v=$(pyv "$py")
  for c in "gnu_atime.tar|GNU tar's access time" "gnu_sparsemap.tar|its old map of a sparse file" \
           "gnu_isextended.tar|the flag saying the map goes on in the next block" "gnu_realsize.tar|a sparse file's real size"; do
    f=${c%%|*}
    refused "tar-inspect (Python $v) refuses $f, bytes 345 to 499 of a GNU header set (where bsdtar reads ${c#*|}, for an entry of any kind)" \
      "bytes where a POSIX header has its name prefix, in a header in GNU tar's format" "$py" -I -B "$TOOLS28" tar-inspect "$T31/$f"
  done
  refused "tar-inspect (Python $v) refuses a time in base 256 below -2^63" \
    "a time in its header (0xff0000000000000000000000) that not every tar reads as the same number" "$py" -I -B "$TOOLS28" tar-inspect "$T31/t_neg_huge.tar"
  for c in "t1960_gnu.tar|a time before 1970 in base 256, as Python's GNU format writes it" "t1960_pax.tar|a time before 1970 in a pax record" \
           "empty.tar|an archive with no entries (Python 3.9's tarfile seeks backwards in one)" \
           "gz_two.tar.gz|an archive in two gzip members" "gz_zerotail.tar.gz|zero bytes after the last gzip member"; do
    f=${c%%|*}; cenv "$py" -I -B "$TOOLS28" tar-inspect "$T31/$f" > "$T31/$f.$v.out" 2>&1; rc=$?
    [ "$rc" = 0 ] && ! grep -q Traceback "$T31/$f.$v.out"; res "tar-inspect (Python $v) accepts $f: ${c#*|}" $? "status $rc: $(tailof "$T31/$f.$v.out")"
  done
  for c in "gz_zeropad.tar.gz|zero bytes between two gzip members: bsdtar stops at them" "gz_flag_first.tar.gz|unknown header flags set" \
           "gz_flag_second.tar.gz|unknown header flags set" "gz_junk.tar.gz|bytes after a gzip member that are neither another member nor zero bytes" \
           "xz_first.tar|a first header that begins as a bzip2, xz or zstd stream does"; do
    f=${c%%|*}
    refused "tar-inspect (Python $v) refuses $f: ${c#*|}" "${c#*|}" "$py" -I -B "$TOOLS28" tar-inspect "$T31/$f"
  done
done
# Times before 1970 from this system's tar, when it is bsdtar (macOS's)
if cenv tar --version 2>/dev/null | grep -q bsdtar; then
  X31b="$T31/bsd1960"; mkdir -p "$X31b/lean/src"; printf 'name = "t"\n' > "$X31b/lean/lakefile.toml"; printf 'x\n' > "$X31b/lean/src/A.lean"
  cenv touch -t 196001010000 "$X31b/lean/lakefile.toml" "$X31b/lean/src/A.lean"
  # Only its pax format keeps such a time (in a pax record): its ustar format leaves the files out, with a warning,
  # and its gnutar format writes the time 0
  (cd "$X31b" && cenv COPYFILE_DISABLE=1 tar --format pax -cf ../bsd1960_pax.tar lean/lakefile.toml lean/src/A.lean) 2> "$T31/bsd1960_pax.err"
  n=$(cenv "$PY3" -I -c 'import sys, tarfile; print(sum(1 for m in tarfile.open(sys.argv[1]) if m.mtime < 0))' "$T31/bsd1960_pax.tar" 2>&1)
  cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T31/bsd1960_pax.tar" > "$T31/bsd1960_pax.out" 2>&1; rc=$?
  [ "$n" = 2 ] && [ "$rc" = 0 ]
  res "tar-inspect accepts two files from 1960 in an archive bsdtar made in its pax format (both with times before 1970)" $? "status $rc, entries before 1970: $n: $(tailof "$T31/bsd1960_pax.out") $(tailof "$T31/bsd1960_pax.err")"
else
  skip "files from 1960 in archives bsdtar made: this system's tar is not bsdtar"
fi

# A name in NFC, extracted by this system's tar: on macOS the file system may store it in NFD
X31="$T31/nfc_tree"; mkdir -p "$X31"; cenv tar -xf "$T31/nfc.tar" -C "$X31"
form=$(ls "$X31/lean/src" | cenv "$PY3" -I -c 'import sys, unicodedata; n = sys.stdin.buffer.read().decode("utf-8").strip(); print("NFC" if n == unicodedata.normalize("NFC", n) else "NFD")')
cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T31/nfc.tar" --check-extracted "$X31" --verify-tree "$X31" > "$T31/nfc.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'byte-for-byte' "$T31/nfc.out"
res "a name in NFC extracted by this system's tar (stored here in $form): --check-extracted and --verify-tree pass, byte-for-byte" $? "status $rc: $(tailof "$T31/nfc.out" 3)"
NFD31=$(printf 'Cafe\314\201.lean')
if [ -e "$X31/lean/src/$NFD31" ]; then
  skip "a second file with an entry's name in the other Unicode form: this file system holds one file for both forms"
else
  printf 'x\n' > "$X31/lean/src/$NFD31"
  cenv "$PY3" -I -B "$TOOLS28" tar-inspect "$T31/nfc.tar" --check-extracted "$X31" > "$T31/nfd2.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q 'a second file with the name of an entry of the archive, in another Unicode form' "$T31/nfd2.out"
  res "--check-extracted refuses a second file with an entry's name in the other Unicode form" $? "status $rc: $(tailof "$T31/nfd2.out" 3)"
fi

# project-info: the forms and paths of the manifest, the lakefile's limits, files that cannot be read
for py in "$PY3" ${PY31B:+"$PY31B"}; do
  v=$(pyv "$py")
  for c in "ok|a lakefile and a manifest in the forms the default target's have" "schema7|a manifest of schemaVersion 7" \
           "guillemets|a package name with the guillemets Lake writes around a part that is not an identifier, and a requirement of that name" \
           "srcdir_spellings|srcDir './src/', which Lake reads as src" "toolchain_crlf|a lean-toolchain with CRLF" \
           "options_all|every Lean option the check allows, with weak. before it or not, in leanOptions, in a library's and with -D" \
           "toolchain_rc|a lean-toolchain naming a release candidate (v4.22.0-rc3)" "toolchain_bare|a lean-toolchain naming no origin (v4.33.1)" \
           "toolchain_nov|a lean-toolchain with no 'v' (leanprover/lean4:4.33.1, as Lake writes it), which elan puts in" \
           "toolchain_bare_nov|a lean-toolchain with no origin and no 'v' (4.33.1)" \
           "roots_bang|roots and globs with '!' and '?' in their parts, which Lean writes with no guillemets" \
           "v6pin|the default target's manifest in the form of version 6 ({\"git\": {...}}, inputRev?, subDir?)" \
           "subdir_dot|a package whose subDir is '.'"; do
    f=${c%%|*}; cenv "$py" -I -B "$TOOLS28" project-info "$T31/$f" --show-urls > "$T31/$f.$v.out" 2>&1; rc=$?
    [ "$rc" = 0 ] && ! grep -q -E '^REFUSED|Traceback' "$T31/$f.$v.out" && grep -q '^  mathlib  *https://example.invalid/mathlib$' "$T31/$f.$v.out" \
      && { [ "$f" != guillemets ] || grep -q -F "  $(printf '\302\253')doc-gen4$(printf '\302\273')  " "$T31/$f.$v.out"; }
    res "project-info (Python $v) accepts $c" $? "status $rc: $(tailof "$T31/$f.$v.out" 3)"
  done
  cenv "$py" -I -B "$TOOLS28" project-info "$T31/url_port" --show-urls > "$T31/url_port.$v.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && ! grep -q -E '^REFUSED|Traceback' "$T31/url_port.$v.out" && grep -q '^  mathlib  *https://example.invalid:8443/mathlib$' "$T31/url_port.$v.out"
  res "project-info (Python $v) accepts an address with a port, in the manifest and in the lakefile" $? "status $rc: $(tailof "$T31/url_port.$v.out" 3)"
  for c in "guillemets_bad|REFUSED: 3 value(s)" \
           "cfg|has the configFile '../../x/lakefile.lean': Lake reads the package's lakefile from there" \
           "sub|has the subDir '../x': Lake takes the package from that directory of its clone" "v6sub|has the subDir? '../x'" \
           "pkgsdir|packagesDir is '../pk': Lake puts the packages there" "mfile|has the manifestFile '../m.json'" \
           "path|the package 'local' is a 'path' package: Lake runs the lakefile in its directory" \
           "nover|gives no version that Lake reads (version None)" "v4|gives no version that Lake reads (version 4)" \
           "v2major|gives no version that Lake reads (version '2.0.0')" \
           "v6flat|is of version 0.6, and a package in it is in the form Lake writes from version 7" \
           "v7tagged|is of version 0.7, and a package in it is in the form Lake writes before version 7" \
           "lean_exe|a table \[\[lean_exe\]\], which is not one this check knows" \
           "root_lower|the package is named 'mathlib', as a package it depends on is" "root_upper|the package is named 'Mathlib', as a package it depends on is" \
           "lib_outside|library 3 ('Other'): its sources are in other, not under src, the directory 03 reads (TGT_SRC_DIR)" \
           "lib_srcx|library 3 ('Other'): its sources are in srcx, not under src, the directory 03 reads (TGT_SRC_DIR)" \
           "libs_dup|two libraries named 'Challenge' (Lake reads a name with its guillemets taken off)" \
           "lib_hidden|library 3 ('Other'): srcDir is not '.' or a relative directory of plain parts and '..' parts, no other part starting with a dot" \
           "lib_abs|library 3 ('Other'): srcDir is not '.' or a relative directory of plain parts and '..' parts, no other part starting with a dot" \
           "lib_elsewhere|library 3 ('Other'): its sources are in other, not under src, the directory 03 reads" \
           "backslash|a backslash in a string" "unknown_key|a key 'precompileModules', which is not one this check knows what Lake does with" \
           "plugin|moreLeanArgs is not a list of arguments to lean of the kinds allowed" \
           "lib_dynlib|library 2 ('Statements'): weakLeanArgs is not a list of arguments to lean of the kinds allowed" \
           "dup_key|the key version is given twice" "two_requires|two requirements named 'mathlib'" "multiline|a multi-line string" \
           "toolchain_not_utf8|lean-toolchain is not UTF-8 text" "lakefile_not_utf8|lakefile.toml is not UTF-8 text" \
           "manifest_not_utf8|lake-manifest.json is not UTF-8 text" "not_json|lake-manifest.json is not JSON that can be read" \
           "big_number|lake-manifest.json is not JSON that can be read (a number of more than 30 digits)" \
           "deep|nests its values more than 32 deep" "deeper|nests its values more than 32 deep" \
           "mathlib_twice|has guillemets around mathlib, which Lake writes without them: it reads the name as mathlib" \
           "mathlib_escaped|has guillemets around mathlib, which Lake writes" \
           "dup_names|two packages are named 'mathlib': Lake uses the last" \
           "bare_hyphen|the package name 'doc-gen4' has a part that is not an identifier, a number or between guillemets" \
           "no_mathlib|no package is named mathlib" "no_packages|is not an object whose" \
           "no_rev|REFUSED: 1 value(s) in the project files are missing" "no_url|REFUSED: 1 value(s) in the project files are missing" \
           "req_missing|the requirement 'extra' has no entry in lake-manifest.json" \
           "req_cyrillic|requirement 1: git is not an address of the form https://<host>/<path> in printable ASCII" \
           "req_git_noscheme|requirement 1: git is not an address of the form https://<host>/<path>" \
           "rev_branch|the package 'mathlib' has the revision master, which is not a full commit hash" \
           "rev_short|the package 'mathlib' has the revision 0123456, which is not a full commit hash" \
           "rev_dep|the package 'plausible' has the revision main, which is not a full commit hash" \
           "url_noscheme|the package 'mathlib' has the address github.com/leanprover-community/mathlib4, which is not of the form https://<host>/<path>" \
           "url_file|has the address file:///x, which is not of the form" "url_ssh|has the address ssh://git@example.com/x, which is not of the form" \
           "url_scp|has the address git@example.com:x/y, which is not of the form" \
           "url_userinfo|has the address https://github.com@example.com/m, which is not of the form" \
           "url_dash|has the address -uhttps://x, which is not of the form" \
           "type_missing|the package 'plausible' has no type: Lake stops at a package with none" \
           "toolchain_nightly|REFUSED: lean-toolchain: it names the release nightly-2025-11-01, which is not a release tag" \
           "toolchain_bare_nightly|REFUSED: lean-toolchain: it names the release nightly-2025-11-01, which is not a release tag" \
           "toolchain_stable|REFUSED: lean-toolchain: it names the release stable, which is not a release tag" \
           "srcdir_dotslash_out|library 3 ('Other'): its sources are in other, not under src, the directory 03 reads" \
           "float_big|(a number of more than 30 digits)" "nan|NaN, which is not JSON" \
           "ver_dash|gives no version that Lake reads (version '1.0.0-')" \
           "sat_solver|leanOptions sets the Lean option 'sat.solver', which is not one this check allows" \
           "trace_arg|moreLeanArgs sets the Lean option 'weak.trace.profiler.output'" \
           "debug_lib|library 1 ('Formalism'): leanOptions sets the Lean option 'debug.skipKernelTC'" \
           "rev_upper|the package 'plausible' has the revision 0123456789ABCDEF0123456789ABCDEF01234567, which is not a full commit hash" \
           "url_dotdot|has the address https://github.com/leanprover-community/mathlib4/../../attacker/mathlib4, which is not of the form" \
           "url_dot|has the address https://example.invalid/./mathlib4, which is not of the form" \
           "url_pct|has the address https://example.invalid/%2e%2e/mathlib4, which is not of the form" \
           "url_query|has the address https://example.invalid/mathlib4?x=1, which is not of the form" \
           "url_frag|has the address https://example.invalid/mathlib4#x, which is not of the form" \
           "url_empty|has the address https://example.invalid//mathlib4, which is not of the form" \
           "url_http|has the address http://example.invalid/mathlib, which is not of the form https://<host>/<path>" \
           "req_http|requirement 1: git is not an address of the form https://<host>/<path>" \
           "req_dotdot|requirement 1: git is not an address of the form https://<host>/<path>" \
           "toolchain_origin_noslash|REFUSED: lean-toolchain: it names the origin lean4, which is not <owner>/<repository>" \
           "toolchain_path|REFUSED: lean-toolchain: the project has a file or directory named leanprover, the start of the line" \
           "toolchain_path_bare|REFUSED: lean-toolchain: the project has a file or directory named v4.33.1, the start of the line" \
           "toolchain_path_link|REFUSED: lean-toolchain: the project has a file or directory named leanprover, the start of the line" \
           "https_bundle|the project has a file or directory named https:, the start of every package's address: git clone reads" \
           "https_link|the project has a file or directory named https:, the start of every package's address" \
           "subdir_x|the package 'plausible' has the subDir 'x': Lake would take the package from that directory of its clone" \
           "v6subx|the package 'mathlib' has the subDir? 'x': Lake would take the package from that directory of its clone" \
           "name_dotdot|has a part between guillemets that is empty or has something other than ASCII letters, digits" \
           "name_build|has a part between guillemets that is empty or has something other than ASCII letters, digits" \
           "name_abs|has a part between guillemets that is empty or has something other than ASCII letters, digits" \
           "name_slash|has a part between guillemets that is empty or has something other than ASCII letters, digits" \
           "name_dot|has a part between guillemets that is empty or has something other than ASCII letters, digits" \
           "name_numstr|the packages '1' and '.xab1.xbb' would be kept in one directory of .lake/packages: Lake drops the guillemets" \
           "name_case|the packages 'Mathlib' and 'mathlib' would be kept in one directory of .lake/packages" \
           "name_long|is longer than 242 characters: 04 clones the package as .lake/packages/.<name>.rhv-partial" \
           "roots_bad|roots is not a list of module names of ASCII letters, digits and the characters _'!? (a part may be between guillemets)" \
           "toolchain_ws|REFUSED: 1 value(s) in the project files"; do
    f=${c%%|*}; want=${c#*|}
    cenv "$py" -I -B "$TOOLS28" project-info "$T31/$f" --show-urls > "$T31/$f.$v.out" 2>&1; rc=$?
    [ "$rc" = 1 ] && grep -q '^REFUSED' "$T31/$f.$v.out" && grep -q -- "$want" "$T31/$f.$v.out" && ! grep -q Traceback "$T31/$f.$v.out"
    res "project-info (Python $v) refuses $f, status 1, no traceback: $want" $? "status $rc: $(tailof "$T31/$f.$v.out" 3 | cut -c1-300)"
  done
done
# What 'lake new' writes keeps the sources in the project's own directory (as srcDir './' does): TGT_SRC_DIR is then '.'
for py in "$PY3" ${PY31B:+"$PY31B"}; do
  v=$(pyv "$py")
  for c in "lake_new|the lakefile.toml 'lake new proj math' writes, Mathlib pinned by a tag" \
           "lake_new_2proj|the one 'lake new 2proj math' writes, whose library is named in guillemets" \
           "lake_new_v6|the one 'lake new proj math' writes, with its manifest in the form of version 6" \
           "lib_bang|one whose library is named Proj!, which Lean writes with no guillemets" \
           "srcdir_dotslash|srcDir './', which Lake reads as the project's directory"; do
    f=${c%%|*}; cenv "$py" -I -B "$TOOLS28" project-info "$T31/$f" --show-urls --src-dir . > "$T31/$f.$v.out" 2>&1; rc=$?
    [ "$rc" = 0 ] && ! grep -q -E '^(REFUSED|WARNING)|Traceback' "$T31/$f.$v.out"
    res "project-info (Python $v) with --src-dir . accepts $c" $? "status $rc: $(tailof "$T31/$f.$v.out" 3)"
  done
done
grep -q -F "Mathlib revision (lakefile): v4.33.1 (the manifest's inputRev: Lake checks out the commit above)" "$T31/lake_new.$V31A.out" \
  && ! grep -q -i 'reservoir' "$T31/lake_new.$V31A.out"
res "...it shows the tag as the manifest's inputRev, and, the scripts running Lake with LAKE_NO_CACHE=1, no Reservoir line" $? "$(tailof "$T31/lake_new.$V31A.out" 4)"
grep -q -F "Mathlib revision (lakefile): v4.33.1 (the manifest's inputRev: Lake checks out the commit above)" "$T31/lake_new_v6.$V31A.out"
res "...and the same from a manifest of version 6, whose entry has it as inputRev?" $? "$(tailof "$T31/lake_new_v6.$V31A.out" 4)"
cenv "$PY3" -I -B "$TOOLS28" project-info "$T31/tag_other" --src-dir . > "$T31/tag_other.out" 2>&1; rc=$?
[ "$rc" = 1 ] && ! grep -q '^REFUSED' "$T31/tag_other.out" && grep -q -F "WARNING: the lakefile and the manifest name different Mathlib revisions (the manifest's entry was made from the revision v4.33.1)" "$T31/tag_other.out" \
  && grep -q -F "Mathlib revision (lakefile): v4.33.0" "$T31/tag_other.out"
res "project-info with the lakefile pinning v4.33.0 and the manifest's entry made from v4.33.1: status 1, a WARNING naming both" $? "status $rc: $(tailof "$T31/tag_other.out" 3)"
cenv "$PY3" -I -B "$TOOLS28" project-info "$T31/no_url" > "$T31/no_url.plain.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q '^addresses and directories refused' "$T31/no_url.plain.out" && grep -q '^  plausible  *None$' "$T31/no_url.plain.out"
res "...and, without --show-urls (as 04 runs it), refuses the package with no address and lists it" $? "status $rc: $(tailof "$T31/no_url.plain.out" 4)"
cenv "$PY3" -I -B "$TOOLS28" project-info "$T31/url_noscheme" > "$T31/url_noscheme.plain.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q '^addresses and directories refused' "$T31/url_noscheme.plain.out" \
  && grep -q '^  mathlib  *github.com/leanprover-community/mathlib4$' "$T31/url_noscheme.plain.out"
res "...and, without --show-urls, lists an address with no scheme as refused" $? "status $rc: $(tailof "$T31/url_noscheme.plain.out" 4)"
for f in toolchain_nightly toolchain_bare_nightly toolchain_stable toolchain_origin_noslash toolchain_path toolchain_path_bare \
         toolchain_path_link rev_branch rev_short rev_dep rev_upper type_missing url_dotdot url_dot url_pct url_query url_frag \
         url_empty url_http url_file url_ssh url_scp url_userinfo url_dash req_http req_dotdot https_bundle https_link subdir_x \
         v6subx name_dotdot name_build name_abs name_slash name_dot name_numstr name_case name_long; do
  cenv "$PY3" -I -B "$TOOLS28" project-info "$T31/$f" > "$T31/$f.plain.out" 2>&1; rc=$?
  want=$(grep -m 1 '^REFUSED' "$T31/$f.$V31A.out")
  [ "$rc" = 1 ] && [ -n "$want" ] && grep -q -F -x -- "$want" "$T31/$f.plain.out"
  res "...and refuses $f without --show-urls too (as 04 runs it), with the same REFUSED line" $? "status $rc: $(tailof "$T31/$f.plain.out" 2 | cut -c1-300)"
done
cenv "$PY3" -I -B "$TOOLS28" project-info "$T31/lib_elsewhere" --src-dir . > "$T31/lib_elsewhere.dot.out" 2>&1; rc=$?
[ "$rc" = 0 ]; res "...and accepts lib_elsewhere with --src-dir ., where 03 reads the whole project" $? "status $rc: $(tailof "$T31/lib_elsewhere.dot.out" 3)"
cenv "$PY3" -I -B "$TOOLS28" project-info "$T31/guillemets_bad" > "$T31/gb.out" 2>&1
for n in "'\\xaba\\u2800\\xbb'" "'\\xab\\xbb'" "'doc-gen4\\xbb'"; do
  grep -q -F -- "$n" "$T31/gb.out"; res "project-info shows the name $n escaped" $? "$(tailof "$T31/gb.out" 4)"
done
! grep -q '^addresses and directories refused' "$T31/gb.out"
res "...and, its addresses being plain, lists none of them as refused" $? "$(tailof "$T31/gb.out" 4)"

# Libraries outside the sources 03 reads: accepted only when --lib-outside-src (TGT_LIBS_OUTSIDE_SRC) names them, and
# then only as libraries the build does not compile, whose modules cannot be taken for ones that 03 read
LIBS31="libraries outside src, which 03 does not read and the build must not compile (TGT_LIBS_OUTSIDE_SRC):"
# libs31 <project> [<library name> ...]: project-info under $py, each name given with --lib-outside-src; the output
# is in libs.out
libs31() {
  local p=$1 n; shift
  for n in "$@"; do set -- "$@" --lib-outside-src "$n"; shift; done
  cenv "$py" -I -B "$TOOLS28" project-info "$T31/$p" "$@" > "$T31/libs.out" 2>&1
}
for py in "$PY3" ${PY31B:+"$PY31B"}; do
  v=$(pyv "$py")
  libs31 libs_out Challenge; rc=$?
  [ "$rc" = 0 ] && ! grep -q -E '^REFUSED|Traceback' "$T31/libs.out" && grep -q -x -F "$LIBS31" "$T31/libs.out" \
    && grep -q -x -F "  Challenge          in the project's own directory (roots: Challenge)" "$T31/libs.out"
  res "project-info (Python $v) --lib-outside-src Challenge accepts a library whose srcDir '..' is the project's own directory, beside src, and which defaultTargets does not name, and prints it under 'libraries outside src'" $? "status $rc: $(tailof "$T31/libs.out" 3)"
  libs31 libs_two Challenge Notes.Extra; rc=$?
  [ "$rc" = 0 ] && ! grep -q -E '^REFUSED|Traceback' "$T31/libs.out" && [ "$(grep -A 2 -x -F "$LIBS31" "$T31/libs.out" | sed 1d | tr -s ' \n' ' ')" = " Challenge in the project's own directory (roots: Challenge) Notes.Extra in notes (roots: Notes.Extra) " ]
  res "project-info (Python $v) with two such libraries, each named, accepts and prints both" $? "status $rc: $(tailof "$T31/libs.out" 3)"
  libs31 libs_back; rc=$?
  [ "$rc" = 0 ] && ! grep -q -E '^REFUSED|Traceback|^libraries outside' "$T31/libs.out"
  res "project-info (Python $v) accepts, with no library named, a library srcDir '../src/Sub', which goes up and comes back under src" $? "status $rc: $(tailof "$T31/libs.out" 3)"
  for c in "libs_out||library 3 ('Challenge'): its sources are in the project's own directory, not under src, the directory 03 reads (TGT_SRC_DIR). If it is a library that the build does not compile and no source imports, the profile can name it in TGT_LIBS_OUTSIDE_SRC if its name is of plain parts (ASCII letters, digits and '_', with dots between them; targets/README.md)" \
           "libs_two|Challenge|library 4 ('Notes.Extra'): its sources are in notes, not under src, the directory 03 reads (TGT_SRC_DIR)" \
           "libs_default|Challenge|library 3 ('Challenge'): it is named as a library the build does not compile (TGT_LIBS_OUTSIDE_SRC), and the lakefile's defaultTargets name it or a module of it ('Challenge')" \
           "libs_default_g|Challenge|library 3 ('Challenge'): it is named as a library the build does not compile (TGT_LIBS_OUTSIDE_SRC), and the lakefile's defaultTargets name it or a module of it ('\xabChallenge\xbb')" \
           "libs_default_mod|Challenge|and the lakefile's defaultTargets name it or a module of it ('Challenge.Extra'): Lake builds a default target that is no declared target as a module" \
           "libs_default_modg|Challenge|and the lakefile's defaultTargets name it or a module of it ('\xabChallenge\xbb.Extra')" \
           "libs_default_root|Challenge|and the lakefile's defaultTargets name it or a module of it ('Challenge.Deep.X')" \
           "libs_nodefaults|Challenge|library 3 ('Challenge'): it is named as a library the build does not compile (TGT_LIBS_OUTSIDE_SRC), and the lakefile gives no defaultTargets to say what the build compiles" \
           "libs_emptydefaults|Challenge|and the lakefile gives no defaultTargets to say what the build compiles" \
           "libs_globs|Challenge|library 3 ('Challenge'): it is named as a library the build does not compile (TGT_LIBS_OUTSIDE_SRC), and it has globs: its modules must be its roots only" \
           "libs_root_bang|Challenge|library 3 ('Challenge'): it is named as a library the build does not compile (TGT_LIBS_OUTSIDE_SRC), and its root 'Proj!' is not a name whose parts are ASCII letters, digits and '_'" \
           "libs_name_quote|Chal'|and its name \"Chal'\" is not a name whose parts are ASCII letters, digits and '_'" \
           "libs_root_stray|Challenge|library 3 ('Challenge'): it is named as a library the build does not compile (TGT_LIBS_OUTSIDE_SRC), and its root 'Mathlib' is not its own name or a name under it (Challenge.<...>)" \
           "libs_root_near|Challenge|and its root 'ChallengeX' is not its own name or a name under it (Challenge.<...>)" \
           "libs_dup|Challenge|two libraries named 'Challenge' (Lake reads a name with its guillemets taken off)" \
           "libs_name_pkg|Mathlib|and its name is, or is under, Mathlib, the name (case apart) of a package the project depends on" \
           "libs_name_pkg_under|Mathlib.Tactic|and its name is, or is under, Mathlib, the name (case apart) of a package the project depends on" \
           "libs_name_core|Init|and its name is, or is under, Init, the name (case apart) of a library of the toolchain" \
           "libs_name_core_under|Lean.Elab|and its name is, or is under, Lean, the name (case apart) of a library of the toolchain" \
           "libs_name_src|src|and the files of its name src would be at src, which is the directory 03 reads, or in or above it" \
           "libs_name_src_under|src.Evil|and the files of its name src.Evil would be at src/Evil, which is the directory 03 reads, or in or above it" \
           "libs_src_module|Challenge|library 3 ('Challenge'): it is named as a library the build does not compile (TGT_LIBS_OUTSIDE_SRC), and the directory 03 reads has a file or directory that reads, with dots for the separators, as its root Challenge or a name under it ('Challenge.lean'): Lake could compile the library's file in place of one 03 read" \
           "libs_src_dir|Challenge|and the directory 03 reads has a file or directory that reads, with dots for the separators, as its root Challenge or a name under it ('Challenge')" \
           "libs_src_root|Challenge|and the directory 03 reads has a file or directory that reads, with dots for the separators, as its root Challenge.Deep or a name under it ('Challenge/Deep.lean')" \
           "libs_src_dotted|Challenge|and the directory 03 reads has a file or directory that reads, with dots for the separators, as its root Challenge or a name under it ('Challenge.Evil.lean')" \
           "libs_src_dotdir|Challenge|and the directory 03 reads has a file or directory that reads, with dots for the separators, as its root Challenge or a name under it ('Challenge.Sub')" \
           "libs_src_case|Challenge|and the directory 03 reads has a file or directory that reads, with dots for the separators, as its root Challenge or a name under it ('CHALLENGE.lean')" \
           "libs_up||library 3 ('Up'): its srcDir '../..' is outside the project's directory" \
           "libs_up|Up|library 3 ('Up'): its srcDir '../..' is outside the project's directory" \
           "ok|Nope|TGT_LIBS_OUTSIDE_SRC names 'Nope', and the lakefile has no library written with that name (one written in guillemets cannot be named there)" \
           "libs_out|Challenge Nope|TGT_LIBS_OUTSIDE_SRC names 'Nope', and the lakefile has no library written with that name (one written in guillemets cannot be named there)" \
           "libs_out|Challenge Statements|library 2 ('Statements'): it is named as a library outside src (TGT_LIBS_OUTSIDE_SRC), and its sources are in src, which 03 reads" \
           "libs_back|Back|library 3 ('Back'): it is named as a library outside src (TGT_LIBS_OUTSIDE_SRC), and its sources are in src/Sub, which 03 reads"; do
    f=${c%%|*}; r=${c#*|}; names=${r%%|*}; want=${r#*|}
    # shellcheck disable=SC2086
    libs31 "$f" $names; rc=$?
    [ "$rc" = 1 ] && grep -q '^REFUSED' "$T31/libs.out" && grep -q -F -- "$want" "$T31/libs.out" && ! grep -q -E 'Traceback|^libraries outside' "$T31/libs.out"
    res "project-info (Python $v) refuses $f with ${names:-no library} named as outside the sources, status 1, no traceback: $want" $? "status $rc: $(tailof "$T31/libs.out" 3 | cut -c1-300)"
  done
  cenv "$py" -I -B "$TOOLS28" project-info "$T31/libs_out" --src-dir . --lib-outside-src Challenge > "$T31/libs.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q -F "library 3 ('Challenge'): it is named as a library outside the project's own directory (TGT_LIBS_OUTSIDE_SRC), and its sources are in the project's own directory, which 03 reads" "$T31/libs.out"
  res "project-info (Python $v) with --src-dir . refuses the library named: 03 then reads the whole project" $? "status $rc: $(tailof "$T31/libs.out" 3 | cut -c1-300)"
  # What the rules above leave accepted: names that only start as the library's does, roots under its own name, no roots
  for c in "libs_src_near|Challenge          in the project's own directory (roots: Challenge)" \
           "libs_default_near|Challenge          in the project's own directory (roots: Challenge)" \
           "libs_root_under|Challenge          in the project's own directory (roots: Challenge, Challenge.Deep)" \
           "libs_root_none|Challenge          in the project's own directory (roots: none)"; do
    f=${c%%|*}; want=${c#*|}
    libs31 "$f" Challenge; rc=$?
    [ "$rc" = 0 ] && ! grep -q -E '^REFUSED|Traceback' "$T31/libs.out" && grep -q -x -F "  $want" "$T31/libs.out"
    res "project-info (Python $v) --lib-outside-src Challenge accepts $f, and prints: $want" $? "status $rc: $(tailof "$T31/libs.out" 3 | cut -c1-300)"
  done
  libs31 libs_name_near MathlibExtras; rc=$?
  [ "$rc" = 0 ] && ! grep -q -E '^REFUSED|Traceback' "$T31/libs.out" && grep -q -x -F "  MathlibExtras      in the project's own directory (roots: MathlibExtras)" "$T31/libs.out"
  res "project-info (Python $v) --lib-outside-src MathlibExtras accepts a library whose name only starts as a package's does" $? "status $rc: $(tailof "$T31/libs.out" 3 | cut -c1-300)"
  # The directory 03 reads is the one given, not one that happens to be called src
  cenv "$py" -I -B "$TOOLS28" project-info "$T31/libs_srcname" --src-dir Sources --lib-outside-src Challenge > "$T31/libs.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && ! grep -q -E '^REFUSED|Traceback' "$T31/libs.out" \
    && grep -q -x -F "libraries outside Sources, which 03 does not read and the build must not compile (TGT_LIBS_OUTSIDE_SRC):" "$T31/libs.out"
  res "project-info (Python $v) with --src-dir Sources accepts the library named, whatever a directory called src holds, and says 'libraries outside Sources'" $? "status $rc: $(tailof "$T31/libs.out" 3 | cut -c1-300)"
  cenv "$py" -I -B "$TOOLS28" project-info "$T31/libs_srcname_module" --src-dir Sources --lib-outside-src Challenge > "$T31/libs.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q -F "and the directory 03 reads has a file or directory that reads, with dots for the separators, as its root Challenge or a name under it ('Challenge.lean')" "$T31/libs.out" && ! grep -q -E 'Traceback|^libraries outside' "$T31/libs.out"
  res "project-info (Python $v) with --src-dir Sources refuses it when Sources has a module of its root" $? "status $rc: $(tailof "$T31/libs.out" 3 | cut -c1-300)"
  # A value that is not a library's name is an error of usage: the project files (here ones it would refuse) are not read
  cenv "$py" -I -B "$TOOLS28" project-info "$T31/not_json" --lib-outside-src a/b > "$T31/libs_usage.out" 2> "$T31/libs_usage.err"; rc=$?
  [ "$rc" = 2 ] && [ ! -s "$T31/libs_usage.out" ] && grep -q -F -- "project-info: --lib-outside-src 'a/b' is not the name of a library" "$T31/libs_usage.err" \
    && ! grep -q Traceback "$T31/libs_usage.err"
  res "project-info (Python $v) --lib-outside-src a/b: status 2, the value named on standard error, nothing on standard output (the project files are not read)" $? "status $rc: $(tailof "$T31/libs_usage.out" 2) $(tailof "$T31/libs_usage.err" 2)"
done
# lib.sh limits the characters of TGT_LIBS_OUTSIDE_SRC, which 02 and 04 split at spaces and pass on name by name
for n in 'A;B' 'A*' 'A?' 'A[b]' '-x' 'a/b' "$(printf '\302\253A\302\273')" "$(printf 'A\tB')" 'Challenge.' '9lib' '..' 'A..B' 'A .B' 'A.9b'; do
  prof fix-bad "TGT_LIBS_OUTSIDE_SRC='$n'"
  refused "lib.sh refuses TGT_LIBS_OUTSIDE_SRC $(printf '%q' "$n" | LC_ALL=C tr -c '[:print:]' '?') in a made-up target's profile" \
    "TGT_LIBS_OUTSIDE_SRC must be names of libraries in lakefile.toml" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
done
refused "...and 'A;B' in the environment, for the default target too" "TGT_LIBS_OUTSIDE_SRC must be names of libraries in lakefile.toml" \
  RH_WORKDIR="$T31/wlibs" TGT_LIBS_OUTSIDE_SRC='A;B' /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad "TGT_LIBS_OUTSIDE_SRC='A B.C'"
t=$(libvar TGT_LIBS_OUTSIDE_SRC RH_TARGET=fix-bad); [ "$t" = "A B.C" ] && [ ! -e "$T31/wlibs" ] && [ ! -e "$NEW/work-fix-bad" ]
res "...and accepts 'A B.C', two names (none of these left a working directory behind)" $? "[$t] $(ls -d "$T31/wlibs" "$NEW/work-fix-bad" 2>&1 | tr '\n' ' ')"
t=$(cenv /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- TGT_LIBS_OUTSIDE_SRC 2>&1); [ "$t" = "TGT_LIBS_OUTSIDE_SRC=[]" ]
res "...and for the default target it is set, to nothing" $? "$t"

# lib.sh sets LAKE_NO_CACHE=1 whatever the environment or config.env says, and stops if it cannot
t=$(libvar LAKE_NO_CACHE LAKE_NO_CACHE=0); [ "$t" = 1 ]; res "lib.sh sets LAKE_NO_CACHE=1 over LAKE_NO_CACHE=0 in the environment" $? "[$t]"
setcfg 'LAKE_NO_CACHE=0'
t=$(libvar LAKE_NO_CACHE); [ "$t" = 1 ]; res "...and over LAKE_NO_CACHE=0 in config.env" $? "[$t]"
t=$(libvar LAKE_NO_CACHE RH_TARGET=fix-git); [ "$t" = 1 ]; res "...for a target other than the default one too" $? "[$t]"
setcfg 'readonly LAKE_NO_CACHE=0'
refused "lib.sh stops when config.env makes LAKE_NO_CACHE read-only at 0" "LAKE_NO_CACHE could not be set to 1" \
  /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- LAKE_NO_CACHE
setcfg 'LAKE_NO_CACHE=(0)'
t=$(cenv /bin/bash -c '. "$1/scripts/lib.sh" && printenv LAKE_NO_CACHE' _ "$NEW" 2>&1); [ "$t" = 1 ]
res "...and gives the programs it runs LAKE_NO_CACHE=1 when config.env makes it an array (bash exports no array)" $? "[$t]"
setcfg 'readonly LAKE_NO_CACHE'
refused "...and stops when config.env makes the environment's LAKE_NO_CACHE, a 1 with a line end after it, read-only" \
  "LAKE_NO_CACHE could not be set to 1" LAKE_NO_CACHE=$'1\n' /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- LAKE_NO_CACHE
nocfg
# lib.sh unsets the variables that point git at another repository, and LAKE_PKG_URL_MAP, and stops if it cannot
V31G="GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  GIT_REPLACE_REF_BASE GIT_GRAFT_FILE GIT_SHALLOW_FILE GIT_IMPLICIT_WORK_TREE GIT_PREFIX GIT_CONFIG LAKE_PKG_URL_MAP LAKE_OVERRIDE_LEAN"
# shellcheck disable=SC2046,SC2086
t=$(cenv $(for v in $V31G; do printf '%s=/x ' "$v"; done) /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- $V31G 2>&1 | tr '\n' ' ')
[ "$t" = "$(for v in $V31G; do printf '%s unset ' "$v"; done)" ]
res "lib.sh unsets GIT_DIR, the other variables that point git at another repository or other objects, LAKE_PKG_URL_MAP and LAKE_OVERRIDE_LEAN" $? "[$t]"
for v in $V31G; do
  setcfg "readonly $v=/x"
  refused "...and stops when config.env makes $v read-only" "$v could not be unset" /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- "$v"
done
setcfg 'readonly -a LAKE_NO_CACHE=(1)'
refused "...and stops when config.env makes LAKE_NO_CACHE a read-only array whose first element is 1 (bash exports no array)" \
  "LAKE_NO_CACHE could not be set to 1" /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- LAKE_NO_CACHE
nocfg
# ...and does all this after it has read the target's profile, which is shell code
prof fix-env31
printf '%s\n' 'LAKE_NO_CACHE=0; export LAKE_NO_CACHE' 'GIT_DIR=/elsewhere/.git; export GIT_DIR' 'LAKE_PKG_URL_MAP={}; export LAKE_PKG_URL_MAP' \
  'GIT_REPLACE_REF_BASE=refs/heads/; export GIT_REPLACE_REF_BASE' >> "$NEW/targets/fix-env31/target.env"
t=$(cenv RH_TARGET=fix-env31 /bin/bash -c '. "$1/scripts/lib.sh" && printenv LAKE_NO_CACHE GIT_DIR LAKE_PKG_URL_MAP GIT_REPLACE_REF_BASE; echo end' _ "$NEW" 2>&1 | tr '\n' ' ')
[ "$t" = "1 end " ]
res "...after the target's profile: a profile that sets LAKE_NO_CACHE=0, GIT_DIR, LAKE_PKG_URL_MAP and GIT_REPLACE_REF_BASE leaves the programs the scripts run LAKE_NO_CACHE=1 and none of the others" $? "[$t]"
prof fix-envro31; printf '%s\n' 'readonly LAKE_PKG_URL_MAP={}' >> "$NEW/targets/fix-envro31/target.env"
refused "...and stops when the profile makes LAKE_PKG_URL_MAP read-only" "LAKE_PKG_URL_MAP could not be unset" \
  RH_TARGET=fix-envro31 /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- LAKE_PKG_URL_MAP

# 04 checks the project files again before it runs anything they name, checks that elan would run the release's own
# lean, clones each package itself and checks it out by its commit, and fetches Mathlib's cache by its package, with
# LAKE_NO_CACHE=1 (lib.sh sets it for every Lake the scripts run). The packages come from a made-up repository with two
# commits, through git's url.<base>.insteadOf (the addresses stay https://example.invalid/..., which git may not fetch
# here), and the project files pin its first commit.
STUB31="$T31/stub"; mkdir -p "$STUB31"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: answers --version, logs any other call and fails\nif [ "$1" = --version ]; then echo "Lake version 5.0.0 (test stand-in)"; exit 0; fi\necho "lake $* (LAKE_NO_CACHE=${LAKE_NO_CACHE-unset})" >> "%s"\nexit 1\n' "$T31/lake.log" > "$STUB31/lake"
chmod +x "$STUB31/lake"
# A stand-in elan that names the release's own lean, in a made-up ELAN_HOME, as the one it would run
EH31="$T31/elanhome"; TC31="$EH31/toolchains/leanprover--lean4---v4.33.1/bin"; mkdir -p "$TC31"
cp "$STUB/lean" "$TC31/lean"; chmod +x "$TC31/lean"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: answers which lean, logs any other call and fails\nif [ "$*" = "which lean" ]; then echo "%s"; exit 0; fi\necho "elan $*" >> "%s"\nexit 1\n' "$TC31/lean" "$T31/elan.log" > "$STUB31/elan"
chmod +x "$STUB31/elan"; : > "$T31/elan.log"
# The package repository; a clone of it whose default branch is named as the first commit and points at the second
R31="$T31/pkgrepo"; R31H="$T31/pkgrepo_branch"; mkdir -p "$R31"
gp() { local r=$1; shift; cenv GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 git -C "$r" -c user.name=test \
         -c user.email=test@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
{ gp "$R31" init -q . && printf 'one\n' > "$R31/f" && gp "$R31" add -A && gp "$R31" commit -q -m one && printf 'two\n' > "$R31/f" \
    && gp "$R31" commit -q -a -m two; } > /dev/null 2>&1 || { echo "could not make the package repository"; exit 2; }
C31B=$(gp "$R31" rev-parse HEAD); C31A=$(gp "$R31" rev-parse HEAD~1)
{ cenv git clone -q "$R31" "$R31H" && gp "$R31H" branch "$C31A" "$C31B" && gp "$R31H" symbolic-ref HEAD "refs/heads/$C31A"; } > /dev/null 2>&1 \
  || { echo "could not make the package repository with a branch named as a commit"; exit 2; }
GIT31=(GIT_CONFIG_COUNT=2 "GIT_CONFIG_KEY_0=url.$R31.insteadOf" GIT_CONFIG_VALUE_0=https://example.invalid/mathlib
       "GIT_CONFIG_KEY_1=url.$R31.insteadOf" GIT_CONFIG_VALUE_1=https://example.invalid/plausible)
GIT31H=("GIT_CONFIG_KEY_1=url.$R31H.insteadOf" GIT_CONFIG_VALUE_1=https://example.invalid/plausible)
# The premises: in a clone of the second repository, 'git checkout --detach <first commit>' takes the branch; git clone
# reads an address as a path in the directory it runs in first, a git bundle there included
N31="$T31/naive"; { cenv git clone -q "$R31H" "$N31" && cenv git -C "$N31" checkout -q --detach "$C31A^{commit}" --; } > /dev/null 2>&1
t0=$(cenv git -C "$N31" rev-parse HEAD 2>&1)
cenv git -C "$N31" checkout -q --detach "$C31A" -- > /dev/null 2>&1; rc=$?
t=$(cenv git -C "$N31" rev-parse HEAD 2>&1)
[ "$t0" = "$C31A" ] && [ "$rc" = 0 ] && [ "$t" = "$C31B" ] && ! cenv git -C "$N31" symbolic-ref -q HEAD > /dev/null 2>&1
res "(premise) in a clone of a repository whose default branch is named as a commit, 'git checkout --detach <that commit>', run from a checkout at that commit (by '<commit>^{commit}'), checks out the branch's commit, with status 0 and HEAD detached" $? "HEAD by ^{commit} [$t0], status $rc, HEAD [$t], the commit $C31A"
GB31="$T31/gitpath"; mkdir -p "$GB31/https:/example.invalid"
gp "$R31" bundle create "$GB31/https:/example.invalid/plausible" --all > /dev/null 2>&1
( cd "$GB31" && cenv git clone -q https://example.invalid/plausible got ) > /dev/null 2>&1
t=$(cenv git -C "$GB31/got" rev-parse HEAD 2>&1); [ "$t" = "$C31B" ]
res "(premise) git clone https://example.invalid/plausible, run where https:/example.invalid/plausible is a git bundle, clones the bundle" $? "HEAD [$t]"
# mk04 <work directory> [<project of this case>]: a work directory of the default target with that project's files (the
# ok project's), the first commit of the package repository in place of the made-up hash, and under src a made-up source
# for each of the default target's smoke modules, which 04 looks for before it runs anything
mk04() {
  local f; mkdir -p "$T31/$1/extract/lean/src/Formalism/GammaFactorNonvanishing"; printf 'alpoge-rh\n' > "$T31/$1/.rh-target"
  for f in lakefile.toml lake-manifest.json lean-toolchain; do sed "s/$MLREV/$C31A/g" "$T31/${2:-ok}/$f" > "$T31/$1/extract/lean/$f"; done
  for f in Statements Formalism/GammaFactorNonvanishing/RhOfRight; do printf -- '-- made up\n' > "$T31/$1/extract/lean/src/$f.lean"; done
}
# run04 <work directory> <label> [VAR=value ...]: 04 there, its output in <label>.out and its status in <label>.rc
run04() {
  local w=$1 l=$2; shift 2
  cenv "$@" RH_WORKDIR="$T31/$w" TGT_RECORDS_DIR=targets/none31/records /bin/bash "$NEW/scripts/04_setup_toolchain.sh" > "$T31/$l.out" 2>&1
  echo "$?" > "$T31/$l.rc"
}
rc31() { cat "$T31/$1.rc"; }
head31() { cenv git -C "$T31/$1/extract/lean/.lake/packages/$2" rev-parse HEAD 2>&1; }
mk04 w04exe lean_exe; mk04 w04ok; mk04 w04elan; mk04 w04elan2; mk04 w04noelan
: > "$T31/lake.log"
refused "04 with a lakefile.toml changed since 02 (an executable named cache added): stops before running anything" \
  "the project files were refused, or do not match what was recorded" \
  PATH="$STUB31:$CPATH" RH_WORKDIR="$T31/w04exe" TGT_RECORDS_DIR=targets/none31/records /bin/bash "$NEW/scripts/04_setup_toolchain.sh"
grep -q 'REFUSED: lakefile.toml: line 26: a table \[\[lean_exe\]\]' "$TMPD/refused.out" && [ ! -s "$T31/lake.log" ]
res "...it shows why, and lake was not run" $? "$(tailof "$TMPD/refused.out" 3) / lake: $(tailof "$T31/lake.log")"
run04 w04ok 04ok "${GIT31[@]}" PATH="$STUB31:$CPATH" ELAN_HOME="$EH31"
[ "$(rc31 04ok)" != 0 ] && [ "$(cat "$T31/lake.log")" = "lake exe mathlib/cache get (LAKE_NO_CACHE=1)" ] && grep -q "'lake exe mathlib/cache get' failed" "$T31/04ok.out" \
  && grep -q 'toolchain directory: .*/toolchains/leanprover--lean4---v4.33.1/bin$' "$T31/04ok.out" && [ ! -s "$T31/elan.log" ]
res "04 with project files it accepts, and the release's own lean, goes on to 'lake exe mathlib/cache get', with LAKE_NO_CACHE=1 (the stand-in lake then fails)" $? "status $(rc31 04ok): $(tailof "$T31/04ok.out" 3) / lake: $(tailof "$T31/lake.log") / elan: $(tailof "$T31/elan.log")"
grep -q "package mathlib: cloning https://example.invalid/mathlib, then checking out $C31A" "$T31/04ok.out" \
  && grep -q "package plausible: cloning https://example.invalid/plausible, then checking out $C31A" "$T31/04ok.out" \
  && grep -q 'each git package is checked out at the commit lake-manifest.json names' "$T31/04ok.out" \
  && [ "$(head31 w04ok mathlib)" = "$C31A" ] && [ "$(head31 w04ok plausible)" = "$C31A" ] \
  && [ "$(cat "$T31/w04ok/extract/lean/.lake/packages/plausible/f")" = one ]
res "...having first cloned each package from its address and checked it out at the commit the manifest names, its files with it" $? "$(tailof "$T31/04ok.out" 5) / mathlib $(head31 w04ok mathlib), plausible $(head31 w04ok plausible)"
# A smoke module with no source file under src (here the default target's second): 04 stops before it runs anything
mk04 w04nosmoke; rm -f "$T31/w04nosmoke/extract/lean/src/Formalism/GammaFactorNonvanishing/RhOfRight.lean"; : > "$T31/lake.log"
run04 w04nosmoke 04nosmoke "${GIT31[@]}" PATH="$STUB31:$CPATH" ELAN_HOME="$EH31"
[ "$(rc31 04nosmoke)" != 0 ] && grep -q -F "the smoke module Formalism.GammaFactorNonvanishing.RhOfRight (TGT_SMOKE_TARGETS) has no source file" "$T31/04nosmoke.out" \
  && [ ! -s "$T31/lake.log" ] && [ ! -e "$T31/w04nosmoke/extract/lean/.lake" ]
res "04 for the default target stops before it clones anything or runs lake when one of its smoke modules has no source file under src" $? "status $(rc31 04nosmoke): $(tailof "$T31/04nosmoke.out" 2 | cut -c1-400) / lake: $(tailof "$T31/lake.log")"
for c in "nov|leanprover/lean4:4.33.1" "bare|v4.33.1" "bare_nov|4.33.1"; do
  t=${c%%|*}; mk04 "w04tc_$t" "toolchain_$t"; : > "$T31/lake.log"
  run04 "w04tc_$t" "04tc_$t" "${GIT31[@]}" PATH="$STUB31:$CPATH" ELAN_HOME="$EH31"
  grep -q 'toolchain directory: .*/toolchains/leanprover--lean4---v4.33.1/bin$' "$T31/04tc_$t.out" && grep -q "'lake exe mathlib/cache get' failed" "$T31/04tc_$t.out"
  res "04 with the toolchain line ${c#*|} takes the release's own lean, in elan's directory of leanprover/lean4:v4.33.1, and goes on" $? "status $(rc31 "04tc_$t"): $(tailof "$T31/04tc_$t.out" 3)"
done
# A stand-in elan that would run a lean from elsewhere, as elan 4.2 runs one at the line's path in the project
STUB31E="$T31/stub_elan_other"; mkdir -p "$STUB31E" "$T31/elsewhere/bin" "$T31/elanhome_empty"; cp "$STUB31/lake" "$STUB31E/lake"
printf '#!/bin/sh\necho planted\n' > "$T31/elsewhere/bin/lean"; chmod +x "$T31/elsewhere/bin/lean"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: names another lean as the one it would run\nif [ "$*" = "which lean" ]; then echo "%s"; exit 0; fi\nexit 1\n' "$T31/elsewhere/bin/lean" > "$STUB31E/elan"
chmod +x "$STUB31E/elan"; : > "$T31/lake.log"
run04 w04elan 04elan "${GIT31[@]}" PATH="$STUB31E:$CPATH" ELAN_HOME="$EH31"
[ "$(rc31 04elan)" != 0 ] && grep -q "the lean elan would run is not the release lean-toolchain names, or could not be checked (the reason is above; see .*); lean and lake were not run" "$T31/04elan.out" \
  && grep -q "elan would run .*/elsewhere/bin/lean, not the release's own lean in .*/toolchains/leanprover--lean4---v4.33.1/bin (a file of the project at the line's path" "$T31/04elan.out" \
  && ! grep -q 'test stand-in' "$T31/04elan.out" && [ ! -s "$T31/lake.log" ] && [ ! -e "$T31/w04elan/extract/lean/.lake" ]
res "04 stops before it runs lean or lake, or clones a package, when elan would run a lean that is not the release's own, and says which" $? "status $(rc31 04elan): $(tailof "$T31/04elan.out" 3) / lake: $(tailof "$T31/lake.log")"
run04 w04elan2 04elan2 "${GIT31[@]}" PATH="$STUB31E:$CPATH" ELAN_HOME="$T31/elanhome_empty"
[ "$(rc31 04elan2)" != 0 ] && grep -q -F "elan would run $T31/elsewhere/bin/lean, not the release's own lean in $T31/elanhome_empty/toolchains/leanprover--lean4---v4.33.1/bin (" "$T31/04elan2.out" \
  && ! grep -q -F '?/bin' "$T31/04elan2.out" && [ ! -s "$T31/lake.log" ]
res "...and where elan's directory has no such release, names the directory it would be in" $? "status $(rc31 04elan2): $(tailof "$T31/04elan2.out" 3)"
# A stand-in elan that chooses no lean, with an escape sequence in what it says
STUB31N="$T31/stub_elan_none"; mkdir -p "$STUB31N"; cp "$STUB31/lake" "$STUB31N/lake"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: chooses no lean\nprintf "error: no toolchain \\033[31mfor\\033[0m this project\\n" >&2\nexit 1\n' > "$STUB31N/elan"
chmod +x "$STUB31N/elan"; : > "$T31/lake.log"
run04 w04noelan 04noelan "${GIT31[@]}" PATH="$STUB31N:$CPATH" ELAN_HOME="$EH31"
L31=$(ls "$T31/w04noelan/logs/"setup-*.log 2>/dev/null | head -n 1)
[ "$(rc31 04noelan)" != 0 ] && grep -q "elan chose no lean for the project ('elan which lean' failed in " "$T31/04noelan.out" \
  && grep -q "; lean and lake were not run" "$T31/04noelan.out" && [ ! -s "$T31/lake.log" ] && [ -n "$L31" ] \
  && grep -q -F 'error: no toolchain ?[31mfor?[0m this project' "$L31" && ! LC_ALL=C grep -q "$(printf '\033')" "$L31" \
  && grep -q -F 'error: no toolchain ?[31mfor?[0m this project' "$T31/04noelan.out" && ! LC_ALL=C grep -q "$(printf '\033')" "$T31/04noelan.out"
res "04 stops before it runs lean or lake when elan chooses no lean, its log and the terminal showing what elan said with '?' for the escapes" $? "status $(rc31 04noelan): $(tailof "$T31/04noelan.out" 3) / log: $(tailof "$L31" 3)"
# A relative or an empty ELAN_HOME, which elan reads against the directory it runs in (the project's)
for c in "rel|.elan" "empty|"; do
  t=${c%%|*}; mk04 "w04eh_$t"; : > "$T31/lake.log"
  run04 "w04eh_$t" "04eh_$t" "${GIT31[@]}" PATH="$STUB31:$CPATH" ELAN_HOME="${c#*|}"
  [ "$(rc31 "04eh_$t")" != 0 ] && grep -q -F "ELAN_HOME is set to '${c#*|}', which is not an absolute path: elan would read it against the project's directory" "$T31/04eh_$t.out" \
    && grep -q '; lean and lake were not run' "$T31/04eh_$t.out" && [ ! -s "$T31/lake.log" ] && [ ! -e "$T31/w04eh_$t/extract/lean/.lake" ]
  res "04 stops before it runs lean or lake, or clones a package, when ELAN_HOME is '${c#*|}', and says why on the terminal" $? "status $(rc31 "04eh_$t"): $(tailof "$T31/04eh_$t.out" 3)"
done
# A package name that is not one directory name
mk04 w04name name_dotdot; : > "$T31/lake.log"
run04 w04name 04name "${GIT31[@]}" PATH="$STUB31:$CPATH" ELAN_HOME="$EH31"
[ "$(rc31 04name)" != 0 ] && grep -q 'the project files were refused' "$T31/04name.out" && [ ! -e "$T31/w04name/extract/lean/.lake" ] \
  && [ ! -e "$T31/w04name/extract/lean/.lake/x" ] && [ ! -s "$T31/lake.log" ]
res "04 with a package named '../x' between guillemets stops before it clones anything" $? "status $(rc31 04name): $(tailof "$T31/04name.out" 3)"

# A stand-in lake whose 'exe mathlib/cache get' leaves the packages 04 cloned as they are, or checks plausible out at
# the second commit, writes the files LAKE31_TRACE names, changes a file of plausible or writes
# .lake/package-overrides.json (as LAKE31_MODE says); its 'build' fails, or, with LAKE31_SMOKE set, writes the compiled
# files of the modules named and then does what LAKE31_SMOKE says (or adds a space to lake-manifest.json)
STUB31P="$T31/stub_pkgs"; mkdir -p "$STUB31P"
cat > "$STUB31P/lake" <<LAKE31P
#!/bin/sh
# stand-in made by test_targets.sh: answers --version; 'exe mathlib/cache get' does what LAKE31_MODE says, and
# 'build' what LAKE31_SMOKE says
if [ "\$1" = --version ]; then echo "Lake version 5.0.0 (test stand-in)"; exit 0; fi
echo "lake \$*" >> "$T31/lakep.log"
act() {
  case "\$1" in
    bad) git -C .lake/packages/plausible checkout -q --detach "$C31B" || exit 1 ;;
    trace) for t in \${LAKE31_TRACE:-}; do mkdir -p "\${t%/*}" && : > "\$t" || exit 1; done ;;
    dirty) printf 'changed\\n' > .lake/packages/plausible/f || exit 1 ;;
    override) printf '{}\\n' > .lake/package-overrides.json || exit 1 ;;
    manifest) printf ' ' >> lake-manifest.json || exit 1 ;;
  esac
}
if [ "\$*" = "exe mathlib/cache get" ]; then act "\${LAKE31_MODE:-}"; exit 0; fi
[ "\$1" = build ] && [ -n "\${LAKE31_SMOKE:-}" ] || exit 1
shift
for a in "\$@"; do
  case "\$a" in +*) f=.lake/build/lib/lean/\$(printf '%s' "\${a#+}" | tr . /).olean; mkdir -p "\${f%/*}" && : > "\$f" || exit 1 ;; esac
done
act "\$LAKE31_SMOKE"
exit 0
LAKE31P
chmod +x "$STUB31P/lake"
# p04 <work directory> <label> [VAR=value ...]: 04 there with this lake, which logs to lakep.<label>.log
p04() {
  local w=$1 l=$2; shift 2; : > "$T31/lakep.log"
  run04 "$w" "04$l" "${GIT31[@]}" PATH="$STUB31P:$STUB31:$CPATH" ELAN_HOME="$EH31" "$@"
  cp "$T31/lakep.log" "$T31/lakep.$l.log"
}
mk04 w04pin; p04 w04pin good LAKE31_MODE=good
[ "$(rc31 04good)" != 0 ] && grep -q 'each git package is still checked out at the commit lake-manifest.json names' "$T31/04good.out" \
  && grep -q 'the smoke build failed' "$T31/04good.out" && grep -q '^lake build ' "$T31/lakep.good.log"
res "04 with each package at the commit the manifest names goes on to the smoke build (the stand-in lake then fails)" $? "status $(rc31 04good): $(tailof "$T31/04good.out" 3)"
mk04 w04pinbad; p04 w04pinbad bad LAKE31_MODE=bad
[ "$(rc31 04bad)" != 0 ] && grep -q "the package plausible is checked out at $C31B, not at $C31A, the commit lake-manifest.json names" "$T31/04bad.out" \
  && grep -q '^lake exe mathlib/cache get$' "$T31/lakep.bad.log" && ! grep -q '^lake build ' "$T31/lakep.bad.log"
res "04 stops, before the smoke build, at a package Lake left checked out at another commit than the manifest names" $? "status $(rc31 04bad): $(tailof "$T31/04bad.out" 3)"
mk04 w04host; p04 w04host host LAKE31_MODE=good "${GIT31H[@]}"
[ "$(rc31 04host)" != 0 ] && grep -q 'the smoke build failed' "$T31/04host.out" && [ "$(head31 w04host plausible)" = "$C31A" ] \
  && [ "$(cat "$T31/w04host/extract/lean/.lake/packages/plausible/f")" = one ]
res "04 checks a package out at the commit the manifest names when the package's default branch is named as that commit and points at another, and goes on to the smoke build" $? "status $(rc31 04host): $(tailof "$T31/04host.out" 3) / plausible $(head31 w04host plausible)"
mk04 w04there; cenv git clone -q "$R31" "$T31/w04there/extract/lean/.lake/packages/plausible" > /dev/null 2>&1
p04 w04there there LAKE31_MODE=good
[ "$(rc31 04there)" != 0 ] && grep -q "the package plausible is checked out at $C31B, not at $C31A, the commit lake-manifest.json names" "$T31/04there.out" \
  && grep -q -F 'w04there/extract/lean/.lake/packages/plausible) and run this step again to clone it again)' "$T31/04there.out" \
  && [ ! -s "$T31/lakep.there.log" ]
res "04 stops before it runs lake when a package's directory is there already, at another commit than the manifest names" $? "status $(rc31 04there): $(tailof "$T31/04there.out" 3) / lake: $(tailof "$T31/lakep.there.log")"
mk04 w04link; { cenv git clone -q "$R31" "$T31/pkglink" && cenv git -C "$T31/pkglink" checkout -q --detach "$C31A"; } > /dev/null 2>&1
mkdir -p "$T31/w04link/extract/lean/.lake/packages"; ln -s "$T31/pkglink" "$T31/w04link/extract/lean/.lake/packages/plausible"
p04 w04link link LAKE31_MODE=good
[ "$(rc31 04link)" != 0 ] && grep -q "w04link/extract/lean/.lake/packages/plausible is not a git clone with its files checked out (" "$T31/04link.out" \
  && [ ! -s "$T31/lakep.link.log" ]
res "...and when a package's directory is a link (here to a clone at that commit)" $? "status $(rc31 04link): $(tailof "$T31/04link.out" 3)"
for m in good bad; do mk04 "w04v6$m" v6pin; p04 "w04v6$m" "v6$m" LAKE31_MODE=$m; done
[ "$(rc31 04v6good)" != 0 ] && grep -q 'the smoke build failed' "$T31/04v6good.out" \
  && grep -q "package plausible: cloning https://example.invalid/plausible, then checking out $C31A" "$T31/04v6good.out"
res "04 with a manifest in the form of version 6 clones its packages and goes on to the smoke build" $? "status $(rc31 04v6good): $(tailof "$T31/04v6good.out" 3)"
[ "$(rc31 04v6bad)" != 0 ] && grep -q "the package plausible is checked out at $C31B, not at $C31A" "$T31/04v6bad.out" && ! grep -q '^lake build ' "$T31/lakep.v6bad.log"
res "...and stops, before the smoke build, at a package Lake left at another commit" $? "status $(rc31 04v6bad): $(tailof "$T31/04v6bad.out" 3)"
# The traces and archives of a package's release build or barrel, where Lake puts them by default, and Lake's own traces
n=0
for t in .lake/packages/plausible/.lake/plausible-build.tar.gz.trace .lake/packages/plausible/.lake/.x.tar.gz.trace \
         .lake/packages/plausible/.lake/dl/x.tar.gz.trace .lake/packages/plausible/.lake/build.barrel .lake/plausible-x.tar.gz \
         .lake/packages/plausible/.lake/config/x.tar.gz.trace .lake/dl/x.tar.gz.trace .lake/.x.tar.gz.trace; do
  n=$((n + 1)); mk04 "w04trace$n"; p04 "w04trace$n" "trace$n" LAKE31_MODE=trace LAKE31_TRACE="$t"
  [ "$(rc31 "04trace$n")" != 0 ] && grep -q -F "Lake downloaded a prebuilt build of a package: $t (" "$T31/04trace$n.out" \
    && ! grep -q '^lake build ' "$T31/lakep.trace$n.log"
  res "04 stops, before the smoke build, at $t, as a release build or barrel Lake downloaded leaves" $? "status $(rc31 "04trace$n"): $(tailof "$T31/04trace$n.out" 3)"
done
mk04 w04tracenot
p04 w04tracenot tracenot LAKE31_MODE=trace LAKE31_TRACE=".lake/config/0/lakefile.olean.trace .lake/build/x.trace .lake/packages/mathlib/.lake/build/m.trace .lake/packages/plausible/widget/js/lake.trace .lake/packages/plausible/.lake/lakefile.olean.trace .lake/lakefile.olean.trace"
[ "$(rc31 04tracenot)" != 0 ] && grep -q 'the smoke build failed' "$T31/04tracenot.out" && grep -q '^lake build ' "$T31/lakep.tracenot.log"
res "...and goes on to the smoke build past the traces Lake keeps in build and config, lakefile.olean.trace at the top of a .lake (an older Lake's), and a package's source file named lake.trace" $? "status $(rc31 04tracenot): $(tailof "$T31/04tracenot.out" 3)"
# 04 with GIT_DIR and GIT_WORK_TREE naming another clone (lib.sh unsets them): the packages are cloned and checked out in
# the project, and that clone is left as it was
OT31="$T31/otherclone"; cenv git clone -q "$R31" "$OT31" > /dev/null 2>&1
mk04 w04gitdir; p04 w04gitdir gitdir LAKE31_MODE=good GIT_DIR="$OT31/.git" GIT_WORK_TREE="$OT31"
[ "$(rc31 04gitdir)" != 0 ] && grep -q 'the smoke build failed' "$T31/04gitdir.out" && [ "$(head31 w04gitdir plausible)" = "$C31A" ] \
  && [ "$(cenv git -C "$OT31" rev-parse HEAD 2>&1)" = "$C31B" ] && [ -z "$(cenv git -C "$OT31" status --porcelain 2>&1)" ]
res "04 with GIT_DIR and GIT_WORK_TREE naming another clone clones and checks out each package in the project, and leaves that clone as it was" $? "status $(rc31 04gitdir): $(tailof "$T31/04gitdir.out" 3) / plausible $(head31 w04gitdir plausible), the other clone at $(cenv git -C "$OT31" rev-parse HEAD 2>&1)"
# A clone an earlier run left half made, under the name 04 gives one, is removed, and the package is cloned again
mk04 w04partial; mkdir -p "$T31/w04partial/extract/lean/.lake/packages/.plausible.rhv-partial/.git"
p04 w04partial partial LAKE31_MODE=good
[ "$(rc31 04partial)" != 0 ] && grep -q 'removing .lake/packages/.plausible.rhv-partial, left by an earlier run of this step that did not finish' "$T31/04partial.out" \
  && grep -q 'the smoke build failed' "$T31/04partial.out" && [ ! -e "$T31/w04partial/extract/lean/.lake/packages/.plausible.rhv-partial" ] \
  && [ "$(head31 w04partial plausible)" = "$C31A" ]
res "04 removes a clone an earlier run left half made under its own name, clones the package again and goes on" $? "status $(rc31 04partial): $(tailof "$T31/04partial.out" 3)"
# A checkout that fails leaves the clone under that name, not as the package's directory; the next run removes it
mk04 w04stop
cenv "$PY3" -I -B -c 'import json, sys
p = sys.argv[1]; m = json.load(open(p))
for q in m["packages"]:
    if q["name"] == "plausible": q["rev"] = "1" * 40
json.dump(m, open(p, "w"), indent=2)' "$T31/w04stop/extract/lean/lake-manifest.json"
p04 w04stop stop1 LAKE31_MODE=good
[ "$(rc31 04stop1)" != 0 ] && grep -q "the package plausible could not be checked out at 1111111111111111111111111111111111111111" "$T31/04stop1.out" \
  && [ ! -e "$T31/w04stop/extract/lean/.lake/packages/plausible" ] && [ -d "$T31/w04stop/extract/lean/.lake/packages/.plausible.rhv-partial/.git" ] \
  && [ ! -s "$T31/lakep.stop1.log" ]
res "04 stops when a package cannot be checked out at its commit, leaving the clone under its own name and not as the package's directory" $? "status $(rc31 04stop1): $(tailof "$T31/04stop1.out" 3)"
mk04 w04stop; p04 w04stop stop2 LAKE31_MODE=good
[ "$(rc31 04stop2)" != 0 ] && grep -q "package mathlib: already at $C31A" "$T31/04stop2.out" \
  && grep -q 'removing .lake/packages/.plausible.rhv-partial' "$T31/04stop2.out" && grep -q 'the smoke build failed' "$T31/04stop2.out" \
  && [ "$(head31 w04stop plausible)" = "$C31A" ]
res "...and, run again with the manifest put right, removes that clone, clones the package and goes on" $? "status $(rc31 04stop2): $(tailof "$T31/04stop2.out" 3)"
# A package directory there already that is a clone with no files checked out (as a clone that was stopped leaves one),
# or a clone at the commit with a file changed
mk04 w04nockout; cenv git clone -q --no-checkout "$R31" "$T31/w04nockout/extract/lean/.lake/packages/plausible" > /dev/null 2>&1
p04 w04nockout nockout LAKE31_MODE=good
[ "$(rc31 04nockout)" != 0 ] && grep -q -F 'w04nockout/extract/lean/.lake/packages/plausible is not a git clone with its files checked out (an earlier run of this step that was stopped, or another program, may have left it; remove it (rm -rf -- ' "$T31/04nockout.out" \
  && grep -q -F 'w04nockout/extract/lean/.lake/packages/plausible) and run this step again to clone it again)' "$T31/04nockout.out" \
  && [ ! -s "$T31/lakep.nockout.log" ]
res "04 stops before it runs lake when a package's directory is a clone with no files checked out, and says how to clone it again" $? "status $(rc31 04nockout): $(tailof "$T31/04nockout.out" 3)"
mk04 w04dirty; PD31="$T31/w04dirty/extract/lean/.lake/packages/plausible"
{ cenv git clone -q "$R31" "$PD31" && cenv git -C "$PD31" checkout -q --detach "$C31A" && printf 'changed\n' > "$PD31/f"; } > /dev/null 2>&1
p04 w04dirty dirty LAKE31_MODE=good
[ "$(rc31 04dirty)" != 0 ] && grep -q "the package plausible has files that are not as in its commit $C31A" "$T31/04dirty.out" && [ ! -s "$T31/lakep.dirty.log" ]
res "...and when it is a clone at the commit with a file changed" $? "status $(rc31 04dirty): $(tailof "$T31/04dirty.out" 3)"
mk04 w04ldirty; p04 w04ldirty ldirty LAKE31_MODE=dirty
[ "$(rc31 04ldirty)" != 0 ] && grep -q "the package plausible has files that are not as in its commit $C31A" "$T31/04ldirty.out" \
  && grep -q "(Lake, or a lakefile or tool it ran, changed it during lake exe mathlib/cache get; running this step again will not undo that" "$T31/04ldirty.out" \
  && grep -q '^lake exe mathlib/cache get$' "$T31/lakep.ldirty.log" && ! grep -q '^lake build ' "$T31/lakep.ldirty.log"
res "04 stops, before the smoke build, at a package in which Lake changed a file" $? "status $(rc31 04ldirty): $(tailof "$T31/04ldirty.out" 3)"
# .lake/package-overrides.json, which Lake reads in place of the manifest's entries
mk04 w04ovr; mkdir -p "$T31/w04ovr/extract/lean/.lake"; printf '{}\n' > "$T31/w04ovr/extract/lean/.lake/package-overrides.json"
mk04 w04ovrlink; mkdir -p "$T31/w04ovrlink/extract/lean/.lake"; ln -s nowhere "$T31/w04ovrlink/extract/lean/.lake/package-overrides.json"
for w in ovr ovrlink; do
  p04 "w04$w" "$w" LAKE31_MODE=good
  [ "$(rc31 "04$w")" != 0 ] && grep -q 'package-overrides.json is there: Lake would take the packages it names from where it says' "$T31/04$w.out" \
    && [ ! -s "$T31/lakep.$w.log" ]
  res "04 stops before it runs lake when .lake/package-overrides.json is there ($w)" $? "status $(rc31 "04$w"): $(tailof "$T31/04$w.out" 3)"
done
mk04 w04lovr; p04 w04lovr lovr LAKE31_MODE=override
[ "$(rc31 04lovr)" != 0 ] && grep -q 'package-overrides.json is there' "$T31/04lovr.out" \
  && grep -q '^lake exe mathlib/cache get$' "$T31/lakep.lovr.log" && ! grep -q '^lake build ' "$T31/lakep.lovr.log"
res "...and, before the smoke build, at one Lake wrote" $? "status $(rc31 04lovr): $(tailof "$T31/04lovr.out" 3)"
# A stand-in smoke build that writes the compiled files of the modules named: 04 reaches its end, and stops at what the
# smoke build left (a release build's trace, a package at another commit, a package-overrides.json)
mk04 w04smoke; p04 w04smoke smoke LAKE31_MODE=good LAKE31_SMOKE=ok
[ "$(rc31 04smoke)" = 0 ] && grep -q 'smoke build ok: both modules compiled, no Mathlib module was rebuilt' "$T31/04smoke.out" \
  && grep -q 'setup complete' "$T31/04smoke.out" && grep -q '^lake build ' "$T31/lakep.smoke.log"
res "04 reaches 'setup complete' after a smoke build that compiles the modules named and leaves the packages as they are" $? "status $(rc31 04smoke): $(tailof "$T31/04smoke.out" 3)"
for c in "trace|Lake downloaded a prebuilt build of a package: .lake/packages/plausible/.lake/x.tar.gz.trace (" \
         "bad|the package plausible is checked out at $C31B, not at $C31A" "override|package-overrides.json is there" \
         "manifest|lake-manifest.json changed during the smoke build (it was "; do
  m=${c%%|*}; mk04 "w04smoke$m"
  p04 "w04smoke$m" "smoke$m" LAKE31_MODE=good LAKE31_SMOKE="$m" LAKE31_TRACE=.lake/packages/plausible/.lake/x.tar.gz.trace
  [ "$(rc31 "04smoke$m")" != 0 ] && grep -q -F -- "${c#*|}" "$T31/04smoke$m.out" && grep -q '^lake build ' "$T31/lakep.smoke$m.log" \
    && ! grep -q 'setup complete' "$T31/04smoke$m.out"
  res "...and stops after the smoke build at what it left ($m)" $? "status $(rc31 "04smoke$m"): $(tailof "$T31/04smoke$m.out" 3)"
done
# A manifest that names an annotated tag's hash: the clone 04 makes is checked out at the commit the tag names, and is
# refused before it is renamed or lake runs, with no word that running 04 again would help
gp "$R31" tag -a -m t t31 "$C31A" > /dev/null 2>&1; TAG31=$(gp "$R31" rev-parse t31 2>&1)
# setrev31 <work directory> <commit>: the manifest of that work directory pins plausible at that commit
setrev31() {
  cenv "$PY3" -I -B -c 'import json, sys
p = sys.argv[1]; m = json.load(open(p))
for q in m["packages"]:
    if q["name"] == "plausible": q["rev"] = sys.argv[2]
json.dump(m, open(p, "w"), indent=2)' "$T31/$1/extract/lean/lake-manifest.json" "$2"
}
mk04 w04tag; setrev31 w04tag "$TAG31"; p04 w04tag tag LAKE31_MODE=good
[ "$(rc31 04tag)" != 0 ] && [ "$TAG31" != "$C31A" ] \
  && grep -q "the package plausible is checked out at $C31A, not at $TAG31, the commit lake-manifest.json names (this is the clone this step has just made, and running this step again would make the same one" "$T31/04tag.out" \
  && [ -d "$T31/w04tag/extract/lean/.lake/packages/.plausible.rhv-partial/.git" ] && [ ! -e "$T31/w04tag/extract/lean/.lake/packages/plausible" ] \
  && [ ! -s "$T31/lakep.tag.log" ]
res "04 refuses its own clone of a package pinned at an annotated tag's hash before it renames it or runs lake, saying that running it again would make the same clone" $? "status $(rc31 04tag): $(tailof "$T31/04tag.out" 3)"
# A package whose .gitattributes has git convert the line ends of a file stored with CRLF, and run a filter that git's
# configuration defines: 04 checks its clone out with the commit's bytes and no filter, and the check passes
R31C="$T31/pkgrepo_attr"; mkdir -p "$R31C"
{ gp "$R31C" init -q . && printf 'one\r\n' > "$R31C/f" && printf 'gee\n' > "$R31C/g" && gp "$R31C" add f g \
    && printf 'f text\ng filter=t31\n' > "$R31C/.gitattributes" && gp "$R31C" add .gitattributes && gp "$R31C" commit -q -m attr; } > /dev/null 2>&1 \
  || { echo "could not make the package repository with a .gitattributes"; exit 2; }
C31C=$(gp "$R31C" rev-parse HEAD 2>&1)
F31="sh -c 'echo ran >> $T31/filter31.log; cat'"
N31C="$T31/naive_attr"; cenv git -c "filter.t31.smudge=$F31" clone -q "$R31C" "$N31C" > /dev/null 2>&1
# the file written again with the same bytes, so that git compares its contents and not only its size and time
cat "$N31C/f" > "$N31C/f.new" && mv "$N31C/f.new" "$N31C/f"
t=$(cenv git -C "$N31C" status --porcelain 2>&1); [ "$t" = " M f" ] && [ -s "$T31/filter31.log" ]
res "(premise) a plain clone of that repository runs the filter, and shows the CRLF file, written again unchanged, as changed" $? "[$t] filter: $(cat "$T31/filter31.log" 2>&1)"
rm -f "$T31/filter31.log"
GIT31C=(GIT_CONFIG_COUNT=3 "GIT_CONFIG_KEY_1=url.$R31C.insteadOf" GIT_CONFIG_VALUE_1=https://example.invalid/plausible
        GIT_CONFIG_KEY_2=filter.t31.smudge "GIT_CONFIG_VALUE_2=$F31")
mk04 w04attr; setrev31 w04attr "$C31C"; p04 w04attr attr LAKE31_MODE=good "${GIT31C[@]}"
PA31="$T31/w04attr/extract/lean/.lake/packages/plausible"
[ "$(rc31 04attr)" != 0 ] && grep -q 'the smoke build failed' "$T31/04attr.out" && [ "$(head31 w04attr plausible)" = "$C31C" ] \
  && [ "$(LC_ALL=C tr '\r' R < "$PA31/f")" = oneR ] && [ "$(cat "$PA31/g")" = gee ] && [ ! -e "$T31/filter31.log" ]
res "04 checks out a package with the commit's bytes, no line ends changed and no filter run, whatever its .gitattributes says, and goes on to the smoke build" $? "status $(rc31 04attr): $(tailof "$T31/04attr.out" 3) / f: $(od -c "$PA31/f" 2>&1 | head -n 1) / filter: $(cat "$T31/filter31.log" 2>&1)"
# Settings that would have git take a changed file as unchanged, in ~/.gitconfig or the environment, and an external diff
H31="$T31/home_ignorestat"; mkdir -p "$H31"; printf '[core]\n\tignoreStat = true\n' > "$H31/.gitconfig"
for c in "istat|core.ignoreStat in ~/.gitconfig|HOME=$H31" \
         "istat2|core.ignoreStat in GIT_CONFIG_COUNT|GIT_CONFIG_COUNT=3|GIT_CONFIG_KEY_2=core.ignoreStat|GIT_CONFIG_VALUE_2=true" \
         "istat3|core.ignoreStat in GIT_CONFIG_PARAMETERS|GIT_CONFIG_PARAMETERS='core.ignorestat'='true'" \
         "xdiff|GIT_EXTERNAL_DIFF=true|GIT_EXTERNAL_DIFF=true|GIT_EXTERNAL_DIFF_TRUST_EXIT_CODE=1"; do
  l=${c%%|*}; r=${c#*|}; why=${r%%|*}; r=${r#*|}
  IFS='|' read -r -a a31 <<EOF
$r
EOF
  mk04 "w04$l"; p04 "w04$l" "$l" LAKE31_MODE=dirty "${a31[@]}"
  [ "$(rc31 "04$l")" != 0 ] && grep -q "the package plausible has files that are not as in its commit $C31A" "$T31/04$l.out" \
    && grep -q '^lake exe mathlib/cache get$' "$T31/lakep.$l.log" && ! grep -q '^lake build ' "$T31/lakep.$l.log"
  res "04 stops, before the smoke build, at a package in which Lake changed a file, with $why" $? "status $(rc31 "04$l"): $(tailof "$T31/04$l.out" 3)"
done
mk04 w04repl; p04 w04repl repl LAKE31_MODE=good "${GIT31H[@]}" GIT_REPLACE_REF_BASE=refs/heads/
[ "$(rc31 04repl)" != 0 ] && grep -q 'the smoke build failed' "$T31/04repl.out" \
  && [ "$(cat "$T31/w04repl/extract/lean/.lake/packages/plausible/f")" = one ]
res "04 checks out the commit's own files when GIT_REPLACE_REF_BASE=refs/heads/ would have the branch named as the commit stand for it" $? "status $(rc31 04repl): $(tailof "$T31/04repl.out" 3) / f: $(cat "$T31/w04repl/extract/lean/.lake/packages/plausible/f" 2>&1)"
# A package directory there already, at the commit, with a changed file git is told not to look at
for c in "au|--assume-unchanged" "sw|--skip-worktree"; do
  m=${c%%|*}; mk04 "w04$m"; PD31="$T31/w04$m/extract/lean/.lake/packages/plausible"
  { cenv git clone -q "$R31" "$PD31" && cenv git -C "$PD31" checkout -q --detach "$C31A" && cenv git -C "$PD31" update-index "${c#*|}" f \
      && printf 'changed\n' > "$PD31/f"; } > /dev/null 2>&1
  t=$(cenv GIT_OPTIONAL_LOCKS=0 git -C "$PD31" status --porcelain --untracked-files=no 2>&1)
  p04 "w04$m" "$m" LAKE31_MODE=good
  [ -z "$t" ] && [ "$(rc31 "04$m")" != 0 ] && grep -q "git is told not to look at a file of the package plausible (assume-unchanged or skip-worktree)" "$T31/04$m.out" \
    && [ ! -s "$T31/lakep.$m.log" ]
  res "04 stops before it runs lake at a package directory with a changed file marked ${c#*|}, which git status does not show" $? "status [$t] $(rc31 "04$m"): $(tailof "$T31/04$m.out" 3)"
done
# A leftover clone under 04's own name that is a dangling link
mk04 w04plink; mkdir -p "$T31/w04plink/extract/lean/.lake/packages"; ln -s nowhere "$T31/w04plink/extract/lean/.lake/packages/.plausible.rhv-partial"
p04 w04plink plink LAKE31_MODE=good
[ "$(rc31 04plink)" != 0 ] && grep -q 'removing .lake/packages/.plausible.rhv-partial, left by an earlier run of this step' "$T31/04plink.out" \
  && grep -q 'the smoke build failed' "$T31/04plink.out" && [ ! -L "$T31/w04plink/extract/lean/.lake/packages/.plausible.rhv-partial" ] \
  && [ "$(head31 w04plink plausible)" = "$C31A" ]
res "04 removes a leftover clone under its own name that is a dangling link, clones the package and goes on" $? "status $(rc31 04plink): $(tailof "$T31/04plink.out" 3)"
# 04's own check of a package name, with a python3 whose project-info accepts anything
STUB31Y="$T31/stub_py"; mkdir -p "$STUB31Y"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: project-info accepts anything; any other call goes to python3\nfor a in "$@"; do [ "$a" = project-info ] && exit 0; done\nexec "%s" "$@"\n' "$PY3" > "$STUB31Y/python3"
chmod +x "$STUB31Y/python3"
for f in name_dotdot name_dot; do
  mk04 "w04y_$f" "$f"; : > "$T31/lakep.log"
  run04 "w04y_$f" "04y_$f" "${GIT31[@]}" PATH="$STUB31Y:$STUB31P:$STUB31:$CPATH" ELAN_HOME="$EH31"
  [ "$(rc31 "04y_$f")" != 0 ] && grep -q 'in lake-manifest.json is not the name of one directory; nothing was cloned for it' "$T31/04y_$f.out" \
    && [ ! -e "$T31/w04y_$f/extract/lean/.lake/x" ] && [ -z "$(ls -A "$T31/w04y_$f/extract/lean/.lake/packages" | grep -v '^mathlib$')" ] \
    && [ ! -s "$T31/lakep.log" ]
  res "04's own check of a package name, with project-info's refusal out of the way, stops at $f before it clones it or runs lake" $? "status $(rc31 "04y_$f"): $(tailof "$T31/04y_$f.out" 3)"
done
# ELAN_HOME under the work directory's extract directory, where the archive is
STUB31X="$T31/stub_elan_extract"; mkdir -p "$STUB31X"; cp "$STUB31/lake" "$STUB31X/lake"
mk04 w04ehx; EX31="$T31/w04ehx/extract/elan/toolchains/leanprover--lean4---v4.33.1/bin"; mkdir -p "$EX31"
cp "$STUB/lean" "$EX31/lean"; chmod +x "$EX31/lean"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: names the lean under the extract directory\nif [ "$*" = "which lean" ]; then echo "%s"; exit 0; fi\nexit 1\n' "$EX31/lean" > "$STUB31X/elan"
chmod +x "$STUB31X/elan"; : > "$T31/lake.log"
run04 w04ehx 04ehx "${GIT31[@]}" PATH="$STUB31X:$CPATH" ELAN_HOME="$T31/w04ehx/extract/elan"
[ "$(rc31 04ehx)" != 0 ] && grep -q "where 02 extracts the archive: it would be one of the archive's files" "$T31/04ehx.out" \
  && [ ! -s "$T31/lake.log" ] && [ ! -e "$T31/w04ehx/extract/lean/.lake" ]
res "04 stops before it runs lean or lake when ELAN_HOME is under the work directory's extract directory" $? "status $(rc31 04ehx): $(tailof "$T31/04ehx.out" 3)"
# 05 and 08, which run elan's lake and lean without asking elan which, refuse a relative or empty ELAN_HOME too
mk04 w05eh; mkdir -p "$T31/w05eh/extract/lean/.lake/packages/mathlib"; : > "$T31/lake.log"
refused "05 start with ELAN_HOME '.elan' stops before it runs lake" "ELAN_HOME is set to '.elan', which is not an absolute path" \
  PATH="$STUB31:$CPATH" ELAN_HOME=.elan RH_WORKDIR="$T31/w05eh" TGT_RECORDS_DIR=targets/none31/records /bin/bash "$NEW/scripts/05_build.sh" start
grep -q 'the build was not started' "$TMPD/refused.out" && [ ! -s "$T31/lake.log" ] && [ ! -e "$T31/w05eh/logs/build.pid" ]
res "...and says the build was not started" $? "$(tailof "$TMPD/refused.out" 3)"
refused "08 with an empty ELAN_HOME stops before it runs lean" "ELAN_HOME is set to '', which is not an absolute path" \
  PATH="$STUB31:$CPATH" ELAN_HOME= RH_WORKDIR="$T31/w05eh" TGT_RECORDS_DIR=targets/none31/records /bin/bash "$NEW/scripts/08_check_axioms.sh"
grep -q 'lean was not run' "$TMPD/refused.out"
res "...and says lean was not run" $? "$(tailof "$TMPD/refused.out" 3)"
# 09 says why it has no toolchain directory when there is neither elan nor lean on PATH
P31N="/usr/bin:/bin:/usr/sbin:/sbin"
if env PATH="$P31N" /bin/sh -c 'command -v elan || command -v lean' > /dev/null 2>&1; then
  skip "09 with no elan and no lean on PATH (one is in $P31N)"
else
  mkdir -p "$T31/w09/extract/lean/.lake/build/lib/lean"; printf 'alpoge-rh\n' > "$T31/w09/.rh-target"
  refused "09 with neither elan nor lean on PATH stops before it runs anything, saying so" "neither elan nor lean is on PATH (elan installs itself in ~/.elan/bin" \
    PATH="$P31N" RH_WORKDIR="$T31/w09" TGT_RECORDS_DIR=targets/none31/records /bin/bash "$NEW/scripts/09_kernel_replay.sh"
  grep -q 'no directory of the pinned toolchain (the reason is above); leanchecker was not run' "$TMPD/refused.out"
  res "...and that leanchecker was not run" $? "$(tailof "$TMPD/refused.out" 3)"
fi

# A made-up git target whose lakefile has two libraries outside its sources, as grh-compact's has one (a challenge file
# beside src, with a 'sorry' in it): with TGT_LIBS_OUTSIDE_SRC naming them, 02 extracts it and shows them, 03 says that
# it does not read them, and 04's own check of the project files is given the names too
RL31="$T31/libsrepo"; mkdir -p "$RL31/proj/src/B" "$RL31/proj/notes/Notes"
printf 'name = "fixture"\nsrcDir = "src"\ndefaultTargets = ["A"]\n\n[[require]]\nname = "mathlib"\ngit = "https://example.invalid/mathlib"\nrev = "%s"\n\n[[lean_lib]]\nname = "A"\nroots = ["A", "B"]\n\n[[lean_lib]]\nname = "Challenge"\nsrcDir = ".."\n\n[[lean_lib]]\nname = "Notes.Extra"\nsrcDir = "../notes"\n' "$C31A" > "$RL31/proj/lakefile.toml"
printf '{"version": "1.1.0",\n "packagesDir": ".lake/packages",\n "packages":\n [{"url": "https://example.invalid/mathlib",\n   "type": "git",\n   "rev": "%s",\n   "name": "mathlib",\n   "inherited": false}],\n "name": "fixture",\n "lakeDir": ".lake"}\n' "$C31A" > "$RL31/proj/lake-manifest.json"
echo 'leanprover/lean4:v4.33.1' > "$RL31/proj/lean-toolchain"
printf 'import B.C\n\ntheorem a_thm : True := trivial\n' > "$RL31/proj/src/A.lean"
printf 'def c : Nat := 1\ntheorem c_thm : c = 1 := rfl\n' > "$RL31/proj/src/B/C.lean"
printf 'import B.C\n\n-- the statement alone, for Comparator; nothing imports this file\ntheorem c_thm_stated : c = 1 := by\n  sorry\n' > "$RL31/proj/Challenge.lean"
printf -- '-- a note kept beside the sources; nothing imports this file\naxiom a_note : True\n' > "$RL31/proj/notes/Notes/Extra.lean"
{ gp "$RL31" init -q . && gp "$RL31" add -A && gp "$RL31" commit -q -m libs; } > /dev/null 2>&1 \
  || { echo "could not make the repository with libraries outside its sources"; exit 2; }
CL31=$(gp "$RL31" rev-parse HEAD)
prof fix-libs "TGT_GIT_URL=\"$RL31\"" "TGT_GIT_COMMIT=$CL31" 'TGT_LIBS_OUTSIDE_SRC="Challenge Notes.Extra"'
WL31="$NEW/work-fix-libs"
cenv RH_TARGET=fix-libs /bin/bash "$NEW/scripts/01_fetch.sh" > "$T31/libs01.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$WL31/download/source.tar" ]; res "01 for a made-up target whose lakefile has two libraries outside its sources writes its tar file" $? "status $rc: $(tailof "$T31/libs01.out")"
cenv RH_TARGET=fix-libs TGT_LIBS_OUTSIDE_SRC= /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$T31/libs02no.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q -F "REFUSED: lakefile.toml: library 2 ('Challenge'): its sources are in the project's own directory, not under src, the directory 03 reads (TGT_SRC_DIR)" "$T31/libs02no.out" \
  && grep -q -F "REFUSED: lakefile.toml: library 3 ('Notes.Extra'): its sources are in notes, not under src" "$T31/libs02no.out" \
  && grep -q 'the tree was not put in place' "$T31/libs02no.out" && [ ! -e "$WL31/extract" ]
res "02 for it with TGT_LIBS_OUTSIDE_SRC empty (given so in the environment) refuses both libraries and puts no tree in place" $? "status $rc: $(tailof "$T31/libs02no.out" 3 | cut -c1-400)"
cenv RH_TARGET=fix-libs /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$T31/libs02.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q -x -F "$LIBS31" "$T31/libs02.out" && grep -q -x -F "  Challenge          in the project's own directory (roots: Challenge)" "$T31/libs02.out" \
  && grep -q -x -F '  Notes.Extra        in notes (roots: Notes.Extra)' "$T31/libs02.out" && ! grep -q '^REFUSED' "$T31/libs02.out" \
  && [ -f "$WL31/extract/proj/Challenge.lean" ] && [ -f "$WL31/extract/proj/notes/Notes/Extra.lean" ] && [ -f "$WL31/extract/proj/src/A.lean" ]
res "02 with the profile's TGT_LIBS_OUTSIDE_SRC=\"Challenge Notes.Extra\" extracts the project and shows the two under 'libraries outside src'" $? "status $rc: $(tailof "$T31/libs02.out" 4 | cut -c1-400)"
cenv RH_TARGET=fix-libs /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$T31/libs02b.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'already extracted' "$T31/libs02b.out" && grep -q -x -F "$LIBS31" "$T31/libs02b.out" && grep -q -x -F "  Challenge          in the project's own directory (roots: Challenge)" "$T31/libs02b.out"
res "...and again, on the tree in place, shows them too" $? "status $rc: $(tailof "$T31/libs02b.out" 4 | cut -c1-400)"
cenv RH_TARGET=fix-libs /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 > "$T31/libs03.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'libraries the profile names as outside the source directory (TGT_LIBS_OUTSIDE_SRC; 02 and 04 check that they are), whose files this scan does not read: Challenge Notes.Extra$' "$T31/libs03.out" \
  && grep -q 'scanning 2 Lean files' "$T31/libs03.out" && ! grep -q -E '^(sorry|axiom) +[1-9]' "$T31/libs03.out"
res "03 for it says that it does not read the libraries named, scans the 2 sources under src, and counts neither the 'sorry' nor the 'axiom' in the libraries' files" $? "status $rc: $(grep -i -E 'libraries|scanning|^(sorry|axiom) ' "$T31/libs03.out" | tr '\n' ' ' | cut -c1-400)"
! grep -q 'TGT_LIBS_OUTSIDE_SRC' "$TMPD/c18.a3"
res "...and for a target whose profile names none (case 18's) prints no such line" $? "$(grep 'TGT_LIBS_OUTSIDE_SRC' "$TMPD/c18.a3")"
: > "$T31/lake.log"
cenv "${GIT31[@]}" PATH="$STUB31:$CPATH" ELAN_HOME="$EH31" RH_TARGET=fix-libs TGT_LIBS_OUTSIDE_SRC= /bin/bash "$NEW/scripts/04_setup_toolchain.sh" > "$T31/libs04no.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q -F "REFUSED: lakefile.toml: library 2 ('Challenge'): its sources are in the project's own directory, not under src" "$T31/libs04no.out" \
  && grep -q 'the project files were refused, or do not match what was recorded' "$T31/libs04no.out" && [ ! -s "$T31/lake.log" ] && [ ! -e "$WL31/extract/proj/.lake" ]
res "04 for it with TGT_LIBS_OUTSIDE_SRC empty stops at its own check of the project files, before it clones anything or runs lake" $? "status $rc: $(tailof "$T31/libs04no.out" 3 | cut -c1-400) / lake: $(tailof "$T31/lake.log")"
# A smoke module must be a module of the sources 03 read: 'lake build +Challenge' would compile the library's own file
cenv "${GIT31[@]}" PATH="$STUB31:$CPATH" ELAN_HOME="$EH31" RH_TARGET=fix-libs TGT_SMOKE_TARGETS="A Challenge" /bin/bash "$NEW/scripts/04_setup_toolchain.sh" > "$T31/libs04smoke.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q -F "the smoke module Challenge (TGT_SMOKE_TARGETS) has no source file" "$T31/libs04smoke.out" && grep -q 'nothing was run' "$T31/libs04smoke.out" \
  && [ ! -s "$T31/lake.log" ] && [ ! -e "$WL31/extract/proj/.lake" ]
res "04 for it with a smoke module that has no source under src (TGT_SMOKE_TARGETS=\"A Challenge\", the second a module of the library) stops before it clones anything or runs lake" $? "status $rc: $(tailof "$T31/libs04smoke.out" 3 | cut -c1-400) / lake: $(tailof "$T31/lake.log")"
cenv "${GIT31[@]}" PATH="$STUB31:$CPATH" ELAN_HOME="$EH31" RH_TARGET=fix-libs /bin/bash "$NEW/scripts/04_setup_toolchain.sh" > "$T31/libs04.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "'lake exe mathlib/cache get' failed" "$T31/libs04.out" && [ "$(cat "$T31/lake.log")" = "lake exe mathlib/cache get (LAKE_NO_CACHE=1)" ] \
  && cat "$WL31"/logs/setup-*.log 2>/dev/null | grep -q -x -F "$LIBS31" \
  && cat "$WL31"/logs/setup-*.log 2>/dev/null | grep -q -x -F '  Notes.Extra        in notes (roots: Notes.Extra)'
res "04 with the profile's TGT_LIBS_OUTSIDE_SRC gives its own check the names (its log lists the two libraries), and goes on to 'lake exe mathlib/cache get' (the stand-in lake then fails)" $? "status $rc: $(tailof "$T31/libs04.out" 3 | cut -c1-400) / lake: $(tailof "$T31/lake.log")"
# What is left if a source imports such a library after all: its module is compiled, and has no source under src. The
# replay's summary (09) then counts it and does not say that every source module is compiled and passing. Here with
# made-up compiled files and results, in which leanchecker passed each module
LB31="$T31/libs_build"; mkdir -p "$LB31/B"
for m in A B/C; do : > "$LB31/$m.olean"; echo made-up-stamp > "$LB31/$m.olean.hash"; done
printf '%s\t0\t1\tmade-up-stamp\t1700000000\n' A B.C > "$T31/libs_results.tsv"
cenv "$PY3" -I -B "$TOOLS28" replay-summary --lib "$LB31" --src "$WL31/extract/proj/src" --results "$T31/libs_results.tsv" --require-complete > "$T31/libs09a.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q -x '  every source module compiled and passing: yes' "$T31/libs09a.out" && ! grep -q 'no source file' "$T31/libs09a.out"
res "replay-summary for it, its two sources compiled and passed and nothing else compiled: complete (status 0 with --require-complete)" $? "status $rc: $(grep -E 'modules:|no source|compiled and passing' "$T31/libs09a.out" | tr '\n' ' ' | cut -c1-300)"
: > "$LB31/Challenge.olean"; echo made-up-stamp > "$LB31/Challenge.olean.hash"; printf '%s\t0\t1\tmade-up-stamp\t1700000000\n' Challenge >> "$T31/libs_results.tsv"
cenv "$PY3" -I -B "$TOOLS28" replay-summary --lib "$LB31" --src "$WL31/extract/proj/src" --results "$T31/libs_results.tsv" --require-complete > "$T31/libs09b.out" 2>&1; rc=$?
[ "$rc" = 3 ] && grep -q -x '  compiled modules with no source file: 1' "$T31/libs09b.out" && grep -q -x '  every source module compiled and passing: no' "$T31/libs09b.out"
res "...and with the module Challenge compiled too, and passed: 'compiled modules with no source file: 1', and not complete (status 3)" $? "status $rc: $(grep -E 'modules:|no source|compiled and passing' "$T31/libs09b.out" | tr '\n' ' ' | cut -c1-300)"
# A source whose file name has a dot in it gets, read as these steps read a path, the name of a module in a directory:
# Challenge.Evil.lean beside a compiled Challenge/Evil.olean. Lake compiles Challenge.Evil from Challenge/Evil.lean only,
# so the one is not the source of the other, and the summary must not take it for that
SD31="$T31/libs_dotted_src"; LD31="$T31/libs_dotted_build"; mkdir -p "$SD31/B" "$LD31/B" "$LD31/Challenge"
: > "$SD31/A.lean"; : > "$SD31/B/C.lean"; : > "$SD31/Challenge.Evil.lean"
for m in A B/C Challenge/Evil; do : > "$LD31/$m.olean"; echo made-up-stamp > "$LD31/$m.olean.hash"; done
printf '%s\t0\t1\tmade-up-stamp\t1700000000\n' A B.C Challenge.Evil > "$T31/libs_dotted_results.tsv"
cenv "$PY3" -I -B "$TOOLS28" replay-summary --lib "$LD31" --src "$SD31" --results "$T31/libs_dotted_results.tsv" --require-complete > "$T31/libs09c.out" 2>&1; rc=$?
[ "$rc" = 3 ] && grep -q -x '  compiled modules with no source file: 1' "$T31/libs09c.out" && grep -q -x '  source modules not compiled: 1' "$T31/libs09c.out" \
  && grep -q -x '  every source module compiled and passing: no' "$T31/libs09c.out"
res "replay-summary with a source Challenge.Evil.lean and a compiled Challenge/Evil.olean, every module passed: neither is taken for the other ('compiled modules with no source file: 1', 'source modules not compiled: 1'), and not complete (status 3)" $? "status $rc: $(grep -E 'modules:|no source|not compiled|compiled and passing' "$T31/libs09c.out" | tr '\n' ' ' | cut -c1-300)"
# Two files of one module name, read as these steps read a path: Lib/X.Y and Lib/X/Y, as sources and as compiled files.
# One would take the other's place in every list (Lake compiles Lib/X.Y.lean, as a module of two parts, when a library's
# globs take it in), so the summary counts such files and does not say complete, though every name it knows has passed
SE31="$T31/libs_twin_src"; LE31="$T31/libs_twin_build"; mkdir -p "$SE31/Lib/X" "$LE31/Lib/X"
: > "$SE31/A.lean"; : > "$SE31/Lib/X.Y.lean"; : > "$SE31/Lib/X/Y.lean"
for m in A Lib/X.Y Lib/X/Y; do : > "$LE31/$m.olean"; echo made-up-stamp > "$LE31/$m.olean.hash"; done
printf '%s\t0\t1\tmade-up-stamp\t1700000000\n' A Lib.X.Y > "$T31/libs_twin_results.tsv"
for py in "$PY3" ${PY31B:+"$PY31B"}; do
  v=$(pyv "$py")
  cenv "$py" -I -B "$TOOLS28" replay-summary --lib "$LE31" --src "$SE31" --results "$T31/libs_twin_results.tsv" --require-c3 > "$T31/libs09d.out" 2>&1; rc=$?
  [ "$rc" = 3 ] && grep -q -x '  files with a dot inside a part of their path, or with a module name another file has: 4' "$T31/libs09d.out" \
    && grep -q -x '  every source module compiled and passing: no' "$T31/libs09d.out" && ! grep -q Traceback "$T31/libs09d.out"
  res "replay-summary (Python $v) with two sources and two compiled files of the one name Lib.X.Y, that name passed: counts the four files as ambiguous and does not say complete (status 3 with --require-c3)" $? "status $rc: $(grep -E 'modules:|dot inside|compiled and passing|all of these' "$T31/libs09d.out" | tr '\n' ' ' | cut -c1-300)"
done

# 00's sizes are the default target's: for another target it says that it does not know them. A stand-in df gives 100 GB
# free, and on macOS a stand-in sysctl a files-in-use limit of 263168, so that the default target's WARNING and NOTE are due
S31D="$T31/stub_sizes"; mkdir -p "$S31D"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: 100 GB free, whatever the directory\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/made-up 1000000000 895142400 104857600 90%% /"\n' > "$S31D/df"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: a files-in-use limit of 263168; any other question goes to the real sysctl\nif [ "$*" = "-n kern.maxvnodes" ]; then echo 263168; exit 0; fi\nexec /usr/sbin/sysctl "$@"\n' > "$S31D/sysctl"
chmod +x "$S31D"/*
P31D="$S31D:$PYBIN:/usr/bin:/bin:/usr/sbin:/sbin"
if cenv PATH="$P31D" /bin/sh -c 'command -v elan || command -v lake' > /dev/null 2>&1; then
  skip "00 and the sizes it prints: an elan or lake is on the narrower PATH"
else
  machine31() { sed -n '/^== Machine/,$p' "$1"; }      # what 00 prints from its Machine section on
  cenv PATH="$P31D" RH_WORKDIR="$T31/w00sizes" /bin/bash "$NEW/scripts/00_check_prereqs.sh" > "$T31/p00d.out" 2>&1
  grep -q -F '175,187 source files' "$T31/p00d.out" && grep -q -F 'full build:                1.2 to 1.4 TB' "$T31/p00d.out" \
    && grep -q -x -F '  WARNING: 100 GB free is less than a full build needs even with setup files removed.' "$T31/p00d.out"
  res "00 for the default target, with 100 GB free: prints that target's sizes and the WARNING that a full build needs more" $? "$(machine31 "$T31/p00d.out" | tail -n 5 | tr '\n' ' ' | cut -c1-400)"
  if [ "$HAVE_BASE" = 1 ]; then
    cenv PATH="$P31D" RH_WORKDIR="$T31/w00sizes" /bin/bash "$MAIN/scripts/00_check_prereqs.sh" > "$T31/p00d.base" 2>&1
    machine31 "$T31/p00d.base" > "$T31/p00d.b"; machine31 "$T31/p00d.out" > "$T31/p00d.n"
    [ -s "$T31/p00d.b" ] && cmp -s "$T31/p00d.b" "$T31/p00d.n"
    res "...and from its Machine section on, what it prints is the base commit's byte for byte" $? "$(diff "$T31/p00d.b" "$T31/p00d.n" | grep '^[<>]' | head -4 | tr '\n' ' ')"
  else
    skip "00 against the base commit's: no base commit"
  fi
  cenv PATH="$P31D" RH_TARGET=fix-git RH_WORKDIR="$T31/w00sizes-fix" /bin/bash "$NEW/scripts/00_check_prereqs.sh" > "$T31/p00f.out" 2>&1
  grep -q -F "The sizes of target 'fix-git' are not known to this script" "$T31/p00f.out" && grep -q -x '== Disk space' "$T31/p00f.out" \
    && grep -q -x -F '  free disk there:   100 GB' "$T31/p00f.out" \
    && ! grep -q -E '175,187|1\.[24] TB|WARNING|240,000|close to this limit|too low for the full build|less than a full build' "$T31/p00f.out"
  res "00 for a made-up target, with 100 GB free: says that it does not know the target's sizes, and prints none of the default target's sizes, no WARNING about free space and nothing of that target's note on a limit" $? "$(machine31 "$T31/p00f.out" | tail -n 8 | tr '\n' ' ' | cut -c1-500)"
  if [ "$(uname -s)" = Darwin ]; then
    grep -q -F "NOTE: whether this limit matters depends on how many modules target 'fix-git' has" "$T31/p00f.out" \
      && grep -q -F 'NOTE: the last modules map about 240,000 files at once, close to this limit.' "$T31/p00d.out"
    res "...and on macOS, with a files-in-use limit of 263168, gives the rule for that limit where the default target gets its figure of 240,000 files" $? "$(grep -A 1 'NOTE: ' "$T31/p00f.out" | tr '\n' ' ' | cut -c1-300)"
  else
    skip "00's note on macOS's files-in-use limit: this system is not macOS"
  fi
  [ ! -e "$T31/w00sizes" ] && [ ! -e "$T31/w00sizes-fix" ]; res "...and neither run wrote a working directory" $? "$(ls -d "$T31"/w00sizes* 2>&1 | head -n 2 | tr '\n' ' ')"
fi

ls -d "$TMPD"/tmp/rhv-clone.* > /dev/null 2>&1; [ $? != 0 ]
res "04 left no directory it cloned from (rhv-clone.*) in TMPDIR, whether it finished or stopped" $? "$(ls -d "$TMPD"/tmp/rhv-clone.* 2>&1 | head -n 3)"

# ================================================================ 32
section 32 "nothing reached for the network or the toolchain in cases 14 to 31"
[ ! -s "$STUBLOG" ] && [ ! -s "$GLOG" ]; res "no stand-in of curl, wget, lake, elan, leanchecker or gcloud was called" $? "$(tailof "$STUBLOG" 3) $(tailof "$GLOG" 3)"

echo "$N checks, $FAILS failed, $SKIPS skipped ($(( $(date +%s) - START )) s)"
[ "$FAILS" = 0 ]
