#!/usr/bin/env python3
"""Static import graph of the extracted Lean source tree.

This reads the `import` lines at the top of every .lean file. It is static reading of source
text: it says which modules a file asks for, not what any proof depends on.

Usage: import_graph.py [SRC_DIR [OUT_DIR]] [--root Main] [--statements Statements]

SRC_DIR defaults to $RH_PROJ/src and OUT_DIR to $RH_AN, as resolved by scripts/lib.sh (see
rhpaths.py). Reads every .lean file once (about 1.0 GB for this project; under a minute).

Writes into OUT_DIR:
  import_graph.json           module -> list of imported modules (project and external)
  import_graph_summary.json   the summary that is also printed
  main_closure.txt            modules reachable from the root module through imports
  not_in_main_closure.txt     modules that are not
  nonprefix_modules.txt       modules whose name is not a prefix of another module's name
  prefix_modules.txt          modules whose name is (see scripts/09_kernel_replay.sh for why)
"""
import argparse
import collections
import json
import os
import re
import sys

import rhpaths

HEADER_WORDS = ("module", "prelude", "public", "private", "meta")
# A module name; \u00ab and \u00bb are the French quotes Lean uses around unusual name parts.
NAME_RE = re.compile("[A-Za-z_\u00ab][\\w.'\u00ab\u00bb]*")


def header_imports(text):
    """Module names imported by a Lean file, and whether the whole header was seen.

    The header is everything before the first token that is not a comment, `module`, `prelude`
    or an import. Line comments and nested block comments are skipped.
    """
    n = len(text)
    i = 0
    imports = []

    def skip(i):
        while i < n:
            if text[i].isspace():
                i += 1
            elif text.startswith("--", i):
                j = text.find("\n", i)
                i = n if j < 0 else j + 1
            elif text.startswith("/-", i):
                depth, i = 1, i + 2
                while i < n and depth:
                    if text.startswith("/-", i):
                        depth, i = depth + 1, i + 2
                    elif text.startswith("-/", i):
                        depth, i = depth - 1, i + 2
                    else:
                        i += 1
            else:
                break
        return i

    def word(i):
        j = i
        while j < n and not text[j].isspace():
            j += 1
        return text[i:j], j

    while True:
        i = skip(i)
        if i >= n:
            return imports, False          # ran off the end: the caller may need more text
        w, j = word(i)
        if w in HEADER_WORDS:
            i = j
            continue
        if w == "import":
            i = skip(j)
            w, j = word(i)
            if w == "all":
                i = skip(j)
                w, j = word(i)
            m = NAME_RE.match(w)
            if m:
                imports.append(m.group(0))
            i = j
            continue
        return imports, True


def read_module(path, head_bytes=65536):
    with open(path, "rb") as fh:
        data = fh.read()
    imports, complete = header_imports(data[:head_bytes].decode("utf-8", "replace"))
    if not complete and len(data) > head_bytes:
        imports, _ = header_imports(data.decode("utf-8", "replace"))
    return imports, data.count(b"\n"), len(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", nargs="?", help="source directory (default: $RH_PROJ/src)")
    ap.add_argument("out", nargs="?", help="output directory (default: $RH_AN)")
    ap.add_argument("--root", default="Main", help="module whose import closure is computed (default Main)")
    ap.add_argument("--statements", default="Statements", help="second module whose closure size is reported")
    a = ap.parse_args()
    src = rhpaths.src_dir(a.src)
    out = rhpaths.analysis_dir(a.out)
    if not os.path.isdir(src):
        sys.exit("source directory not found: %s" % src)

    mods = {}      # module -> (lines, bytes)
    deps = {}      # module -> [imports]
    for root, _dirs, files in os.walk(src):
        for f in files:
            if not f.endswith(".lean"):
                continue
            p = os.path.join(root, f)
            m = os.path.relpath(p, src)[:-5].replace(os.sep, ".")
            imports, lines, size = read_module(p)
            mods[m] = (lines, size)
            deps[m] = imports
    local = set(mods)

    def closure(roots):
        seen, stack = set(), [r for r in roots if r in local]
        while stack:
            x = stack.pop()
            if x in seen:
                continue
            seen.add(x)
            for d in deps[x]:
                if d in local and d not in seen:
                    stack.append(d)
        return seen

    main_cl = closure([a.root])
    stmts_cl = closure([a.statements])

    # Longest import chain below each module of the root's closure, in modules and in lines.
    order, state = [], {}
    for r in sorted(main_cl):
        if r in state:
            continue
        st = [(r, iter([d for d in deps[r] if d in local]))]
        state[r] = 1
        while st:
            node, it = st[-1]
            advanced = False
            for d in it:
                if d not in state:
                    state[d] = 1
                    st.append((d, iter([e for e in deps[d] if e in local])))
                    advanced = True
                    break
            if not advanced:
                order.append(node)
                st.pop()
    depth, wdepth = {}, {}
    for n in order:
        ld = [d for d in deps[n] if d in local]
        depth[n] = 1 + max((depth.get(d, 0) for d in ld), default=0)
        wdepth[n] = mods[n][0] + max((wdepth.get(d, 0) for d in ld), default=0)

    # leanchecker treats its argument as a name prefix, so a module whose name is a proper
    # prefix of another module's name cannot be checked on its own.
    prefixes = set()
    for m in local:
        parts = m.split(".")
        for i in range(1, len(parts)):
            prefixes.add(".".join(parts[:i]))
    prefix_modules = sorted(local & prefixes)
    nonprefix_modules = sorted(local - prefixes)

    def top(m):
        return m.split(".")[0]

    ext = collections.Counter(d for m in local for d in deps[m] if d not in local)
    indeg = collections.Counter(d for m in main_cl for d in deps[m] if d in local)
    res = {
        "modules_total": len(local),
        "lines_total": sum(v[0] for v in mods.values()),
        "bytes_total": sum(v[1] for v in mods.values()),
        "root": a.root,
        "main_closure_modules": len(main_cl),
        "main_closure_lines": sum(mods[m][0] for m in main_cl),
        "statements_closure_modules": len(stmts_cl),
        "not_in_main_closure": len(local) - len(main_cl),
        "critical_path_depth_modules": depth.get(a.root),
        "critical_path_lines": wdepth.get(a.root),
        "prefix_modules": len(prefix_modules),
        "by_top_all": dict(collections.Counter(top(m) for m in local)),
        "by_top_main": dict(collections.Counter(top(m) for m in main_cl)),
        "external_imports_top30": sorted(ext.items(), key=lambda kv: (-kv[1], kv[0]))[:30],
        "external_import_roots": dict(collections.Counter(k.split(".")[0] for k in ext.elements())),
        "most_imported_in_main_closure_top25": sorted(indeg.items(), key=lambda kv: (-kv[1], kv[0]))[:25],
        "largest_files_top25": sorted(((v[0], m) for m, v in mods.items()), key=lambda t: (-t[0], t[1]))[:25],
    }

    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "import_graph_summary.json"), "w", encoding="utf-8") as fh:
        json.dump(res, fh, indent=1)
    with open(os.path.join(out, "import_graph.json"), "w", encoding="utf-8") as fh:
        json.dump({m: deps[m] for m in sorted(local)}, fh)
    for name, items in (("main_closure.txt", sorted(main_cl)),
                        ("not_in_main_closure.txt", sorted(local - main_cl)),
                        ("nonprefix_modules.txt", nonprefix_modules),
                        ("prefix_modules.txt", prefix_modules)):
        with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
            for m in items:
                fh.write(m + "\n")
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
