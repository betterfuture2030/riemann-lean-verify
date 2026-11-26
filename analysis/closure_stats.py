#!/usr/bin/env python3
"""How much of the project does a typical module import?

For a module, its closure is the set of project modules it imports directly or indirectly.
Closure size matters for build time and disk use, because the compiler loads the whole
closure for every module it compiles. This script reports the exact closure size of a few key
modules, the distribution over a random sample of modules, and a histogram of import depth
(the length of the longest import chain below a module).

Static reading of import lines only; it says nothing about what any proof depends on.

Usage: closure_stats.py [--analysis-dir DIR] [--out-dir DIR] [--sample N] [--seed S] [--key MODULE ...]

Reads import_graph.json (written by import_graph.py) from the analysis directory, by default
$RH_AN as resolved by scripts/lib.sh (see rhpaths.py). Writes closure_stats.json to --out-dir
(default: the analysis directory) and prints it. Takes a few seconds.

The sample figures are estimates. Two samples of 1,500 modules drawn on 2026-11-20 gave medians
of 606 and 725 and means of 2,672 and 3,145, so read them to one significant figure.

Those figures, and the key modules reported when no --key is given, are the default target's. For
another target (targets/README.md) the key module reported when no --key is given is its root module
(TGT_ROOT_MODULE); name others with --key.
"""
import argparse
import collections
import json
import os
import random
import sys

import rhpaths

# A few modules near the top of the default target's import graph, chosen by reading its
# source. Names that do not exist in the graph are skipped.
DEFAULT_KEYS = [
    "Main",
    "Supplements.Kernels.MainTheorems",
    "Supplements.Kernels.MainTheoremsAll",
    "Development.AutomorphicArithmetic.CharacterBoxes.MainConclusion",
    "Development.AutomorphicArithmetic.ThetaCorrespondence.ThetaPairLifts.ThirdPlaceSeries.EveryCharacterOfLiteratureOfVWin",
    "Development.AutomorphicArithmetic.CharacterBoxes.EveryCharacter",
    "Formalism.GammaFactorNonvanishing.CritLine",
]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--analysis-dir", help="directory containing import_graph.json (default: $RH_AN)")
    ap.add_argument("--out-dir", help="where to write closure_stats.json (default: the analysis directory)")
    ap.add_argument("--sample", type=int, default=1500, help="number of modules to sample (default 1500)")
    ap.add_argument("--seed", type=int, default=7, help="random seed for the sample (default 7)")
    ap.add_argument("--key", action="append", help="module whose exact closure size to report (repeatable)")
    a = ap.parse_args()
    adir = rhpaths.analysis_dir(a.analysis_dir)
    if a.key:
        keys = a.key
    elif rhpaths.target(paths_given=bool(a.analysis_dir)) == rhpaths.DEFAULT_TARGET:
        keys = DEFAULT_KEYS
    else:
        keys = [rhpaths.root_module()]
    out = a.out_dir or adir
    graph_file = os.path.join(adir, "import_graph.json")
    if not os.path.isfile(graph_file):
        sys.exit("not found: %s (run import_graph.py first)" % graph_file)
    with open(graph_file, encoding="utf-8") as fh:
        g = json.load(fh)

    names = sorted(g)      # sorted, so that the sample depends only on the seed
    idx = {m: i for i, m in enumerate(names)}
    dl = [[idx[d] for d in g[m] if d in idx] for m in names]
    n = len(names)

    # Depth (longest import chain) by an iterative depth-first search.
    depth = [0] * n
    state = [0] * n
    for r in range(n):
        if state[r]:
            continue
        st = [(r, 0)]
        state[r] = 1
        while st:
            v, i = st[-1]
            if i < len(dl[v]):
                st[-1] = (v, i + 1)
                w = dl[v][i]
                if not state[w]:
                    state[w] = 1
                    st.append((w, 0))
            else:
                depth[v] = 1 + max((depth[w] for w in dl[v]), default=0)
                st.pop()
    hist = collections.Counter(depth)
    top = max(depth) if depth else 0

    def closure(v):
        seen = {v}
        st = [v]
        while st:
            x = st.pop()
            for w in dl[x]:
                if w not in seen:
                    seen.add(w)
                    st.append(w)
        return len(seen) - 1

    random.seed(a.seed)
    sample = random.sample(range(n), min(a.sample, n))
    cs = sorted(closure(v) for v in sample)

    def q(p):
        return cs[min(len(cs) - 1, int(p * len(cs)))]

    res = {
        "n": n,
        "depth_max": top,
        "depth_hist_buckets": {"%d-%d" % (lo, lo + 19): sum(c for d, c in hist.items() if lo <= d < lo + 20)
                               for lo in range(1, max(top, 1) + 1, 20)},
        "modules_with_zero_project_imports": sum(1 for x in dl if not x),
        "sample_size": len(cs),
        "sample_seed": a.seed,
        "sample_closure_quantiles": {str(p): q(p) for p in (0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99)} if cs else {},
        "sample_closure_mean": sum(cs) / len(cs) if cs else None,
        "sample_closure_max": cs[-1] if cs else None,
        "share_of_sample_with_closure_over": {str(t): sum(1 for c in cs if c > t) / len(cs)
                                              for t in (0, 10, 100, 1000, 10000, 50000, 100000)} if cs else {},
        "key_module_closures": {k: closure(idx[k]) for k in keys if k in idx},
    }
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "closure_stats.json"), "w", encoding="utf-8") as fh:
        json.dump(res, fh, indent=1)
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
