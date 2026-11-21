#!/usr/bin/env python3
"""Helpers for the numbered scripts in scripts/. Not meant to be run by hand.

Subcommands
  tar-inspect      list a tarball without extracting it and check every entry (02)
  project-info     toolchain, Mathlib revision and file hashes of the extracted project (02)
  audit-literals   print the fixed strings the source audit pre-filters on (03)
  audit-classify   classify pre-filtered source lines into audit categories (03)
  axioms-summary   read the output of the axiom check and decide pass or fail (08)
  replay-plan      decide which compiled modules still need a kernel re-check (09)
  replay-summary   summarise kernel re-check results (09)
  import-graph     read the import lines of every source file (09)
  closure-worker   run the stock checker on a batch of modules, each with only its imports visible (09)
  replay-driver-check   compare the second replay program's source with the toolchain's (09)

Only the Python standard library is used. Python 3.6 or later.
Nothing here writes outside the files named on its command line.
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


def report_comparison(what, expected_path, section_present, diffs):
    """Print the outcome of a comparison with recorded values. Returns True if all matched."""
    if not section_present:
        print("%s: no recorded values to compare with (%s)" % (what, expected_path or "no file given"))
        return True
    if diffs:
        print("%s: DIFFERS from the recorded values in %s" % (what, expected_path))
        for d in diffs:
            print("  - " + d)
        return False
    print("%s: matches the recorded values in %s" % (what, expected_path))
    return True


# --------------------------------------------------------------------------------------------
# 02: tarball inspection

CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f]")


def cmd_tar_inspect(a):
    import tarfile

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
            violations.append("%s: %s" % (why, name))

    by_ext = collections.Counter()
    by_top = collections.Counter()
    seen = set()
    entries = total_bytes = src_lean = 0
    tree = os.path.abspath(a.verify_tree) if a.verify_tree else None
    tree_missing = tree_differs = 0
    tree_examples = []

    with tarfile.open(a.tarball, mode="r|gz") as tf:
        for m in tf:
            entries += 1
            name = m.name
            ok = True
            if m.type not in (tarfile.REGTYPE, tarfile.AREGTYPE):
                bad(name, "not a regular file (%s)" % type_names.get(m.type, "type %r" % m.type)); ok = False
            if name.startswith("/"):
                bad(name, "absolute path"); ok = False
            parts = name.split("/")
            if ".." in parts:
                bad(name, "'..' path component"); ok = False
            if "" in parts or "." in parts:
                bad(name, "empty or '.' path component"); ok = False
            if not name.startswith(a.prefix):
                bad(name, "outside %s" % a.prefix); ok = False
            if "\\" in name or CONTROL_CHARS.search(name):
                bad(name, "backslash or control character in name"); ok = False
            if m.mode & 0o111:
                bad(name, "executable bit set (mode %o)" % m.mode); ok = False
            if m.mode & 0o7000:
                bad(name, "setuid, setgid or sticky bit set (mode %o)" % m.mode); ok = False
            if name in seen:
                bad(name, "duplicate entry"); ok = False
            seen.add(name)
            base = parts[-1]
            ext = os.path.splitext(base)[1] or "(none)"
            by_ext[ext] += 1
            by_top[parts[1] if len(parts) > 1 else parts[0]] += 1
            total_bytes += m.size
            if name.startswith(a.prefix + "src/") and name.endswith(".lean"):
                src_lean += 1
            if tree and ok:
                path = os.path.join(tree, name)
                if not os.path.isfile(path) or os.path.islink(path):
                    tree_missing += 1
                    if len(tree_examples) < 10:
                        tree_examples.append("missing on disk: " + name)
                else:
                    fh = tf.extractfile(m)
                    data = fh.read() if fh is not None else b""
                    with open(path, "rb") as dh:
                        if dh.read() != data:
                            tree_differs += 1
                            if len(tree_examples) < 10:
                                tree_examples.append("content differs: " + name)

    def say(text):
        if not a.quiet:
            print(text)

    say("tarball entries:        %d" % entries)
    say("total uncompressed:     %d bytes (%.2f GB)" % (total_bytes, total_bytes / 1e9))
    say("Lean files under %ssrc/: %d" % (a.prefix, src_lean))
    say("entries by extension:")
    for ext, c in sorted(by_ext.items(), key=lambda kv: (-kv[1], kv[0])):
        say("  %-10s %d" % (ext, c))
    say("entries by top-level item under %s:" % a.prefix)
    for top, c in sorted(by_top.items(), key=lambda kv: (-kv[1], kv[0])):
        say("  %-22s %d" % (top, c))

    status = 0
    if n_viol:
        print("UNSAFE OR UNEXPECTED ENTRIES: %d (showing up to 25)" % n_viol)
        for v in violations:
            print("  - " + v)
        status = 1
    else:
        say("entry check: every entry is a regular, non-executable file under %s; no links," % a.prefix)
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
    elif not report_comparison("tarball listing", a.expected, bool(exp), diffs):
        status = 1

    if tree:
        extra = []
        root = os.path.join(tree, a.prefix.rstrip("/"))
        for dirpath, dirnames, filenames in os.walk(root):
            if dirpath == root:
                dirnames[:] = [d for d in dirnames if d != ".lake"]   # build products and packages
            for f in filenames:
                rel = os.path.relpath(os.path.join(dirpath, f), tree).replace(os.sep, "/")
                if rel not in seen:
                    extra.append(rel)
        print("tree comparison (files on disk against the tarball's contents):")
        print("  files in the tarball missing on disk:     %d" % tree_missing)
        print("  files whose content differs:              %d" % tree_differs)
        print("  files on disk that are not in the tarball: %d (the .lake directory is not counted)" % len(extra))
        for line in tree_examples + ["not in tarball: " + e for e in sorted(extra)[:10]]:
            print("  - " + line)
        if tree_missing or tree_differs or extra:
            print("tree comparison: DIFFERENT from the tarball")
            status = 1
        else:
            print("tree comparison: the extracted files are byte-for-byte the tarball's contents")

    if a.write_expected and status == 0:
        merge_expected(a.write_expected, "tarball", summary)
    return status


# --------------------------------------------------------------------------------------------
# 02: project files

def cmd_project_info(a):
    proj = a.project
    files = ["lakefile.toml", "lake-manifest.json", "lean-toolchain"]
    missing = [f for f in files if not os.path.isfile(os.path.join(proj, f))]
    if missing:
        print("project files missing: " + ", ".join(missing))
        return 1
    with open(os.path.join(proj, "lean-toolchain"), encoding="utf-8") as fh:
        toolchain = fh.read().strip()
    manifest = load_json(os.path.join(proj, "lake-manifest.json"))
    packages = {p.get("name"): p.get("rev") for p in manifest.get("packages", [])}
    mathlib = packages.get("mathlib")
    with open(os.path.join(proj, "lakefile.toml"), encoding="utf-8") as fh:
        lakefile = fh.read()
    # The lakefile's own pin, read with a narrow pattern: the `rev` of the requirement named mathlib.
    m = re.search(r'\[\[require\]\]\s*(?:[^\[]*?\n)?\s*name\s*=\s*"mathlib"[^\[]*?\brev\s*=\s*"([^"]+)"', lakefile)
    lakefile_rev = m.group(1) if m else None
    hashes = {f: sha256_file(os.path.join(proj, f)) for f in files}

    print("lean-toolchain:              %s" % toolchain)
    print("Mathlib revision (manifest): %s" % mathlib)
    print("Mathlib revision (lakefile): %s" % lakefile_rev)
    print("packages in the manifest:    %d" % len(packages))
    for name in sorted(packages, key=str.lower):
        print("  %-18s %s" % (name, packages[name]))
    for f in files:
        print("sha256 %-20s %s" % (f, hashes[f]))

    status = 0
    if lakefile_rev and mathlib and lakefile_rev != mathlib:
        print("WARNING: the lakefile and the manifest name different Mathlib revisions")
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
    if not report_comparison("project files", a.expected, bool(exp), diffs):
        status = 1
    if a.write_expected and status == 0:
        merge_expected(a.write_expected, "project", summary)
    return status


# --------------------------------------------------------------------------------------------
# 03: source audit
#
# The scan has two stages. Stage 1 (ripgrep or grep, fixed strings only) keeps every source line
# that contains at least one of AUDIT_LITERALS. Stage 2 (this file) applies the regular
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
PROTECTED_NAMES = ["RiemannHypothesis", "riemannZeta", "LFunction"]
NAMES_ALT = "|".join(PROTECTED_NAMES)
# A declaration whose name, or last name component, is one of the protected names.
LOCAL_DEF_RE = re.compile(
    r"\b(?:def|abbrev|theorem|lemma|structure|class|inductive|instance|opaque|axiom|alias|"
    r"notation|macro|syntax)\s+(?:[\w.']+\.)?(" + NAMES_ALT + r")(?![\w.'!?])")
# A name introduced by a binder keyword, or a quoted notation token, that reuses one of the
# protected names: `fun riemannZeta =>`, `variable (riemannZeta : ...)`, `intro LFunction`,
# `notation "riemannZeta" => ...`. Binders written inside a declaration's signature cannot be
# told apart from type ascriptions by a regular expression and are not covered; the statement
# report of 08_check_axioms.sh, which works on what the kernel sees, covers that case.
SHADOW_RE = re.compile(
    r"(?:\b(?:fun|let|have|set|intro|intros|rintro|obtain|rcases|variable|universe)\b|[\u03bb\u2200\u2203])"
    r"[^:=,\u21a6]*?(?<![\w.'])(?:" + NAMES_ALT + r")(?![\w.'!?])"
    r"|\"(?:" + NAMES_ALT + r")\"")

AUDIT_LITERALS = sorted(set([
    "sorry", "admit", "axiom", "native", "ReduceBool", "reduceBool", "ReduceNat", "reduceNat", "trustCompiler",
    "unsafe", "implemented_by", "extern", "opaque", "#eval", "initialize", "IO", "System.", "FilePath",
    "readFile", "writeFile", "BinFile", "removeFile", "createDir", "removeDir", "readDir", "pathExists",
    "readToEnd", "putStr", "getLine", "Process.",
    "skipKernelTC", "addDecl", "addAndCompile", "Environment", "modifyEnv", "setEnv", "run_cmd", "run_elab",
    "run_meta", "set_option", "MetaM", "TacticM", "TermElabM", "CommandElabM", "CoreM",
    "import", "RiemannHypothesis", "riemannZeta", "LFunction",
] + SYNTAX_KEYWORDS))

HIT_RE = re.compile(r"^(?:\./)?(.*?\.lean):(\d+):(.*)$")


def cmd_audit_literals(_a):
    for lit in AUDIT_LITERALS:
        print(lit)
    return 0


def cmd_audit_classify(a):
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
            if LOCAL_DEF_RE.search(body):
                local_defs.append("%s:%d: %s" % (path, lineno, body.strip()[:140]))
            if SHADOW_RE.search(body):
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
                                    "declarations named " + ", ".join(PROTECTED_NAMES)))
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
    print("Declarations named %s: %d" % (", ".join(PROTECTED_NAMES), len(local_defs)))
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
        print("comparison: no recorded audit values to compare with (%s)" % (a.expected or "no file given"))
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
# 08: axiom check summary

ALLOWED_AXIOMS = ["propext", "Classical.choice", "Quot.sound"]
RH_MODULE = "Mathlib.NumberTheory.LSeries.RiemannZeta"


def cmd_axioms_summary(a):
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
    chk = checks.get("statement_is_constant_RiemannHypothesis")
    if not chk or chk["subject"] != a.primary or not chk["value"]:
        what = "conclusion" if a.mode == "probe" else "type"
        failures.append("%s: its %s is not exactly the constant RiemannHypothesis" % (a.primary, what))
    if modules.get("RiemannHypothesis") != RH_MODULE:
        failures.append("RiemannHypothesis is defined in module %r, expected %s" % (modules.get("RiemannHypothesis"), RH_MODULE))
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
    if a.json:
        write_json(a.json, result)

    print()
    print("== Axiom and statement check (%s mode), Lean %s" % (a.mode, lean_version or "version unknown"))
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
        print("  %s of %s is exactly the constant RiemannHypothesis: %s" % (
            "conclusion" if a.mode == "probe" else "type", chk["subject"], "yes" if chk["value"] else "NO"))
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
            print("  RiemannHypothesis; and that constant is the one defined in")
            print("  %s." % RH_MODULE)
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
    """One walk of root. Returns {ext: {module name: path}} for the files that end with each extension."""
    out = {e: {} for e in exts}
    if not os.path.isdir(root):
        return out
    for dirpath, _dirs, files in os.walk(root):
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
    # the ".olean" of a module that is not a `module` file. This project has no `module` files, so any such
    # part beside a compiled file is something the build did not write: it is reported and blocks "complete".
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
            # part it finds beside the file, so they must be beside the link too. (This project has none, and
            # the summary reports any as a fault of the build; the link is here so that the tool is never shown
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

    p = sub.add_parser("tar-inspect")
    p.add_argument("tarball")
    p.add_argument("--prefix", default="lean/")
    p.add_argument("--sha256", default="")
    p.add_argument("--expected", default="")
    p.add_argument("--write-expected", default="")
    p.add_argument("--verify-tree", default="")
    p.add_argument("--quiet", action="store_true")
    p.set_defaults(fn=cmd_tar_inspect)

    p = sub.add_parser("project-info")
    p.add_argument("project")
    p.add_argument("--expected", default="")
    p.add_argument("--write-expected", default="")
    p.set_defaults(fn=cmd_project_info)

    p = sub.add_parser("audit-literals")
    p.set_defaults(fn=cmd_audit_literals)

    p = sub.add_parser("audit-classify")
    p.add_argument("--hits", required=True)
    p.add_argument("--lean-files", type=int, required=True)
    p.add_argument("--tool", default="?")
    p.add_argument("--show", type=int, default=3)
    p.add_argument("--json", default="")
    p.add_argument("--expected", default="")
    p.add_argument("--write-expected", default="")
    p.add_argument("--strict", action="store_true")
    p.set_defaults(fn=cmd_audit_classify)

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
