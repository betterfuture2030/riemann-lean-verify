#!/bin/bash
# spot_checkpoint.sh - archives of finished compiled modules ("parts"), and the state file, for a cloud run that
# continues on a fresh machine after Google takes the last one back (cloud/gcp/full_guest.sh with full-spot=1).
#
# What it does: nothing over the network; the cloud driver moves the files. Subcommands:
#   cut      Selects every finished module of a Lake build directory that is not yet saved, and writes one
#            zstd-compressed tar archive of every file the build tool needs to treat each as up to date. A module
#            is finished when its .trace file exists, parses, and (with --settle-before) was last modified before
#            that time: Lake writes the .trace file last, after the .olean, .ilean, the C file and every .hash
#            file (Lake 5.0.0, Build/Common.lean, buildAction), so an older trace means all of them are complete.
#            Which files: under lib/lean, <module>.olean, .ilean and .trace and the .hash files beside them (and
#            .olean.server, .olean.private, .ir and .ir.sig with theirs, which only "module" files have); under
#            ir, <module>.c and .bc and their .hash files. That is the set Module.checkArtifactsExist and
#            computeArtifacts read (Build/Module.lean); the .hash files are included because Lake trusts a .hash
#            file instead of reading the output again (Build/Common.lean, fetchFileHash). Never the bulky
#            <module>.setup.json, which nothing reads once the module is built, and never a *.tmp.* file, which a
#            killed compiler leaves. Tested with the v4.33.1 toolchain on a toy project: a build directory wiped
#            and restored from parts is accepted without compiling anything again
#            (scripts/dev/test_spot_checkpoint.sh).
#            What is saved is tracked file by file, in the done file (see below), by size, modification time and
#            SHA-256. A saved .olean, .ilean, .trace, C file or other output whose size has changed, or that has
#            gone, or whose time has changed and whose bytes are not those recorded (or no SHA-256 is recorded for
#            it), means the build tool compiled that module again, which the parts cannot represent: that is exit
#            status 4. One whose time alone has changed, with the very bytes recorded, was only written again: it
#            is saved again in the next part, with its new time, and the error output says how many files were
#            "written again with the same bytes". With --settle-before, a saved file (not a .hash file) whose size
#            or time has changed and that was modified at or after that time, and not more than 60 s ahead of the
#            current time, may be in the middle of being written:
#            it is neither status 4 nor saved in this cut, but left for the next ("N saved files changed in the last
#            seconds; looked at again next round"); one with a time further in the future is judged at once, as
#            above. Without --settle-before nothing is left for later. A .hash
#            file that is new or has changed since it was saved is simply saved again in the next part; a restore
#            applies the parts in order, so the later copy wins.
#            With --all (the last cut after the build has ended) every other regular file under lib/lean and ir
#            that is not saved as it now is goes in too, so that the directory the seal fingerprints can be
#            rebuilt exactly from the parts; but never a *.tmp.* or *.setup.json file, and never a file of a
#            module that is not complete (no trace, a trace that does not parse, or a needed output missing):
#            the build tool compiles such a module again anyway.
#            With --paths-from FILE (a repair at the seal) exactly the files that FILE lists are taken, one path
#            a line, relative to the build directory, and nothing is selected.
#            With --dry-run nothing is archived: the done lines of what would be saved are printed.
#   list     Prints the modules an archive holds, checking every member as restore does; with --members-out or
#            --done-out, writes those files for it instead (see below).
#   restore  Checks an archive's SHA-256, then extracts it into a build directory. It refuses any member that is
#            not a regular file or a directory, whose path is absolute, contains "..", or lies outside lib/ and
#            ir/; it never writes through an existing file or a symbolic link (each file is created afresh, and
#            every directory on its way is checked not to be a link). Files get mode 644, directories 755, the
#            extracting user as owner, and the modification time recorded in the archive.
#   cover    Whether the parts reproduce the sealed compiled files exactly. Takes the members files of the parts
#            in the order the parts are restored (a later file's line for a path wins), keeps the paths under
#            --prefix, and compares them, path by path and hash by hash, with the seal's manifest of the compiled
#            files (lib_sha256.txt, whose paths are "./<path under lib/lean>"). Prints one line per path that is
#            "missing" (sealed, in no part), "different" (in a part, with other bytes) or "extra" (in a part, not
#            sealed), each followed by a tab and the path as the parts name it (lib/lean/...).
#   trim     Drops a last line that has no newline (a copy of the replay's results taken in mid-write). Refuses
#            (status 1) anything that is not a regular file, a symbolic link included, and never follows one.
#   state    Changes the run's state file (JSON) in place, atomically: top-level values, shell variables to
#            remember, completed units, the entry of one attempt. "progress" is recomputed from what is saved
#            and never goes down.
#   state-get    Prints one top-level value, or (with --done UNIT) answers by its exit status.
#   state-export Prints NAME='value' lines, quoted for the shell, for the variables named on the command line
#            that the state holds. Only names of the form [A-Z][A-Z0-9_]* are accepted.
# Files it reads and writes beside the archives:
#   done file      one line per saved file: "<path><TAB><size><TAB><modification time, whole seconds><TAB><sha256>",
#                  the path relative to the build directory (lib/lean/... or ir/...), the SHA-256 that of the bytes
#                  archived. A later line for a path wins. cut, list and restore always write the fourth column;
#                  a line of three columns (no SHA-256) is still read.
#   members file   one line per archive member: "<sha256>  <path>", the SHA-256 of the bytes archived or
#                  extracted. Written gzip-compressed when its name ends in .gz, and read either way.
#   Any of --done-out, --members-out and --list may be "-", the standard output, unless the archive goes there.
# What it changes on disk: only the files named on its command line, and the build directory given to restore.
# Requires: python3 (standard library only) and zstd. Portable: the same code runs on macOS and on Linux.
#
# Usage:
#   spot_checkpoint.sh cut --build-dir DIR (--done FILE [--settle-before EPOCH] [--all] | --paths-from FILE)
#                          (--out FILE|- | --dry-run) [--list FILE] [--done-out FILE] [--members-out FILE]
#   spot_checkpoint.sh list --part FILE|- [--members-out FILE] [--done-out FILE]
#   spot_checkpoint.sh restore --build-dir DIR --part FILE --sha256 HEX [--list FILE] [--members-out FILE] [--done-out FILE]
#   spot_checkpoint.sh cover --lib-manifest FILE [--prefix lib/lean] --members FILE [--members FILE]... [FILE...]
#   spot_checkpoint.sh trim --file FILE
#   spot_checkpoint.sh state --file FILE [--runtag R] [--set K=V] [--set-int K=N] [--set-json K=JSON] [--var NAME=V]
#                            [--done UNIT] [--attempt N] [--attempt-set K=V] [--attempt-set-json K=JSON]
#                            [--parts-modules N] [--results-saved N] [--close-open-attempts TEXT]
#   spot_checkpoint.sh state-get --file FILE (--key K | --done UNIT)
#   spot_checkpoint.sh state-export --file FILE NAME...
# Exit status: 0 done (cut: a part was made; cover: the parts reproduce the manifest exactly); 3 cut: nothing was
#   due, cover: the parts do not reproduce the manifest; 4 cut only: a saved module changed; 1 any other failure
#   or refusal; 2 a usage error.
set -u
command -v python3 >/dev/null 2>&1 || { echo "spot_checkpoint.sh: python3 not found" >&2; exit 1; }
[ $# -ge 1 ] || { sed -n '2,86p' "$0"; exit 2; }
exec python3 -I -B -c '
import gzip, hashlib, json, os, re, shlex, stat, subprocess, sys, tarfile, time

LIB_EXTS = ("olean", "olean.hash", "ilean", "ilean.hash", "trace", "olean.server", "olean.server.hash",
            "olean.private", "olean.private.hash", "ir", "ir.hash", "ir.sig", "ir.sig.hash")
IR_EXTS = ("c", "c.hash", "bc", "bc.hash")
NEEDED_LIB = ("olean", "ilean", "trace")       # what Lake checks exists (besides the C file) before it trusts a trace
NEEDED_IR = ("c",)
TMP = re.compile(r"\.tmp\.")
NAME = re.compile(r"^[A-Z][A-Z0-9_]*$")

def die(msg, code=1):
    print("spot_checkpoint.sh: " + msg, file=sys.stderr); sys.exit(code)

def args_of(argv, flags, multi=(), bools=()):
    out = {k: None for k in flags}; out.update({k: [] for k in multi}); out.update({k: False for k in bools}); rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in bools: out[a] = True; i += 1; continue
        if a in flags or a in multi:
            if i + 1 >= len(argv): die(a + " needs a value", 2)
            if a in multi: out[a].append(argv[i + 1])
            else: out[a] = argv[i + 1]
            i += 2; continue
        if a.startswith("--"): die("unknown option " + a, 2)
        rest.append(a); i += 1
    return out, rest

def need(o, *keys):
    for k in keys:
        if o[k] is None: die(k + " is required", 2)

def one_stdout(o, *keys):
    # at most one output may be the standard output
    if sum(1 for k in keys if o.get(k) == "-") > 1: die("only one of %s may be -" % ", ".join(keys), 2)

def mod_of(rel, exts):
    # "Foo/Bar.olean.hash" -> ("Foo.Bar", "olean.hash"), or None if the name has none of the extensions
    d, f = os.path.split(rel)
    for e in sorted(exts, key=len, reverse=True):
        if f.endswith("." + e) and len(f) > len(e) + 1:
            stem = f[: -len(e) - 1]
            return (os.path.join(d, stem).replace(os.sep, "."), e)
    return None

def stem_path(mod):
    return mod.replace(".", os.sep)

def trace_ok(path):
    try:
        with open(path, "rb") as fh: d = json.loads(fh.read().decode("utf-8"))
        return isinstance(d, dict) and "depHash" in d
    except Exception:
        return False

def module_of_trace(rel):
    # "lib/lean/Foo/Bar.trace" -> "Foo.Bar", or None
    if rel.startswith("lib/lean/") and rel.endswith(".trace"):
        return rel[len("lib/lean/"): -len(".trace")].replace("/", ".")
    return None

def read_done(path):
    done = {}
    try: fh = open(path)
    except OSError: die("cannot read the done file " + path)
    with fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line: continue
            f = line.split("\t")
            if len(f) not in (3, 4) or (len(f) == 4 and not re.match(r"^[0-9a-f]{64}$", f[3])):
                die("bad line in the done file: " + line)
            try: done[f[0]] = (int(f[1]), int(f[2]), f[3] if len(f) == 4 else None)
            except ValueError: die("bad line in the done file: " + line)
    return done

def sha_nofollow(path):
    # the SHA-256 of a regular file, opened without following a link and without waiting on a pipe
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    with os.fdopen(fd, "rb") as fh:
        if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode): die("not a regular file: " + path)
        h = hashlib.sha256()
        for b in iter(lambda: fh.read(1 << 20), b""): h.update(b)
    return h.hexdigest()

class Out:
    # an output file named on the command line: "-" is the standard output, a name ending in .gz is compressed
    def __init__(self, name):
        self.name = name; self.fh = None; self.tmp = None
        if name is None: return
        if name == "-": self.fh = sys.stdout; return
        self.tmp = name + ".tmp"
        self.fh = gzip.open(self.tmp, "wt") if name.endswith(".gz") else open(self.tmp, "w")
    def write(self, s):
        if self.fh is not None: self.fh.write(s)
    def close(self):
        if self.fh is None: return
        if self.tmp is None: self.fh.flush(); return
        self.fh.close(); os.replace(self.tmp, self.name)
    def drop(self):
        if self.tmp is not None:
            try: self.fh.close()
            except Exception: pass
            try: os.unlink(self.tmp)
            except OSError: pass

def open_text(path):
    with open(path, "rb") as fh: magic = fh.read(2)
    return gzip.open(path, "rt") if magic == b"\x1f\x8b" else open(path)

def zstd_cmd(extra):
    return ["zstd", "-q"] + extra

class Hashing:
    # a file read through this is hashed as tar copies it into the archive
    def __init__(self, fh): self.fh = fh; self.h = hashlib.sha256()
    def read(self, n=-1):
        b = self.fh.read(n); self.h.update(b); return b

def clean_rel(rel):
    parts = rel.split("/")
    if not rel or rel.startswith("/") or "\\" in rel or any(p in ("", ".", "..") for p in parts) or parts[0] not in ("lib", "ir"):
        die("refused: not a path under lib/ or ir/: %r" % rel)
    return rel

# ---------------------------------------------------------------- cut
def cut(argv):
    o, _ = args_of(argv, ("--build-dir", "--done", "--out", "--list", "--settle-before", "--done-out", "--members-out", "--paths-from"),
                   bools=("--all", "--dry-run"))
    need(o, "--build-dir")
    if o["--paths-from"] is None: need(o, "--done")
    if not o["--dry-run"]: need(o, "--out")
    one_stdout(o, "--out", "--list", "--done-out", "--members-out")
    bdir = o["--build-dir"]; lib = os.path.join(bdir, "lib", "lean")
    settle = float(o["--settle-before"]) if o["--settle-before"] is not None else None
    done = read_done(o["--done"]) if o["--done"] is not None else {}
    files = []                                   # paths relative to the build directory, in archive order
    skipped = 0; same_again = set()
    if o["--paths-from"] is not None:
        with open(o["--paths-from"]) as fh:
            for line in fh:
                rel = line.rstrip("\n")
                if not rel: continue
                rel = clean_rel(rel)
                try: st = os.lstat(os.path.join(bdir, rel))
                except OSError: die("not there: " + rel)
                if not stat.S_ISREG(st.st_mode): die("not a regular file: " + rel)
                if rel not in files: files.append(rel)
    else:
        if not os.path.isdir(lib):
            return 3
        # Every regular file under lib/lean and ir as it is now: size and modification time (whole seconds).
        cur = {}
        for tag in ("lib/lean", "ir"):
            base = os.path.join(bdir, tag)
            for root, dirs, fs in os.walk(base):
                dirs.sort(); fs.sort()
                for f in fs:
                    p = os.path.join(root, f); rel = os.path.join(tag, os.path.relpath(p, base)).replace(os.sep, "/")
                    st = os.lstat(p)
                    cur[rel] = (st.st_mode, st.st_size, int(st.st_mtime))
        def unsaved(rel):
            c = cur.get(rel); d = done.get(rel)
            return c is not None and (d is None or (d[0], d[1]) != (c[1], c[2]))
        # A saved output that was written again, or has gone: the build tool compiled that module again. Unless
        # only its time changed and its bytes are exactly those recorded: then it was written again with the same
        # bytes, and is simply saved again (below) with its new time.
        # With --settle-before, one whose size or time has changed and that was modified at or after the settle time
        # may be in the middle of being written: it is judged in a later round, and not saved in this one.
        same_again = set(); recent = set()
        for rel, (size, mt, h) in done.items():
            if rel.endswith(".hash"): continue
            c = cur.get(rel)
            if c is None:
                print("saved file %s is gone" % rel, file=sys.stderr); return 4
            if stat.S_ISREG(c[0]) and (c[1], c[2]) == (size, mt): continue
            # (only with a time not more than 60 s ahead of now: one further in the future, set by hand or by a
            # clock step, would otherwise be put off at every round; it is judged at once)
            if settle is not None and stat.S_ISREG(c[0]) and settle <= os.lstat(os.path.join(bdir, rel)).st_mtime <= time.time() + 60:
                recent.add(rel); continue
            if stat.S_ISREG(c[0]) and c[1] == size and h is not None and sha_nofollow(os.path.join(bdir, rel)) == h:
                same_again.add(rel); continue
            print("saved file %s was written again after it was saved" % rel, file=sys.stderr); return 4
        incomplete = set(); traced = set()
        for rel in sorted(cur):
            mod = module_of_trace(rel)
            if mod is None: continue
            traced.add(mod)
            stem = stem_path(mod); mine = []
            if rel in done:
                # saved already; only a .hash file of it that is new or has changed goes in again, and a file of it
                # written again with the same bytes
                for base, exts in (("lib/lean", LIB_EXTS), ("ir", IR_EXTS)):
                    for e in exts:
                        q = base + "/" + stem + "." + e
                        if q in same_again: mine.append(q)
                        elif e.endswith("hash") and unsaved(q) and stat.S_ISREG(cur[q][0]) and (settle is None or cur[q][2] < settle):
                            mine.append(q)
                files.extend(mine); continue
            if not stat.S_ISREG(cur[rel][0]): die("not a regular file: " + rel)
            if settle is not None and os.lstat(os.path.join(bdir, rel)).st_mtime >= settle: continue
            if not trace_ok(os.path.join(bdir, rel)): skipped += 1; incomplete.add(mod); continue   # being written, or damaged
            complete = True
            for base, exts, needed in (("lib/lean", LIB_EXTS, NEEDED_LIB), ("ir", IR_EXTS, NEEDED_IR)):
                for e in exts:
                    q = base + "/" + stem + "." + e
                    if q not in cur:
                        if e in needed: complete = False
                        continue
                    if not stat.S_ISREG(cur[q][0]): die("not a regular file: " + q)
                    if unsaved(q): mine.append(q)
            # a file of it saved before (in a repair part, say) that may be in the middle of being written: the
            # whole module waits for a later round
            if any(q in recent for q in mine): complete = False
            if not complete: skipped += 1; incomplete.add(mod); continue
            files.extend(mine)
        if o["--all"]:
            chosen = set(files)
            for rel in sorted(cur):
                if rel in chosen or rel in recent or not unsaved(rel) or not stat.S_ISREG(cur[rel][0]): continue
                f = rel.rsplit("/", 1)[-1]
                if TMP.search(f) or f.endswith(".setup.json"): continue
                if rel.startswith("lib/lean/"): m = mod_of(rel[len("lib/lean/"):], LIB_EXTS)
                else: m = mod_of(rel[len("ir/"):], IR_EXTS)
                if m and (m[0] in incomplete or m[0] not in traced): continue   # a module that is not complete
                files.append(rel)
        for rel in sorted(same_again):           # whatever module it belongs to, it is saved again with its new time
            if rel not in files: files.append(rel)
        if recent: print("%d saved files changed in the last seconds; looked at again next round" % len(recent), file=sys.stderr)
    again = ("; %d files written again with the same bytes" % len(same_again)) if same_again else ""
    mods = [m for m in (module_of_trace(r) for r in files) if m]
    if not files:
        if skipped: print("nothing due (%d modules not yet complete)" % skipped, file=sys.stderr)
        return 3
    if o["--dry-run"]:
        out = Out(o["--done-out"] or "-")
        for rel in files:
            p = os.path.join(bdir, rel); st = os.lstat(p)
            out.write("%s\t%d\t%d\t%s\n" % (rel, st.st_size, int(st.st_mtime), sha_nofollow(p)))
        out.close()
        if again: print("dry run: %d files%s" % (len(files), again), file=sys.stderr)
        return 0
    outs = [Out(o["--done-out"]), Out(o["--members-out"])]
    out = o["--out"]; tmp = None
    if out == "-": sink = sys.stdout.buffer
    else: tmp = out + ".tmp"; sink = open(tmp, "wb")
    z = subprocess.Popen(zstd_cmd(["-T2", "-3", "-c"]), stdin=subprocess.PIPE, stdout=sink)
    nbytes = 0; lines = []
    try:
        with tarfile.open(fileobj=z.stdin, mode="w|", format=tarfile.PAX_FORMAT) as tar:
            for rel in files:
                fd = os.open(os.path.join(bdir, rel), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
                with os.fdopen(fd, "rb") as fh:
                    st = os.fstat(fh.fileno())
                    if not stat.S_ISREG(st.st_mode): die("not a regular file: " + rel)
                    ti = tarfile.TarInfo(rel); ti.size = st.st_size; ti.mtime = int(st.st_mtime); ti.mode = 0o644
                    ti.uid = ti.gid = 0; ti.uname = ti.gname = ""
                    hr = Hashing(fh); tar.addfile(ti, hr); nbytes += st.st_size
                    lines.append((rel, st.st_size, int(st.st_mtime), hr.h.hexdigest()))
        z.stdin.close()
    except Exception as e:
        z.kill(); z.wait()
        if tmp: os.unlink(tmp)
        for x in outs: x.drop()
        die("could not write the archive: %s" % e)
    if z.wait() != 0:
        if tmp: os.unlink(tmp)
        for x in outs: x.drop()
        die("zstd failed")
    if tmp:
        sink.flush(); os.fsync(sink.fileno()); sink.close(); os.replace(tmp, out)
    for rel, size, mt, h in lines:
        outs[0].write("%s\t%d\t%d\t%s\n" % (rel, size, mt, h)); outs[1].write("%s  %s\n" % (h, rel))
    for x in outs: x.close()
    if o["--list"]:
        lo = Out(o["--list"])
        for m in mods: lo.write(m + "\n")
        lo.close()
    print("part: %d modules, %d files, %d bytes before compression; %d modules not yet complete%s"
          % (len(mods), len(files), nbytes, skipped, again), file=sys.stderr)
    return 0

# ---------------------------------------------------------------- list / restore
def members(part):
    if part == "-":
        z = subprocess.Popen(zstd_cmd(["-d", "-c"]), stdin=sys.stdin.buffer, stdout=subprocess.PIPE)
    else:
        z = subprocess.Popen(zstd_cmd(["-d", "-c", "--", part]), stdout=subprocess.PIPE)
    tar = tarfile.open(fileobj=z.stdout, mode="r|")
    return z, tar

def check_member(ti):
    n = ti.name
    if not n or n.startswith("/") or "\\" in n: die("refused: absolute or odd path in the archive: %r" % n)
    parts = n.rstrip("/").split("/")
    if any(p in ("", ".", "..") for p in parts): die("refused: path with \"..\" or an empty part: %r" % n)
    if parts[0] not in ("lib", "ir"): die("refused: path outside lib/ and ir/: %r" % n)
    if not (ti.isreg() or ti.isdir()): die("refused: %r is not a regular file or a directory" % n)
    return parts

def entry_of(parts):
    return module_of_trace("/".join(parts))

def sha_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""): h.update(b)
    return h.hexdigest()

def list_part(argv):
    o, _ = args_of(argv, ("--part", "--members-out", "--done-out")); need(o, "--part")
    if o["--part"] == "-" and "-" in (o["--members-out"], o["--done-out"]): pass   # stdin in, stdout out: fine
    one_stdout(o, "--members-out", "--done-out")
    mo, do = Out(o["--members-out"]), Out(o["--done-out"])
    z, tar = members(o["--part"]); out = []
    try:
        for ti in tar:
            parts = check_member(ti)
            if ti.isdir(): continue
            m = entry_of(parts)
            if m: out.append(m)
            rel = "/".join(parts)
            if o["--members-out"] is not None or o["--done-out"] is not None:
                src = tar.extractfile(ti); h = hashlib.sha256()
                for b in iter(lambda: src.read(1 << 20), b""): h.update(b)
                mo.write("%s  %s\n" % (h.hexdigest(), rel))
                do.write("%s\t%d\t%d\t%s\n" % (rel, ti.size, int(ti.mtime), h.hexdigest()))
        tar.close()
        if z.wait() != 0: die("zstd failed on " + o["--part"])
    except SystemExit:
        mo.drop(); do.drop(); raise
    mo.close(); do.close()
    if o["--members-out"] is None and o["--done-out"] is None:
        for m in sorted(out): print(m)
    return 0

def safe_dir(base, parts):
    # every directory from base down: created if missing, refused if it exists as anything but a directory
    d = base
    for p in parts:
        d = os.path.join(d, p)
        try: st = os.lstat(d)
        except FileNotFoundError:
            os.mkdir(d, 0o755); os.chmod(d, 0o755); continue
        if not stat.S_ISDIR(st.st_mode): die("refused: %s exists and is not a directory" % d)
    return d

def restore(argv):
    o, _ = args_of(argv, ("--build-dir", "--part", "--sha256", "--list", "--members-out", "--done-out"))
    need(o, "--build-dir", "--part", "--sha256")
    one_stdout(o, "--list", "--members-out", "--done-out")
    want = o["--sha256"].strip().lower()
    if not re.match(r"^[0-9a-f]{64}$", want): die("--sha256 must be 64 hexadecimal digits", 2)
    got = sha_of(o["--part"])
    if got != want: die("checksum mismatch for %s: %s, expected %s" % (o["--part"], got, want))
    bdir = os.path.abspath(o["--build-dir"]); parent = os.path.dirname(bdir)
    st = os.lstat(parent)
    if not stat.S_ISDIR(st.st_mode): die("refused: %s is not a directory" % parent)
    safe_dir(parent, [os.path.basename(bdir)])
    mo, do = Out(o["--members-out"]), Out(o["--done-out"])
    z, tar = members(o["--part"]); mods = []; n = 0; nbytes = 0
    try:
        for ti in tar:
            parts = check_member(ti)
            if ti.isdir(): safe_dir(bdir, parts); continue
            d = safe_dir(bdir, parts[:-1]); p = os.path.join(d, parts[-1])
            try:
                if stat.S_ISDIR(os.lstat(p).st_mode): die("refused: %s is a directory" % p)
                os.unlink(p)                                  # never write through what is there
            except FileNotFoundError:
                pass
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
            src = tar.extractfile(ti); h = hashlib.sha256()
            with os.fdopen(fd, "wb") as fh:
                for b in iter(lambda: src.read(1 << 20), b""): fh.write(b); h.update(b)
                os.fchmod(fh.fileno(), 0o644)
            os.utime(p, (ti.mtime, ti.mtime))
            n += 1; nbytes += ti.size
            rel = "/".join(parts)
            mo.write("%s  %s\n" % (h.hexdigest(), rel)); do.write("%s\t%d\t%d\t%s\n" % (rel, ti.size, int(ti.mtime), h.hexdigest()))
            m = entry_of(parts)
            if m: mods.append(m)
        tar.close()
        if z.wait() != 0: die("zstd failed on " + o["--part"])
    except SystemExit:
        mo.drop(); do.drop(); raise
    mo.close(); do.close()
    if o["--list"]:
        lo = Out(o["--list"])
        for m in sorted(mods): lo.write(m + "\n")
        lo.close()
    print("restored %d modules, %d files, %d bytes" % (len(mods), n, nbytes), file=sys.stderr)
    return 0

# ---------------------------------------------------------------- cover
def cover(argv):
    o, rest = args_of(argv, ("--lib-manifest", "--prefix"), multi=("--members",))
    need(o, "--lib-manifest")
    prefix = (o["--prefix"] or "lib/lean").rstrip("/") + "/"
    have = {}
    for path in o["--members"] + rest:              # in part order: a later line for a path wins
        with open_text(path) as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line: continue
                h, sep, rel = line.partition("  ")
                if not sep or not re.match(r"^[0-9a-f]{64}$", h): die("bad line in the members file %s: %r" % (path, line))
                if rel.startswith(prefix): have[rel[len(prefix):]] = h
    sealed = {}
    with open_text(o["--lib-manifest"]) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line: continue
            if line.startswith("not-a-file:"):           # the seal refuses these; no part can hold one
                rel = line.partition("  ")[2].split(" -> ")[0]
                sealed[rel[2:] if rel.startswith("./") else rel] = None; continue
            h, sep, rel = line.partition("  ")
            if not sep or not re.match(r"^[0-9a-f]{64}$", h): die("bad line in the manifest: %r" % line)
            sealed[rel[2:] if rel.startswith("./") else rel] = h
    report = []
    for rel in sorted(set(sealed) | set(have)):
        if rel not in have: report.append(("missing", rel))
        elif rel not in sealed: report.append(("extra", rel))
        elif sealed[rel] != have[rel]: report.append(("different", rel))
    for kind, rel in report: print("%s\t%s%s" % (kind, prefix, rel))
    counts = {k: sum(1 for x in report if x[0] == k) for k in ("missing", "different", "extra")}
    print("cover: %d sealed files, %d in the parts; missing %d, different %d, extra %d"
          % (len(sealed), len(have), counts["missing"], counts["different"], counts["extra"]), file=sys.stderr)
    return 3 if report else 0

def trim(argv):
    o, _ = args_of(argv, ("--file",)); need(o, "--file")
    p = o["--file"]
    # never through a link, never a pipe or a device: root runs this on copies of files another user wrote
    try: fd = os.open(p, os.O_RDWR | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0))
    except OSError as e: die("trim: cannot open %s as a regular file: %s" % (p, e.strerror))
    with os.fdopen(fd, "rb+") as fh:
        if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode): die("trim: not a regular file: " + p)
        data = fh.read()
        if data and not data.endswith(b"\n"):
            fh.truncate(data.rfind(b"\n") + 1)
    return 0

# ---------------------------------------------------------------- state
UNIT_STEP = 1000000          # progress for one completed unit: more than any count of modules or results

def load_state(p):
    try:
        with open(p) as fh: s = json.load(fh)
        if not isinstance(s, dict): die("the state file does not hold an object: " + p)
        return s
    except FileNotFoundError:
        return {}
    except ValueError:
        die("the state file does not parse: " + p)

def kv(s, what):
    k, sep, v = s.partition("=")
    if not sep or not k: die("%s needs KEY=VALUE, got %r" % (what, s), 2)
    return k, v

def state(argv):
    o, _ = args_of(argv, ("--file", "--runtag", "--attempt", "--parts-modules", "--results-saved", "--close-open-attempts"),
                   multi=("--set", "--set-int", "--set-json", "--var", "--done", "--attempt-set", "--attempt-set-json"))
    need(o, "--file")
    s = load_state(o["--file"])
    s.setdefault("final", False); s.setdefault("attempts", []); s.setdefault("done", []); s.setdefault("vars", {})
    s.setdefault("parts_modules", 0); s.setdefault("results_saved", 0); s.setdefault("progress", 0)
    if o["--runtag"] is not None: s["runtag"] = o["--runtag"]
    for a in o["--set"]: k, v = kv(a, "--set"); s[k] = v
    for a in o["--set-int"]: k, v = kv(a, "--set-int"); s[k] = int(v)
    for a in o["--set-json"]: k, v = kv(a, "--set-json"); s[k] = json.loads(v)
    for a in o["--var"]:
        k, v = kv(a, "--var")
        if not NAME.match(k): die("not a variable name: " + k, 2)
        s["vars"][k] = v
    for u in o["--done"]:
        if u not in s["done"]: s["done"].append(u)
    if o["--close-open-attempts"] is not None:
        for e in s["attempts"]:
            if not e.get("ended"): e["ended"] = o["--close-open-attempts"]
    if o["--attempt"] is not None:
        n = int(o["--attempt"]); s["attempt"] = n
        e = next((x for x in s["attempts"] if x.get("n") == n), None)
        if e is None: e = {"n": n}; s["attempts"].append(e); s["attempts"].sort(key=lambda x: x.get("n", 0))
        for a in o["--attempt-set"]: k, v = kv(a, "--attempt-set"); e[k] = v
        for a in o["--attempt-set-json"]: k, v = kv(a, "--attempt-set-json"); e[k] = json.loads(v)
    elif o["--attempt-set"] or o["--attempt-set-json"]:
        die("--attempt-set needs --attempt", 2)
    # Saved work only, and never less than before: modules in parts the manifest lists, replay results uploaded,
    # and a large step for each completed unit.
    if o["--parts-modules"] is not None: s["parts_modules"] = max(int(s["parts_modules"]), int(o["--parts-modules"]))
    if o["--results-saved"] is not None: s["results_saved"] = max(int(s["results_saved"]), int(o["--results-saved"]))
    s["progress"] = max(int(s["progress"]), int(s["parts_modules"]) + int(s["results_saved"]) + UNIT_STEP * len(s["done"]))
    tmp = o["--file"] + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(s, fh, indent=1, sort_keys=True); fh.write("\n"); fh.flush(); os.fsync(fh.fileno())
    os.replace(tmp, o["--file"])
    return 0

def state_get(argv):
    o, _ = args_of(argv, ("--file", "--key", "--done")); need(o, "--file")
    s = load_state(o["--file"])
    if o["--done"] is not None: return 0 if o["--done"] in s.get("done", []) else 1
    need(o, "--key")
    v = s.get(o["--key"])
    if v is None: v = ""
    elif isinstance(v, bool): v = "true" if v else "false"
    elif not isinstance(v, (str, int, float)): v = json.dumps(v, sort_keys=True)
    print(v)
    return 0

def state_export(argv):
    o, names = args_of(argv, ("--file",)); need(o, "--file")
    v = load_state(o["--file"]).get("vars", {})
    for n in names:
        if not NAME.match(n): die("not a variable name: " + n, 2)
        if n in v:
            val = v[n]
            if not isinstance(val, str): die("the value of %s is not a string" % n)
            print("%s=%s" % (n, shlex.quote(val)))
    return 0

cmds = {"cut": cut, "list": list_part, "restore": restore, "cover": cover, "trim": trim, "state": state,
        "state-get": state_get, "state-export": state_export}
if len(sys.argv) < 2 or sys.argv[1] not in cmds: die("unknown subcommand (cut, list, restore, cover, trim, state, state-get, state-export)", 2)
try:
    sys.exit(cmds[sys.argv[1]](sys.argv[2:]))
except SystemExit:
    raise
except BrokenPipeError:
    die("output closed early")
except Exception as e:
    die("%s: %s" % (type(e).__name__, e))
' "$@"
