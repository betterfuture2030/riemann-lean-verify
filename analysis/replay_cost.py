#!/usr/bin/env python3
"""replay_cost.py - what the kernel replay costs per module, and why the stock tool's cost grows with the tree.

What it does: reads the recorded results of two cloud runs in which `leanchecker` checked modules one process
  at a time, 32 at a time, on the same machine type but with different numbers of compiled modules on disk,
  and fits   seconds per check = fixed + per_file * (compiled files on the search path) + per_import * closure.
  Seconds here are wall-clock seconds of one check while 32 run at once ("job seconds"): the whole tree then
  takes modules * seconds / 32. The rehearsal recorded that directly. The pilot recorded CPU seconds, which are
  turned into job seconds by its measured useful CPU per thread-second (0.971).
  `leanchecker` lists every compiled file on the search path once per process (src/lean/LeanChecker.lean in
  the toolchain: SearchPath.findAllWithExt, then searchModuleNameOfFileName for each file), so `per_file` is the
  cost of that listing. From the fit it projects the replay of the whole tree by the stock tool, and by a
  program that does not list the search path (scripts/verify/replay). If runs that used that program are given
  (--driver-run), their measured rate is reported beside the projection.

  With two runs the fit is two points and a line: it shows the size of the effect, not a precise figure.

What it changes on disk: writes the JSON named by --out, if given. Nothing else.
How long it takes: a second.

Usage: python3 analysis/replay_cost.py [--out FILE] [--driver-run DIR]...
       (run from the repository root; reads records/cloud)
"""
import argparse
import gzip
import json
import os
import statistics
import sys
import time

LIBRARY_FILES = 8651 + 1801     # compiled modules of Mathlib and its dependencies, and of the toolchain
TREE_MODULES = 175187
JOBS = 32


def results(path, method=None):
    rows = []
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) < 5 or f[0] == "module":
                continue
            m = f[5] if len(f) > 5 else "leanchecker"
            if method is None or m == method:
                rows.append((f[0], int(f[1]), float(f[2]), int(f[4])))
    return rows


def phases(path):
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) >= 2 and f[0].isdigit():
                out.append((int(f[0]), f[1], f[2:]))
    return out


def window(ph, name):
    """(start, end) of the last phase called `name` that has an end mark."""
    start = None
    for t, label, _rest in ph:
        if label == name:
            start = t
        elif start is not None and label.endswith(":end") and label.split(":")[0] == name.split(":")[0]:
            return start, t
    return None


def oleans(path):
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            f = line.split()
            if len(f) == 2 and f[0] == "oleans":
                return int(f[1])
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="")
    ap.add_argument("--driver-run", action="append", default=[], help="directory of a recorded run that used rhv-replay")
    a = ap.parse_args()
    root = "records/cloud"
    est = json.load(open(os.path.join(root, "pilot/pilot_estimate.json")))
    eff = est["checker"]["useful_cpu_per_thread_second"]              # CPU seconds delivered per job second in the pilot
    per_import = est["checker"]["per_1000_imports"] / 1000.0 / eff    # job seconds per module in the import closure
    mean_closure_tree = est["tree"]["mean_closure"]

    # Point 1: the third rehearsal of the full run. 1,792 modules compiled; the main pass at 32 at a time.
    r3 = os.path.join(root, "full-rehearsals/full-rehearsal-20261120-214914")
    ph = phases(os.path.join(r3, "phases.tsv"))
    a0, b0 = window(ph, "check:N=32")
    # Results written after the main pass began (the trials before it ran at other job counts).
    rows = [r for r in results(os.path.join(r3, "c3_results.tsv.gz")) if a0 < r[3] <= b0 and r[1] == 0]
    p1 = {"run": "full-rehearsal-20261120-214914", "compiled_modules": oleans(os.path.join(r3, "disk.txt")),
          "checks_counted": len(rows), "mean_seconds_per_check": round(statistics.mean(r[2] for r in rows), 2),
          "mean_closure": 0,
          "note": "wall seconds of each check while 32 ran at once; whole seconds, so the mean is good to about 0.1. "
                  "The closure is taken as 0: no module here imports more than 1,791 others, which is under half a second"}
    p1["files_on_search_path"] = p1["compiled_modules"] + LIBRARY_FILES

    # Point 2: the calibration pilot. 29,633 modules compiled; 2,225 checks at 32 at a time.
    pilot = os.path.join(root, "pilot/pilot-20261120-162141")
    p2 = {"run": "pilot-20261120-162141", "compiled_modules": oleans(os.path.join(pilot, "disk.txt")),
          "checks_counted": est["windows"]["check"]["finished"],
          "mean_cpu_seconds_per_check": est["windows"]["check"]["mean_cpu_s"], "useful_cpu_per_job_second": eff,
          "mean_seconds_per_check": round(est["windows"]["check"]["mean_cpu_s"] / eff, 2),
          "mean_closure": est["observed"]["mean_closure_compiled"],
          "share_of_cpu_time_spent_in_the_operating_system": est["windows"]["check"]["sys_share"]}
    p2["files_on_search_path"] = p2["compiled_modules"] + LIBRARY_FILES

    y1 = p1["mean_seconds_per_check"] - per_import * p1["mean_closure"]
    y2 = p2["mean_seconds_per_check"] - per_import * p2["mean_closure"]
    per_file = (y2 - y1) / (p2["files_on_search_path"] - p1["files_on_search_path"])
    fixed = y1 - per_file * p1["files_on_search_path"]
    files_tree = TREE_MODULES + LIBRARY_FILES
    listing = per_file * files_tree
    closure = per_import * mean_closure_tree
    stock = fixed + listing + closure
    direct = fixed + closure
    hours = lambda s: round(TREE_MODULES * s / JOBS / 3600.0, 1)
    out = {
        "what": "cost of the kernel replay per module, in wall-clock seconds of one check while 32 run at once on n4d-highmem-32, from two recorded runs; a two-point fit",
        "made_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "points": [p1, p2],
        "fit_seconds_per_check": {"fixed": round(fixed, 2), "per_compiled_file_on_the_search_path": round(per_file, 6),
                                  "per_module_in_the_import_closure": round(per_import, 6)},
        "whole_tree": {"modules": TREE_MODULES, "files_on_search_path": files_tree, "mean_closure": mean_closure_tree,
                       "leanchecker_one_process_per_module": {
                           "seconds_per_check": round(stock, 1), "of_which_listing_the_search_path": round(listing, 1),
                           "hours_at_32": hours(stock)},
                       "without_the_listing": {"seconds_per_check": round(direct, 1), "hours_at_32": hours(direct),
                                               "note": "a projection from the stock tool's fit (its fixed and closure terms); not a measurement of rhv-replay"}},
        "earlier_estimate_it_replaces": {"hours": est["hours"]["expected"]["check_hours"],
                                         "why_it_was_wrong": "it took the cost per check measured with 29,633 modules compiled as the cost at any size"},
    }
    # The whole run, with the build and the allowances of pilot_estimate.json and the replay as fitted here.
    # Priced as there: billed hours at the machine's and the disk's hourly rates, plus the disk for six hours more.
    cfg = est["configurations"][0]
    rate = cfg["machine_usd_per_hour"] + cfg["disk_usd_per_hour"]
    stock_sample = 2000                                   # modules the stock tool checks again after rhv-replay
    prefix_pass_hours = 0.3                               # allowance: 114 prefix modules with the modules beneath them
    runs = {}
    for method in ("leanchecker", "rhv-replay"):
        runs[method] = {}
        for case in ("low", "expected", "high"):
            c, h = est["cases"][case], est["hours"][case]
            closure_c = per_import * c["chk_slope"] * mean_closure_tree
            if method == "leanchecker":
                check = TREE_MODULES * (fixed + listing + closure_c) / JOBS / c["chk_eff"] / 3600.0
            else:
                check = (TREE_MODULES * (fixed + closure_c) + stock_sample * (fixed + listing + closure_c)) / JOBS / c["chk_eff"] / 3600.0 + prefix_pass_hours
            billed = h["build_hours"] + h["other_hours"] + check
            runs[method][case] = {"build_hours": h["build_hours"], "replay_hours": round(check, 1), "other_hours": h["other_hours"],
                                  "billed_hours": round(billed, 1), "usd": round(billed * rate + 6 * cfg["disk_usd_per_hour"])}
    out["whole_run"] = {"configuration": cfg["name"], "usd_per_billed_hour": round(rate, 3),
                        "with_rhv_replay_the_stock_tool_also_checks": "%d random modules and every prefix module" % stock_sample,
                        "by_method_for_the_whole_tree": runs}
    drv = []
    for d in a.driver_run:
        ph = phases(os.path.join(d, "phases.tsv"))
        w = None
        for t, label, _rest in ph:
            if label.startswith("check:N="):
                w = window(ph, label)
                jobs = int(label.split("=")[1])
        f = os.path.join(d, "c3_results.tsv.gz")
        if w is None or not os.path.exists(f):
            continue
        rows = [r for r in results(f, "rhv-replay") if w[0] <= r[3] <= w[1] and r[1] == 0]
        if not rows:
            continue
        span = max(r[3] for r in rows) - min(r[3] for r in rows) or 1
        drv.append({"run": os.path.basename(d.rstrip("/")), "compiled_modules": oleans(os.path.join(d, "disk.txt")), "jobs": jobs,
                    "modules_replayed_in_the_main_pass": len(rows), "seconds_between_first_and_last_result": span,
                    "modules_per_second": round(len(rows) / span, 1),
                    "mean_seconds_inside_the_replay_per_module": round(statistics.mean(r[2] for r in rows), 2),
                    "job_seconds_per_module": round(jobs * span / len(rows), 2)})
    if drv:
        out["rhv_replay_measured"] = drv
    text = json.dumps(out, indent=1)
    print(text)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
