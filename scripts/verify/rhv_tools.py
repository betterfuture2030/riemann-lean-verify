#!/usr/bin/env python3
"""Helpers for the numbered scripts in scripts/. Not meant to be run by hand.

Subcommands
  git-export       write the files of one commit of a git repository to a tar file (01)
  tar-inspect      list a tarball without extracting it and check every entry (02)
  project-info     toolchain, Mathlib revision and file hashes of the extracted project (02)
  audit-literals   print the fixed strings the source audit pre-filters on (03)
  audit-classify   classify pre-filtered source lines into audit categories (03)
  axioms-body      print the body of the axiom check file with the target's constant names in it (08)
  axioms-summary   read the output of the axiom check and decide pass or fail (08)
  replay-plan      decide which compiled modules still need a kernel re-check (09)
  replay-summary   summarise kernel re-check results (09)
  import-graph     read the import lines of every source file (09)
  closure-worker   run the stock checker on a batch of modules, each with only its imports visible (09)
  replay-driver-check   compare the second replay program's source with the toolchain's (09)

What is a fact about one archive (its top directory, where its sources are, the names of the
constants its theorems are about) is an argument. Every such argument has the value of the default
target (targets/alpoge-rh) as its default, so a command line that names none of them does what it
did before there were targets. targets/README.md describes the settings.

Only the Python standard library is used. Python 3.6 or later.
Nothing here writes outside the files named on its command line, apart from a temporary <name>.tmp
beside a file it writes, which is renamed into place. git-export runs git, which reads the repository
it is given and changes nothing in it.
"""
import argparse
import collections
import hashlib
import json
import os
import random
import re
import sys
import time


# --------------------------------------------------------------------------------------------
# Shared helpers

CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f]")


def not_utf8(name):
    """Whether a name Python's tarfile read is not UTF-8. tarfile decodes a name of a POSIX ustar or GNU header with
    the file system's encoding, giving each byte it cannot decode as a surrogate escape (\\udc80 to \\udcff): with
    UTF-8 on most systems, but with ASCII under Python 3.6 in the C locale, where a UTF-8 name is all escapes. So the
    bytes it read are given back and read as UTF-8."""
    try:
        name.encode("utf-8", "surrogateescape").decode("utf-8")
        return False
    except UnicodeError:
        return True


def dir_arg_problem(value, closing_slash):
    """What is wrong with a relative directory name given as an argument, or None if nothing is.

    These names are compared with the names of archive entries as plain text, so they must have the
    one form an entry name has: components separated by single slashes, none of them empty, '.' or
    '..', no backslash, no control character. With closing_slash the name must end in a slash, as an
    archive prefix does: without one, 'lean' would also accept the entries of 'leanx/'."""
    if closing_slash:
        if not value.endswith("/"):
            return "must end with a slash"
        value = value[:-1]
    if not value:
        return "is empty"
    if "\\" in value or CONTROL_CHARS.search(value):
        return "has a backslash or a control character in it"
    if any(p in ("", ".", "..") for p in value.split("/")):
        return "must be a relative path with no empty, '.' or '..' component"
    return None


# Characters that the HFS+ file system leaves out when it compares names (APFS does not), so that
# '.g‌it' is '.git' there. git refuses '.git' spelled with them at checkout, and so do these checks.
HFS_IGNORABLE = re.compile("[‌-‏‪-‮⁪-⁯﻿]")


def reserved_component(comp):
    """Why one component of an entry's name is refused although it is a plain name, or None.

    '.git', in the spellings of it that git itself refuses at checkout and this check knows of: in any
    case, with characters HFS+ ignores in names, with dots or spaces at the end, followed by ':' and the
    name of an NTFS stream, or as 'git~1', which Windows may take for the same name. A directory of that
    name would be a git repository, with a configuration git obeys, inside the project.
    '.lake', in the same spellings: Lake keeps compiled modules and fetched packages there, and files
    brought there by the archive would be used by the build without being compiled from the sources that
    are inspected."""
    c = HFS_IGNORABLE.sub("", comp).split(":", 1)[0].rstrip(". ").casefold()
    if c in (".git", "git~1"):
        return "a '.git' component (git's own directory, refused in any spelling)"
    if c in (".lake", "lake~1"):
        return "a '.lake' component (Lake's directory of build products and packages)"
    return None


def repository_marker(base):
    """Why a file of this name is refused, or None. git takes any directory that holds a file named HEAD (with
    objects/ and refs/, or a file named commondir, beside it) for a repository, whatever the directory is called,
    and then obeys the configuration in it whenever git runs there or below, for example in a shell prompt that
    shows the branch. So no file may be named HEAD, in any case and in the spellings refused for '.git'. A
    directory named so is not refused: git needs a file."""
    if HFS_IGNORABLE.sub("", base).split(":", 1)[0].rstrip(". ").casefold() == "head":
        return ("a file named 'HEAD' (with objects/ and refs/ beside it git takes the directory for a repository "
                "and obeys its configuration; refused in any spelling)")
    return None


# The longest name, and the longest component of a name, that an entry may have: macOS's limits for a path
# (PATH_MAX) and for one name in it (NAME_MAX), in bytes of UTF-8. The default target's longest name has 244
# bytes. The limits also keep the checks below cheap whatever an archive holds.
MAX_NAME_BYTES = 1024
MAX_COMPONENT_BYTES = 255


def name_too_long(name):
    """Why a name is longer than an entry's name may be, or None. name is str or bytes."""
    b = name.encode("utf-8", "surrogateescape") if isinstance(name, str) else name
    if len(b) > MAX_NAME_BYTES:
        return "a name longer than %d bytes (%d)" % (MAX_NAME_BYTES, len(b))
    longest = max(len(c) for c in b.split(b"/"))
    if longest > MAX_COMPONENT_BYTES:
        return "a component of the name longer than %d bytes (%d)" % (MAX_COMPONENT_BYTES, longest)
    return None


def name_tree(names):
    """The names as a tree of their components, in time and memory that grow with the total length of the names
    (a set of every path prefix would grow with the square of a name's depth). Returns the nodes, as a list of
    (parent node, component) in which node 0 is the top and a parent comes before its children, and a dict from
    each name to its node. Names may be str or bytes; components are split at '/'."""
    nodes, index, node_of = [(None, "")], {}, {}
    for n in names:
        p = 0
        for c in n.split("/" if isinstance(n, str) else b"/"):
            q = index.get((p, c))
            if q is None:
                q = index[(p, c)] = len(nodes)
                nodes.append((p, c))
            p = q
        node_of[n] = p
    return nodes, node_of


def node_path(nodes, i, sep="/"):
    parts = []
    while i:
        i, c = nodes[i]
        parts.append(c)
    return sep.join(reversed(parts))


def name_collisions(names):
    """Pairs of names, of entries or of the directories on the way to them, that differ as written and are
    one name on a file system that ignores case and Unicode normalisation, as macOS's does by default:
    there, extracting both leaves one. Each pair is (the first of the names in sorted order, another), and the
    pairs are in the sorted order of the second name.

    Names are folded one component at a time, which gives the same result as folding the whole path: '/' is
    left alone by the stripping of ignorable characters, by NFD (it is a starter, so nothing is reordered or
    combined across it) and by casefold (which maps one character at a time)."""
    import unicodedata
    nodes, _ = name_tree(names)
    folded, fold_of, members = [0], {}, {}
    for i in range(1, len(nodes)):
        parent, comp = nodes[i]
        k = (folded[parent], unicodedata.normalize("NFD", HFS_IGNORABLE.sub("", comp)).casefold())
        f = fold_of.setdefault(k, len(fold_of) + 1)
        folded.append(f)
        members.setdefault(f, []).append(i)
    out = []
    for group in members.values():
        if len(group) > 1:
            paths = sorted(node_path(nodes, i) for i in group)
            out.extend((paths[0], p) for p in paths[1:])
    out.sort(key=lambda pair: pair[1])
    return out


def below_files(names, files):
    """The names, of names, that have a name of files on the way to them: a file is where such a name needs a
    directory. In sorted order. files must be among names."""
    nodes, node_of = name_tree(names)
    is_file = bytearray(len(nodes))
    for f in files:
        is_file[node_of[f]] = 1
    under = bytearray(len(nodes))          # a file is on the way to this node
    for i in range(1, len(nodes)):
        p = nodes[i][0]
        under[i] = under[p] | is_file[p]
    return sorted(n for n in names if under[node_of[n]])


def unassigned_names(names):
    """The names with a character in them that is unassigned in the Unicode tables of the Python running
    this. How a file system folds the case of such a character, or normalises it, is not known here, so a
    collision with another name could not be ruled out: such names are refused, not passed."""
    import unicodedata
    return sorted(n for n in names if any(unicodedata.category(ch) == "Cn" for ch in n))


def usage_error(cmd, text):
    """An argument this tool cannot work with: one line on stderr and status 2, 'could not run'."""
    sys.stderr.write("rhv_tools: %s: %s\n" % (cmd, text))
    return 2

def load_json(path):
    if not path or not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=True, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, path)


def merge_expected(path, section, data):
    """Replace one top-level section of the expected-values file, keeping the others."""
    doc = load_json(path) or {}
    doc.setdefault("schema", 1)
    doc[section] = data
    write_json(path, doc)
    print("recorded section '%s' in %s" % (section, path))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def compare(label, got, want, diffs):
    """Record a difference between a computed value and a recorded one."""
    if want is None:
        return
    if got != want:
        diffs.append("%s: found %r, recorded %r" % (label, got, want))


def no_recorded_values(what, expected_path, section):
    """Print the one line that says a comparison did not take place.

    It is in capitals so that a first run, which has nothing to be compared with, cannot be read
    as a run that matched. It is not a failure: the status of the command is not changed by it."""
    if not expected_path:
        why = "no file of recorded values was named"
    elif not os.path.isfile(expected_path):
        why = "there is no file %s" % expected_path
    else:
        why = "%s has nothing in a section '%s'" % (expected_path, section)
    print("NO RECORDED VALUES TO COMPARE WITH for the %s: %s" % (what, why))


def report_comparison(what, expected_path, section, section_present, diffs):
    """Print the outcome of a comparison with recorded values. Returns True if all matched."""
    if not section_present:
        no_recorded_values(what, expected_path, section)
        return True
    if diffs:
        print("%s: DIFFERS from the recorded values in %s" % (what, expected_path))
        for d in diffs:
            print("  - " + d)
        return False
    print("%s: matches the recorded values in %s" % (what, expected_path))
    return True


# --------------------------------------------------------------------------------------------
# 01: the files of one commit of a git repository, as a tar file
#
# The tar file is written here, block by block. `git archive` and `git checkout` are not used,
# because both can change file contents according to attribute files inside the repository.
# Python's tarfile module is not used to write it, because the headers that module writes are
# not the same in every Python version. What is written depends on the commit, the subdirectory
# and the prefix, and on nothing else: not on the machine, the clock, the user, the locale, or
# the version of git or of Python. That is what lets the SHA-256 of the file be recorded and
# compared like a published tarball's.
#
# Every object is read with `git cat-file --batch`, which gives it as git stores it, and is
# checked against its name before it is used: the commit, each tree and each blob must have the
# SHA-1 it was asked for by. File names and modes are read from the trees themselves.
#
# The format is the one GNU tar writes and every common tar reads: for each file one 512-byte
# header and the contents, in the order of the names as bytes; a name longer than 100 bytes is
# given in full in a '././@LongLink' entry in front of its file. Mode 0644 or 0755, as the tree
# says; time 0; owner and group 0 with empty names; no entries for directories.

class Refused(Exception):
    """Something in the repository, or about the commit asked for, that git-export will not go on with."""


class GitFailed(Exception):
    """git could not be run, or did not answer as `git cat-file --batch` answers."""


# Variables that would make git read another object store than the one named with --git-dir.
GIT_ENV_NOT_PASSED_ON = ("GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR",
                         "GIT_NAMESPACE", "GIT_INDEX_FILE", "GIT_WORK_TREE")


def git_sha1():
    """A SHA-1 to check a git object against its name with."""
    try:
        return hashlib.sha1(usedforsecurity=False)      # Python 3.9 and later; needed where SHA-1 is restricted
    except TypeError:
        return hashlib.sha1()


def shown(name):
    """A file name from a git tree, for a message: quoted, with whatever is not printable text escaped."""
    return repr(name.decode("utf-8", "backslashreplace"))


class GitObjects:
    """The objects of one repository, read through one `git cat-file --batch` process. The type and size of a
    commit or tree are first asked of a second process, `git cat-file --batch-check`, which does not read the
    object's contents, so that one larger than git-export reads is refused before this tool holds it. (git may
    still have to build an object from its deltas to give it: an object stored as a long chain of deltas, or as a
    delta against a very large one, takes git that time and memory, and nothing here bounds them.)"""

    def __init__(self, git_dir):
        import subprocess
        env = {k: v for k, v in os.environ.items() if k not in GIT_ENV_NOT_PASSED_ON}
        # --no-replace-objects: the objects themselves, not ones a refs/replace entry puts in their place.
        base = ["git", "--no-replace-objects", "--git-dir", git_dir, "cat-file"]
        self.proc = subprocess.Popen(base + ["--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        self.check = subprocess.Popen(base + ["--batch-check"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)

    @staticmethod
    def _ask(proc, oid):
        """Send one object's name to a `git cat-file --batch` or `--batch-check` process and read the line it
        answers with. Returns (type, size), or None if the repository does not have the object."""
        want = oid.encode("ascii")
        try:
            proc.stdin.write(want + b"\n")
            proc.stdin.flush()
            line = proc.stdout.readline()
        except OSError:                                 # git has gone: a broken pipe
            line = b""
        if not line:
            raise GitFailed("git cat-file ended with status %s without an answer (its own message, if any, is above)"
                            % proc.wait())
        f = line.split()
        if len(f) == 2 and f[0] == want and f[1] == b"missing":
            return None
        if len(f) != 3 or f[0] != want or not f[2].isdigit():
            raise GitFailed("unexpected answer from git cat-file for %s: %r (a repository whose object names "
                            "are not SHA-1 is not supported)" % (oid, line[:200]))
        return f[1].decode("ascii", "replace"), int(f[2])

    def start(self, oid):
        """Ask for one object. Returns (type, size), or None if the repository does not have it. The
        contents are then read with read(), all of them, and closed with end()."""
        return self._ask(self.proc, oid)

    def read(self, n):
        data = self.proc.stdout.read(n)
        if len(data) != n:
            raise GitFailed("git cat-file ended in the middle of an object")
        return data

    def end(self):
        if self.proc.stdout.read(1) != b"\n":
            raise GitFailed("unexpected output from git cat-file after an object")

    def whole(self, oid, kind, limit, limit_text, too_large=None):
        """The contents of the commit or tree named oid, checked against that name. Refused, before anything of
        it is read, if it is larger than limit bytes; limit_text says why that is the limit, or too_large, given
        the size, gives the whole message."""
        head = self._ask(self.check, oid)
        if head is None:
            raise Refused("%s %s is not in the repository" % (kind, oid))
        if head[0] != kind:
            raise Refused("%s is a %s in the repository, not a %s" % (oid, head[0], kind))
        if head[1] > limit:
            if too_large is not None:
                raise Refused(too_large(head[1]))
            raise Refused("%s %s is %d bytes, and git-export reads at most %d bytes of a %s: %s"
                          % (kind, oid, head[1], limit, kind, limit_text))
        if self.start(oid) != head:
            raise GitFailed("git cat-file gave %s two different types or sizes" % oid)
        typ, size = head
        data = self.read(size)
        self.end()
        h = git_sha1()
        h.update(("%s %d" % (typ, size)).encode("ascii") + b"\0")
        h.update(data)
        if h.hexdigest() != oid:
            raise Refused("what git gives as %s %s has the SHA-1 %s: the repository is damaged or has been altered"
                          % (kind, oid, h.hexdigest()))
        return data

    def finish(self):
        """End the processes after the last object. Returns the exit status of the one that gave the contents
        (or the other's, if only that one failed)."""
        rcs = []
        for proc in (self.proc, self.check):
            proc.stdin.close()
            proc.stdout.read()
            proc.stdout.close()
            rcs.append(proc.wait())
        return rcs[0] or rcs[1]

    def abort(self):
        for proc in (self.proc, self.check):
            if proc.poll() is None:
                proc.kill()
            for fh in (proc.stdin, proc.stdout):
                try:
                    fh.close()
                except OSError:
                    pass
            proc.wait()


def iter_tree(data, oid):
    """The entries of a git tree object as stored, one at a time: (mode, name as bytes, name of the object)."""
    i, n = 0, len(data)
    while i < n:
        sp = data.find(b" ", i, i + 8)
        nul = data.find(b"\0", sp + 1) if sp >= 0 else -1
        if sp < 0 or nul < 0 or nul + 21 > n or not re.match(rb"[0-7]{1,7}\Z", data[i:sp]):
            raise Refused("tree %s is not in the form of a git tree" % oid)
        yield int(data[i:sp], 8), data[sp + 1:nul], data[nul + 1:nul + 21].hex()
        i = nul + 21


# The most entries (files and directories), and the most bytes of contents, that git-export reads and writes unless
# told otherwise: a little over ten times the default target's 175,190 files, and 64 GiB. git stores a directory once
# however many times a commit names it, so a repository of a few kilobytes can name more files and directories than
# any disk holds. So every entry of every tree read counts, a directory once each time the commit names it, and
# git-export stops as soon as the count passes the limit, before the next entry is looked at. The paths of the
# entries are held in memory and written into the tar file, so their bytes are counted too, against
# MAX_EXPORT_PATH_BYTES (the default target's come to about 18 MB). Each tree is read from git once and kept, up to
# MAX_TREE_CACHE_BYTES of them, however many times the commit names it: so the time a repository of a few
# kilobytes can take, naming the same few trees again and again, goes with the entries counted and not with
# git's work to give each tree.
MAX_EXPORT_FILES = 2000000
MAX_EXPORT_BYTES = 64 << 30
MAX_EXPORT_PATH_BYTES = 256 << 20
# The largest commit and the largest tree that git-export reads: both are read whole, so their size is asked of git
# first. A tree is also refused if it is larger than the entries still allowed could be: an entry takes at most
# TREE_ENTRY_MAX_BYTES (a mode of up to 7 digits, a space, a name of up to 255 bytes, a NUL and 20 bytes of the
# object's name), and a name longer than that stops git-export at once.
MAX_COMMIT_BYTES = 1 << 20
MAX_TREE_BYTES = 64 << 20
TREE_ENTRY_MAX_BYTES = 7 + 1 + 255 + 1 + 20
MAX_TREE_CACHE_BYTES = 64 << 20


def git_tree_files(git, tree, max_files=MAX_EXPORT_FILES):
    """Every file under one tree: [(path as bytes, 0o644 or 0o755, name of the blob)], the first 25 of the things
    there that cannot be exported, and how many there are. Kinds of entry, by the mode git records: 040000 a
    directory, 100644 and 100755 a file, 120000 a symbolic link, 160000 a submodule.

    Raises Refused as soon as more than max_files entries have been read, whatever their kind, a directory counted
    again each time it is named; as soon as a name of more than MAX_COMPONENT_BYTES is read; as soon as the paths
    of the entries read come to more than MAX_EXPORT_PATH_BYTES; and before reading a tree larger than
    MAX_TREE_BYTES or than the entries still allowed could be. So the work this tool does, and the memory it uses,
    grow with max_files and not with what the repository names. (git's own work to build each object from its
    deltas is not bounded here: see GitObjects.)"""
    files, problems = [], []
    n_problems = n_entries = n_path_bytes = 0

    def note(text):
        nonlocal n_problems
        n_problems += 1
        if len(problems) < 25:
            problems.append(text)

    too_many = ("the tree has more than %d entries, files and directories, a directory counted each time the commit "
                "names it; git-export stops at %d (--max-files)" % (max_files, max_files))
    stack = [(tree, b"")]
    cache, n_cached = {}, 0
    while stack:
        oid, base = stack.pop()
        left = max_files - n_entries

        def too_large(size):
            return (too_many if left == 0 else
                    "tree %s is %d bytes, more than the %d entries still allowed can take (at most %d bytes each): "
                    "it has more entries than git-export reads (%d in all, --max-files), or a name longer than %d "
                    "bytes" % (oid, size, left, TREE_ENTRY_MAX_BYTES, max_files, MAX_COMPONENT_BYTES))
        data = cache.get(oid)
        if data is not None:
            if len(data) > left * TREE_ENTRY_MAX_BYTES:
                raise Refused(too_large(len(data)))
        elif left * TREE_ENTRY_MAX_BYTES < MAX_TREE_BYTES:
            # No entry takes more than TREE_ENTRY_MAX_BYTES, so a tree larger than this has more entries than are
            # still allowed: the count is over the limit, and the tree need not be read to know it.
            data = git.whole(oid, "tree", left * TREE_ENTRY_MAX_BYTES, None, too_large=too_large)
        else:
            data = git.whole(oid, "tree", MAX_TREE_BYTES, "the most for one directory")
        if oid not in cache and n_cached + len(data) <= MAX_TREE_CACHE_BYTES:
            cache[oid] = data
            n_cached += len(data)
        for mode, name, child in iter_tree(data, oid):
            n_entries += 1
            if n_entries > max_files:
                raise Refused(too_many)
            if len(name) > MAX_COMPONENT_BYTES:
                raise Refused("a name longer than %d bytes (%d) in tree %s, in %s: %s"
                              % (MAX_COMPONENT_BYTES, len(name), oid, shown(base or b"."), shown(name[:200] + b"...")))
            path = base + name
            n_path_bytes += len(path)
            if n_path_bytes > MAX_EXPORT_PATH_BYTES:
                raise Refused("the paths of the tree's entries come to more than %d bytes, a directory's counted each "
                              "time the commit names it; git-export stops there" % MAX_EXPORT_PATH_BYTES)
            kind = mode & 0o170000
            if name in (b"", b".", b"..") or b"/" in name:
                note("an entry whose name is empty, '.', '..' or has a slash in it: %s" % shown(path))
            elif name_too_long(path):
                # Nothing below such a name is looked at.
                note("%s: %s" % (name_too_long(path), shown(path[:200] + b"...")))
            elif reserved_component(name.decode("utf-8", "replace")):
                note("%s: %s" % (reserved_component(name.decode("utf-8", "replace")), shown(path)))
            elif kind == 0o040000:
                stack.append((child, path + b"/"))
            elif kind == 0o100000 and repository_marker(name.decode("utf-8", "replace")):
                note("%s: %s" % (repository_marker(name.decode("utf-8", "replace")), shown(path)))
            elif kind == 0o100000:
                files.append((path, 0o755 if mode & 0o100 else 0o644, child))
            elif kind == 0o120000:
                note("symbolic link: %s" % shown(path))
            elif kind == 0o160000:
                note("submodule: %s" % shown(path))
            else:
                note("entry of a kind this tool does not know (mode %o): %s" % (mode, shown(path)))
    files.sort(key=lambda f: f[0])
    names = set()
    for path, _mode, _oid in files:
        try:
            path.decode("utf-8")
        except UnicodeDecodeError:
            note("a name that is not UTF-8: %s" % shown(path))
        if path in names:
            note("two entries with one name: %s" % shown(path))
        names.add(path)
    for path in below_files(names, names):
        note("a file where another entry needs a directory, on the way to %s" % shown(path))
    decoded = [p.decode("utf-8", "replace") for p in names]
    for one, other in name_collisions(decoded):
        note("two names that are one where case and Unicode normalisation are ignored, as on macOS: "
             "%s and %s" % (one, other))
    for n in unassigned_names(decoded):
        note("a character unassigned in Unicode %s, so a collision cannot be ruled out: %s"
             % (__import__("unicodedata").unidata_version, n))
    return files, problems, n_problems


def tar_header(name, mode, size, typeflag):
    """One 512-byte tar header in GNU tar's format, with no time, no owner and no group."""
    if len(name) > 100 or size >= 8 ** 11:
        raise ValueError("name or size too long for a tar header")
    h = bytearray(512)
    h[0:len(name)] = name
    h[100:108] = b"%07o\0" % mode
    h[108:116] = b"0000000\0"                   # owner
    h[116:124] = b"0000000\0"                   # group
    h[124:136] = b"%011o\0" % size
    h[136:148] = b"00000000000\0"               # time of last change
    h[148:156] = b"        "                    # the checksum is taken with its own field as spaces
    h[156:157] = typeflag
    h[257:265] = b"ustar  \0"                   # owner and group names, at 265 and 297, stay empty
    h[148:156] = b"%06o\0 " % sum(h)
    return bytes(h)


def cmd_git_export(a):
    """Write the files of one commit, or of one directory of it, to a tar file. The last line printed is
    'sha256 <of the file> entries <number of files>'.

    Exit status: 0 written; 1 refused (the commit is not named by all 40 characters, is not in the repository
    or is not a commit; the directory is not in it; a symbolic link, a submodule, a file named HEAD or an
    unusable name is among the files; there are more entries, files and directories, than --max-files allows,
    or more bytes in the files than --max-bytes; a commit or a tree is larger than git-export reads; an object
    does not have the SHA-1 it is named by); 2 could not run. Unless the status is 0 the file named with --out
    is left as it was."""
    import shutil
    cmd = "git-export"
    commit = a.commit.lower()
    if not re.match(r"[0-9a-f]{40}\Z", commit):
        sys.stderr.write("git-export: REFUSED: --commit must be all 40 hexadecimal characters of the commit's name, "
                         "and %r is not. A branch or tag name is not accepted: it can come to mean another commit.\n" % a.commit)
        return 1
    problem = dir_arg_problem(a.prefix, True)
    if problem:
        return usage_error(cmd, "--prefix %r %s" % (a.prefix, problem))
    subdir = a.subdir.rstrip("/")
    if a.subdir and dir_arg_problem(subdir, False):
        return usage_error(cmd, "--subdir %r %s" % (a.subdir, dir_arg_problem(subdir, False)))
    if not os.path.isdir(a.git_dir):
        return usage_error(cmd, "--git-dir %s is not a directory" % a.git_dir)
    if not shutil.which("git"):
        return usage_error(cmd, "git was not found on the PATH")
    prefix = a.prefix.encode("utf-8")
    tmp = a.out + ".tmp"
    git = GitObjects(a.git_dir)
    try:
        m = re.match(rb"tree ([0-9a-f]{40})\n", git.whole(commit, "commit", MAX_COMMIT_BYTES, "the most for a commit"))
        if not m:
            raise Refused("commit %s does not begin with the name of its tree" % commit)
        tree = m.group(1).decode("ascii")
        print("git-export: commit %s, tree %s" % (commit, tree))
        if subdir:
            for comp in subdir.encode("utf-8").split(b"/"):
                found = [e for e in iter_tree(git.whole(tree, "tree", MAX_TREE_BYTES, "the most for one directory"),
                                              tree) if e[1] == comp]
                if len(found) != 1 or found[0][0] & 0o170000 != 0o040000:
                    raise Refused("%s is not a directory of commit %s" % (subdir, commit))
                tree = found[0][2]
            print("git-export: directory %s of it, tree %s" % (subdir, tree))
        files, problems, n_problems = git_tree_files(git, tree, a.max_files)
        if n_problems:
            raise Refused("%d things in %s cannot be written to a tar file (showing up to 25)\n  - %s" % (
                n_problems, "directory %s of commit %s" % (subdir, commit) if subdir else "commit " + commit,
                "\n  - ".join(problems)))
        if not files:
            raise Refused("there are no files to write")
        total = n_exec = 0
        with open(tmp, "wb") as out:
            for path, mode, oid in files:
                name = prefix + path
                head = git.start(oid)
                if head is None or head[0] != "blob":
                    raise Refused("%s, the contents of %s, is %s" % (
                        oid, shown(path), "not in the repository" if head is None else "a %s, not a blob" % head[0]))
                size = head[1]
                if size >= 8 ** 11:
                    raise Refused("%s is larger than a tar header can say (%d bytes)" % (shown(path), size))
                if total + size > a.max_bytes:
                    raise Refused("the files come to more than %d bytes of contents; git-export stops at %d "
                                  "(--max-bytes)" % (a.max_bytes, a.max_bytes))
                if len(name) > 100:
                    long_name = name + b"\0"
                    out.write(tar_header(b"././@LongLink", 0, len(long_name), b"L"))
                    out.write(long_name + b"\0" * (-len(long_name) % 512))
                out.write(tar_header(name[:100], mode, size, b"0"))
                h = git_sha1()
                h.update(b"blob %d\0" % size)
                left = size
                while left:
                    chunk = git.read(min(left, 1 << 20))
                    h.update(chunk)
                    out.write(chunk)
                    left -= len(chunk)
                git.end()
                if h.hexdigest() != oid:
                    raise Refused("what git gives as blob %s, the contents of %s, has the SHA-1 %s: the repository "
                                  "is damaged or has been altered" % (oid, shown(path), h.hexdigest()))
                out.write(b"\0" * (-size % 512))
                total += size
                n_exec += 1 if mode == 0o755 else 0
            out.write(b"\0" * 1024)                         # the end of the archive: two empty blocks,
            out.write(b"\0" * (-out.tell() % 10240))        # and the file filled up to a whole record
            out.flush()
            os.fsync(out.fileno())
        rc = git.finish()
        if rc != 0:
            raise GitFailed("git cat-file ended with status %d" % rc)
        os.replace(tmp, a.out)
    except (Refused, GitFailed) as ex:
        git.abort()
        if os.path.isfile(tmp):
            os.remove(tmp)
        refused = isinstance(ex, Refused)
        sys.stderr.write("git-export: %s%s\n" % ("REFUSED: " if refused else "could not run: ", ex))
        sys.stderr.write("git-export: nothing was written to %s\n" % a.out)
        return 1 if refused else 2
    except BaseException:
        git.abort()
        if os.path.isfile(tmp):
            os.remove(tmp)
        raise
    print("git-export: %d files, %d bytes of contents, %d of the files with an executable bit" % (len(files), total, n_exec))
    print("git-export: written to %s (%d bytes)" % (a.out, os.path.getsize(a.out)))
    print("sha256 %s entries %d" % (sha256_file(a.out), len(files)))
    return 0


# --------------------------------------------------------------------------------------------
# 02: tarball inspection

class KeptTail:
    """A file that tarfile reads an archive from, once, from start to end. It keeps the last bytes it has given
    out (at least KEEP of them), so that the headers of each entry can be read again as they are, and once
    tarfile has stopped, what lies between the end it found and the end of the file can still be read."""
    KEEP = 1 << 20

    def __init__(self, f):
        self.f, self.pos, self.kept, self.chunks = f, 0, 0, collections.deque()

    def read(self, n=-1):
        data = self.f.read(n)
        if data:
            self.chunks.append((self.pos, data))
            self.pos += len(data)
            self.kept += len(data)
            while self.kept - len(self.chunks[0][1]) >= self.KEEP:
                self.kept -= len(self.chunks.popleft()[1])
        return data

    def since(self, offset):
        """The bytes given out from offset on, or None if some of them are no longer kept."""
        if not self.chunks:
            return b"" if offset >= self.pos else None
        if self.chunks[0][0] > offset:
            return None
        return b"".join(d[max(0, offset - s):] for s, d in self.chunks if s + len(d) > offset)


class GzipMembers:
    """The data of a gzip file, member after member, as bsdtar's gzip reader (libarchive's) reads it. Python's gzip
    reads on past zero bytes between two members, and past a member whose header has reserved flag bits set;
    libarchive takes either for the end of the compressed data, so a tar that extracts the archive would not see
    the members after it. So here each member must follow the one before it directly, and after the last there may
    be zero bytes and nothing else (libarchive stops there too); zlib refuses reserved flag bits, and checks each
    member's checksum and length."""
    CHUNK = 1 << 14       # compressed bytes at a time: at most about 16 MiB of data comes out of them

    def __init__(self, f):
        import zlib
        self.f, self.zlib = f, zlib
        self.d, self.left, self.out, self.at, self.done = zlib.decompressobj(31), b"", b"", 0, False

    def read(self, n=-1):
        parts, have = [], 0
        while n < 0 or have < n:
            if self.at < len(self.out):
                take = self.out[self.at:] if n < 0 else self.out[self.at:self.at + n - have]
                self.at += len(take)
                have += len(take)
                parts.append(take)
            elif self.done:
                break
            else:
                self.out, self.at = self.more(), 0
        return b"".join(parts)

    def more(self):
        """The next piece of the data: possibly empty, as when a piece of a member's header was all that was read."""
        if self.d.eof:
            self.next_member()
            if self.done:
                return b""
        data = self.left or self.f.read(self.CHUNK)
        self.left = b""
        if not data:
            raise EOFError("the gzip data ends inside a member")
        got = self.d.decompress(data)
        if self.d.eof:
            self.left = self.d.unused_data
        return got

    def next_member(self):
        rest, zeros = self.left, 0
        self.left = b""
        while True:
            body = rest.lstrip(b"\0")
            zeros += len(rest) - len(body)
            if body:
                break
            rest = self.f.read(self.CHUNK)
            if not rest:
                self.done = True
                return
        if zeros:
            raise OSError("zero bytes between two gzip members: bsdtar stops at them and does not read what follows")
        while len(body) < 2:
            more = self.f.read(self.CHUNK)
            if not more:
                break
            body += more
        if body[:2] != b"\x1f\x8b":
            raise OSError("bytes after a gzip member that are neither another member nor zero bytes")
        self.d, self.left = self.zlib.decompressobj(31), body


def header_number(field):
    """The number in a numeric field of a tar header, or None unless every tar reads the field as that number.
    Python's tarfile reads more forms than other tars do ('0o' in front, '_' between digits, tabs or new lines
    around them), and where two tars read an entry's size differently, one of them finds entries in what the
    other reads as data. Accepted: octal digits, with spaces before or after them and a NUL after them, and the
    form GNU tar writes for large numbers (a first byte of 0x80, the number in base 256 after it), if it is below
    2**63, the most a signed 64-bit size holds. A larger one is refused here; bsdtar 3.5 refuses it too ('Tar
    entry size overflow'), and also 2**63 - 1. A size anywhere near these is larger than any archive, and the
    first short read of the entry's data stops the listing (read_entry_data)."""
    if field[:1] == b"\x80":
        n = 0
        for c in bytearray(field[1:]):
            n = n * 256 + c
        return n if n < 1 << 63 else None
    s = field.split(b"\0", 1)[0].strip(b" ")
    if not re.match(rb"[0-7]*\Z", s):
        return None
    return int(s, 8) if s else 0


# The bytes of a header numbered above 127, for counting them: some old tars summed a header's bytes as signed.
HIGH_BYTES = bytes(range(128, 256))


def header_checksum_problem(blk):
    """Why the checksum of one header block is refused, or None. Python's tarfile reads the field as int() reads
    a number ('0o' in front, '_' between digits, tabs around them and base 256 all pass), libarchive only as
    spaces, NULs and octal digits; bsdtar skips a header whose checksum it refuses ('Damaged tar archive') and
    reads on in what tarfile took for that header's data. So the field must be octal digits with spaces before
    them and spaces or NULs after them, and its value the sum of the header's bytes, the field itself counted as
    eight spaces, with the bytes taken as unsigned or (as some old tars wrote it) as signed."""
    field = blk[148:156]
    m = re.match(rb" *([0-7]+)[ \0]*\Z", field)
    if not m:
        return ("a header checksum (%r) that not every tar reads as the same number"
                % field.decode("latin-1"))
    rest = blk[:148] + blk[156:]
    unsigned = sum(rest) + 8 * 32
    value = int(m.group(1), 8)
    if value != unsigned and value != unsigned - 256 * (len(rest) - len(rest.translate(None, HIGH_BYTES))):
        return "a header checksum that does not match the header"
    return None


# The fields of a tar header that hold numbers, and those that hold text, in the POSIX ustar layout: a name, its
# offset and its length. GNU tar's own format has the same fields in the same places, but puts other numbers where
# ustar has the name prefix (from byte 345).
NUMBER_FIELDS = (("mode", 100, 8), ("user id", 108, 8), ("group id", 116, 8), ("size", 124, 12), ("time", 136, 12),
                 ("device major number", 329, 8), ("device minor number", 337, 8))
TEXT_FIELDS = (("name", 0, 100), ("link name", 157, 100), ("user name", 265, 32), ("group name", 297, 32))
USTAR_MAGIC = b"ustar\x0000"            # the magic and version of POSIX ustar (and pax) headers
GNU_MAGIC = b"ustar  \x00"              # and of GNU tar's own format
# Octal digits, with spaces before them and spaces or NULs after them: libarchive's form of a number. It reads
# a first header with a number in any other form as not a tar header at all (and may then read the archive as
# another format); tarfile reads more forms.
OCTAL_FIELD = re.compile(rb" *[0-7]*[ \0]*\Z")
# Printable bytes (none below 0x20, no DEL) up to the first NUL, and nothing but NULs after it.
TEXT_FIELD = re.compile(rb"[^\0-\x1f\x7f]*\0*\Z")


def field_shown(field):
    """A field of a header, for a message: in hexadecimal if it is a number in base 256 (binary, and mostly NUL
    bytes), and otherwise quoted, up to its first NUL, with whatever is not printable escaped."""
    if field[:1] and field[0] & 0x80:
        return "0x" + field.hex()
    return repr(field.split(b"\0", 1)[0].decode("latin-1"))


def header_fields_problem(blk, first):
    """Why the fields of one header block are refused, or None; first is True for the archive's first header.

    libarchive (bsdtar) chooses how to read an archive from its first bytes: it looks there for the signatures of
    compressed formats and of uuencoded data, which it then decodes, and for those of other archive formats, and
    it reads the archive as a tar file only if its first header's numbers are in libarchive's form. tarfile reads
    the same bytes as a tar file whatever they hold. So every header must be in POSIX ustar format (pax's too) or
    in GNU tar's, with each number in libarchive's form (or in base 256, and a time before 1970 in base 256 as a
    negative number, which both read alike) and each text field printable up to a NUL and NULs after it. Then the first header is a tar header to libarchive too, and the first block holds a NUL
    before any new line, so that it cannot begin uuencoded data, and no field can hold the start of a compressed
    stream, all of whose signatures but bzip2's, xz's and zstd's have a control byte, or a NUL with other bytes
    after it; a first header that begins as one of those three does is refused. In GNU tar's format every byte where
    ustar has the name prefix (bytes 345 to 499) must be NUL: tarfile puts what is there in front of the name, and
    libarchive reads GNU tar's access and change times, old sparse map and real size there, for an entry of any
    kind (a sparse map can make it read the next block as part of the header, and a real size gives the file
    another length)."""
    magic = blk[257:265]
    if magic not in (USTAR_MAGIC, GNU_MAGIC):
        return ("a header in neither POSIX ustar format nor GNU tar's (its magic and version are %r): other tars may "
                "not read the archive as a tar file" % magic.decode("latin-1"))
    for what, at, length in NUMBER_FIELDS:
        field = blk[at:at + length]
        if what == "time" and field[:1] == b"\xff" and int.from_bytes(field, "big", signed=True) >= -(1 << 63):
            continue    # before 1970: tarfile and libarchive both read base 256 with a first byte of 0xff as negative
        if header_number(field) is None or not (field[:1] == b"\x80" or OCTAL_FIELD.match(field)):
            return "a %s in its header (%s) that not every tar reads as the same number" % (what, field_shown(field))
    for what, at, length in TEXT_FIELDS + ((("name prefix", 345, 155),) if magic == USTAR_MAGIC else ()):
        if not TEXT_FIELD.match(blk[at:at + length]):
            return ("a %s field in a header with a control character in it, or bytes after the NUL that ends it: "
                    "other tars may read such a header as something else" % what)
    if magic == GNU_MAGIC and blk[345:500].strip(b"\0"):
        return ("bytes where a POSIX header has its name prefix, in a header in GNU tar's format: Python's tarfile "
                "puts them in front of the name, and bsdtar reads GNU tar's times, old sparse map and real size there, "
                "for an entry of any kind")
    if first and re.match(rb"BZh[1-9]|\x28\xb5\x2f\xfd|\xfd7zXZ\x00", blk):
        return ("a first header that begins as a bzip2, xz or zstd stream does: other tars may read the archive as "
                "compressed data")
    return None


# The kinds of header that tarfile reads as part of the next entry: pax headers (local, global, Solaris's) and
# GNU tar's long names.
EXTENDED_HEADER_TYPES = (b"x", b"g", b"X", b"L", b"K")
# The largest extended header that tar-inspect reads. tarfile reads one whole, in one piece, before anything here
# can look at it, so a header that gives a size near that of the archive would have the whole rest of the archive
# held in memory at once (a gzipped archive of a few megabytes can hold gigabytes of zeros). A path or a pax
# record of a real archive takes a few kilobytes; KeptTail keeps 1 MiB, the most a header can take and still be
# read again to be checked.
MAX_EXTENDED_HEADER_BYTES = 512 << 10
# The most extended headers that tar-inspect reads in a row, before one entry. An archive needs at most a few: a
# global pax header, a pax header of the entry's own, a long name and a long link name. tarfile reads each one by
# calling itself again, so a long run of them would exhaust Python's stack; libarchive reads at most 32 and then
# reads on in the data of the last as if it were headers.
MAX_EXTENDED_HEADERS = 8
SPARSE_TYPE_REFUSED = "a sparse entry (GNU tar's type S), which tars read differently; tar-inspect does not read sparse entries"
SPARSE_KEYS_REFUSED = ("pax keys of a sparse file (GNU.sparse.*) that give a map of its holes, which tars read "
                       "differently; tar-inspect does not read sparse entries")


def capped_tarinfo():
    """A TarInfo class for tarfile.open(tarinfo=...) that stops tarfile, with tarfile.ReadError, before it reads
    the data of an extended header larger than MAX_EXTENDED_HEADER_BYTES, the next header after
    MAX_EXTENDED_HEADERS extended headers in a row, or the map of a sparse entry (GNU tar's type S, and the pax
    keys GNU.sparse.* of the formats tarfile knows as 0.0, 0.1 and 1.0). tarfile reads a sparse entry's map as it
    reads the header, with no limit on its size, and gives errors of its own for a map it cannot read. tarfile has
    no public place to do this: _proc_member is the method that tarfile (3.9 to 3.14 at least) calls on each header
    once it is parsed, before it reads what follows, and the others are the methods it calls for sparse maps.
    test_targets.sh checks that each takes effect with the Python it runs."""
    import tarfile

    class CappedTarInfo(tarfile.TarInfo):
        def _proc_member(self, tf):
            if self.type == tarfile.GNUTYPE_SPARSE:
                raise tarfile.ReadError(SPARSE_TYPE_REFUSED)
            if self.type not in EXTENDED_HEADER_TYPES:
                tf.rhv_extended = 0
                return super()._proc_member(tf)
            tf.rhv_extended = getattr(tf, "rhv_extended", 0) + 1
            if tf.rhv_extended > MAX_EXTENDED_HEADERS:
                raise tarfile.ReadError("more than %d extended headers (pax headers and GNU long names) in a row; "
                                        "tar-inspect reads at most %d before an entry" % (MAX_EXTENDED_HEADERS,
                                                                                          MAX_EXTENDED_HEADERS))
            if self.size > MAX_EXTENDED_HEADER_BYTES:
                raise tarfile.ReadError("an extended header (type %s) of %d bytes; tar-inspect reads at most %d"
                                        % (self.type.decode("latin-1"), self.size, MAX_EXTENDED_HEADER_BYTES))
            return super()._proc_member(tf)

        def _proc_sparse(self, tf):
            raise tarfile.ReadError(SPARSE_TYPE_REFUSED)

        def _proc_gnusparse_00(self, *args):
            raise tarfile.ReadError(SPARSE_KEYS_REFUSED)

        _proc_gnusparse_01 = _proc_gnusparse_10 = _proc_gnusparse_00
    return CappedTarInfo


# Errors that tarfile's own parsing raises on some headers it cannot read, instead of tarfile.ReadError: int() of
# a pax value that is not a number, an index past the end of a block, a stack exhausted.
TARFILE_PARSE_ERRORS = (ValueError, IndexError, OverflowError, RecursionError)


def tarfile_step(call):
    """call(), a step of tarfile reading the archive's headers, with TARFILE_PARSE_ERRORS given as
    tarfile.ReadError, so that such a header is refused as one that cannot be read and not taken for a fault of
    this tool."""
    import tarfile
    try:
        return call()
    except TARFILE_PARSE_ERRORS as ex:
        raise tarfile.ReadError("Python's tarfile could not read a header (%s: %s)" % (type(ex).__name__, ex)) from None


PAX_RECORD = re.compile(rb"([0-9]{1,20}) [^=\n\0]+=")


def pax_records_problem(data, n):
    """Why the data of a pax header (n bytes, then the rest of its last block) is refused, or None. libarchive
    reads the records in the n bytes the header's size gives. Python's tarfile reads the whole of the blocks, to
    the first NUL where a record would begin, and the tarfile of Python 3.9 stops without a word at the first
    bytes that are not a record. So the n bytes must be whole records and nothing else, each its length in
    decimal digits, a space, a keyword, '=', a value and a new line, its length counted right, and the rest of
    the block must be NULs: then both read the same records."""
    if data[n:].strip(b"\0"):
        return "bytes after the end of a pax header's data, in the rest of its block, which Python's tarfile reads as records and other tars do not"
    pos = 0
    while pos < n:
        m = PAX_RECORD.match(data, pos, n)          # read in place: a copy of the rest for each record would be slow
        length = int(m.group(1)) if m else 0
        if not m or length < m.end() - pos + 1 or pos + length > n or data[pos + length - 1:pos + length] != b"\n":
            return "a pax header whose data is not whole records, which tars read differently"
        pos += length
    return None


def header_chain_problem(src, start, member):
    """Why the headers of one entry are refused, or None. They are read again as they are, block by block, from
    start (the end of the entry before it, as tarfile counted it) to the entry's own header. Each must have a
    checksum that every tar reads alike and fields that pass header_fields_problem (a format every tar
    recognises, numbers every tar reads alike, text fields with nothing after their NUL), and each but the last
    must be an extended header whose data ends where the next header begins. A GNU long name (types L and K) must end within the size its header gives:
    tarfile reads on to the first NUL in the blocks, other tars stop at the size. A pax header's data must be
    whole records that end where the size ends, and the rest of its block NULs (pax_records_problem). There may be
    one pax header of an entry's own (type x or X), one long name and one long link name: of two, tarfile uses the
    first and bsdtar the last. (Global pax headers, type g, may be more than one; what they set is refused by
    global_pax_problem; capped_tarinfo stops tarfile after MAX_EXTENDED_HEADERS in a row.)

    These are the disagreements between tarfile and other tars that are known and that the headers show, refused
    so that the two find the same entries in the same places; they are not all there could be. For any target but
    the default one, 02 also compares what tar wrote with this listing (check_extracted and --verify-tree)."""
    end = member.offset_data - 512
    off = start
    kinds = set()
    while True:
        blk = src.since(off)
        if blk is None or len(blk) < 512:
            return "its headers could not be read again to be checked"
        blk = blk[:512]
        problem = header_checksum_problem(blk) or header_fields_problem(blk, off == 0)
        if problem:
            return problem
        n = header_number(blk[124:136])          # a number: header_fields_problem has checked the field
        if off == end:
            return None
        typ = blk[156:157]
        if typ not in EXTENDED_HEADER_TYPES:
            return "a header of type %r before its own, which another tar may read as an entry" % typ.decode("latin-1")
        kind = b"x" if typ == b"X" else typ
        if kind != b"g":
            if kind in kinds:
                return ("two extended headers of one kind (type %s) before one entry: Python's tarfile uses the "
                        "first, bsdtar the last" % typ.decode("latin-1"))
            kinds.add(kind)
        padded = -(-n // 512) * 512
        data = src.since(off + 512)
        if data is None or len(data) < padded:
            return "its headers could not be read again to be checked"
        data = data[:padded]
        if typ in (b"L", b"K"):
            nul = data.find(b"\0")
            if (nul if nul >= 0 else padded) > n:
                return ("a GNU long name (type %s) that runs past the size its header gives, which tars read "
                        "differently" % typ.decode("latin-1"))
        else:
            problem = pax_records_problem(data, n)
            if problem:
                return problem
        off += 512 + padded
        if off > end:
            return "headers that do not end where its own header begins"


def pax_header_problem(member):
    """Why the pax header of one entry is refused, or None: values that tars read differently. tarfile takes
    '1_025' for a size of 1025 where other tars stop at the '_'; it drops a slash at the end of a path where
    other tars make the entry a directory and read no data for it; it takes GNU's sparse-file keys as the
    size of the entry's data where other tars do not; it ignores Solaris's keys (SUN.*), of which bsdtar takes
    SUN.holesdata as a map of holes in the file and writes other bytes than tarfile reads; and it leaves out an
    access control list (SCHILY.acl.*), which bsdtar uses for the file's mode and can apply, letting other users
    write the file."""
    pax = member.pax_headers or {}
    if "size" in pax and not re.match(r"[0-9]+\Z", pax["size"]):
        return "a pax size (%r) that not every tar reads as the same number" % pax["size"][:40]
    if pax.get("path", "").endswith("/"):
        return "a pax path that ends with a slash, which other tars read as a directory's"
    odd = sorted(k for k in pax if k.startswith("GNU.sparse.") or k == "SCHILY.realsize")
    if odd:
        return "pax keys of a sparse file (%s), which tars read differently" % ", ".join(map(text_shown, odd[:3]))
    sun = sorted(k for k in pax if k.startswith("SUN."))
    if sun:
        return ("pax keys of Solaris's tar (%s), which bsdtar applies and Python's tarfile does not (SUN.holesdata "
                "makes holes in the file)" % ", ".join(map(text_shown, sun[:3])))
    acl = sorted(k for k in pax if k.startswith("SCHILY.acl."))
    if acl:
        return ("pax keys of an access control list (%s), which tars apply differently"
                % ", ".join(map(text_shown, acl[:3])))
    return None


def global_pax_problem(tf):
    """Why the global pax headers read so far are refused, or None. tarfile applies their path, size and other
    values to every entry after them; libarchive does not apply them at all. A comment (git archive writes the
    commit's name in one) changes nothing and is accepted."""
    keys = sorted(k for k in (tf.pax_headers or {}) if k != "comment")
    if keys:
        return ("a global pax header that sets %s, which tarfile applies to the entries after it and other tars "
                "do not" % ", ".join(map(text_shown, keys[:3])))
    return None


def text_shown(s):
    """Text from an archive, for a message: as it is if it is printable, and otherwise quoted with whatever is
    not printable escaped, so that it cannot move the cursor or rewrite what a terminal shows."""
    return s if s.isprintable() else repr(s)


def drain_stored_data(tf):
    """Read, a piece at a time, whatever is left of the data stored for the entry tarfile has just listed: the
    bytes tarfile would otherwise skip, by reading on to where it counts the next header to be, without end if
    that is far beyond the end of the archive. A short read stops the listing at once."""
    import tarfile
    left = tf.offset - tf.fileobj.tell()
    while left > 0:
        x = tf.fileobj.read(min(left, 1 << 20))
        if not x:
            raise tarfile.ReadError("unexpected end of data")
        left -= len(x)


def read_entry_data(tf, m, path):
    """Read the data of entry m to its end, a piece at a time, so that a large entry is never held in memory
    whole, and compare it with the file at path unless path is None. Returns None if the file holds the same
    bytes (or path is None), and otherwise why not.

    The data is read even when there is nothing to compare it with: left unread, tarfile would skip it by reading
    on to the size the header gives, without end if that size is far larger than the archive. Read here, the
    first short read stops the listing with 'unexpected end of data'. A sparse entry does not get here:
    capped_tarinfo stops tarfile at GNU tar's type S and at the pax keys that give a sparse map, before it reads
    the map. Were one to get here all the same, it would not be read through tarfile, which would give its holes
    as zero bytes up to a size the archive chooses, without reading the archive: only the bytes stored for it are
    read, as they are."""
    import tarfile
    if m.sparse is not None:
        drain_stored_data(tf)
        return None if path is None else "a sparse entry, not compared"
    fh = tf.extractfile(m) if (m.isreg() or m.type not in tarfile.SUPPORTED_TYPES) else None
    dh, why = None, None
    if path is not None:
        try:
            dh = open(path, "rb")
        except OSError as ex:
            why = "cannot be read on disk (%s)" % (ex.strerror or ex)
    try:
        while True:
            x = fh.read(1 << 20) if fh is not None else b""
            if dh is not None:
                try:
                    same = dh.read(len(x) or 1) == x
                except OSError as ex:
                    same, why = False, "cannot be read on disk (%s)" % (ex.strerror or ex)
                if not same:
                    why = why or "content differs"
                    dh.close()
                    dh = None
            if not x:
                break
    finally:
        if dh is not None:
            dh.close()
    # Anything tarfile counts as stored for the entry and has not given out (nothing, for a regular file read to
    # its end) is read too, for the reason above.
    drain_stored_data(tf)
    return why


def check_extracted(root, names, allow_exec, quiet):
    """Compare what a tar wrote under root with the names of the archive's entries, as tar-inspect read them.

    Every file system entry under root is looked at with lstat, without following links and without leaving
    .lake out. Each must be a directory with an entry of the archive in it, or a regular file that is an entry,
    with one name only, no executable bit unless allow_exec, and no setuid, setgid or sticky bit. Every entry
    must be there. This checks the names and kinds of what the extracting tar made of the archive, and that no file
    has an executable bit (unless allowed) or a setuid, setgid or sticky bit, whether or not that tar read the
    archive as tar-inspect did. The other permission bits are not compared with the entry's mode (tar applies the
    umask to them). It does not read the files, so 02 also passes --verify-tree, which compares each file's bytes
    with the entry's. Names are compared in NFD, the form HFS+ stores them in (the listing refuses two names that
    are one when normalised). Prints one line if all is well, the problems otherwise; returns True if all is
    well."""
    import stat
    import unicodedata

    def nfd(s):
        return unicodedata.normalize("NFD", s)

    want = {nfd(n) for n in names}
    found, holds = set(), set()          # holds: the directories with an entry in them, at any depth
    problems, n_problems, n_files = [], 0, 0

    def odd(why, rel):
        nonlocal n_problems
        n_problems += 1
        if len(problems) < 10:
            problems.append("%s: %s" % (why, text_shown(rel)))

    root = os.path.abspath(root)

    def unreadable(ex):
        odd("cannot be read (%s)" % (ex.strerror or ex), os.path.relpath(ex.filename or root, root))

    # Bottom up, so that a directory is looked at after everything in it. A link to a directory is listed with
    # the directories and is not entered.
    for dirpath, dirnames, filenames in os.walk(root, topdown=False, onerror=unreadable):
        here = False
        for d in dirnames + filenames:
            p = os.path.join(dirpath, d)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            try:
                st = os.lstat(p)
            except OSError as ex:
                unreadable(ex)
                continue
            mode = st.st_mode
            if stat.S_ISLNK(mode):
                odd("a symbolic link", rel)
            elif stat.S_ISDIR(mode):
                if p in holds:
                    here = True
                else:
                    odd("a directory with no entry of the archive in it", rel)
            elif not stat.S_ISREG(mode):
                odd("neither a regular file nor a directory", rel)
            elif nfd(rel) not in want:
                odd("a file that is not an entry of the archive", rel)
            elif nfd(rel) in found:
                odd("a second file with the name of an entry of the archive, in another Unicode form", rel)
            else:
                n_files += 1
                found.add(nfd(rel))
                here = True
                if mode & 0o111 and not allow_exec:
                    odd("an executable bit (mode %o)" % (mode & 0o7777), rel)
                if mode & 0o7000:
                    odd("a setuid, setgid or sticky bit (mode %o)" % (mode & 0o7777), rel)
                if st.st_nlink > 1:
                    odd("a file with more than one name (a hard link)", rel)
        if here:
            holds.add(dirpath)
    for rel in sorted(want - found):
        odd("an entry of the archive that is not on disk", rel)
    if n_problems:
        print("EXTRACTED TREE DIFFERS FROM THE LISTING: %d thing(s) under %s (showing up to 10)" % (n_problems, root))
        for p in problems:
            print("  - " + p)
        return False
    print("extracted tree: %d files under %s, each a regular file and an entry of the archive; nothing else is there"
          % (n_files, root))
    return True


def cmd_tar_inspect(a):
    import errno
    import stat
    import tarfile
    import unicodedata
    import zlib

    # The archive's top directory and the source directory under it. The defaults are the default
    # target's, 'lean/' and 'src'.
    prefix = a.prefix
    problem = dir_arg_problem(prefix, True)
    if problem:
        return usage_error("tar-inspect", "--prefix %r %s" % (a.prefix, problem))
    # '.' is the project directory itself, Lake's default when a lakefile names no srcDir.
    if a.src_dir == ".":
        src_prefix = prefix
    else:
        problem = dir_arg_problem(a.src_dir, False)
        if problem:
            return usage_error("tar-inspect", "--src-dir %r %s" % (a.src_dir, problem))
        src_prefix = prefix + a.src_dir + "/"
    top_at = prefix.count("/")           # the position, in an entry's name, of the first component under the prefix

    type_names = {
        tarfile.SYMTYPE: "symbolic link", tarfile.LNKTYPE: "hard link", tarfile.DIRTYPE: "directory",
        tarfile.CHRTYPE: "character device", tarfile.BLKTYPE: "block device", tarfile.FIFOTYPE: "fifo",
    }
    violations = []
    n_viol = 0

    def bad(name, why):
        nonlocal n_viol
        n_viol += 1
        if len(violations) < 25:
            violations.append("%s: %s" % (why, text_shown(name)))

    by_ext = collections.Counter()
    by_top = collections.Counter()
    seen = set()
    not_dirs = []                        # the names of the entries that are not directories
    entries = total_bytes = src_lean = executable = 0
    tree = os.path.abspath(a.verify_tree) if a.verify_tree else None
    tree_missing = tree_differs = tree_unreadable = tree_unlistable = tree_skipped = 0
    tree_examples = []
    global_seen = False                  # a global pax header has been refused (said once)

    try:
        raw = open(a.tarball, "rb")
    except OSError as ex:
        return usage_error("tar-inspect", "cannot open %s: %s" % (a.tarball, ex.strerror or ex))
    # The archive is read as a stream: gzipped (the default target's tarball) if it starts with the two bytes
    # of gzip's signature, and an uncompressed tar file (what git-export writes) otherwise. tarfile is not left
    # to decide where the archive ends. It stops without a word at a header it cannot read, or at the first
    # empty block, where the tar that extracts the archive may carry on and find more entries; and its own
    # gzip reader stops at the end of the first of several gzip members. So GzipMembers, which reads every member
    # as libarchive does and refuses what libarchive would stop at, reads the file, and once tarfile has stopped,
    # everything from where it stopped to the end of the data must be zero bytes.
    unreadable = after_end = None
    gzipped = False
    try:
        with raw:
            gzipped = raw.read(2) == b"\x1f\x8b"
            raw.seek(0)
            src = KeptTail(GzipMembers(raw) if gzipped else raw)
            with tarfile_step(lambda: tarfile.open(fileobj=src, mode="r|", tarinfo=capped_tarinfo())) as tf:
                data_end = 0                 # where the data of the entry before ends, as tarfile counts it
                # tarfile's own iterator, not tf.next(): Python 3.9's next(), called again after the first block was
                # found empty (an empty archive), seeks back in the stream and fails.
                members = iter(tf)
                while True:
                    m = tarfile_step(lambda: next(members, None))
                    if m is None:
                        break
                    entries += 1
                    name = m.name
                    ok = True
                    # tarfile is one reader of the archive, and the tar that extracts it is another. These checks
                    # refuse the headers that the two are known to read differently, so that both find the same
                    # entries in the same places. They cannot be known to cover every difference: what tar wrote
                    # is also compared with this listing afterwards, for any target but the default one (see
                    # check_extracted and --verify-tree).
                    headers_start, data_end = data_end, tf.offset
                    for problem in (header_chain_problem(src, headers_start, m), pax_header_problem(m),
                                    None if global_seen else global_pax_problem(tf)):
                        if problem:
                            bad(name if len(name) <= 300 else name[:200] + "...", problem); ok = False
                            global_seen = global_seen or problem.startswith("a global pax header")
                    too_long = name_too_long(name)
                    if too_long:
                        # Left out of every check below that looks at more than this one entry.
                        bad(name[:200] + "...", too_long)
                        read_entry_data(tf, m, None)
                        tree_skipped += 1 if tree else 0
                        continue
                    if m.type not in (tarfile.REGTYPE, tarfile.AREGTYPE):
                        bad(name, "not a regular file (%s)" % type_names.get(m.type, "type %r" % m.type)); ok = False
                    if m.type != tarfile.DIRTYPE:
                        not_dirs.append(name)
                    if name.startswith("/"):
                        bad(name, "absolute path"); ok = False
                    parts = name.split("/")
                    if ".." in parts:
                        bad(name, "'..' path component"); ok = False
                    if "" in parts or "." in parts:
                        bad(name, "empty or '.' path component"); ok = False
                    if not name.startswith(prefix):
                        bad(name, "outside %s" % prefix); ok = False
                    if "\\" in name or CONTROL_CHARS.search(name):
                        bad(name, "backslash or control character in name"); ok = False
                    if not_utf8(name):
                        bad(name, "a name that is not UTF-8 (Python shows each byte that is not as \\udc80 to "
                            "\\udcff): tars read such names differently, and macOS cannot hold them"); ok = False
                    reserved = [r for r in map(reserved_component, parts) if r]
                    if m.type != tarfile.DIRTYPE and repository_marker(parts[-1]):
                        reserved.append(repository_marker(parts[-1]))
                    if reserved:
                        bad(name, reserved[0]); ok = False
                    if m.type != tarfile.DIRTYPE and parts[-1].startswith("._"):
                        bad(name, "an AppleDouble file ('._' in front of the name): macOS's tar does not write it but "
                            "applies what it holds, as extended attributes and an access control list, to the entry "
                            "that follows it in the archive, whatever that entry's name. macOS's tar adds such files "
                            "when it makes an archive unless COPYFILE_DISABLE=1 is set; in a git source the file is "
                            "in the commit itself")
                        ok = False
                    if m.mode & 0o111:
                        executable += 1
                        if not a.allow_exec:
                            bad(name, "executable bit set (mode %o)" % m.mode); ok = False
                    if m.mode & 0o7000:
                        bad(name, "setuid, setgid or sticky bit set (mode %o)" % m.mode); ok = False
                    if name in seen:
                        bad(name, "duplicate entry"); ok = False
                    seen.add(name)
                    base = parts[-1]
                    ext = os.path.splitext(base)[1] or "(none)"
                    by_ext[ext] += 1
                    by_top[parts[top_at] if len(parts) > top_at else parts[0]] += 1
                    total_bytes += m.size
                    if name.startswith(src_prefix) and name.endswith(".lean"):
                        src_lean += 1
                    path = None
                    if tree and not ok:
                        # A refused entry is not compared: its name may not be one the tree can hold.
                        tree_skipped += 1
                    elif tree:
                        path = os.path.join(tree, name)
                        try:
                            there = "" if stat.S_ISREG(os.lstat(path).st_mode) else " (not a regular file there)"
                        except OSError as ex:
                            # Not there, or there and out of reach (a directory on the way that cannot be searched).
                            there = None if ex.errno in (errno.ENOENT, errno.ENOTDIR) else ex
                        if there is None or isinstance(there, str) and there:
                            tree_missing += 1
                            if len(tree_examples) < 10:
                                tree_examples.append("missing on disk%s: %s" % (there or "", text_shown(name)))
                            path = None
                        elif not isinstance(there, str):
                            tree_unreadable += 1
                            if len(tree_examples) < 10:
                                tree_examples.append("cannot be read on disk (%s): %s"
                                                     % (there.strerror or there, text_shown(name)))
                            path = None
                    why = read_entry_data(tf, m, path)
                    if why:
                        if why.startswith("cannot be read on disk"):
                            tree_unreadable += 1
                        else:
                            tree_differs += 1
                        if len(tree_examples) < 10:
                            tree_examples.append("%s: %s" % (why, text_shown(name)))
                # tarfile has stopped: at the first empty block, at a header it cannot read, or at the end of the
                # data. From the block it stopped at to the end of the file there may be zero bytes and nothing else.
                rest = src.since(tf.offset)
                nonzero = rest is None or rest.strip(b"\0") != b""
                while True:
                    chunk = src.read(1 << 20)
                    if not chunk:
                        break
                    nonzero = nonzero or chunk.strip(b"\0") != b""
                if nonzero:
                    after_end = tf.offset
    except (tarfile.TarError, OSError, EOFError, zlib.error) as ex:     # TARFILE_PARSE_ERRORS too: tarfile_step
        # A gzip member that cannot be read is a zlib.error (data that is not gzip, a wrong checksum, reserved
        # flags), an EOFError (one cut short) or an OSError (what follows a member, from GzipMembers).
        unreadable = "%s: %s" % (type(ex).__name__, ex)
    if unreadable:
        bad(a.tarball, "the archive cannot be read to its end (%s), so what follows may hold entries that were "
            "not checked" % unreadable)
    if after_end is not None:
        bad(a.tarball, "data after the end of the archive, from byte %d of the %s: a tar that extracts the "
            "archive may find entries there that were not checked" % (after_end, "unpacked stream" if gzipped else "file"))

    for name in below_files(seen, not_dirs):
        bad(name, "a file where this entry needs a directory, on the way to it")
    for one, other in name_collisions(seen):
        bad("%s and %s" % (one, other), "one name where case and Unicode normalisation are ignored, as on macOS")
    for name in unassigned_names(seen):
        bad(name, "a character unassigned in Unicode %s, so a collision cannot be ruled out" % unicodedata.unidata_version)

    def say(text):
        if not a.quiet:
            print(text)

    say("tarball entries:        %d" % entries)
    say("total uncompressed:     %d bytes (%.2f GB)" % (total_bytes, total_bytes / 1e9))
    say("Lean files under %s: %d" % (src_prefix, src_lean))
    say("entries by extension:")
    for ext, c in sorted(by_ext.items(), key=lambda kv: (-kv[1], kv[0])):
        say("  %-10s %d" % (text_shown(ext), c))
    say("entries by top-level item under %s:" % prefix)
    for top, c in sorted(by_top.items(), key=lambda kv: (-kv[1], kv[0])):
        say("  %-22s %d" % (text_shown(top), c))

    status = 0
    if n_viol:
        print("UNSAFE OR UNEXPECTED ENTRIES: %d (showing up to 25)" % n_viol)
        for v in violations:
            print("  - " + v)
        status = 1
    elif a.allow_exec:
        say("entry check: every entry is a regular file under %s; no links," % prefix)
        say("             absolute paths, '..' components or duplicate names")
        say("             entries with an executable bit, accepted because of --allow-exec: %d" % executable)
    else:
        say("entry check: every entry is a regular, non-executable file under %s; no links," % prefix)
        say("             absolute paths, '..' components or duplicate names")

    summary = {"entries": entries, "total_bytes": total_bytes, "source_lean_files": src_lean,
               "by_extension": dict(by_ext)}
    if a.sha256:
        summary["sha256"] = a.sha256

    exp = (load_json(a.expected) or {}).get("tarball")
    diffs = []
    if exp:
        for key in ("sha256", "entries", "total_bytes", "source_lean_files", "by_extension"):
            if key in summary:
                compare(key, summary[key], exp.get(key), diffs)
    if a.quiet and not diffs:
        pass
    elif not report_comparison("tarball listing", a.expected, "tarball", bool(exp), diffs):
        status = 1

    if tree:
        extra = []
        root = os.path.join(tree, prefix.rstrip("/"))

        def walk_error(ex):
            # A directory that cannot be listed may hold files that are not in the tarball.
            nonlocal tree_unlistable
            tree_unlistable += 1
            if len(tree_examples) < 10:
                tree_examples.append("directory cannot be listed on disk (%s): %s" % (
                    ex.strerror or ex, text_shown(os.path.relpath(ex.filename or root, tree).replace(os.sep, "/"))))

        # Names are compared in NFD, as check_extracted compares them: HFS+ stores names in that form, and macOS's
        # tar writes a name from a pax header in it on any file system. A second file with an entry's name in
        # another form (a file system that keeps both apart) is not in the tarball.
        seen_nfd, claimed = {unicodedata.normalize("NFD", n) for n in seen}, set()
        for dirpath, dirnames, filenames in os.walk(root, onerror=walk_error):
            if dirpath == root:
                dirnames[:] = [d for d in dirnames if d != ".lake"]   # build products and packages
            for d in dirnames:
                # A link to a directory is not entered, and the files of the tarball compared above may have been
                # read through it.
                if os.path.islink(os.path.join(dirpath, d)):
                    extra.append(os.path.relpath(os.path.join(dirpath, d), tree).replace(os.sep, "/")
                                 + " (a symbolic link to a directory)")
            for f in filenames:
                rel = os.path.relpath(os.path.join(dirpath, f), tree).replace(os.sep, "/")
                key = unicodedata.normalize("NFD", rel)
                if key not in seen_nfd or key in claimed:
                    extra.append(rel)
                else:
                    claimed.add(key)
        print("tree comparison (files on disk against the tarball's contents):")
        print("  files in the tarball missing on disk:     %d" % tree_missing)
        print("  files whose content differs:              %d" % tree_differs)
        if tree_unreadable:
            print("  files that cannot be read on disk:        %d" % tree_unreadable)
        if tree_unlistable:
            print("  directories that cannot be listed:        %d" % tree_unlistable)
        print("  files on disk that are not in the tarball: %d (the .lake directory is not counted)" % len(extra))
        if tree_skipped:
            print("  entries refused above, not compared:      %d" % tree_skipped)
        for line in tree_examples + ["not in tarball: " + text_shown(e) for e in sorted(extra)[:10]]:
            print("  - " + line)
        if tree_missing or tree_differs or tree_unreadable or tree_unlistable or extra:
            print("tree comparison: DIFFERENT from the tarball")
            status = 1
        elif unreadable:
            print("tree comparison: NOT FINISHED: the archive cannot be read to its end (see above)")
            status = 1
        elif tree_skipped:
            print("tree comparison: NOT FINISHED: %d entries the listing refused were not compared (see above)"
                  % tree_skipped)
            status = 1
        else:
            print("tree comparison: the extracted files are byte-for-byte the tarball's contents")

    if a.check_extracted:
        if not check_extracted(a.check_extracted, seen, a.allow_exec, a.quiet):
            status = 1

    if a.write_expected and status == 0:
        merge_expected(a.write_expected, "tarball", summary)
    return status


# --------------------------------------------------------------------------------------------
# 02: project files

# What a manifest may say about where a package's own files are and where the packages go: what Lake 4.33.1
# writes. Lake joins these to a directory with no check that the result stays inside it, so another value could
# name a file of the archive as the lakefile of a package whose address the reader trusts (Lake runs a
# lakefile.lean, and a lakefile.toml decides what it builds), or put the packages anywhere.
MANIFEST_CONFIG_FILES = ("lakefile", "lakefile.lean", "lakefile.toml")
MANIFEST_FILE = "lake-manifest.json"
MANIFEST_PACKAGES_DIR = ".lake/packages"
# The deepest a manifest nests its values: Lake writes three levels. Python's json reader fails on deep nesting
# under 3.9 and not under 3.14, and what is printed must not depend on that.
MAX_MANIFEST_DEPTH = 32
# A directory inside the one it is relative to: plain parts separated by '/', none starting with a dot (so no '..',
# '.git' or '.lake'); or '.' for that directory itself.
PLAIN_DIR = re.compile(r"[A-Za-z0-9_+-][A-Za-z0-9_.+-]*(?:/[A-Za-z0-9_+-][A-Za-z0-9_.+-]*)*\Z")


def plain_dir(d):
    """d if it is '.' or a directory of plain parts inside the one it is relative to, else None."""
    return d if isinstance(d, str) and (d == "." or PLAIN_DIR.match(d)) else None


def json_too_deep(v, limit):
    """Whether v nests lists and objects more than limit deep (counted without recursion)."""
    stack = [(v, 1)]
    while stack:
        x, depth = stack.pop()
        if isinstance(x, (list, dict)):
            if depth > limit:
                return True
            stack.extend((y, depth + 1) for y in (x.values() if isinstance(x, dict) else x))
    return False


def short_int(digits):
    """A number in the manifest, if it has at most 30 digits. Python 3.11 and later refuse to read one of more than
    4300; a manifest has none of more than a few."""
    if len(digits.lstrip("-")) > 30:
        raise ValueError("a number of more than 30 digits")
    return int(digits)


def short_float(text):
    """A number with a fraction or an exponent in the manifest, limited as short_int limits whole numbers."""
    if sum(c.isdigit() for c in text) > 30:
        raise ValueError("a number of more than 30 digits")
    return float(text)


def no_constant(name):
    """Python's json reads NaN and Infinity; they are not JSON, and Lake does not read them."""
    raise ValueError("%s, which is not JSON" % name)


def manifest_version(m):
    """The version of a manifest as Lake 4.33.1 reads it, as (major, minor), or None where Lake refuses it. Lake
    reads 'version', else 'schemaVersion': a whole number n is 0.n, text is major.minor.patch; below 0.5, or of a
    major version above 1, it is refused."""
    v = m["version"] if "version" in m else m.get("schemaVersion")
    if isinstance(v, int) and not isinstance(v, bool) and v >= 0:
        ver = (0, v)
    elif isinstance(v, str) and re.match(r"[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}(?:-[!-~]+)?\Z", v):
        ver = tuple(int(x) for x in v.split("-", 1)[0].split(".")[:2])
    else:
        return None
    return ver if (0, 5) <= ver and ver[0] <= 1 else None


class TomlStop(Exception):
    """A lakefile.toml outside the part of TOML that read_lakefile_toml reads."""


class TomlInline(dict):
    """An inline table: nothing can be added to it later."""


class TomlHeaderTable(dict):
    """A table opened by a header: a dotted key in another table cannot add to it."""


class TomlTableArray(list):
    """An array of tables ([[name]] headers)."""


TOML_KEY = re.compile(r"[A-Za-z0-9_-]+")
TOML_NUMBER_OR_BOOL = re.compile(r"(?:[+-]?(?:0|[1-9][0-9]{0,17})|true|false)(?=[ \t\n,\]}#]|\Z)")
TOML_FORBIDDEN = re.compile("[\x00-\x08\x0b-\x1f\x7f﻿]")


def read_lakefile_toml(text):
    """The document in a lakefile.toml, as (dict, None), or (None, why) for one outside the part of TOML read here.

    Lake reads more of TOML than this; what is read here is what lakefiles are written in, and anything else is
    refused rather than read in a way that could differ from Lake's. Each line is blank, a comment, a header
    ([leanOptions], [[require]] or [[lean_lib]]), or key = value, the key bare parts joined by dots. A value is a
    string in double or single quotes on one line with no backslash in it (so no escape can spell a key or a
    name), a whole number, true or false, an array of values (over several lines if need be), or an inline table
    on one line. A key given twice is refused, as Lake refuses it."""
    text = text.replace("\r\n", "\n")
    n, root = len(text), {}
    st = {"pos": 0, "table": root}

    def fail(why):
        raise TomlStop("line %d: %s" % (text.count("\n", 0, st["pos"]) + 1, why))

    def at(c):
        return text.startswith(c, st["pos"])

    def ws():
        while st["pos"] < n and text[st["pos"]] in " \t":
            st["pos"] += 1

    def comment():
        if at("#"):
            e = text.find("\n", st["pos"])
            st["pos"] = n if e < 0 else e

    def gap():
        while True:
            ws()
            comment()
            if not at("\n"):
                return
            st["pos"] += 1

    def key():
        parts = []
        while True:
            ws()
            m = TOML_KEY.match(text, st["pos"])
            if not m:
                fail("a key that is not bare (letters, digits, '_' and '-' only; quoted keys are not read here): %s"
                     % ascii(text[st["pos"]:st["pos"] + 30]))
            parts.append(m.group())
            st["pos"] = m.end()
            ws()
            if not at("."):
                return parts
            st["pos"] += 1

    def put(table, parts, v):
        for p in parts[:-1]:
            sub = table.get(p)
            if sub is None:
                sub = table[p] = {}
            elif type(sub) is not dict:
                fail("the key %s is given twice" % ".".join(parts))
            table = sub
        if parts[-1] in table:
            fail("the key %s is given twice" % ".".join(parts))
        table[parts[-1]] = v

    def value():
        c = text[st["pos"]] if st["pos"] < n else ""
        if c in ("\"", "'"):
            if at(c * 3):
                fail("a multi-line string")
            e = text.find(c, st["pos"] + 1)
            v = text[st["pos"] + 1:e] if e >= 0 else "\n"
            if "\n" in v:
                fail("a string with no end on its line")
            if "\\" in v:
                fail("a backslash in a string: escapes are not read here, since they could spell a key or a name")
            st["pos"] = e + 1
            return v
        if c == "[":
            st["pos"] += 1
            items = []
            while True:
                gap()
                if at("]"):
                    st["pos"] += 1
                    return items
                items.append(value())
                gap()
                if at(","):
                    st["pos"] += 1
                elif not at("]"):
                    fail("an array whose values are not separated by commas")
        if c == "{":
            st["pos"] += 1
            t = TomlInline()
            ws()
            if at("}"):
                st["pos"] += 1
                return t
            while True:
                k = key()
                if not at("="):
                    fail("a key with no '=' after it")
                st["pos"] += 1
                ws()
                put(t, k, value())
                ws()
                if at("}"):
                    st["pos"] += 1
                    return t
                if not at(","):
                    fail("an inline table that is not key = value pairs separated by commas, on one line")
                st["pos"] += 1
        m = TOML_NUMBER_OR_BOOL.match(text, st["pos"])
        if not m:
            fail("a value that is not a string, a whole number, true or false, an array or an inline table: %s"
                 % ascii(text[st["pos"]:st["pos"] + 30]))
        st["pos"] = m.end()
        return {"true": True, "false": False}[m.group()] if m.group() in ("true", "false") else int(m.group())

    try:
        bad = TOML_FORBIDDEN.search(text)
        if bad:
            st["pos"] = bad.start()
            fail("a control character or a byte order mark")
        while True:
            gap()
            if st["pos"] >= n:
                break
            if at("[["):
                st["pos"] += 2
                name = ".".join(key())
                if not at("]]"):
                    fail("a [[ header with no ]] to end it")
                st["pos"] += 2
                if name not in ("require", "lean_lib"):
                    fail("a table [[%s]], which is not one this check knows" % name)
                arr = root.get(name)
                if arr is None:
                    arr = root[name] = TomlTableArray()
                elif not isinstance(arr, TomlTableArray):
                    fail("the key %s is given twice" % name)
                st["table"] = TomlHeaderTable()
                arr.append(st["table"])
            elif at("["):
                st["pos"] += 1
                name = ".".join(key())
                if not at("]"):
                    fail("a [ header with no ] to end it")
                st["pos"] += 1
                if name != "leanOptions":
                    fail("a table [%s], which is not one this check knows" % name)
                if name in root:
                    fail("the key %s is given twice" % name)
                st["table"] = root[name] = TomlHeaderTable()
            else:
                k = key()
                if not at("="):
                    fail("a line that is neither a header nor key = value")
                st["pos"] += 1
                ws()
                put(st["table"], k, value())
            ws()
            comment()
            if st["pos"] < n:
                if not at("\n"):
                    fail("more on the line after the value or header: %s" % ascii(text[st["pos"]:st["pos"] + 30]))
                st["pos"] += 1
    except TomlStop as ex:
        return None, str(ex)
    except RecursionError:
        return None, "arrays nested too deeply"
    return root, None


# A part of a Lean name: an identifier (an ASCII letter or '_', then ASCII letters, digits and the characters _'!?,
# as Lean writes it, with no guillemets), or, as Lake writes a part that is not an identifier ('lake new 2proj math'
# names its library '«2proj»'), ASCII letters, digits and the characters _'!?+- between guillemets: never a dot or
# a slash, so that the file of a module stays in its library's directory.
LEAN_NAME_PART = r"(?:[A-Za-z_][A-Za-z0-9_'!?]*|«[A-Za-z0-9_'!?+-]+»)"
LEAN_NAME = LEAN_NAME_PART + r"(?:\." + LEAN_NAME_PART + r")*"
# What each key of a lakefile.toml may hold, by kind, and the keys that may be given at the top, in a requirement
# and in a library. Lake acts on more keys than these, in ways the scripts do not check, so any other is refused.
# The address of a git package, in the manifest or in a requirement: https, a host name (and a port or not), then a
# path of plain parts (ASCII letters, digits and the characters _.~+-), none of them '.' or '..'. git reads an
# address with no scheme as a directory, which could be one of the archive's own files (a git bundle stored at
# lean/github.com/leanprover-community/mathlib4), and Lake passes the address to git as it is, before the directory
# and with no '--'. file://, ssh:// and user@host:path are other ways of fetching, and a user name before the host
# ('https://github.com@example.com/') makes an address look like another host's. git's https transport (libcurl)
# takes '.' and '..' parts out of the path before it sends the request, so that
# 'https://github.com/leanprover-community/mathlib4/../../other/x' fetches github.com/other/x; '%', '?', '#' and
# empty parts, which a server may read in other ways, are refused too (a closing '/' is allowed). The scheme does not
# keep git from reading an address as a path: git clone reads it as a path in the directory it runs in first, and
# 'https://github.com/x/y' is the path https:/github.com/x/y, so project-info refuses a project with a file named
# https: and 04 clones each package from a directory of its own.
GIT_URL = re.compile(r"https://[A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]{1,5})?(?:/(?!\.\.?(?:/|\Z))[A-Za-z0-9_.~+-]+)+/?\Z")
LAKEFILE_KINDS = {
    "package": re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]*\Z"),
    "target": re.compile(LEAN_NAME + r"\Z"),
    "module": re.compile(LEAN_NAME + r"\Z"),
    "glob": re.compile(LEAN_NAME + r"(?:\.[+*])?\Z"),
    # Arguments to lean that only set a limit or an option (an option of LEAN_OPTIONS_ALLOWED: checked apart).
    # Others can load a library of native code into lean (--plugin, --load-dynlib) or write files where lean is
    # told to.
    "arg": re.compile(r"(?:--(?:tstack|threads|memory|timeout)=[0-9]{1,12}|-D[A-Za-z_][A-Za-z0-9_.]*=[A-Za-z0-9_.-]{1,64})\Z"),
}
LAKEFILE_KEYS = {
    "": {"name": "package", "version": "text", "description": "text", "keywords": "texts", "homepage": "text",
         "license": "text", "srcDir": "dir", "defaultTargets": "targets", "moreLeanArgs": "args",
         "weakLeanArgs": "args", "leanOptions": "options", "require": "tables", "lean_lib": "tables"},
    "require": {"name": "package", "scope": "plain", "git": "url", "rev": "plain", "version": "plain"},
    "lean_lib": {"name": "target", "srcDir": "dir", "roots": "modules", "globs": "globs", "leanOptions": "options",
                 "moreLeanArgs": "args", "weakLeanArgs": "args"},
}
LAKEFILE_KIND_WORDS = {
    "text": "is not text", "texts": "is not a list of texts", "plain": "is not printable ASCII text with no space "
    "in it", "url": "is not an address of the form https://<host>/<path> in printable ASCII, its path of plain parts "
    "(ASCII letters, digits and the characters _.~+-, none of them '.' or '..')",
    "package": "is not a package name (letters, digits, "
    "'_' and '-')", "target": "is not a Lean name of ASCII letters, digits and the characters _'!? (a part may be "
    "between guillemets)", "targets": "is not a "
    "list of such names", "modules": "is not a list of module names of ASCII letters, digits and the characters _'!? (a part "
    "may be between guillemets)",
    "globs": "is not a list of module names, each with '.+' or '.*' after it or not", "args": "is not a list of "
    "arguments to lean of the kinds allowed (--tstack, --threads, --memory, --timeout, -D<option>=<value>)",
    "dir": "is not '.' or a relative directory of plain parts, none starting with a dot", "options": "is not a "
    "table of Lean options with a string, a whole number, true or false for each", "tables": "is not given as "
    "[[...]] tables"}


# The Lean options a lakefile may set, in leanOptions or with -D, with 'weak.' before them or not: options that only
# change how sources are elaborated, printed or linted, or a limit. Others are refused, since some do more: sat.solver
# names a program that lean runs (in any module that uses bv_decide), trace.profiler.output a file that lean
# writes, and debug.skipKernelTC has declarations added with no check by the kernel. Another option that a project
# needs can be added here once what it does is known.
LEAN_OPTIONS_ALLOWED = ("autoImplicit", "relaxedAutoImplicit", "maxHeartbeats", "maxRecDepth", "maxSynthPendingDepth",
                        "synthInstance.maxHeartbeats", "synthInstance.maxSize", "warningAsError", "Elab.async")
LEAN_OPTION_PREFIXES_ALLOWED = ("pp.", "linter.", "backward.")


def lean_option_names(table):
    """The options a leanOptions table sets, each as its dotted name (a.b = 1 and a = {b = 1} both set a.b)."""
    names, stack = [], [(table, "")]
    while stack:
        t, prefix = stack.pop()
        for k, v in t.items():
            if isinstance(v, dict):
                stack.append((v, prefix + k + "."))
            else:
                names.append(prefix + k)
    return sorted(names)


def lean_option_problem(name):
    """Why a lakefile may not set the Lean option name, or None."""
    base = name[len("weak."):] if name.startswith("weak.") else name
    if base in LEAN_OPTIONS_ALLOWED or base.startswith(LEAN_OPTION_PREFIXES_ALLOWED):
        return None
    return ("the Lean option %s, which is not one this check allows: some options make lean run a program, write "
            "a file or add declarations with no check by the kernel (the ones allowed are LEAN_OPTIONS_ALLOWED in "
            "rhv_tools.py)" % ascii(name)[:80])


def lakefile_dir(d):
    """A srcDir as Lake joins it to a directory: './src' and 'src/' are the directory src, './' is '.'."""
    if not isinstance(d, str) or d.startswith("/"):
        return d
    while d.startswith("./"):
        d = d[2:]
    return d.rstrip("/") or "."


def lakefile_value_ok(kind, v):
    if kind == "text":
        return isinstance(v, str)
    if kind == "plain":
        return isinstance(v, str) and bool(re.match(r"[!-~]+\Z", v))
    if kind == "url":
        return isinstance(v, str) and bool(GIT_URL.match(v))
    if kind in ("package", "target"):
        return isinstance(v, str) and bool(LAKEFILE_KINDS[kind].match(v))
    if kind in ("texts", "targets", "modules", "globs", "args"):
        one = {"texts": None, "targets": "target", "modules": "module", "globs": "glob", "args": "arg"}[kind]
        return isinstance(v, list) and all(isinstance(x, str) and (one is None or LAKEFILE_KINDS[one].match(x))
                                           for x in v)
    if kind == "dir":
        return plain_dir(lakefile_dir(v)) is not None
    if kind == "options":
        stack = [v]
        while stack:
            t = stack.pop()
            if not isinstance(t, dict):
                return False
            for x in t.values():
                if isinstance(x, dict):
                    stack.append(x)
                elif not isinstance(x, (str, int)):
                    return False
        return True
    if kind == "tables":
        return isinstance(v, TomlTableArray)
    return False


def lakefile_problems(doc, src_dir, dependencies):
    """Why a lakefile.toml, as read_lakefile_toml read it, is refused: a list of reasons, empty if there are none.

    Lake builds and runs what a lakefile declares, and 03 reads only the sources under src_dir (TGT_SRC_DIR). So the
    lakefile may declare libraries and requirements and nothing else, with only the keys of LAKEFILE_KEYS: an
    executable, for one, is built and run by its name, and one called cache would be run by 'lake exe cache get' in
    place of Mathlib's. Each library's sources must lie under src_dir. And the package may not take the name of a
    package it depends on: Lake would then leave that package out and use this one's code in its place (with the
    name mathlib, 'lake exe mathlib/cache' too)."""
    problems = []
    src = "." if src_dir in (".", "") else src_dir.rstrip("/")

    def check(where, table, keys):
        for k, v in table.items():
            kind = keys.get(k)
            if kind is None:
                problems.append("%sa key %s, which is not one this check knows what Lake does with" % (where, ascii(k)))
            elif not lakefile_value_ok(kind, v):
                problems.append("%s%s %s" % (where, k, LAKEFILE_KIND_WORDS.get(kind, "is not allowed")))
            else:
                options = (lean_option_names(v) if kind == "options" else
                           [x[2:].split("=", 1)[0] for x in v if x.startswith("-D")] if kind == "args" else [])
                for o in options:
                    why = lean_option_problem(o)
                    if why:
                        problems.append("%s%s sets %s" % (where, k, why))

    check("", doc, LAKEFILE_KEYS[""])
    taken = {re.sub("[«»]", "", d).lower() for d in dependencies}
    reqs = doc.get("require") if isinstance(doc.get("require"), TomlTableArray) else []
    req_names = []
    for i, r in enumerate(reqs, 1):
        check("requirement %d: " % i, r, LAKEFILE_KEYS["require"])
        if isinstance(r.get("name"), str):
            req_names.append(r["name"])
    for name in sorted({x for x in req_names if req_names.count(x) > 1}):
        problems.append("two requirements named %s" % ascii(name))
    taken |= {x.lower() for x in req_names}
    name = doc.get("name")
    if isinstance(name, str) and name.lower() in taken:
        problems.append("the package is named %s, as a package it depends on is: Lake would leave that package out "
                        "and use this one's code in its place" % ascii(name))
    top = plain_dir(lakefile_dir(doc.get("srcDir", ".")))
    libs = doc.get("lean_lib") if isinstance(doc.get("lean_lib"), TomlTableArray) else []
    for i, lib in enumerate(libs, 1):
        where = "library %d (%s): " % (i, ascii(lib.get("name"))[:60])
        check(where, lib, LAKEFILE_KEYS["lean_lib"])
        sub = plain_dir(lakefile_dir(lib.get("srcDir", ".")))
        if top is None or sub is None:
            continue                        # refused above
        parts = [p for p in (top + "/" + sub).split("/") if p != "."]
        lib_dir = "/".join(parts) or "."
        if not (src == "." or lib_dir == src or lib_dir.startswith(src + "/")):
            problems.append("%sits sources are in %s, not under %s, the directory 03 reads (TGT_SRC_DIR)"
                            % (where, lib_dir, src))
    return problems


LEAN_ID_PART = re.compile(r"[A-Za-z_][A-Za-z0-9_'!?]*")


def manifest_name_problem(name):
    """Why a package name in the manifest is not written as Lake writes it, or None; for a name of printable ASCII
    and guillemets (others are refused as values).

    Lake reads a name as Lean does: parts separated by dots, each an identifier, a number, or anything but a '»'
    between '«' and '»', which are dropped. So '«mathlib»' is the name mathlib, and a manifest could give
    mathlib twice, in two spellings, where a check that compares the text would see two packages and report the
    revision of the one Lake does not use. Lake writes guillemets only around a part that is not an identifier,
    and a number with no zero before it; a name written in any other way is refused, so that the text of each
    name that is accepted is the name Lake reads. Between guillemets only ASCII letters, digits and the characters
    _'!?+- are accepted, as in a lakefile's names: Lake keeps a package in the directory .lake/packages/<name>, the
    name with its guillemets dropped, with no check that this is one directory there ('«../x»' would be outside
    it, and so would the clone 04 makes)."""
    i, n = 0, len(name)
    while True:
        if name.startswith("«", i):
            j = name.find("»", i + 1)
            if j < 0:
                return "a '«' with no '»' after it: Lake cannot read it"
            if not re.fullmatch(r"[A-Za-z0-9_'!?+-]+", name[i + 1:j]):
                return ("a part between guillemets that is empty or has something other than ASCII letters, digits "
                        "and the characters _'!?+- in it (%s): Lake keeps a package in .lake/packages/<its name>, and with a '/' or a "
                        "'.' that need not be one directory there" % ascii(name[i:j + 1])[:40])
            if LEAN_ID_PART.fullmatch(name, i + 1, j):
                return ("guillemets around %s, which Lake writes without them: it reads the name as %s"
                        % (name[i + 1:j], name[:i] + name[i + 1:j] + name[j + 1:]))
            i = j + 1
        else:
            m = LEAN_ID_PART.match(name, i) or re.compile("[0-9]+").match(name, i)
            if not m:
                return "a part that is not an identifier, a number or between guillemets: Lake cannot read it"
            if m.group()[0] == "0" and len(m.group()) > 1:
                return "a number with a zero before it (%s), which Lake writes without it" % m.group()
            i = m.end()
        if i == n:
            return None
        if name[i] != ".":
            return ("a part that is not an identifier, a number or between guillemets (from %s on): Lake cannot read it"
                    % ascii(name[i:])[:40])
        if i + 1 == n:
            return "a dot at its end: Lake cannot read it"
        i += 1


def cmd_project_info(a):
    proj = a.project
    files = ["lakefile.toml", "lake-manifest.json", "lean-toolchain"]
    missing = [f for f in files if not os.path.isfile(os.path.join(proj, f))]
    if missing:
        print("project files missing: " + ", ".join(missing))
        return 1
    if a.src_dir != "." and dir_arg_problem(a.src_dir, False):
        return usage_error("project-info", "--src-dir %r %s" % (a.src_dir, dir_arg_problem(a.src_dir, False)))
    # Each file is read once, as bytes: its SHA-256 is that of what was read. A file that is not UTF-8 text, or a
    # manifest that is not JSON this reads, is refused here, not left to fail as a fault of this tool.
    raw, text = {}, {}
    for f in files:
        with open(os.path.join(proj, f), "rb") as fh:
            raw[f] = fh.read()
        try:
            text[f] = raw[f].decode("utf-8").replace("\r\n", "\n")
        except UnicodeDecodeError as ex:
            print("REFUSED: %s is not UTF-8 text (%s)" % (f, ex))
            return 1
    toolchain = text["lean-toolchain"].rstrip("\n")         # whitespace or a control byte elsewhere is refused
    try:
        manifest = json.loads(text["lake-manifest.json"], parse_int=short_int, parse_float=short_float,
                              parse_constant=no_constant)
        too_deep = json_too_deep(manifest, MAX_MANIFEST_DEPTH)
    except RecursionError:
        too_deep = True
    except ValueError as ex:
        print("REFUSED: lake-manifest.json is not JSON that can be read (%s)" % str(ex)[:200])
        return 1
    if too_deep:
        print("REFUSED: lake-manifest.json nests its values more than %d deep; Lake writes three levels"
              % MAX_MANIFEST_DEPTH)
        return 1
    # The packages, as Lake writes them: an object with a list "packages" of objects, each with its name, type
    # ("git" or "path"), revision and address or directory. Lake reads the form of the manifest's own version: from
    # version 7 each package is such an object, and before it each is {"git": {...}} or {"path": {...}}. A
    # manifest with no version Lake reads, or with a package in the other form, is refused: Lake stops at it, and
    # what is printed below could not show what it would read. Lake also stops at a manifest that is missing a
    # field it needs, and then fetches nothing; that is not checked here.
    entries = manifest.get("packages") if isinstance(manifest, dict) else None
    if not isinstance(entries, list) or not all(isinstance(p, dict) for p in entries):
        print("REFUSED: lake-manifest.json is not an object whose \"packages\" is a list of objects, the form Lake "
              "writes; what it names cannot be shown")
        return 1
    ver = manifest_version(manifest)
    if ver is None:
        given = manifest["version"] if "version" in manifest else manifest.get("schemaVersion")
        print("REFUSED: lake-manifest.json gives no version that Lake reads (version %s); Lake stops at it, and what "
              "it would read cannot be shown" % ascii(given)[:60])
        return 1
    pkgs = []
    for p in entries:
        tagged = len(p) == 1 and list(p)[0] in ("git", "path") and isinstance(p[list(p)[0]], dict)
        if tagged != (ver < (0, 7)):
            print("REFUSED: lake-manifest.json is of version %d.%d, and a package in it is in the form Lake writes %s "
                  "version 7; Lake reads only the form of the manifest's own version and stops at the other, so "
                  "what it would read cannot be shown" % (ver[0], ver[1], "before" if tagged else "from"))
            return 1
        pkgs.append(dict(p[list(p)[0]], type=list(p)[0]) if tagged else p)
    # Keyed by name; a name that is not text is keyed by its escaped form (and refused below).
    packages = {(p.get("name") if isinstance(p.get("name"), str) else ascii(p.get("name"))): p.get("rev") for p in pkgs}
    mathlib = packages.get("mathlib")
    # Lake records the revision a requirement names (a tag, a branch or a commit) as the entry's inputRev, and the
    # commit it resolved to as its rev, and checks out the rev. Of two entries of one name it keeps the last.
    mathlib_input = next((p.get("inputRev", p.get("inputRev?")) for p in reversed(pkgs) if p.get("name") == "mathlib"),
                         None)
    lakefile = text["lakefile.toml"]
    # The lakefile's own pin: the `rev` of the requirement named mathlib, from the document as read_lakefile_toml
    # reads it, or, where it reads no document (the lakefile is then refused below), with a narrow pattern.
    doc, toml_problem = read_lakefile_toml(lakefile)
    if doc is not None:
        reqs = doc.get("require") if isinstance(doc.get("require"), TomlTableArray) else []
        revs = [r.get("rev") for r in reqs if r.get("name") == "mathlib"]
        lakefile_rev = revs[0] if revs else None
    else:
        m = re.search(r'\[\[require\]\]\s*(?:[^\[]*?\n)?\s*name\s*=\s*"mathlib"[^\[]*?\brev\s*=\s*"([^"]+)"', lakefile)
        lakefile_rev = m.group(1) if m else None
    hashes = {f: hashlib.sha256(raw[f]).hexdigest() for f in files}

    # Every value printed below comes from the archive, and a reader is asked to judge what is printed. So a value
    # that is not printable ASCII is shown escaped and quoted, and refused: control characters could hide or
    # rewrite what follows them on a terminal; other characters can look blank (U+2800, U+3164) or like ASCII
    # letters (a host 'gіthub.com'). A value with a space in it is refused too: it could pass for two values,
    # or for the note printed after an address. No toolchain, revision or address needs such characters, and no
    # package name but for the guillemets Lake puts around a part that is not an identifier ('«doc-gen4»'), which
    # a name may have around printable ASCII. The directory of a path package may have a space in it: it is shown
    # quoted (and a path package is refused below). A name, or a git package's address or revision, that is
    # missing or is not text is refused (a package with no type is refused below); the directory of a path
    # package, and the Mathlib revisions, may be missing, and are then shown as None.
    escaped, escaped_seen, n_refused = [], set(), [0]

    def plain(v, space_ok=False, missing_ok=False, name=False):
        if v is None and missing_ok:
            return "None"
        if isinstance(v, str) and re.match(r"[!-~]+\Z", v):
            return v
        if name and isinstance(v, str) and re.match("(?:[!-~]|«[!-~]+?»)+\\Z", v):
            return v
        if isinstance(v, str) and space_ok and re.match(r"[ -~]+\Z", v) and v.strip(" ") == v:
            return repr(v)
        n_refused[0] += 1
        key = ascii(v)[:80]
        if key not in escaped_seen:
            escaped_seen.add(key)
            escaped.append(key)
        return ascii(v)

    print("lean-toolchain:              %s" % plain(toolchain))
    print("Mathlib revision (manifest): %s" % plain(mathlib, missing_ok=True))
    print("Mathlib revision (lakefile): %s%s" % (plain(lakefile_rev, missing_ok=True),
                                                  " (the manifest's inputRev: Lake checks out the commit above)"
                                                  if lakefile_rev and lakefile_rev == mathlib_input != mathlib else ""))
    print("packages in the manifest:    %d" % len(packages))
    for p in sorted(pkgs, key=lambda p: ascii(p.get("name")).lower()):
        print("  %-18s %s" % (plain(p.get("name"), name=True),
                              plain(p.get("rev"), missing_ok=p.get("type", "git") != "git")))
    for f in files:
        print("sha256 %-20s %s" % (f, hashes[f]))
    # Where each package comes from is read whether it is to be printed or not, so that an address that is
    # missing or not plain is refused either way; without --show-urls only the refused ones are printed (02 lists
    # them all for every target but the default one, whose archive is pinned).
    wheres = []
    for p in sorted(pkgs, key=lambda p: ascii(p.get("name")).lower()):
        name = plain(p.get("name"), name=True)      # before the count: a refused name is not a refused address
        before = n_refused[0]
        git = p.get("type", "git") == "git"
        where = (plain(p.get("url")) if git
                 else "%s %s" % (plain(p.get("type")), plain(p.get("dir"), space_ok=True, missing_ok=True)))
        not_https = git and isinstance(p.get("url"), str) and where == p["url"] and not GIT_URL.match(where)
        wheres.append((name, where, n_refused[0] > before or not_https))
    if not a.show_urls and any(refused for _, _, refused in wheres):
        print("addresses and directories refused (--show-urls lists every one):")
        for name, where, refused in wheres:
            if refused:
                print("  %-18s %s" % (name, where))
    if a.show_urls:
        # Step 04 runs code these files choose, with the rights of whoever runs it: elan installs and runs the
        # toolchain lean-toolchain names, 04 clones every package from its address, Lake runs its lakefile, builds
        # and runs Mathlib's cache tool (named by its package), and builds the libraries lakefile.toml declares
        # (checked below: their sources are the ones 03 reads). So where they come from is printed for a reader
        # to judge.
        origin = toolchain.split(":", 1)[0] if ":" in toolchain else None
        print("where step 04 fetches and runs code from (read these before running it):")
        if origin is None:
            print("  %-18s %s" % ("toolchain", "leanprover/lean4 (elan's default: lean-toolchain names no origin)"))
        else:
            print("  %-18s %s%s" % ("toolchain", plain(origin),
                                    "" if origin == "leanprover/lean4" else "   <- NOT leanprover/lean4"))
        for name, where, _ in wheres:
            print("  %-18s %s" % (name, where))
        # Lake would also download a prebuilt build of a package (from Reservoir for the scopes leanprover and
        # leanprover-community, or from the package's GitHub releases) where its build directory is missing, but
        # the scripts run every Lake with LAKE_NO_CACHE=1 (lib.sh), so it does not.

    # Where Lake would read a package's own files from, and where it would put the packages.
    manifest_problems = []
    if "packagesDir" in manifest and manifest["packagesDir"] != MANIFEST_PACKAGES_DIR:
        manifest_problems.append("packagesDir is %s: Lake puts the packages there, a directory joined to the "
                                 "project's with no check that it stays inside it; Lake writes %s"
                                 % (ascii(manifest["packagesDir"])[:80], MANIFEST_PACKAGES_DIR))
    for p in sorted(pkgs, key=lambda p: ascii(p.get("name")).lower()):
        who = "the package %s" % ascii(p.get("name"))[:60]
        if p.get("type", "git") != "git":
            manifest_problems.append(
                "%s is a %s package: Lake runs the lakefile in its directory, code that nothing here reads"
                % (who, ascii(p.get("type"))[:20]) if p.get("type") == "path" else
                "%s is of type %s, which Lake does not read" % (who, ascii(p.get("type"))[:40]))
            continue
        if "type" not in p:
            manifest_problems.append("%s has no type: Lake stops at a package with none" % who)
        rev, url = p.get("rev"), p.get("url")
        # Lake reads only 40 lowercase hexadecimal digits as a commit (Util/Git.lean, isFullSha1). Even then git's
        # checkout prefers a branch of that name, which a clone has when it is the remote's default branch, and Lake
        # does not compare what it checked out with the manifest. So 04 clones each git package itself before Lake
        # runs, and checks out <hash>^{commit}, which no branch can stand for; Lake then finds it at that commit.
        if isinstance(rev, str) and re.match(r"[!-~]+\Z", rev) and not re.match(r"[0-9a-f]{40}\Z", rev):
            manifest_problems.append("%s has the revision %s, which is not a full commit hash: Lake writes there the "
                                     "commit it checked out, and resolves any other revision against the package's "
                                     "address (as a branch or tag of that name first) each time it fetches the "
                                     "package, so the files would not name the commit it checks out" % (who, rev[:60]))
        if isinstance(url, str) and re.match(r"[!-~]+\Z", url) and not GIT_URL.match(url):
            manifest_problems.append("%s has the address %s, which is not of the form https://<host>/<path> with "
                                     "a path of plain parts: Lake passes the address to git as it is, and git reads "
                                     "one with no scheme as a directory (which could be a file of the archive), "
                                     "fetches from file://, ssh:// and user@host:path in other ways, from the host "
                                     "after a user name ('https://github.com@example.com/') rather than the one it "
                                     "seems to name, and from the path left once '.' and '..' parts are taken out "
                                     "('.../mathlib4/../../other/x' is other/x)" % (who, url[:100]))
        if "configFile" in p and p["configFile"] not in MANIFEST_CONFIG_FILES:
            manifest_problems.append("%s has the configFile %s: Lake reads the package's lakefile from there, joined to "
                                     "its directory with no check that it stays inside it; Lake writes lakefile, "
                                     "lakefile.lean or lakefile.toml" % (who, ascii(p["configFile"])[:80]))
        if "manifestFile" in p and p["manifestFile"] != MANIFEST_FILE:
            manifest_problems.append("%s has the manifestFile %s; Lake writes %s"
                                     % (who, ascii(p["manifestFile"])[:80], MANIFEST_FILE))
        for k in ("subDir", "subDir?"):
            if p.get(k) is not None and plain_dir(p[k]) is None:
                manifest_problems.append("%s has the %s %s: Lake takes the package from that directory of its "
                                         "clone, with no check that it stays inside it; it must be a relative "
                                         "directory of plain parts, none starting with a dot" % (who, k, ascii(p[k])[:80]))
            elif p.get(k) not in (None, "."):
                manifest_problems.append("%s has the %s %s: Lake would take the package from that directory of its "
                                         "clone, and these scripts take each package from the top of its clone, "
                                         "where 04 looks for a prebuilt build Lake downloaded" % (who, k, ascii(p[k])[:80]))
    names = [p["name"] for p in pkgs if isinstance(p.get("name"), str)]
    for name in sorted(set(names), key=str.lower):
        why = manifest_name_problem(name) if plain(name, name=True) == name else None   # others are refused as values
        if why:
            manifest_problems.append("the package name %s has %s" % (ascii(name)[:60], why))
        if names.count(name) > 1:
            manifest_problems.append("two packages are named %s: Lake uses the last" % ascii(name)[:60])
    # Lake keeps a package in .lake/packages/<its name with the guillemets dropped>, so two names Lake reads as two
    # (1, a number, and 1 between guillemets, a string) can be kept in one directory, and on a file system that ignores
    # case (APFS and NTFS do by default) so can mathlib and Mathlib: 04 would clone one and find it there for the other.
    # And 04 clones a package as .lake/packages/.<directory>.rhv-partial, which must fit in a directory name.
    pdirs = {}
    for name in sorted(set(names)):
        pd = name.replace("\xab", "").replace("\xbb", "")
        pdirs.setdefault(pd.lower(), []).append(name)
        if len(pd.encode("utf-8", "surrogatepass")) > 242:
            manifest_problems.append("the package name %s... is longer than 242 characters: 04 clones the package as "
                                     ".lake/packages/.<name>.rhv-partial, which would be longer than a directory "
                                     "name can be" % ascii(name)[:60])
    for pd in sorted(pdirs):
        if len(pdirs[pd]) > 1:
            manifest_problems.append("the packages %s would be kept in one directory of .lake/packages: Lake drops "
                                     "the guillemets, and the file system may not tell upper from lower case"
                                     % " and ".join(ascii(x)[:60] for x in pdirs[pd]))
    if "mathlib" not in names:
        manifest_problems.append("no package is named mathlib: these scripts build against Mathlib, and fetch its "
                                 "cache with 'lake exe mathlib/cache get'")
    # git clone reads an address as a path in the directory it runs in before it reads it as an address (clone.c,
    # get_repo_path, with '/.git', '.git' or '.bundle' after it or not): 'https://github.com/x/y' is the path
    # https:/github.com/x/y. Lake runs git in the project's directory, so that a repository or a git bundle the archive
    # puts there would be cloned in place of the address shown. Every address accepted starts with https:.
    if os.path.lexists(os.path.join(proj, "https:")):
        manifest_problems.append("the project has a file or directory named https:, the start of every package's "
                                 "address: git clone reads an address as a path in the directory it runs in before it "
                                 "fetches anything ('https://github.com/x/y' is the path https:/github.com/x/y), and "
                                 "Lake runs it in the project's directory, so a repository or git bundle there would "
                                 "be cloned in place of the address shown")
    # elan reads the line as <origin>:<release>, with the origin leanprover/lean4 when none is given, and puts a 'v'
    # before a release that starts with a digit (4.33.1 is v4.33.1, as Lake writes the line when no elan runs it).
    # A release that is not a tag is refused: elan fetches a nightly from another repository than the one named (the
    # origin with '-nightly' after it), resolves stable, beta and nightly over the network, and runs a toolchain
    # linked under another name from wherever it was linked; it fetches and installs such a toolchain as soon as 04
    # asks it which lean it would run, before 04 can compare anything. elan 4.2 also reads the line as a path in the project first, a release tag included, and runs
    # <line>/bin/lean if the project has one, so that the archive's own lean, lake and leanchecker would be run: a
    # project with a file or directory named as the line's first part is refused (04 checks which lean elan chose),
    # and so is an origin that is not <owner>/<repository> as elan reads one. (A line that is not printable ASCII is
    # refused above.)
    origin, release = toolchain.split(":", 1) if ":" in toolchain else (None, toolchain)
    toolchain_problems = []
    if re.match(r"[!-~]+\Z", toolchain):
        if origin is not None and not re.match(r"[A-Za-z0-9_-]+/[A-Za-z0-9_-]+\Z", origin):
            toolchain_problems.append("it names the origin %s, which is not <owner>/<repository> of ASCII letters, "
                                      "digits, '_' and '-': elan reads such a line as a path, or not at all"
                                      % origin[:60])
        if not re.match(r"v?[0-9]+\.[0-9]+\.[0-9]+(?:-rc[0-9]+)?\Z", release):
            toolchain_problems.append("it names the release %s, which is not a release tag (v<major>.<minor>.<patch>, "
                                      "with -rc<n> after it or not, the 'v' optional): elan fetches a nightly from "
                                      "another repository than the one named, resolves stable, beta and nightly over "
                                      "the network and runs a linked toolchain from wherever it is, and it would fetch "
                                      "and install such a toolchain as soon as 04 asked it which lean it would run"
                                      % release[:60])
        first = toolchain.split("/", 1)[0]
        if first and os.path.lexists(os.path.join(proj, first)):
            toolchain_problems.append("the project has a file or directory named %s, the start of the line: elan 4.2 "
                                      "reads the line as a path in the project first, and runs <line>/bin/lean from "
                                      "there if there is one, in place of the release" % first[:60])
    lakefile_refused = [toml_problem] if toml_problem else lakefile_problems(doc, a.src_dir, names)
    if not toml_problem:
        # Lake stops at a requirement the manifest has no entry for; what it would fetch for it is not listed.
        given = {re.sub("[«»]", "", x) for x in names}
        for r in doc.get("require") if isinstance(doc.get("require"), TomlTableArray) else []:
            if isinstance(r.get("name"), str) and r["name"] not in given:
                lakefile_refused.append("the requirement %s has no entry in lake-manifest.json: Lake stops at it, "
                                        "and where it would fetch it from is not listed" % ascii(r["name"])[:60])

    status = 0
    if escaped:
        print("REFUSED: %d value(s) in the project files are missing, are not printable ASCII text, or have a space "
              "in them, and are shown quoted and escaped above (first: %s); no toolchain, revision or address needs "
              "such characters, nor any package name but for the guillemets Lake puts around a part of one that is "
              "not an identifier"
              % (len(escaped), escaped[0]))
        status = 1
    for why in toolchain_problems:
        print("REFUSED: lean-toolchain: " + why)
    for why in manifest_problems[:10]:
        print("REFUSED: lake-manifest.json: " + why)
    for why in lakefile_refused[:10]:
        print("REFUSED: lakefile.toml: " + why)
    for f, more in (("lake-manifest.json", manifest_problems[10:]), ("lakefile.toml", lakefile_refused[10:])):
        if more:
            print("REFUSED: %s: %d more" % (f, len(more)))
    if toolchain_problems or manifest_problems or lakefile_refused:
        status = 1
    if isinstance(lakefile_rev, str) and lakefile_rev and mathlib and lakefile_rev not in (mathlib, mathlib_input):
        print("WARNING: the lakefile and the manifest name different Mathlib revisions (the manifest's entry was "
              "made from the revision %s)" % (mathlib_input if isinstance(mathlib_input, str)
                                              and re.match(r"[!-~]+\Z", mathlib_input) else ascii(mathlib_input)[:60]))
        status = 1
    summary = {"lean_toolchain": toolchain, "mathlib_rev": mathlib, "packages": packages, "sha256": hashes}
    exp = (load_json(a.expected) or {}).get("project")
    diffs = []
    if exp:
        compare("lean_toolchain", toolchain, exp.get("lean_toolchain"), diffs)
        compare("mathlib_rev", mathlib, exp.get("mathlib_rev"), diffs)
        compare("packages", packages, exp.get("packages"), diffs)
        for f in files:
            compare("sha256 of " + f, hashes[f], (exp.get("sha256") or {}).get(f), diffs)
    if not report_comparison("project files", a.expected, "project", bool(exp), diffs):
        status = 1
    if a.write_expected and status == 0:
        merge_expected(a.write_expected, "project", summary)
    return status


# --------------------------------------------------------------------------------------------
# 03: source audit
#
# The scan has two stages. Stage 1 (ripgrep or grep, fixed strings only) keeps every source line
# that contains at least one of the strings of audit_literals(). Stage 2 (this file) applies the regular
# expressions below to those lines. Every expression can only match a line that contains one of
# the literals, so the result does not depend on which tool did stage 1.
#
# Counts are of matching lines, wherever they occur, comments and strings included. A count of
# zero is therefore a strong statement; a non-zero count is a list of places to read.

def w(alternatives):
    """A whole word. A plain word boundary is used on purpose: it also matches next to a quote
    mark or a dot, so the counts err on the side of reporting too much."""
    return r"\b(?:" + alternatives + r")\b"


# Lean's own input/output, file-system and process API, matched by the names of its functions and
# types. The bare word IO is counted separately (io_word), because a project can have a namespace
# or structure field called IO that has nothing to do with input and output.
IO_PRIMITIVES_RE = (
    r"\bIO\.(?:FS|Process|Prim|println|eprintln|print|eprint|getEnv|appPath|appDir|currentDir|mkRef|sleep|"
    r"monoMsNow|monoNanosNow|getStdin|getStdout|getStderr|setStdout|setStderr|userError|toEIO|lazyPure|"
    r"RealWorld|rand|getRandomBytes|asTask|mapTask|bindTask|wait|cancel|Error)\b"
    r"|\b(?:BaseIO|EIO|unsafeIO|unsafeBaseIO|unsafeEIO)\b"
    r"|\bIO\s+\(?(?:Unit|PUnit|Nat|String|Bool|UInt8|UInt32|UInt64|Empty|Array|List|Option|Except)\b"
    r"|\bSystem\.(?:FilePath|Platform)\b|\bFilePath\b"
    r"|\b(?:readFile|writeFile|readBinFile|writeBinFile|removeFile|createDir|createDirAll|removeDirAll|"
    r"readDir|pathExists|readToEnd|putStrLn|putStr|getLine)\b"
    r"|\bProcess\.(?:spawn|output|run|exit)\b")

AUDIT_CATEGORIES = [
    # key, what it looks for, regular expression
    ("sorry", "the word sorry", w("sorry")),
    ("sorryAx", "the axiom behind sorry, named directly", w("sorryAx")),
    ("admit", "the word admit", w("admit")),
    ("axiom", "the word axiom (axiom declarations)", w("axiom")),
    ("native_decide", "native_decide, decide +native, native := true", w("native_decide") + r"|\+native\b|\bnative\s*:=\s*true\b"),
    ("reduceBool", "ofReduceBool, reduceBool, ofReduceNat, reduceNat, trustCompiler", w("ofReduceBool|reduceBool|ofReduceNat|reduceNat|trustCompiler")),
    ("unsafe", "the word unsafe", w("unsafe")),
    ("implemented_by", "the attribute implemented_by", w("implemented_by")),
    ("extern", "the word extern", w("extern")),
    ("opaque", "the word opaque", w("opaque")),
    ("hash_eval", "#eval commands", r"#eval\b"),
    ("initialize", "initialize and builtin_initialize", w("initialize|builtin_initialize")),
    ("io_primitives", "Lean's IO, file and process primitives, by name (see IO_PRIMITIVES_RE)", IO_PRIMITIVES_RE),
    ("io_word", "the bare word IO (also matches a project namespace or field of that name)", w("IO")),
    ("skipKernelTC", "the option debug.skipKernelTC", w("skipKernelTC")),
    ("addDecl", "addDecl..., addAndCompile (kernel-checked additions to the environment)", r"\b(?:addDecl\w*|addAndCompile)\b"),
    ("unchecked_add", "addDeclWithoutChecking, Environment.add, Kernel.Environment", w("addDeclWithoutChecking") + r"|\bEnvironment\.add\b|\bKernel\.Environment\b"),
    ("modifyEnv", "modifyEnv and setEnv", w("modifyEnv|setEnv")),
    ("run_cmd", "run_cmd, run_elab, run_meta", w("run_cmd|run_elab|run_meta")),
]

SYNTAX_KEYWORDS = ["elab", "elab_rules", "macro", "macro_rules", "notation", "notation3", "infix", "infixl",
                   "infixr", "prefix", "postfix", "syntax", "declare_syntax_cat", "binder_predicate"]
SYNTAX_RE = re.compile(
    r"^\s*(?:/--.*?-/\s*)?(?:@\[[^\]]*\]\s*)*((?:(?:local|scoped|private|protected)\s+)*)"
    r"(elab_rules|elab|macro_rules|macro|notation3|notation|infixl|infixr|infix|prefix|postfix|"
    r"declare_syntax_cat|syntax|binder_predicate)(?![\w'.])")

SET_OPTION_RE = re.compile(r"\bset_option\s+([A-Za-z_][\w.]*)")
META_IMPORT_RE = re.compile(r"^\s*(?:(?:public|private|meta)\s+)*import\s+(?:all\s+)?((?:Lean|Qq|Lake)(?:\.[\w.']+)?)\s*$")
META_WORD_RE = re.compile(w("MetaM|TacticM|TermElabM|CommandElabM|CoreM|Environment"))
# The protected names: names of the library that the source should not declare for itself. These three
# are the default target's; --protected-names gives another target's (TGT_PROTECTED_NAMES).
PROTECTED_NAMES = ["RiemannHypothesis", "riemannZeta", "LFunction"]


def protected_names_res(names):
    """The two expressions about the protected names, for a list of such names: one for declarations,
    one for binders and notation tokens."""
    names_alt = "|".join(re.escape(n) for n in names)
    # A declaration whose name, or last name component, is one of the protected names.
    local_def_re = re.compile(
        r"\b(?:def|abbrev|theorem|lemma|structure|class|inductive|instance|opaque|axiom|alias|"
        r"notation|macro|syntax)\s+(?:[\w.']+\.)?(" + names_alt + r")(?![\w.'!?])")
    # A name introduced by a binder keyword, or a quoted notation token, that reuses one of the
    # protected names: `fun riemannZeta =>`, `variable (riemannZeta : ...)`, `intro LFunction`,
    # `notation "riemannZeta" => ...`. Binders written inside a declaration's signature cannot be
    # told apart from type ascriptions by a regular expression and are not covered; the statement
    # report of 08_check_axioms.sh, which works on what the kernel sees, covers that case.
    shadow_re = re.compile(
        r"(?:\b(?:fun|let|have|set|intro|intros|rintro|obtain|rcases|variable|universe)\b|[\u03bb\u2200\u2203])"
        r"[^:=,\u21a6]*?(?<![\w.'])(?:" + names_alt + r")(?![\w.'!?])"
        r"|\"(?:" + names_alt + r")\"")
    return local_def_re, shadow_re


# The fixed strings of stage 1, without the protected names: audit_literals adds those, so that a
# line that names one of them always reaches stage 2.
BASE_LITERALS = [
    "sorry", "admit", "axiom", "native", "ReduceBool", "reduceBool", "ReduceNat", "reduceNat", "trustCompiler",
    "unsafe", "implemented_by", "extern", "opaque", "#eval", "initialize", "IO", "System.", "FilePath",
    "readFile", "writeFile", "BinFile", "removeFile", "createDir", "removeDir", "readDir", "pathExists",
    "readToEnd", "putStr", "getLine", "Process.",
    "skipKernelTC", "addDecl", "addAndCompile", "Environment", "modifyEnv", "setEnv", "run_cmd", "run_elab",
    "run_meta", "set_option", "MetaM", "TacticM", "TermElabM", "CommandElabM", "CoreM",
    "import",
]


def audit_literals(names):
    return sorted(set(BASE_LITERALS + list(names) + SYNTAX_KEYWORDS))


def protected_names_arg(a, cmd):
    """The names given with --protected-names, or None after a message if there is none to work with.
    A name is put into a regular expression as literal text and given to stage 1 as a fixed string, so it
    may not be empty or have white space in it; splitting the argument at white space sees to both."""
    names = a.protected_names.split()
    if not names:
        usage_error(cmd, "--protected-names names no name; give at least one, separated by spaces")
        return None
    return names


HIT_RE = re.compile(r"^(?:\./)?(.*?\.lean):(\d+):(.*)$")


def cmd_audit_literals(a):
    names = protected_names_arg(a, "audit-literals")
    if names is None:
        return 2
    for lit in audit_literals(names):
        print(lit)
    return 0


def cmd_audit_classify(a):
    names = protected_names_arg(a, "audit-classify")
    if names is None:
        return 2
    local_def_re, shadow_re = protected_names_res(names)
    compiled = [(key, desc, re.compile(rx)) for key, desc, rx in AUDIT_CATEGORIES]
    lines = {key: 0 for key, _, _ in compiled}
    files = {key: set() for key, _, _ in compiled}
    examples = {key: [] for key, _, _ in compiled}
    syntax_lines = collections.Counter()
    syntax_scope = collections.Counter()
    syntax_files = set()
    set_options = collections.Counter()
    meta_import_files = {}
    meta_word_files = collections.defaultdict(set)
    local_defs = []
    local_binders = []
    hit_lines = unparsed = 0

    with (sys.stdin.buffer if a.hits == "-" else open(a.hits, "rb")) as fh:
        for raw in fh:
            text = raw.decode("utf-8", "replace").rstrip("\r\n")
            m = HIT_RE.match(text)
            if not m:
                unparsed += 1
                continue
            hit_lines += 1
            path, lineno, body = m.group(1), int(m.group(2)), m.group(3)
            for key, _desc, rx in compiled:
                if rx.search(body):
                    lines[key] += 1
                    files[key].add(path)
                    if len(examples[key]) < a.show:
                        examples[key].append("%s:%d: %s" % (path, lineno, body.strip()[:140]))
            sm = SYNTAX_RE.match(body)
            if sm:
                mods = sm.group(1).split()
                scope = "local" if "local" in mods else "scoped" if "scoped" in mods else "global"
                syntax_lines[sm.group(2)] += 1
                syntax_scope[scope] += 1
                syntax_files.add(path)
            for om in SET_OPTION_RE.finditer(body):
                set_options[om.group(1)] += 1
            im = META_IMPORT_RE.match(body)
            if im:
                meta_import_files.setdefault(path, set()).add(im.group(1))
            for wm in META_WORD_RE.finditer(body):
                meta_word_files[path].add(wm.group(0))
            if local_def_re.search(body):
                local_defs.append("%s:%d: %s" % (path, lineno, body.strip()[:140]))
            if shadow_re.search(body):
                local_binders.append("%s:%d: %s" % (path, lineno, body.strip()[:140]))

    meta_files = sorted(set(meta_import_files) | set(meta_word_files))
    local_defs.sort()
    local_binders.sort()

    print("Lean source files scanned:  %d" % a.lean_files)
    print("stage 1 tool:               %s" % a.tool)
    print("lines kept by stage 1:      %d" % hit_lines)
    if unparsed:
        print("WARNING: %d stage-1 lines could not be parsed and were ignored" % unparsed)
    print()
    print("Counts are of matching LINES, anywhere in a file, comments included.")
    print("%-16s %10s %8s   %s" % ("category", "lines", "files", "what is matched"))
    for key, desc, _rx in compiled:
        print("%-16s %10d %8d   %s" % (key, lines[key], len(files[key]), desc))
    print("%-16s %10d %8d   %s" % ("syntax_def", sum(syntax_lines.values()), len(syntax_files),
                                    "lines that begin a syntax-defining command"))
    print("%-16s %10d %8d   %s" % ("local_def", len(local_defs), len(set(d.split(":")[0] for d in local_defs)),
                                    "declarations named " + ", ".join(names)))
    print("%-16s %10d %8d   %s" % ("shadowing", len(local_binders), len(set(d.split(":")[0] for d in local_binders)),
                                    "names introduced by a binder keyword, or notation tokens, that reuse one"))
    print()
    print("Syntax-defining commands by keyword: " +
          (", ".join("%s %d" % kv for kv in sorted(syntax_lines.items(), key=lambda kv: (-kv[1], kv[0]))) or "none"))
    print("Syntax-defining commands by scope:   " +
          (", ".join("%s %d" % kv for kv in sorted(syntax_scope.items(), key=lambda kv: (-kv[1], kv[0]))) or "none"))
    print()
    print("set_option names (occurrences): %d distinct" % len(set_options))
    for name, c in sorted(set_options.items(), key=lambda kv: (-kv[1], kv[0])):
        print("  %8d  %s" % (c, name))
    print()
    print("Files that import Lean, Qq or Lake modules, or mention MetaM, TacticM, TermElabM,")
    print("CommandElabM, CoreM or Environment: %d (%d of them by import)" % (len(meta_files), len(meta_import_files)))
    for path in meta_files:
        why = sorted(meta_import_files.get(path, set())) + sorted(meta_word_files.get(path, set()))
        print("  %s   [%s]" % (path, ", ".join(why)))
    print()
    print("Declarations named %s: %d" % (", ".join(names), len(local_defs)))
    for d in local_defs:
        print("  " + d)
    print("Names introduced by a binder keyword, or notation tokens, that reuse one of them: %d" % len(local_binders))
    for d in local_binders[:40]:
        print("  " + d)
    if len(local_binders) > 40:
        print("  ... and %d more" % (len(local_binders) - 40))
    if a.show:
        shown = [(key, examples[key]) for key, _, _ in compiled if examples[key]]
        if shown:
            print()
            print("First matching lines per category (up to %d each):" % a.show)
            for key, ex in shown:
                print("  [%s]" % key)
                for e in ex:
                    print("    " + e)

    summary = {
        "lean_files": a.lean_files,
        "categories": {key: {"lines": lines[key], "files": len(files[key])} for key, _, _ in compiled},
        "syntax_definitions": {"lines": sum(syntax_lines.values()), "files": len(syntax_files),
                               "by_keyword": dict(syntax_lines), "by_scope": dict(syntax_scope)},
        "set_option": dict(set_options),
        "metaprogramming_files": meta_files,
        "metaprogramming_import_files": sorted(meta_import_files),
        "local_definitions": local_defs,
        "shadowing": local_binders,
    }
    summary["categories"]["local_def"] = {"lines": len(local_defs), "files": len(set(d.split(":")[0] for d in local_defs))}
    summary["categories"]["shadowing"] = {"lines": len(local_binders), "files": len(set(d.split(":")[0] for d in local_binders))}
    if a.json:
        write_json(a.json, summary)

    exp = (load_json(a.expected) or {}).get("audit")
    status = 0
    print()
    if not exp:
        no_recorded_values("source audit", a.expected, "audit")
    else:
        zero_diffs, other_diffs = [], []
        compare("lean_files", a.lean_files, exp.get("lean_files"), other_diffs)
        for key, want in sorted((exp.get("categories") or {}).items()):
            got = summary["categories"].get(key)
            if got is None:
                other_diffs.append("category %s is recorded but no longer computed" % key)
                continue
            if got != want:
                msg = "%s: found %d lines in %d files, recorded %d lines in %d files" % (
                    key, got["lines"], got["files"], want.get("lines", 0), want.get("files", 0))
                (zero_diffs if want.get("lines", 0) == 0 else other_diffs).append(msg)
        for key in ("syntax_definitions", "set_option", "metaprogramming_files", "local_definitions", "shadowing"):
            if key in exp and exp[key] != summary[key]:
                other_diffs.append("%s differs from the recorded value" % key)
        if zero_diffs:
            print("comparison: FAILED. Categories recorded as zero now have matches:")
            for d in zero_diffs:
                print("  - " + d)
            status = 1
        if other_diffs:
            print("comparison: differences in other recorded values (%s):" %
                  ("treated as failures because of --strict" if a.strict else "reported, not treated as failures"))
            for d in other_diffs:
                print("  - " + d)
            if a.strict:
                status = 1
        if not zero_diffs and not other_diffs:
            print("comparison: matches the recorded values in %s" % a.expected)
    if a.write_expected and status == 0:
        merge_expected(a.write_expected, "audit", summary)
    return status


# --------------------------------------------------------------------------------------------
# 08: the body of the axiom check file, and the axiom check summary

ALLOWED_AXIOMS = ["propext", "Classical.choice", "Quot.sound"]
# The default target's: the constant its primary theorem's statement must be, the module that
# constant must be defined in, and the constants whose defining module the check file reports.
# Other targets give theirs with --statement-const, --statement-const-module and --report-consts
# (TGT_STATEMENT_CONST, TGT_STATEMENT_CONST_MODULE, TGT_REPORT_CONSTS).
STATEMENT_CONST = "RiemannHypothesis"
STATEMENT_CONST_MODULE = "Mathlib.NumberTheory.LSeries.RiemannZeta"
REPORT_CONSTS = ["RiemannHypothesis", "riemannZeta", "DirichletCharacter.LFunction"]

# A Lean name of plain ASCII components with dots between them. The names are written into the check
# file after a backquote, and one of them into a string, so nothing else is let through. (Lean accepts
# some other letters too, but not all that Python calls letters; a name that needs them is refused here
# rather than written into a file Lean cannot read.)
LEAN_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_'!?]*(?:\.[A-Za-z_][A-Za-z0-9_'!?]*)*\Z")


def body_lines(const, report):
    """The four lines of scripts/verify/axioms_check_body.lean that name constants, without their
    indentation, as they read for one statement constant and one list of constants to report."""
    return ["let isRH : Bool := target == mkConst `%s" % const,
            'logInfo m!"RHV CHECK statement_is_constant_%s {primary} {isRH}"' % const,
            "for c in [%s] do" % ", ".join("`" + n for n in report),
            "if c == `%s then" % const]


def cmd_axioms_body(a):
    """Print the body of the check file for the constants given.

    For the default target's constants the file is printed as it is, byte for byte, whatever is in it.
    For others, the four lines that name constants are printed with the names given, and every other
    line as it is. The statement constant is put in front of the list of constants to report if it is
    not in it, because axioms-summary needs its module. Status 2, with nothing printed, if a name is
    not a plain Lean name, if one of the four lines is not in the file exactly once, or if another
    line of the file names one of the default target's constants: then the file has changed and
    this function has to be changed with it."""
    with open(a.body, "rb") as fh:
        raw = fh.read()
    const = a.statement_const
    report = a.report_consts.split() or [const]
    if const == STATEMENT_CONST and report == REPORT_CONSTS:
        sys.stdout.buffer.write(raw)
        sys.stdout.buffer.flush()
        return 0
    bad = [n for n in dict.fromkeys([const] + report) if not LEAN_NAME_RE.match(n)]
    if bad:
        return usage_error("axioms-body", "not a plain Lean name (components of letters, digits, _ ' ! ?, with dots "
                           "between them): %s" % ", ".join(repr(n) for n in bad))
    if const not in report:
        report = [const] + report
    old, new = body_lines(STATEMENT_CONST, REPORT_CONSTS), body_lines(const, report)
    lines = raw.decode("utf-8").split("\n")
    where = []
    for text in old:
        at = [i for i, ln in enumerate(lines) if ln.strip() == text]
        if len(at) != 1:
            return usage_error("axioms-body", "%s must have the line '%s' exactly once, and has it %d times; the file and "
                               "body_lines in rhv_tools.py have to be changed together" % (a.body, text, len(at)))
        where.append(at[0])
    for i, ln in enumerate(lines):
        if i not in where and any(n in ln for n in REPORT_CONSTS):
            return usage_error("axioms-body", "line %d of %s names a constant of the default target and is not one of the "
                               "lines this tool rewrites: '%s'; the file and body_lines in rhv_tools.py have to be "
                               "changed together" % (i + 1, a.body, ln.strip()))
    for i, was, now in zip(where, old, new):
        lines[i] = lines[i].replace(was, now)
    sys.stdout.buffer.write("\n".join(lines).encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0


def cmd_axioms_summary(a):
    const, const_module = a.statement_const, a.statement_const_module
    if not const or not const_module:
        return usage_error("axioms-summary", "--statement-const and --statement-const-module may not be empty")
    theorems = a.theorem
    info = {t: {"present": False, "kind": None, "declared_in": None, "axiom_count": None, "axioms": [],
                "type": None, "statement_project_constants": [], "statement_library_constants": []}
            for t in theorems}
    checks, modules, defs = {}, {}, {}
    lean_version = mode = None
    done = False
    deep = {"requested": bool(a.deep), "visited": None, "axioms": [], "missing": [], "axiom_count": None,
            "module_count": None}
    deep_modules = []       # (P or L, module, constants visited): which modules the deep walk touched
    block_kind = block_name = None
    block = []

    with open(a.output, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            s = line.strip()
            if block_kind:
                if s == "RHV %s_END %s" % (block_kind, block_name):
                    text = "\n".join(block)
                    if block_kind == "TYPE" and block_name in info:
                        info[block_name]["type"] = text
                    else:
                        defs[block_name] = text
                    block_kind = None
                else:
                    block.append(line)
                continue
            if not s.startswith("RHV "):
                continue
            f = s.split(" ")
            tag = f[1]
            if tag in ("TYPE_BEGIN", "DEF_BEGIN", "PROJECT_DEF_BEGIN"):
                block_kind, block_name, block = tag[:-6], " ".join(f[2:]), []
            elif tag == "LEAN_VERSION":
                lean_version = " ".join(f[2:])
            elif tag == "MODE":
                mode = f[2]
            elif tag == "DONE":
                done = True
            elif tag == "KIND" and f[2] in info:
                info[f[2]]["present"] = True
                info[f[2]]["kind"] = f[3]
            elif tag == "DECLARED_IN" and f[2] in info:
                info[f[2]]["declared_in"] = f[3]
            elif tag == "AXIOM_COUNT" and f[2] in info:
                info[f[2]]["axiom_count"] = int(f[3])
            elif tag == "AXIOM" and f[2] in info:
                info[f[2]]["axioms"].append(" ".join(f[3:]))
            elif tag == "STATEMENT_PROJECT_CONST" and f[2] in info:
                info[f[2]]["statement_project_constants"].append({"name": f[3], "module": f[4]})
            elif tag == "STATEMENT_LIBRARY_CONST" and f[2] in info:
                info[f[2]]["statement_library_constants"].append({"name": f[3], "module": f[4]})
            elif tag == "CHECK":
                checks[f[2]] = {"subject": f[3], "value": f[4] == "true"}
            elif tag == "MODULE":
                modules[f[2]] = f[3]
            elif tag == "DEEP_VISITED":
                deep["visited"] = int(f[2])
            elif tag == "DEEP_AXIOM_COUNT":
                deep["axiom_count"] = int(f[2])
            elif tag == "DEEP_AXIOM":
                deep["axioms"].append({"name": f[2], "module": f[3] if len(f) > 3 else None})
            elif tag == "DEEP_MISSING":
                deep["missing"].append(" ".join(f[2:]))
            elif tag == "DEEP_MODULE_COUNT":
                deep["module_count"] = int(f[2])
            elif tag == "DEEP_MODULE" and len(f) == 5:
                deep_modules.append((f[2], f[3], int(f[4])))

    failures = []
    if a.lean_status != 0:
        failures.append("lean exited with status %d (see the log)" % a.lean_status)
    if not done:
        failures.append("the check did not run to completion (no final marker in the output)")
    if mode != a.mode:
        failures.append("the output is from mode %r, expected %r" % (mode, a.mode))
    if a.primary not in theorems:
        # 08_check_axioms.sh refuses such a profile before running lean; this guards the record itself.
        failures.append("%s, the theorem whose statement is compared, is not one of the theorems checked (%s)"
                        % (a.primary, ", ".join(theorems) or "none"))
    for t in theorems:
        d = info[t]
        if not d["present"]:
            failures.append("%s: not found in the environment" % t)
            continue
        if d["axiom_count"] is None or d["axiom_count"] != len(d["axioms"]):
            failures.append("%s: axiom list is incomplete in the output" % t)
        extra = [x for x in d["axioms"] if x not in ALLOWED_AXIOMS]
        d["axioms_within_allowed"] = not extra
        if extra:
            failures.append("%s: depends on axioms outside the allowed three: %s" % (t, ", ".join(extra)))
        if d["kind"] == "axiom":
            failures.append("%s: is itself declared as an axiom" % t)
    chk = checks.get("statement_is_constant_" + const)
    if not chk or chk["subject"] != a.primary or not chk["value"]:
        what = "conclusion" if a.mode == "probe" else "type"
        failures.append("%s: its %s is not exactly the constant %s" % (a.primary, what, const))
    if modules.get(const) != const_module:
        failures.append("%s is defined in module %r, expected %s" % (const, modules.get(const), const_module))
    if a.deep:
        if deep["visited"] is None or deep["axiom_count"] is None or deep["axiom_count"] != len(deep["axioms"]):
            failures.append("deep walk: did not complete")
        else:
            extra = [x["name"] for x in deep["axioms"] if x["name"] not in ALLOWED_AXIOMS]
            if extra:
                failures.append("deep walk: reached axioms outside the allowed three: %s" % ", ".join(extra[:20]))
            if deep["missing"]:
                failures.append("deep walk: %d referenced constants are not in the environment" % len(deep["missing"]))

    # The list of modules the deep walk touched is reported, not judged: it decides nothing.
    if a.deep and deep["visited"] is not None:
        proj = [m for m in deep_modules if m[0] == "P"]
        lib = [m for m in deep_modules if m[0] == "L"]
        deep["modules_listed_completely"] = deep["module_count"] == len(deep_modules)
        deep["project_modules_touched"] = len(proj)
        deep["project_constants_visited"] = sum(m[2] for m in proj)
        deep["library_modules_touched"] = len(lib)
        deep["library_constants_visited"] = sum(m[2] for m in lib)
        if a.json and deep_modules:
            cone = os.path.splitext(a.json)[0] + ".modules.tsv"
            with open(cone, "w", encoding="utf-8") as fh:
                fh.write("origin\tmodule\tconstants_visited\n")
                for origin, mod, k in sorted(deep_modules, key=lambda m: (m[0], m[1])):
                    fh.write("%s\t%s\t%d\n" % ("project" if origin == "P" else "library", mod, k))
            deep["modules_file"] = os.path.basename(cone)

    verdict = "PASS" if not failures else "FAIL"
    result = {
        "check": "axioms and statement", "mode": a.mode, "verdict": verdict, "failures": failures,
        "run_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "lean_version": lean_version, "lean_exit_status": a.lean_status,
        "tarball_sha256": a.tarball_sha256 or None,
        "compiled_modules": a.compiled, "source_modules": a.sources,
        "allowed_axioms": ALLOWED_AXIOMS, "primary_theorem": a.primary,
        "theorems": info, "checks": checks, "defining_modules": modules, "definitions": defs,
        "deep_walk": deep, "log_file": os.path.basename(a.output),
    }
    if a.source_id:                 # what identifies the source when it is not, or not only, a tarball's SHA-256
        result["source_id"] = a.source_id
    if a.target:                    # given for every target but the default one
        result["target"] = a.target
    if a.json:
        write_json(a.json, result)

    print()
    print("== Axiom and statement check (%s mode), Lean %s" % (a.mode, lean_version or "version unknown"))
    if a.target:
        print("  target: %s" % a.target)
    if a.source_id:
        print("  source: %s" % a.source_id)
    for t in theorems:
        d = info[t]
        if not d["present"]:
            print("  %-42s NOT FOUND" % t)
            continue
        ax = ", ".join(d["axioms"]) if d["axioms"] else "none"
        print("  %s  (%s, declared in %s)" % (t, d["kind"], d["declared_in"]))
        print("      axioms: %s" % ax)
        print("      type:   %s" % (d["type"] or "?").replace("\n", "\n              "))
        for c in d["statement_project_constants"]:
            print("      statement uses project definition %s (module %s)" % (c["name"], c["module"]))
    for name, text in sorted(defs.items()):
        print("  definition of %s:" % name)
        print("      " + text.replace("\n", "\n      "))
    for name in sorted(modules):
        print("  %s is defined in module %s" % (name, modules[name]))
    if chk:
        print("  %s of %s is exactly the constant %s: %s" % (
            "conclusion" if a.mode == "probe" else "type", chk["subject"], const, "yes" if chk["value"] else "NO"))
    if a.deep and deep["visited"] is not None:
        print("  deep walk: visited %d constants; axioms reached: %s" % (
            deep["visited"], ", ".join(x["name"] for x in deep["axioms"]) or "none"))
        if deep.get("project_modules_touched") is not None:
            print("  deep walk: touched %d project modules (%d constants) and %d library modules (%d constants)%s" % (
                deep["project_modules_touched"], deep["project_constants_visited"],
                deep["library_modules_touched"], deep["library_constants_visited"],
                "" if deep["modules_listed_completely"] else "; WARNING: the module list in the output is incomplete"))
    print()
    if failures:
        print("RESULT: FAIL")
        for f_ in failures:
            print("  - " + f_)
    else:
        print("RESULT: PASS")
        if a.mode == "probe":
            print("  This is the probe. It covers only the reduction lemma %s," % a.primary)
            print("  which has hypotheses. It says nothing about whether those hypotheses are proved.")
        else:
            print("  Lean reports that each listed theorem depends on no axioms other than")
            print("  %s; the type of %s is the constant" % (", ".join(ALLOWED_AXIOMS), a.primary))
            print("  %s; and that constant is the one defined in" % const)
            print("  %s." % const_module)
        print("  Scope of this result: it reads the compiled modules on disk. The axiom lists come")
        print("  from Lean.collectAxioms, the function behind '#print axioms', which for imported")
        print("  declarations answers from lists the compiler recorded in each compiled file. The")
        print("  result is therefore as complete as the build (06_progress.sh) and as trustworthy as")
        print("  the compiled files (09_kernel_replay.sh re-checks them; --deep re-derives the axiom")
        print("  list without the recorded lists)." + ("" if a.deep else " The deep walk was not requested in this run."))
    return 0 if not failures else 1


# --------------------------------------------------------------------------------------------
# 09: kernel re-check planning and summary

def lib_files(root, exts):
    """One walk of root. Returns {ext: {module name: path}} for the files that end with each extension.

    A '.lake' directory directly under root is not walked: when the sources are the project directory
    itself (a target whose sources are in '.'), that is where Lake keeps its build and the packages it
    fetched, none of which are the project's sources."""
    out = {e: {} for e in exts}
    if not os.path.isdir(root):
        return out
    for dirpath, dirs, files in os.walk(root):
        if dirpath == root:
            dirs[:] = [d for d in dirs if d != ".lake"]
        for f in files:
            for e in exts:
                if f.endswith(e):
                    rel = os.path.relpath(os.path.join(dirpath, f), root)[:-len(e)]
                    out[e][rel.replace(os.sep, ".")] = os.path.join(dirpath, f)
                    break
    return out


# Exit statuses that say nothing about the module, because no replay of it was completed:
#   96   the checker could not do its work (it could not be started, or could not open or find a compiled file)
#   97   the stock tool ended with status 0 without reporting that it replayed this module
#   98   the stock tool replayed other modules in the same process (modules beneath this one that it imports)
#        and rejected one of THEM; this module was not judged, and the rejected one has a check of its own
#   129, 130, 137, 143   it was ended by a signal from outside: hang-up, interrupt, kill (typically the system's
#        out-of-memory killer), terminate (typically a time limit)
# Any other non-zero status is a REJECTION of the module by the tool (status 1) or a CRASH of the tool on it
# (128 or more). Neither is ever replaced by a later result: see replay_state.
NOT_RUN_STATUSES = (96, 97, 98, 129, 130, 137, 143)

# The two programs that can replay a module. Both run the same function of the pinned toolchain on it
# (replayFromImports in LeanChecker.lean).
#   leanchecker   the stock tool shipped with the toolchain: the tool criterion C3 names
#   rhv-replay    scripts/verify/replay: many exactly-named modules per process; an optional second replay
REPLAY_METHODS = ("leanchecker", "rhv-replay")

RERUNS_AFTER_A_REJECTION = 2      # how often a tool is run again on a module it has rejected, as evidence


def prefix_names(names):
    """The names that are a proper prefix of another name in the set, by the components between dots
    (module A when module A.B exists; not A when only AB exists)."""
    prefixes = set()
    for n in names:
        parts = n.split(".")
        for i in range(1, len(parts)):
            prefixes.add(".".join(parts[:i]))
    return set(names) & prefixes


def read_results(path):
    """Every complete line of the results file, in the order written. Returns (rows, damaged).

    A row is (module, status, stamp, epoch, method, program, how). Three shapes of line are complete: five
    fields (written before the method was recorded: all leanchecker's), six (with the method), eight (with the
    SHA-256 of the program that produced the line and how it was run). Anything else is damaged: a line cut
    short by a full disk, two lines run together, a status that is not a number, a last line with no newline,
    a line with a zero byte in it (what a file can end with after the machine went down in mid-write).
    Damaged lines are counted, never credited to a tool, and block every "complete" below."""
    rows, damaged = [], 0
    if not os.path.isfile(path):
        return rows, damaged
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if f[0] == "module" or line.strip() == "":
                continue
            ok = line.endswith("\n") and "\x00" not in line and len(f) in (5, 6, 8) and (len(f) == 5 or f[5] in REPLAY_METHODS)
            if ok:
                try:
                    rc = int(f[1])
                except ValueError:
                    ok = False
            if not ok:
                damaged += 1
                continue
            rows.append((f[0], rc, f[3], f[4], f[5] if len(f) > 5 else "leanchecker",
                         f[6] if len(f) == 8 else "", f[7] if len(f) == 8 else ""))
    return rows, damaged


def replay_state(a):
    """What is compiled, and what every recorded result says about it. Nothing recorded is ever set aside.

    For each module and each tool, the results for the compiled file now on disk are kept in order:
      P  the tool passed the module            R  the tool rejected the module, or crashed on it
    (results that say nothing, NOT_RUN_STATUSES, only mark the module as still to be checked).
    A module's state with one tool:
      passed         at least one P and no R
      rejected       one R; the tool is run on it again, RERUNS_AFTER_A_REJECTION times, as evidence
      failed         two or more R: the rejection came back
      not_run        only results that say nothing
      not_judged     the last such result was the stock tool stopping at a rejected module beneath this one,
                     which it replays in the same process when this module imports it
      stale          results only for an earlier compiled file, none of them an R
      no_stamp       the build tool never finished this file, so no result can be for "the file now on disk"
    An R recorded for an EARLIER compiled file of the module is not forgotten when the module is compiled
    again: it is reported, and like every other R it blocks "complete". The kernel is deterministic on a given
    file, so an R that does not come back is a fault of the machine or of the tooling, and it is not for this
    script to decide that it did not matter."""
    files = lib_files(a.lib, (".olean.server", ".olean.private", ".olean"))
    compiled = files[".olean"]
    # leanchecker replays a module's ".olean.private" part when one exists, while an importing file reads only
    # the ".olean" of a module that is not a `module` file. The default target has no `module` files, and this
    # replay does not support a project that has them (docs/adapting-to-another-proof.md). So any such part
    # beside a compiled file is reported and blocks "complete": either the build did not write it, or the
    # project is one this replay was not made for.
    extra_parts = sorted(set(files[".olean.server"]) | set(files[".olean.private"]))
    sources = lib_files(a.src, (".lean",))[".lean"] if a.src else {}
    # leanchecker checks every module whose name has its argument as a prefix. With the whole library on its
    # search path, a module that is a proper prefix of another module's name can therefore not be checked on
    # its own. With only its import closure on the search path (the default here) it can.
    prefix_modules = sorted(set(compiled) & prefix_names(set(compiled) | set(sources)))

    # The stamp of a compiled file is the content hash the build tool keeps beside it. A compiled file without
    # one was left by a compiler that the build tool never saw finish; no result can be current for it.
    stamps = {}
    for mod, path in compiled.items():
        try:
            with open(path + ".hash", encoding="ascii", errors="replace") as fh:
                stamps[mod] = fh.read().strip() or None
        except OSError:
            stamps[mod] = None

    rows, damaged = read_results(a.results)
    seq = {m: {} for m in REPLAY_METHODS}       # method -> module -> "PRP..." for the current file, in order
    earlier = []                                # rejections and crashes recorded for an earlier compiled file
    rejections = []                             # every R for the current file: (module, method, status, epoch, how)
    other = {m: {} for m in REPLAY_METHODS}     # method -> module -> "not_run" | "not_judged" | "stale"
    programs = {m: collections.Counter() for m in REPLAY_METHODS}   # method -> {program sha256: passes counted}
    hows = {m: collections.Counter() for m in REPLAY_METHODS}       # method -> {how the tool was run: passes counted}
    for mod, rc, stamp, epoch, method, program, how in rows:
        if mod not in compiled:
            if rc != 0 and rc not in NOT_RUN_STATUSES:
                earlier.append((mod, method, rc, stamp, "the module is no longer compiled"))
            continue
        cur = stamps[mod]
        if cur is None or stamp != cur:
            if rc != 0 and rc not in NOT_RUN_STATUSES:
                earlier.append((mod, method, rc, stamp, "an earlier compiled file" if cur else "a file the build tool had not finished"))
            else:
                other[method].setdefault(mod, "stale")
            continue
        if rc == 0:
            seq[method][mod] = seq[method].get(mod, "") + "P"
            programs[method][program] += 1
            hows[method][how or "not recorded"] += 1
        elif rc == 98:
            other[method][mod] = "not_judged"       # the tool stopped at another module replayed with this one
        elif rc in NOT_RUN_STATUSES:
            other[method][mod] = "not_run"
        else:
            seq[method][mod] = seq[method].get(mod, "") + "R"
            rejections.append((mod, method, rc, epoch, how))

    def state(mod, method):
        if stamps[mod] is None:
            return "no_stamp"
        s = seq[method].get(mod, "")
        if s.count("R") >= 2:
            return "failed"
        if "R" in s:
            return "rejected"
        if "P" in s:
            return "passed"
        return other[method].get(mod)           # not_run, not_judged, stale, or None

    def reruns_owed(mod, method):
        """How many more times the tool is to be run on a module it has rejected once."""
        s = seq[method].get(mod, "")
        if s.count("R") != 1:
            return 0
        return max(0, RERUNS_AFTER_A_REJECTION - (len(s) - s.index("R") - 1))

    by = {m: {} for m in REPLAY_METHODS}
    for mod in compiled:
        for method in REPLAY_METHODS:
            st = state(mod, method)
            if st:
                by[method][mod] = st
    earlier_mods = {e[0] for e in earlier}
    passed, failed, rejected_once, remaining, disagree = [], [], [], [], []
    for mod in sorted(compiled):
        sts = [by[m].get(mod) for m in REPLAY_METHODS]
        if "failed" in sts:
            failed.append(mod)
        elif "rejected" in sts or mod in earlier_mods:
            rejected_once.append(mod)
        elif "passed" in sts:
            passed.append(mod)
        else:
            remaining.append(mod)
        if ("failed" in sts or "rejected" in sts) and "passed" in sts:
            disagree.append(mod)
    owed = {m: sorted(x for x in compiled if stamps[x] is not None and reruns_owed(x, m)) for m in REPLAY_METHODS}
    # A module that was not judged because a module beneath it was rejected cannot be judged while that module
    # stays failed: the tool would stop at the same place again. It is not planned again, and it is reported.
    failed_by = {m: sorted(x for x, v in by[m].items() if v == "failed") for m in REPLAY_METHODS}
    blocked = {}
    for m in REPLAY_METHODS:
        nj = [x for x, v in by[m].items() if v == "not_judged"]
        blocked[m] = sorted(x for x in nj if any(f.startswith(x + ".") for f in failed_by[m]))
    return {"compiled": compiled, "sources": sources, "prefix_modules": prefix_modules, "extra_parts": extra_parts,
            "stamps": stamps, "by": by, "passed": passed, "failed": failed, "rejected_once": rejected_once,
            "remaining": remaining, "disagree": disagree, "damaged": damaged, "rejections": rejections,
            "earlier": earlier, "owed": owed, "programs": programs, "hows": hows, "blocked": blocked}


def cmd_replay_plan(a):
    """Print what the chosen tool has still to do: modules it has no result for, and modules it has rejected
    once and has not yet been run on again twice. A module it has passed, or failed, is not run again."""
    st = replay_state(a)
    mine = st["by"][a.method]
    has_stamp = {m for m, s in st["stamps"].items() if s is not None}
    prefix = set(st["prefix_modules"])
    owed = set(st["owed"][a.method])
    blocked = set(st["blocked"][a.method])
    def wanted(m):
        if a.only_reruns:               # only the evidence runs after a rejection, nothing new
            return m in owed
        return m in owed or (mine.get(m) in (None, "not_run", "not_judged", "stale") and m not in blocked)
    listed = None
    if a.list:
        with open(a.list, encoding="utf-8") as fh:
            listed = [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]
    if a.prefix_modules:
        # Whole-library mode only. One line per prefix module still to check: module, stamp, and the word
        # "prefix", which tells kernel_check_one.sh to keep the checker's list of the modules it replayed.
        # With a list, only the prefix modules it names.
        mine_prefix = [m for m in st["prefix_modules"] if listed is None or m in set(listed)]
        todo = [m for m in mine_prefix if m in has_stamp and wanted(m)]
        for m in todo:
            sys.stdout.write("%s\t%s\tprefix\n" % (m, st["stamps"][m]))
        sys.stderr.write("prefix modules: %d compiled%s; %d to check now\n" % (
            len(prefix), " (%d of them in the list)" % len(mine_prefix) if listed is not None else "", len(todo)))
        return 0
    # With the whole library on its search path the stock tool cannot check a prefix module by itself: those
    # are left to the prefix pass.
    eligible = sorted(m for m in has_stamp if a.all_modules or a.method == "rhv-replay" or m not in prefix)
    if listed is not None:
        ok = set(eligible)
        unknown = [m for m in listed if m not in has_stamp]
        if unknown:
            sys.stderr.write("note: %d listed modules are not compiled, or were never finished by the build; skipped\n" % len(unknown))
        later = [m for m in listed if m in has_stamp and m not in ok]
        if later:
            sys.stderr.write("note: %d listed modules are prefix modules; they are checked in the prefix pass\n" % len(later))
        pool = [m for m in listed if m in ok]
    else:
        pool = eligible
    if a.sample and a.sample < len(pool):
        pool = sorted(random.Random(a.seed).sample(sorted(pool), a.sample))
    todo = [m for m in pool if wanted(m)]
    # A fixed shuffle, so that cheap and costly modules are mixed instead of arriving library by library.
    # The order has no bearing on the result: every module is replayed from its own imports.
    random.Random(a.seed).shuffle(todo)
    for m in todo:
        sys.stdout.write("%s\t%s\n" % (m, st["stamps"][m]))
    again = len([m for m in todo if m in owed])
    sys.stderr.write("%s: selected %d modules; %d to check now%s\n" % (
        a.method, len(pool), len(todo), " (of which %d are being run again after a rejection)" % again if again else ""))
    return 0


def cmd_replay_summary(a):
    st = replay_state(a)
    compiled, by = st["compiled"], st["by"]
    passed, failed, rejected_once, remaining, disagree = st["passed"], st["failed"], st["rejected_once"], st["remaining"], st["disagree"]
    prefix = st["prefix_modules"]
    total_src = len(st["sources"])
    # Compared by name, not by count: a compiled file with no source must not stand in for a missing one.
    not_compiled = sorted(set(st["sources"]) - set(compiled))
    no_source = sorted(set(compiled) - set(st["sources"])) if total_src else []
    extra_parts = st["extra_parts"]
    no_stamp = sorted(m for m, s in st["stamps"].items() if s is None)
    damaged = st["damaged"]
    not_judged = sorted(m for m in remaining if any(by[x].get(m) == "not_judged" for x in REPLAY_METHODS))
    not_run = sorted(m for m in remaining if m not in set(not_judged) and any(by[x].get(m) == "not_run" for x in REPLAY_METHODS))
    blocked_all = sorted(set(st["blocked"]["leanchecker"]) | set(st["blocked"]["rhv-replay"]))
    # A crash in a process that also replayed modules beneath the one asked for may belong to one of those.
    beneath = "import-closure-directory-holding-modules-beneath"
    crash_unsure = sorted({r[0] for r in st["rejections"] if r[2] >= 128 and r[4] == beneath})
    stale = sorted(m for m in remaining if any(by[x].get(m) == "stale" for x in REPLAY_METHODS))
    owed = sorted(set(st["owed"]["leanchecker"]) | set(st["owed"]["rhv-replay"]))
    n_pass = {x: sum(1 for v in by[x].values() if v == "passed") for x in REPLAY_METHODS}
    both = sum(1 for m in compiled if all(by[x].get(m) == "passed" for x in REPLAY_METHODS))
    # What another run could still do: check what has no result, and run again what was rejected once.
    checkable_left = len([m for m in remaining if st["stamps"][m] is not None]) + len(owed)
    # What the plan of each tool would still select from the whole tree (the same rule as cmd_replay_plan's).
    owed_by = {x: set(st["owed"][x]) for x in REPLAY_METHODS}
    blocked_by = {x: set(st["blocked"][x]) for x in REPLAY_METHODS}
    to_check = {x: len([m for m in compiled if st["stamps"][m] is not None and
                        (m in owed_by[x] or (by[x].get(m) in (None, "not_run", "not_judged", "stale") and m not in blocked_by[x]))])
                for x in REPLAY_METHODS}
    any_rejection = bool(st["rejections"] or st["earlier"])
    structure_ok = total_src > 0 and not not_compiled and not no_source and not extra_parts and not no_stamp
    # Complete: the sources are known; every one of them is compiled and was finished by the build tool; nothing
    # else is compiled; every compiled module has been passed, for the file now on disk; no tool has rejected
    # or crashed on any module, in any recorded run; and no line of the results file is damaged.
    clean = structure_ok and not any_rejection and damaged == 0
    complete = clean and not remaining and not rejected_once and not failed
    complete_by = {x: clean and n_pass[x] == len(compiled) for x in REPLAY_METHODS}
    # Criterion C3 of PREREGISTRATION.md: every compiled module is re-checked by leanchecker, and every one passes.
    c3 = {"every_source_module_is_compiled_and_nothing_else_is": structure_ok,
          "every_compiled_module_passed_by_leanchecker": bool(compiled) and n_pass["leanchecker"] == len(compiled),
          "no_rejection_or_crash_recorded_by_any_tool": not any_rejection,
          "the_results_file_has_no_damaged_lines": damaged == 0}
    c3_holds = all(c3.values())
    # The optional second replay: one program for every pass, and which.
    progs = {x: [{"sha256": k or "not recorded", "passes": v} for k, v in sorted(st["programs"][x].items())] for x in REPLAY_METHODS}
    trusted = a.trusted_program
    rhv_ok = bool(compiled) and n_pass["rhv-replay"] == len(compiled)
    rhv_one = len(st["programs"]["rhv-replay"]) == 1 and "" not in st["programs"]["rhv-replay"] and \
        (not trusted or list(st["programs"]["rhv-replay"]) == [trusted])
    print("== Kernel re-check summary")
    if total_src:
        print("  source modules:                         %d" % total_src)
    print("  compiled modules:                       %d" % len(compiled))
    print("    passed (for the file now on disk, and never rejected): %d" % len(passed))
    print("      by leanchecker: %d   by rhv-replay: %d   by both: %d" % (n_pass["leanchecker"], n_pass["rhv-replay"], both))
    print("    FAILED (rejected or crashed on, and again when run again): %d" % len(failed))
    print("    rejected or crashed on once (not a pass, whatever followed): %d%s" % (
        len(rejected_once), "  (still to be run again: %d)" % len(owed) if owed else ""))
    print("    remaining (never checked, or recompiled since): %d  (of which recompiled since: %d)" % (len(remaining), len(stale)))
    if st["earlier"]:
        print("  rejections recorded for an earlier compiled file of a module, or for a module no longer compiled: %d" % len(st["earlier"]))
    if disagree:
        print("  THE TWO TOOLS DISAGREE on %d modules (passed by one, rejected by the other)" % len(disagree))
    if not_run:
        print("  checker not run or ended from outside (counted as remaining, not as rejected; run again, with fewer jobs): %d" % len(not_run))
    if not_judged:
        print("  not judged: the stock tool stopped at a rejected module beneath it, replayed in the same process: %d" % len(not_judged))
        print("    (of which cannot be judged while that module stays failed, and are not run again: %d)" % len(blocked_all))
        for m in not_judged[:20]:
            print("  not judged: " + m)
    if crash_unsure:
        print("  crashes in a process that also replayed modules beneath the one asked for (the crash may be theirs; see out/<module>.out): %d" % len(crash_unsure))
    if no_stamp:
        print("  compiled files the build tool never finished (no hash beside them; rebuild them): %d" % len(no_stamp))
    if damaged:
        print("  DAMAGED lines in the results file (not a complete result; nothing is complete while there are any): %d" % damaged)
    if extra_parts:
        print("  modules with an .olean.server or .olean.private file the build should not have written: %d" % len(extra_parts))
        print("    (a file that starts with `module` is compiled to these parts; this replay does not support such"
              " projects: docs/adapting-to-another-proof.md)")
    if not_compiled:
        print("  source modules not compiled: %d" % len(not_compiled))
    if no_source:
        print("  compiled modules with no source file: %d" % len(no_source))
    for m in failed[:50]:
        print("  FAILED: " + m)
    for m in rejected_once[:50]:
        print("  rejected once: " + m)
    if len(failed) + len(rejected_once) > 100:
        print("  ... and more; summary.json has the lists")
    print("  every source module compiled and passing: %s" % ("yes" if complete else "no"))
    print("  criterion C3 (every compiled module re-checked by leanchecker, and every one passes):")
    for k, v in c3.items():
        print("    %-58s %s" % (k.replace("_", " ") + ":", "yes" if v else "NO"))
    print("    all of these hold: %s" % ("yes" if c3_holds else "NO"))
    if n_pass["rhv-replay"]:
        print("  second replay, by rhv-replay: every compiled module passed: %s; every pass by one recorded program: %s" % (
            "yes" if rhv_ok else "no", "yes" if rhv_one else "NO"))
    if a.json:
        def rej(rows):
            return [{"module": r[0], "tool": r[1], "status": r[2], "what": "crash" if r[2] >= 128 else "rejection"} for r in rows[:200]]
        write_json(a.json, {
            "check": "kernel replay of each compiled module from its imports (replayFromImports of the pinned toolchain)",
            "run_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "source_modules": total_src, "compiled_modules": len(compiled),
            "passed": len(passed), "passed_by_leanchecker": n_pass["leanchecker"], "passed_by_rhv_replay": n_pass["rhv-replay"],
            "passed_by_both": both,
            "failed": len(failed), "failed_modules": failed[:200],
            "rejected_once": len(rejected_once), "rejected_once_modules": rejected_once[:200],
            "rejections_and_crashes_recorded_for_the_current_files": len(st["rejections"]), "rejections_sample": rej(st["rejections"]),
            "rejections_recorded_for_earlier_files": [{"module": e[0], "tool": e[1], "status": e[2], "about": e[4]} for e in st["earlier"][:200]],
            "tools_disagree": len(disagree), "disagreeing_modules": disagree[:200],
            "remaining": len(remaining), "remaining_that_another_run_could_check": checkable_left,
            "still_to_be_run_again_after_a_rejection": len(owed),
            "leanchecker_still_to_check": to_check["leanchecker"], "rhv_replay_still_to_check": to_check["rhv-replay"],
            "leanchecker_passes_by_how_it_was_run": dict(sorted(st["hows"]["leanchecker"].items())),
            "recompiled_since_checked": len(stale), "damaged_result_lines": damaged,
            "not_run_or_ended_from_outside": len(not_run), "not_run_sample": not_run[:200],
            "not_judged_because_a_module_beneath_was_rejected": len(not_judged), "not_judged_sample": not_judged[:200],
            "not_judged_and_not_run_again_while_that_module_stays_failed": len(blocked_all),
            "crash_may_belong_to_a_module_beneath": crash_unsure[:200],
            "prefix_modules": len(prefix),
            "compiled_files_never_finished_by_the_build": len(no_stamp), "never_finished_sample": no_stamp[:50],
            "modules_with_unexpected_parts": len(extra_parts), "unexpected_parts_sample": extra_parts[:50],
            "source_modules_not_compiled": len(not_compiled), "not_compiled_sample": not_compiled[:50],
            "compiled_modules_without_source": len(no_source), "without_source_sample": no_source[:50],
            "programs_that_produced_the_passes": progs,
            "complete": complete, "complete_by_leanchecker_alone": complete_by["leanchecker"],
            "complete_by_rhv_replay_alone": complete_by["rhv-replay"],
            "criterion_c3": {"conditions": c3, "all_hold": c3_holds},
            "second_replay_by_rhv_replay": {"every_compiled_module_passed": rhv_ok, "every_pass_by_one_recorded_program": rhv_one,
                                            "program_expected": trusted or None},
        })
    if failed or rejected_once or st["earlier"]:
        return 1
    if damaged:
        return 3            # a damaged line may be what is left of a rejection: never "nothing rejected"
    if a.require_c3:
        return 0 if c3_holds else 3
    # A run of one tool over everything is complete when THAT tool has passed every module.
    return 3 if a.require_complete and not complete_by[a.method] else 0


# ---- the import graph, and directories that hold one module's import closure ----------------------------------

def read_imports(path):
    """The modules a Lean source file imports: the `import` lines of its header."""
    out, depth = [], 0
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return out
    with fh:
        for line in fh:
            s = line.strip()
            if depth:                                   # inside a block comment
                depth += s.count("/-") - s.count("-/")
                depth = max(depth, 0)
                continue
            if not s or s.startswith("--"):
                continue
            if s.startswith("/-"):
                depth = s.count("/-") - s.count("-/")
                depth = max(depth, 0)
                continue
            words = s.split()
            while words and words[0] in ("public", "meta", "private"):
                words = words[1:]
            if words and words[0] == "import":
                out.extend(w for w in words[1:] if w not in ("all", "runtime", "public", "meta"))
            elif words and words[0] in ("module", "prelude"):
                continue
            else:
                break                                   # the header is over
    return out


def source_fingerprint(sources):
    """A digest of the source files' names, sizes and modification times: cheap to compute, and different
    whenever a source file was added, removed or rewritten."""
    h = hashlib.sha256()
    for n in sorted(sources):
        try:
            st = os.stat(sources[n])
            h.update(("%s\t%d\t%d\n" % (n, st.st_size, st.st_mtime_ns)).encode("utf-8"))
        except OSError:
            h.update(("%s\tmissing\n" % n).encode("utf-8"))
    return h.hexdigest()


def cmd_import_graph(a):
    """Write the project's import graph: its modules, and for each the project modules it imports directly.

    With --if-stale the graph is read again only when the source tree is not the one the existing file was
    made from (by the names, sizes and modification times of the source files). A graph older than the
    sources cannot make a module pass, but it would leave changed modules "not checked" for ever."""
    sources = lib_files(a.src, (".lean",))[".lean"]
    fp = source_fingerprint(sources)
    if a.if_stale and os.path.isfile(a.out):
        try:
            with open(a.out, encoding="utf-8") as fh:
                if json.load(fh).get("source_fingerprint") == fp:
                    return 0
        except (OSError, ValueError, AttributeError):
            pass                                        # unreadable or damaged: make it again
        sys.stderr.write("import graph: the source tree is not the one the stored graph was read from; reading it again\n")
    names = sorted(sources)
    index = {n: i for i, n in enumerate(names)}
    imports = [sorted({index[x] for x in read_imports(sources[n]) if x in index}) for n in names]
    with open(a.out + ".tmp", "w", encoding="utf-8") as fh:
        json.dump({"what": "the project's modules and, for each, the positions of the project modules it imports directly",
                   "source_fingerprint": fp,
                   "source_fingerprint_is": "SHA-256 over the sorted lines 'module<TAB>size<TAB>modification time in ns' of the source files",
                   "modules": names, "imports": imports}, fh)
    os.replace(a.out + ".tmp", a.out)
    sys.stderr.write("import graph: %d modules, %d import edges\n" % (len(names), sum(len(x) for x in imports)))
    return 0


def cmd_closure_worker(a):
    """Check a batch of modules with the stock tool, each with only its import closure on the search path.

    For each module a directory is made that holds hard links to the compiled files of the module and of every
    project module it imports, directly or not, and nothing else of the project. kernel_check_one.sh then runs
    leanchecker with that directory in place of the project's library directory, and the directory is removed.
    leanchecker lists every compiled file on its search path before it checks anything; this keeps that list to
    what the module needs. The files are the same files (hard links), so what the kernel is shown is unchanged.
    If the closure is computed too small, the tool reports a missing file and the module is recorded as not
    checked; it cannot make a module pass."""
    import shutil
    import subprocess
    import tempfile
    with open(a.graph, encoding="utf-8") as fh:
        g = json.load(fh)
    names, imports = g["modules"], g["imports"]
    index = {n: i for i, n in enumerate(names)}
    with open(a.batch, encoding="utf-8") as fh:
        todo = [ln.rstrip("\n").split("\t") for ln in fh if ln.strip()]
    warned = unknown = False

    def stamp_now(rel):
        try:
            with open(os.path.join(a.lib, rel) + ".hash", encoding="ascii", errors="replace") as fh:
                return fh.read().strip() or None
        except OSError:
            return None

    for item in todo:
        mod, stamp = item[0], (item[1] if len(item) > 1 else "nohash")
        if mod not in index and not unknown:
            sys.stderr.write("closure-worker: %s is not in the import graph, which is then older than the source tree; "
                             "only its own compiled file is made visible\n" % mod)
            unknown = True
        seen = set()
        stack = [index[mod]] if mod in index else []
        while stack:
            i = stack.pop()
            if i in seen:
                continue
            seen.add(i)
            stack.extend(j for j in imports[i] if j not in seen)
        own = mod.replace(".", os.sep) + ".olean"
        rels = [names[i].replace(".", os.sep) + ".olean" for i in seen] or [own]
        farm = tempfile.mkdtemp(prefix="closure.", dir=a.dir_base)
        made = set()
        for rel in rels:
            dst = os.path.join(farm, rel)
            d = os.path.dirname(dst)
            if d not in made:
                os.makedirs(d, exist_ok=True)
                made.add(d)
            try:
                os.link(os.path.join(a.lib, rel), dst)
            except FileNotFoundError:
                continue                # not compiled: the tool will say which file it missed
            except OSError as ex:
                if not warned:
                    sys.stderr.write("closure-worker: cannot link compiled files into %s: %s\n" % (a.dir_base, ex))
                    warned = True
                break
            # The further parts of a module compiled with the module system. The tool replays the most private
            # part it finds beside the file, so they must be beside the link too. (The default target has none,
            # and the summary reports any as a fault; the link is here so that the tool is never shown
            # less of a module than it would be shown in the library directory.)
            for part in (".server", ".private"):
                try:
                    os.link(os.path.join(a.lib, rel) + part, dst + part)
                except OSError:
                    pass
        # The result will be recorded for the stamp the plan read. It must still be the stamp of the file at
        # the module's path, and that file must be the one linked: a compiled file replaced since the plan was
        # made is not checked under the old stamp.
        # The tool replays every module on its search path whose name begins with the name it is given: when the
        # module imports modules beneath itself, they are replayed in the same process, and the record says so.
        kind = "closure-beneath" if any(names[i].startswith(mod + ".") for i in seen) else "closure"
        try:
            same_file = os.path.samefile(os.path.join(a.lib, own), os.path.join(farm, own))
        except OSError:
            same_file = True            # no file to compare: the tool will report the missing file
        if stamp_now(own) != stamp or not same_file:
            kind = "changed"
        env = dict(os.environ)
        env["RH_LEAN_PATH"] = farm + (":" + a.packages if a.packages else "")
        subprocess.call([a.check_one, mod, stamp, kind], env=env)
        shutil.rmtree(farm, ignore_errors=True)
    return 0


# The SHA-256 of scripts/verify/replay/RhvReplay.lean as reviewed. replay-driver-check refuses any other file:
# to change the program, change this line in the same commit, where the two can be seen together.
DRIVER_SHA256 = "52c1984827f2c461ce4c7db782076a1d47cce8875657722556ae62d26a7bc3ef"
DRIVER_HEADER = ["import Lean.CoreM", "import Lean.Replay", "open Lean"]
# Words that could change what a definition in the driver means, or put other code in its place. None of them
# has any business in a file that is one copied function and one loop.
DRIVER_FORBIDDEN = ("@[", "attribute", "implemented_by", "extern", "macro", "syntax", "elab", "notation",
                    "set_option", "instance", "initialize", "namespace", "section", "theorem", "axiom",
                    "abbrev", "opaque", "example", "structure", "inductive", "class", "mutual", "universe",
                    "variable", "deriving", "#eval", "run_cmd", "open ", "import ", "local ", "scoped ")


def cmd_replay_driver_check(a):
    """Exit 0 only if the driver is the reviewed file and carries the toolchain's replayFromImports unchanged.

    Checked: (1) the driver file as a whole has the SHA-256 pinned above; (2) its replayFromImports is the
    toolchain's, character for character; (3) each of the two definitions occurs exactly once; (4) the file
    opens with one comment that contains no comment inside it, and there is no block comment anywhere after it
    (Lean's block comments nest, so a stray opener could put the visible program out of action); (5) between
    that comment and the function there are the three expected lines and nothing else; (6) `main`, the only
    other definition, contains none of the words that could redefine or replace a function.
    (1) alone settles it for the file in this repository; (2) ties that file to the toolchain actually installed;
    the rest is there so that the check still means something if the pin is ever changed.
    Not checked, because no comparison of text can: that `main` does what its 25 lines appear to do. Read it."""
    START, MAIN, FRESH = "unsafe def replayFromImports", "unsafe def main", "unsafe def replayFromFresh"
    with open(a.driver_src, encoding="utf-8") as fh:
        ours_text = fh.read()
    with open(a.toolchain_src, encoding="utf-8") as fh:
        theirs_text = fh.read()
    sha = lambda t: hashlib.sha256(t.encode("utf-8")).hexdigest()
    problems = []
    if sha(ours_text) != DRIVER_SHA256:
        problems.append("the driver is not the reviewed file: its sha256 is %s, expected %s" % (sha(ours_text), DRIVER_SHA256))
    if ours_text.count(START) != 1 or ours_text.count(MAIN) != 1:
        problems.append("the driver must contain 'unsafe def replayFromImports' and 'unsafe def main' exactly once each")
    if theirs_text.count(START) != 1 or theirs_text.count(FRESH) != 1:
        problems.append("the toolchain's LeanChecker.lean does not have the two definitions expected of it")
    structure_ok = ours_text.count(START) == 1 and ours_text.count(MAIN) == 1 and theirs_text.count(START) == 1 and theirs_text.count(FRESH) == 1
    if structure_ok:
        o0, o1 = ours_text.index(START), ours_text.index(MAIN)
        t0, t1 = theirs_text.index(START), theirs_text.index(FRESH)
        if not o0 < o1 or not t0 < t1:
            problems.append("the definitions are not in the expected order")
            structure_ok = False
    if structure_ok:
        ours, theirs = ours_text[o0:o1].rstrip() + "\n", theirs_text[t0:t1].rstrip() + "\n"
        if ours != theirs:
            problems.append("the two definitions of replayFromImports differ")
        # One leading comment, with no comment opened inside it, and no block comment after it.
        end = ours_text.find("-/")
        if not ours_text.startswith("/-") or end < 0 or "/-" in ours_text[2:end]:
            problems.append("the driver must open with one block comment that has no comment inside it")
        elif "/-" in ours_text[end + 2:] or "-/" in ours_text[end + 2:]:
            problems.append("the driver may not contain a block comment after its opening one")
        else:
            head = ours_text[end + 2:o0]
            if [ln.strip() for ln in head.splitlines() if ln.strip()] != DRIVER_HEADER:
                problems.append("between the opening comment and replayFromImports the driver must have exactly these lines: " + "; ".join(DRIVER_HEADER))
        tail = ours_text[o1 + len(MAIN):]
        found = [w.strip() for w in DRIVER_FORBIDDEN if w in tail] + (["def"] if re.search(r"\bdef\b", tail) else [])
        if found:
            problems.append("the driver's main contains text that has no place there: " + ", ".join(found))
    if problems:
        for msg in problems:
            sys.stderr.write("replay-driver-check: %s\n" % msg)
        return 1
    print("replayFromImports: identical in the driver and in the toolchain's LeanChecker.lean (%d characters, sha256 %s)" % (len(ours), sha(ours)))
    print("driver source as a whole: %s sha256 %s, the reviewed file" % (os.path.basename(a.driver_src), sha(ours_text)))
    return 0


# --------------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")

    p = sub.add_parser("git-export")
    p.add_argument("--git-dir", required=True, help="the repository: a bare clone, or the .git directory of one")
    p.add_argument("--commit", required=True, help="all 40 hexadecimal characters of the commit's name")
    p.add_argument("--subdir", default="", help="write only the files of this directory of the commit")
    p.add_argument("--prefix", required=True, help="put this in front of every name in the tar file; ends with a slash")
    p.add_argument("--out", required=True, help="the tar file to write (not compressed)")
    p.add_argument("--max-files", type=int, default=MAX_EXPORT_FILES,
                   help="refuse a commit with more entries than this, files and directories, a directory counted "
                        "each time it is named (default %d)" % MAX_EXPORT_FILES)
    p.add_argument("--max-bytes", type=int, default=MAX_EXPORT_BYTES,
                   help="refuse a commit whose files hold more bytes than this (default %d)" % MAX_EXPORT_BYTES)
    p.set_defaults(fn=cmd_git_export)

    p = sub.add_parser("tar-inspect")
    p.add_argument("tarball")
    p.add_argument("--prefix", default="lean/", help="the directory every entry must be under, with its closing slash")
    p.add_argument("--src-dir", default="src",
                   help="where the Lean sources are under the prefix: a relative path, or . for the prefix itself")
    p.add_argument("--allow-exec", action="store_true", help="accept entries with an executable bit, and count them")
    p.add_argument("--sha256", default="")
    p.add_argument("--expected", default="")
    p.add_argument("--write-expected", default="")
    p.add_argument("--verify-tree", default="",
                   help="a directory the archive was extracted into: every entry's file there must hold the entry's "
                        "bytes, and no file outside .lake may be there that is not an entry")
    p.add_argument("--check-extracted", default="",
                   help="a directory the archive was just extracted into: everything in it, .lake included, must be an "
                        "entry of the archive or a directory on the way to one, with no links (02 runs this, with "
                        "--verify-tree on the same directory, for any target but the default one)")
    p.add_argument("--quiet", action="store_true")
    p.set_defaults(fn=cmd_tar_inspect)

    p = sub.add_parser("project-info")
    p.add_argument("project")
    p.add_argument("--expected", default="")
    p.add_argument("--write-expected", default="")
    p.add_argument("--show-urls", action="store_true",
                   help="also print where lean-toolchain and every package in lake-manifest.json come from, which "
                        "step 04 fetches and runs (02 passes this for any target but the default one)")
    p.add_argument("--src-dir", default="src",
                   help="the project's directory of Lean sources (TGT_SRC_DIR), which 03 reads: every library "
                        "lakefile.toml declares must have its sources under it ('.' for the project directory)")
    p.set_defaults(fn=cmd_project_info)

    protected_help = "names the source should not declare for itself, separated by spaces"
    p = sub.add_parser("audit-literals")
    p.add_argument("--protected-names", default=" ".join(PROTECTED_NAMES), help=protected_help)
    p.set_defaults(fn=cmd_audit_literals)

    p = sub.add_parser("audit-classify")
    p.add_argument("--protected-names", default=" ".join(PROTECTED_NAMES), help=protected_help)
    p.add_argument("--hits", required=True)
    p.add_argument("--lean-files", type=int, required=True)
    p.add_argument("--tool", default="?")
    p.add_argument("--show", type=int, default=3)
    p.add_argument("--json", default="")
    p.add_argument("--expected", default="")
    p.add_argument("--write-expected", default="")
    p.add_argument("--strict", action="store_true")
    p.set_defaults(fn=cmd_audit_classify)

    p = sub.add_parser("axioms-body")
    p.add_argument("--body", required=True, help="scripts/verify/axioms_check_body.lean")
    p.add_argument("--statement-const", default=STATEMENT_CONST)
    p.add_argument("--report-consts", default=" ".join(REPORT_CONSTS), help="separated by spaces")
    p.set_defaults(fn=cmd_axioms_body)

    p = sub.add_parser("axioms-summary")
    p.add_argument("--output", required=True)
    p.add_argument("--mode", required=True, choices=["full", "probe"])
    p.add_argument("--primary", required=True)
    p.add_argument("--theorem", action="append", required=True)
    p.add_argument("--lean-status", type=int, required=True)
    p.add_argument("--deep", action="store_true")
    p.add_argument("--json", default="")
    p.add_argument("--tarball-sha256", default="")
    p.add_argument("--compiled", type=int, default=None)
    p.add_argument("--sources", type=int, default=None)
    p.add_argument("--statement-const", default=STATEMENT_CONST, help="the constant the primary theorem's statement must be")
    p.add_argument("--statement-const-module", default=STATEMENT_CONST_MODULE, help="the module it must be defined in")
    p.add_argument("--source-id", default="", help="what identifies the source, for one that is not a published tarball")
    p.add_argument("--target", default="", help="the name of the target, for any target but the default one")
    p.set_defaults(fn=cmd_axioms_summary)

    for name, fn in (("replay-plan", cmd_replay_plan), ("replay-summary", cmd_replay_summary)):
        p = sub.add_parser(name)
        p.add_argument("--lib", required=True)
        p.add_argument("--src", default="")
        p.add_argument("--results", required=True)
        p.add_argument("--json", default="")
        p.add_argument("--sample", type=int, default=0)
        p.add_argument("--seed", type=int, default=20261120)
        p.add_argument("--list", default="")
        p.add_argument("--prefix-modules", action="store_true")
        p.add_argument("--all-modules", action="store_true", help="plan prefix modules like any other (import-closure directories)")
        p.add_argument("--only-reruns", action="store_true", help="plan only modules the tool rejected once and has not yet been run on again twice")
        p.add_argument("--require-complete", action="store_true")
        p.add_argument("--require-c3", action="store_true")
        p.add_argument("--method", default="leanchecker", choices=list(REPLAY_METHODS))
        p.add_argument("--trusted-program", default="", help="SHA-256 of the one rhv-replay program whose passes are expected")
        p.set_defaults(fn=fn)

    p = sub.add_parser("import-graph")
    p.add_argument("--src", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--if-stale", action="store_true", help="keep the existing file if it was made from this source tree")
    p.set_defaults(fn=cmd_import_graph)

    p = sub.add_parser("closure-worker")
    p.add_argument("--graph", required=True)
    p.add_argument("--lib", required=True)
    p.add_argument("--dir-base", required=True)
    p.add_argument("--packages", default="")
    p.add_argument("--check-one", required=True)
    p.add_argument("--batch", required=True)
    p.set_defaults(fn=cmd_closure_worker)

    p = sub.add_parser("replay-driver-check")
    p.add_argument("--driver-src", required=True)
    p.add_argument("--toolchain-src", required=True)
    p.set_defaults(fn=cmd_replay_driver_check)

    a = ap.parse_args()
    if not a.cmd:
        ap.print_help()
        return 2
    try:
        return a.fn(a)
    except Exception as ex:          # an error of this tool is "could not run": never the 1 that means a finding
        import traceback
        traceback.print_exc()
        sys.stderr.write("rhv_tools: %s failed: %s: %s\n" % (a.cmd, type(ex).__name__, ex))
        return 2


if __name__ == "__main__":
    sys.exit(main())
