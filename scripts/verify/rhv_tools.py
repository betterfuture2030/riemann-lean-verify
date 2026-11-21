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


# Exit statuses that say nothing about the module: 96 = the checker could not do its work (it could not be
# started, or could not open or find a compiled file; kernel_check_one.sh and kernel_check_batch.sh), and four
# signals that come from outside the checker: 129 (hang-up), 130 (interrupt), 137 (kill; typically the system's
# out-of-memory killer) and 143 (terminate; typically a time limit). Any other non-zero status counts as a
# failure; one of 128 or more is a checker that crashed by itself, which is reported apart from a module the
# kernel rejected.
NOT_RUN_STATUSES = (96, 129, 130, 137, 143)

# The two ways a module can be replayed. Both run the same function of the pinned toolchain on the module
# (replayFromImports in LeanChecker.lean); they differ in how the modules to check are chosen.
#   leanchecker   the stock tool: one process per module, and one per prefix module with the modules beneath it
#   rhv-replay    scripts/verify/replay: many exactly-named modules per process
REPLAY_METHODS = ("leanchecker", "rhv-replay")


def replay_state(a):
    files = lib_files(a.lib, (".olean.server", ".olean.private", ".olean"))
    compiled = files[".olean"]
    # leanchecker replays a module's ".olean.private" part when one exists, while an importing file reads only
    # the ".olean" of a module that is not a `module` file. This project has no `module` files, so any such
    # part beside a compiled file is something the build did not write: it is reported and blocks "complete".
    extra_parts = sorted(set(files[".olean.server"]) | set(files[".olean.private"]))
    sources = lib_files(a.src, (".lean",))[".lean"] if a.src else {}
    names = set(compiled) | set(sources)
    # leanchecker checks every module whose name has its argument as a prefix. A module that is a proper prefix
    # of another module's name can therefore not be checked on its own by the stock tool: it is checked in one
    # process together with the compiled modules beneath it (the "prefix pass"). rhv-replay takes exact names.
    prefixes = set()
    for n in names:
        parts = n.split(".")
        for i in range(1, len(parts)):
            prefixes.add(".".join(parts[:i]))
    prefix_modules = sorted(set(compiled) & prefixes)

    # The stamp of a compiled file is the content hash the build tool keeps beside it. A compiled file without
    # one was left by a compiler that the build tool never saw finish; no result can be current for it.
    stamps = {}
    for mod, path in compiled.items():
        try:
            with open(path + ".hash", encoding="ascii", errors="replace") as fh:
                stamps[mod] = fh.read().strip() or None
        except OSError:
            stamps[mod] = None

    latest = {}     # (module, method) -> the last result line
    unreadable = 0  # lines that are neither a complete old line (five fields) nor a complete new one (six)
    if os.path.isfile(a.results):
        with open(a.results, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                f = line.rstrip("\n").split("\t")
                if f[0] == "module" or line.strip() == "":
                    continue
                if not line.endswith("\n"):         # a write cut short, at the very end of the file
                    unreadable += 1
                    continue
                # Lines written before the method column existed have five fields and were all leanchecker's.
                # Anything else that is not a complete six-field line (a line cut short by a full disk, two
                # lines run together) is counted and ignored: it is never credited to either method.
                if len(f) == 5:
                    method = "leanchecker"
                elif len(f) == 6 and f[5] in REPLAY_METHODS:
                    method = f[5]
                else:
                    unreadable += 1
                    continue
                latest[(f[0], method)] = f

    def status(mod, method):
        """passed, failed, crashed, not_run, stale, no_stamp, or None if there is no result."""
        r = latest.get((mod, method))
        if r is None:
            return None
        try:
            rc = int(r[1])
        except ValueError:
            rc = 1
        if stamps[mod] is None:
            # No hash beside the file: no result can be current for it. But a failure that was recorded for
            # this module is not forgotten for that: it stays under FAILED until the module is checked again.
            if rc != 0 and rc not in NOT_RUN_STATUSES:
                return "crashed" if rc >= 128 else "failed"
            return "no_stamp"
        if r[3] != stamps[mod]:
            return "stale"          # compiled again since it was checked
        if rc == 0:
            return "passed"
        if rc in NOT_RUN_STATUSES:
            return "not_run"
        return "crashed" if rc >= 128 else "failed"

    by = {m: {} for m in REPLAY_METHODS}        # method -> {module: status}
    for mod in compiled:
        for method in REPLAY_METHODS:
            st = status(mod, method)
            if st:
                by[method][mod] = st
    passed, failed, crashed, remaining, disagree = [], [], [], [], []
    for mod in sorted(compiled):
        sts = [by[m].get(mod) for m in REPLAY_METHODS]
        bad = [x for x in sts if x in ("failed", "crashed")]
        if bad and "passed" in sts:
            disagree.append(mod)
        if bad:
            failed.append(mod)
            if "failed" not in sts:
                crashed.append(mod)
        elif "passed" in sts:
            passed.append(mod)
        else:
            remaining.append(mod)
    return {"compiled": compiled, "sources": sources, "prefix_modules": prefix_modules, "extra_parts": extra_parts,
            "stamps": stamps, "by": by, "passed": passed, "failed": failed, "crashed": crashed,
            "remaining": remaining, "disagree": disagree, "unreadable": unreadable}


def cmd_replay_plan(a):
    st = replay_state(a)
    done_states = ("passed",) if a.retry_failed else ("passed", "failed", "crashed")
    mine = st["by"][a.method]
    has_stamp = {m for m, s in st["stamps"].items() if s is not None}
    prefix = set(st["prefix_modules"])
    if a.prefix_modules:
        # One line per prefix module still to check: module, stamp, and the word "prefix", which tells
        # kernel_check_one.sh to keep the checker's list of the modules it replayed.
        todo = [m for m in st["prefix_modules"] if m in has_stamp and mine.get(m) not in done_states]
        for m in todo:
            sys.stdout.write("%s\t%s\tprefix\n" % (m, st["stamps"][m]))
        sys.stderr.write("prefix modules: %d compiled; %d already have a current result; %d to check now\n" % (
            len(prefix), len(prefix) - len(todo), len(todo)))
        return 0
    # The stock tool cannot check a prefix module by itself; the other method names modules exactly.
    eligible = sorted(m for m in has_stamp if a.method == "rhv-replay" or m not in prefix)
    if a.list:
        with open(a.list, encoding="utf-8") as fh:
            wanted = [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]
        ok = set(eligible)
        unknown = [m for m in wanted if m not in ok]
        if unknown:
            sys.stderr.write("note: %d listed modules are not compiled, were never finished by the build, or cannot be checked singly by this method; skipped\n" % len(unknown))
        pool = [m for m in wanted if m in ok]
    else:
        pool = eligible
    if a.sample and a.sample < len(pool):
        pool = sorted(random.Random(a.seed).sample(sorted(pool), a.sample))
    todo = [m for m in pool if mine.get(m) not in done_states]
    # A fixed shuffle, so that cheap and costly modules are mixed instead of arriving library by library.
    # The order has no bearing on the result: every module is replayed from its own imports.
    random.Random(a.seed).shuffle(todo)
    for m in todo:
        sys.stdout.write("%s\t%s\n" % (m, st["stamps"][m]))
    sys.stderr.write("%s: selected %d modules; %d already have a current result by this method; %d to check now\n" % (
        a.method, len(pool), len(pool) - len(todo), len(todo)))
    return 0


def cmd_replay_summary(a):
    st = replay_state(a)
    compiled, by = st["compiled"], st["by"]
    passed, failed, crashed, remaining, disagree = st["passed"], st["failed"], st["crashed"], st["remaining"], st["disagree"]
    prefix = st["prefix_modules"]
    total_src = len(st["sources"])
    # Compared by name, not by count: a compiled file with no source must not stand in for a missing one.
    not_compiled = sorted(set(st["sources"]) - set(compiled))
    no_source = sorted(set(compiled) - set(st["sources"])) if total_src else []
    extra_parts = st["extra_parts"]
    no_stamp = sorted(m for m, s in st["stamps"].items() if s is None)
    # Which replay programs the rhv-replay runs used (09_kernel_replay.sh keeps the list beside the results).
    programs = {}
    plist = os.path.join(os.path.dirname(os.path.abspath(a.results)), "replay_program.tsv")
    if os.path.isfile(plist) and not os.path.islink(plist):
        with open(plist, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                f = line.rstrip("\n").split("\t")
                if len(f) >= 3 and line.endswith("\n"):
                    programs[(f[1], f[2])] = programs.get((f[1], f[2]), 0) + 1
    programs = [{"sha256": k[0], "origin": k[1], "runs": n} for k, n in sorted(programs.items())]
    # What another run could still check: everything remaining except files the build tool never finished.
    checkable_left = len([m for m in remaining if st["stamps"][m] is not None])
    unreadable = st["unreadable"]
    not_run = sorted(m for m in remaining if any(by[x].get(m) == "not_run" for x in REPLAY_METHODS))
    stale = sorted(m for m in remaining if any(by[x].get(m) == "stale" for x in REPLAY_METHODS))
    n_pass = {x: sum(1 for v in by[x].values() if v == "passed") for x in REPLAY_METHODS}
    both = sum(1 for m in compiled if all(by[x].get(m) == "passed" for x in REPLAY_METHODS))
    prefix_left = [m for m in prefix if m in set(remaining)]
    # Complete: the sources are known, every one of them is compiled and was finished by the build tool,
    # nothing else is compiled, and every compiled module has a passing result for the file now on disk.
    structure_ok = total_src > 0 and not not_compiled and not no_source and not extra_parts and not no_stamp
    complete = structure_ok and not failed and not remaining
    complete_by = {x: structure_ok and not failed and n_pass[x] == len(compiled) for x in REPLAY_METHODS}
    print("== Kernel re-check summary")
    if total_src:
        print("  source modules:                         %d" % total_src)
    print("  compiled modules:                       %d" % len(compiled))
    print("    passed (result is for the current file): %d" % len(passed))
    print("      by leanchecker: %d   by rhv-replay: %d   by both: %d" % (n_pass["leanchecker"], n_pass["rhv-replay"], both))
    print("    FAILED:                                 %d%s" % (len(failed), "  (of which the checker itself crashed: %d)" % len(crashed) if crashed else ""))
    print("    remaining (never checked, or recompiled since): %d  (of which recompiled since: %d)" % (len(remaining), len(stale)))
    print("  prefix modules (name is a prefix of another module's name): %d, of which without a result: %d" % (len(prefix), len(prefix_left)))
    if disagree:
        print("  THE TWO METHODS DISAGREE on %d modules (passed by one, failed by the other)" % len(disagree))
    if not_run:
        print("  checker not run or killed from outside (counted as remaining, not as failed; run again, with fewer jobs): %d" % len(not_run))
    if no_stamp:
        print("  compiled files the build tool never finished (no hash beside them; rebuild them): %d" % len(no_stamp))
    if unreadable:
        print("  lines of the results file that are not a complete result (ignored): %d" % unreadable)
    for pr in programs:
        print("  rhv-replay program used in %d run(s): sha256 %s (%s)" % (pr["runs"], pr["sha256"], pr["origin"].replace("_", " ")))
    if extra_parts:
        print("  modules with an .olean.server or .olean.private file the build should not have written: %d" % len(extra_parts))
    if not_compiled:
        print("  source modules not compiled: %d" % len(not_compiled))
    if no_source:
        print("  compiled modules with no source file: %d" % len(no_source))
    for m in failed[:50]:
        print("  FAILED: " + m + ("  (checker crashed)" if m in set(crashed) else ""))
    if len(failed) > 50:
        print("  ... and %d more" % (len(failed) - 50))
    print("  every source module compiled and passing: %s" % ("yes" if complete else "no"))
    if a.json:
        write_json(a.json, {
            "check": "kernel replay of each compiled module from its imports (replayFromImports of the pinned toolchain)",
            "run_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "source_modules": total_src, "compiled_modules": len(compiled),
            "passed": len(passed), "passed_by_leanchecker": n_pass["leanchecker"], "passed_by_rhv_replay": n_pass["rhv-replay"],
            "passed_by_both": both,
            "failed": len(failed), "failed_modules": failed, "checker_crashed": len(crashed), "crashed_modules": crashed[:200],
            "methods_disagree": len(disagree), "disagreeing_modules": disagree[:200],
            "remaining": len(remaining), "remaining_that_another_run_could_check": checkable_left,
            "recompiled_since_checked": len(stale), "result_lines_ignored_as_incomplete": unreadable,
            "rhv_replay_programs_used": programs,
            "not_run_or_killed": len(not_run), "not_run_or_killed_modules": not_run[:200],
            "prefix_modules": prefix, "prefix_remaining": len(prefix_left),
            "compiled_files_never_finished_by_the_build": len(no_stamp), "never_finished_sample": no_stamp[:50],
            "modules_with_unexpected_parts": len(extra_parts), "unexpected_parts_sample": extra_parts[:50],
            "source_modules_not_compiled": len(not_compiled), "not_compiled_sample": not_compiled[:50],
            "compiled_modules_without_source": len(no_source), "without_source_sample": no_source[:50],
            "complete": complete, "complete_by_leanchecker_alone": complete_by["leanchecker"],
            "complete_by_rhv_replay_alone": complete_by["rhv-replay"],
        })
    if failed:
        return 1
    return 3 if a.require_complete and not complete else 0


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
        p.add_argument("--retry-failed", action="store_true")
        p.add_argument("--prefix-modules", action="store_true")
        p.add_argument("--require-complete", action="store_true")
        p.add_argument("--method", default="leanchecker", choices=list(REPLAY_METHODS))
        p.set_defaults(fn=fn)

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
