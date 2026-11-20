#!/usr/bin/env python3
"""A rough model of build time: wall time per module against the size of its import closure.

Lake prints the wall time of each module it compiles. This script collects those times from
the build logs, pairs each with the module's closure size (the number of project modules it
imports directly or indirectly, from import_graph.json), fits a straight line
    wall seconds = a + b * closure
to the modules compiled with one given job count, and uses the line to project the total.

Read the result with care. The projection extrapolates beyond the closure sizes seen so far:
early in a build only modules with small closures have been compiled. On 2026-11-20, with
1,228 timed modules whose closures were at most 837, the fitted slope was negative, which
makes a projection meaningless; the script says so when that happens. Later the same day, with
5,862 modules compiled at 8 jobs and closures up to 7,741, the slope was positive (about 1.4 s
per 1,000 imported modules) and the projection was 3.4 days at 8 jobs, still a rough guide:
the largest closures in the project are above 170,000. Wall times also depend on how many jobs
ran at once, which is why only one job count is fitted at a time.

Usage: eta_model.py [--analysis-dir DIR] [--logs-dir DIR] [--out-dir DIR] [--jobs N]
                    [--sample N] [--seed S]

Reads import_graph.json from the analysis directory ($RH_AN) and build-status.txt and
build-*.log from the logs directory ($RH_LOGS), both as resolved by scripts/lib.sh (see
rhpaths.py). Writes eta_model.json to --out-dir (default: the analysis directory). Reads the
logs only; it does not touch the build. Takes a minute or two.
"""
import argparse
import collections
import glob
import json
import os
import random
import re
import statistics as st
import sys

import rhpaths

# A job line of a successfully compiled module: "<mark> [n/m] Built <module> (<time>)".
# The marks are U+2714 (ok) and U+26A0 (ok, with warnings).
BUILT_RE = re.compile("^(?:\u2714|\u26a0) \\[\\d+/\\d+\\] Built (\\S+) \\(([0-9.]+)(ms|s|m)\\)")
UNIT = {"ms": 0.001, "s": 1.0, "m": 60.0}
BINS = [(0, 0), (1, 10), (11, 100), (101, 300), (301, 1000), (1001, 3000), (3001, 10000), (10001, None)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--analysis-dir", help="directory containing import_graph.json (default: $RH_AN)")
    ap.add_argument("--logs-dir", help="directory containing the build logs (default: $RH_LOGS)")
    ap.add_argument("--out-dir", help="where to write eta_model.json (default: the analysis directory)")
    ap.add_argument("--jobs", help="fit only modules compiled with this job count (default: the count with most data)")
    ap.add_argument("--sample", type=int, default=4000, help="modules sampled to estimate the mean closure (default 4000)")
    ap.add_argument("--seed", type=int, default=11, help="random seed for that sample (default 11)")
    a = ap.parse_args()
    adir = rhpaths.analysis_dir(a.analysis_dir)
    ldir = rhpaths.logs_dir(a.logs_dir)
    out = a.out_dir or adir
    graph_file = os.path.join(adir, "import_graph.json")
    status_file = os.path.join(ldir, "build-status.txt")
    for f in (graph_file, status_file):
        if not os.path.isfile(f):
            sys.exit("not found: %s" % f)
    with open(graph_file, encoding="utf-8") as fh:
        g = json.load(fh)
    names = sorted(g)      # sorted, so that the sample depends only on the seed
    idx = {m: i for i, m in enumerate(names)}
    dl = [[idx[d] for d in g[m] if d in idx] for m in names]

    def closure(v):
        seen = {v}
        stack = [v]
        while stack:
            x = stack.pop()
            for w in dl[x]:
                if w not in seen:
                    seen.add(w)
                    stack.append(w)
        return len(seen) - 1

    # Which job count was each log written with? build-status.txt has one START line per run.
    with open(status_file, encoding="utf-8", errors="replace") as fh:
        status = fh.read()
    jobs_of = {os.path.basename(m.group(2)): m.group(1) for m in re.finditer(r"threads=(\S+) log=(\S+)", status)}

    rows = []      # (module, wall seconds, job count)
    for f in sorted(glob.glob(os.path.join(ldir, "build-2*.log"))):
        jobs = jobs_of.get(os.path.basename(f), "?")
        with open(f, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = BUILT_RE.match(line)
                if m and m.group(1) in idx:
                    rows.append((m.group(1), float(m.group(2)) * UNIT[m.group(3)], jobs))
    by_jobs = collections.Counter(r[2] for r in rows)
    print("modules with timings: %d   by job count: %s" % (len(rows), dict(sorted(by_jobs.items()))))
    print("distinct modules compiled so far (from the logs): %d of %d" % (len(set(r[0] for r in rows)), len(names)))
    if not rows:
        sys.exit("no timed modules found in %s" % ldir)

    jobs = a.jobs or max((j for j in by_jobs if j.isdigit()), key=lambda j: by_jobs[j], default=None)
    data = [(closure(idx[m]), t) for m, t, j in rows if j == jobs]
    if len(data) < 2 or not (jobs or "").isdigit():
        sys.exit("not enough timed modules for job count %r" % jobs)
    xs = [c for c, _ in data]
    ys = [t for _, t in data]
    print("fitting the %d modules compiled with %s jobs:" % (len(data), jobs))
    print("  closure: median %d, mean %.0f, max %d   wall: median %.1f s, mean %.1f s" % (
        st.median(xs), st.mean(xs), max(xs), st.median(ys), st.mean(ys)))
    for lo, hi in BINS:
        b = [t for c, t in data if c >= lo and (hi is None or c <= hi)]
        if b:
            print("  closure %6d-%-6s n=%6d  median wall %6.1f s  mean %6.1f s" % (
                lo, "max" if hi is None else hi, len(b), st.median(b), st.mean(b)))

    mx, my = st.mean(xs), st.mean(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx if sxx > 0 else 0.0
    intercept = my - slope * mx
    print("least-squares fit: wall = %.2f s + %.3f s per 1000 imported project modules" % (intercept, slope * 1000))

    random.seed(a.seed)
    sample = random.sample(range(len(names)), min(a.sample, len(names)))
    sample_closures = [closure(v) for v in sample]
    mean_closure = st.mean(sample_closures)
    beyond = sum(1 for c in sample_closures if c > max(xs)) / len(sample_closures)
    total_s = len(names) * (intercept + slope * mean_closure)
    nj = int(jobs)
    days = total_s / 3600 / nj / 24
    usable = slope > 0 and total_s > 0
    print("closure over all modules (sample of %d): mean %.0f, largest %d; largest closure in the fit: %d" % (
        len(sample), mean_closure, max(sample_closures), max(xs)))
    print("share of all modules whose closure is larger than any in the fit: %.0f%%" % (100 * beyond))
    if usable:
        print("projected sum of per-module wall time: %.0f h; at %d parallel jobs: %.0f h = %.1f days" % (
            total_s / 3600, nj, total_s / 3600 / nj, days))
        print("CAUTION: this assumes the same straight line holds for closures far larger than any in the")
        print("fit, that jobs pack perfectly, and that the rate does not change as memory fills. Rough guide only.")
    else:
        print("NOT USABLE: the fitted slope is not positive, so this data shows no trend that could be")
        print("extrapolated. No projection is made. Try again when modules with larger closures have been compiled.")

    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "eta_model.json"), "w", encoding="utf-8") as fh:
        json.dump({"jobs": nj, "a": intercept, "b": slope, "n_fit": len(data), "max_closure_in_fit": max(xs),
                   "mean_closure": mean_closure, "max_closure_in_sample": max(sample_closures),
                   "share_of_modules_beyond_fit": beyond, "usable": usable,
                   "projected_days": days if usable else None}, fh, indent=1)


if __name__ == "__main__":
    main()
