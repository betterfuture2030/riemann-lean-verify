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
  (--driver-run), their measured rate is reported beside the projection. If runs in which `leanchecker` was given
  only each module's import closure on its search path are given (--closure-run), what they measured is set beside
  what the fit projects for the same modules.

  With two runs the fit is two points and a line: it shows the size of the effect, not a precise figure.

What it changes on disk: writes the JSON named by --out, if given. Nothing else.
How long it takes: about a second, with or without --closure-run.

  Two measures appear below and are not the same thing. "Seconds per check" is the mean of the seconds recorded
  for each check (the fit's points are of this kind). "Job seconds per module" is throughput: jobs x (seconds
  between a window's first and last result) / modules. They agree only when every job is busy throughout and
  nothing outside the check costs time, so a ratio is only ever taken between two figures of the same kind.

Usage: python3 analysis/replay_cost.py [--out FILE] [--driver-run DIR]... [--closure-run DIR]...
       (run from the repository root; reads records/cloud, and records/source/import_graph.json.gz for --closure-run)
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


def results_by_how(path, how):
    """Passing leanchecker lines whose eighth field (how the tool was run) begins with `how`: (module, seconds, epoch)."""
    rows = []
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) >= 8 and f[5] == "leanchecker" and f[7].startswith(how) and f[1] == "0":
                rows.append((f[0], float(f[2]), int(f[4])))
    return rows


def closure_sizes(graph_path, modules):
    """Number of project modules each of `modules` imports, directly or not. (The directory a check is given
    holds one compiled file more than this: the module's own.)"""
    with gzip.open(graph_path, "rt", encoding="utf-8") as fh:
        g = json.load(fh)
    out = {}
    for m in modules:
        seen, stack = set(), [m]
        while stack:
            for y in g.get(stack.pop(), ()):
                if y in g and y not in seen:
                    seen.add(y)
                    stack.append(y)
        out[m] = len(seen)
    return out


def window_stats(rows, ph, labels):
    """One entry per phase whose label begins with one of `labels` and in which at least 20 checks finished.
    rows: (module, seconds, epoch of the result)."""
    out = []
    for k, (t, label, _rest) in enumerate(ph):
        if not label.startswith(labels):
            continue
        end = next((t2 for t2, l2, _r in ph[k + 1:] if t2 >= t and l2 != label), None)
        if end is None:
            continue
        w = [r for r in rows if t < r[2] <= end]
        if len(w) < 20:
            continue
        jobs = int(label.split("=")[1])
        last = max(r[2] for r in w)
        span = last - min(r[2] for r in w) or 1
        first_start = min(r[2] - r[1] for r in w)
        out.append({"window": label, "jobs": jobs, "modules_checked": len(w),
                    "seconds_between_first_and_last_result": span,
                    "modules_per_second": round(len(w) / span, 2),
                    "job_seconds_per_module": round(jobs * span / len(w), 2),
                    "mean_seconds_per_check": round(statistics.mean(r[1] for r in w), 2),
                    "mean_checks_in_flight": round(sum(r[1] for r in w) / float((last - first_start) or 1), 1),
                    "_rows": w})
    return out


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
    ap.add_argument("--closure-run", action="append", default=[],
                    help="directory of a recorded run in which leanchecker had only each module's import closure on its search path")
    ap.add_argument("--graph", default="records/source/import_graph.json.gz", help="the import graph, for --closure-run")
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
    # leanchecker with a search path that holds, of the project, only the module's import closure (hard links):
    # the listing then covers the libraries and that closure, and the links have to be made and removed.
    LINK_SECONDS = 0.00006            # assumed: making and removing one hard link, 30 microseconds each way
    closure_dir = fixed + per_file * (LIBRARY_FILES + mean_closure_tree) + closure + LINK_SECONDS * mean_closure_tree
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
                       "leanchecker_with_only_the_import_closure_on_the_search_path": {
                           "seconds_per_check": round(closure_dir, 1), "hours_at_32": hours(closure_dir),
                           "of_which_listing": round(per_file * (LIBRARY_FILES + mean_closure_tree), 1),
                           "of_which_making_and_removing_links_assumed": round(LINK_SECONDS * mean_closure_tree, 2),
                           "note": "a projection from the fit; this way of running leanchecker has not been timed on the cloud machine"},
                       "without_the_listing": {"seconds_per_check": round(direct, 1), "hours_at_32": hours(direct),
                                               "note": "a projection from the stock tool's fit (its fixed and closure terms); not a measurement of rhv-replay"}},
        "earlier_estimate_it_replaces": {"hours": est["hours"]["expected"]["check_hours"],
                                         "why_it_was_wrong": "it took the cost per check measured with 29,633 modules compiled as the cost at any size"},
    }
    # The first point is the mean over the third rehearsal's main pass. The trial at 32 just before it, in the
    # same run and also with 32 checks in flight, gave a different mean. The line moves with that choice.
    r3rows = [(r[0], r[2], r[3]) for r in results(os.path.join(r3, "c3_results.tsv.gz")) if r[1] == 0]
    r3trial = [w for w in window_stats(r3rows, ph, ("check_trial:N=",)) if w["jobs"] == JOBS]
    if r3trial:
        y1t = r3trial[0]["mean_seconds_per_check"] - per_import * p1["mean_closure"]
        pf_t = (y2 - y1t) / (p2["files_on_search_path"] - p1["files_on_search_path"])
        fx_t = y1t - pf_t * p1["files_on_search_path"]
        out["if_the_first_point_were_that_runs_trial_at_32"] = {
            "mean_seconds_per_check": r3trial[0]["mean_seconds_per_check"], "checks_counted": r3trial[0]["modules_checked"],
            "mean_checks_in_flight": r3trial[0]["mean_checks_in_flight"],
            "fixed": round(fx_t, 2), "per_compiled_file_on_the_search_path": round(pf_t, 6),
            "whole_tree_hours_at_32": {
                "leanchecker_one_process_per_module": hours(fx_t + pf_t * files_tree + closure),
                "leanchecker_with_only_the_import_closure_on_the_search_path":
                    hours(fx_t + pf_t * (LIBRARY_FILES + mean_closure_tree) + closure + LINK_SECONDS * mean_closure_tree)},
            "note": "the same run and the same job count as the first point, a few minutes earlier; the two means differ by more "
                    "than the whole of the saving the line predicts for a shorter search path at this size of tree"}
    # The whole run, with the build and the allowances of pilot_estimate.json and the replay as fitted here.
    # Priced as there: billed hours at the machine's and the disk's hourly rates, plus the disk for six hours more.
    cfg = est["configurations"][0]
    rate = cfg["machine_usd_per_hour"] + cfg["disk_usd_per_hour"]
    stock_sample = 2000                                   # modules the stock tool checks again after rhv-replay
    prefix_pass_hours = 0.3                               # allowance: 114 prefix modules with the modules beneath them
    def whole_run(fixed_rhv):
        """Billed hours and cost by method and case; fixed_rhv is rhv-replay's cost per module before the closure term."""
        runs = {}
        for method in ("leanchecker, whole library on the search path", "leanchecker, import closure on the search path", "rhv-replay"):
            runs[method] = {}
            for case in ("low", "expected", "high"):
                c, h = est["cases"][case], est["hours"][case]
                closure_c = per_import * c["chk_slope"] * mean_closure_tree
                if method.startswith("leanchecker, whole"):
                    check = TREE_MODULES * (fixed + listing + closure_c) / JOBS / c["chk_eff"] / 3600.0
                elif method.startswith("leanchecker, import"):
                    check = TREE_MODULES * (closure_dir - closure + closure_c) / JOBS / c["chk_eff"] / 3600.0
                else:
                    check = (TREE_MODULES * (fixed_rhv + closure_c) + stock_sample * (fixed + listing + closure_c)) / JOBS / c["chk_eff"] / 3600.0 + prefix_pass_hours
                billed = h["build_hours"] + h["other_hours"] + check
                runs[method][case] = {"build_hours": h["build_hours"], "replay_hours": round(check, 1), "other_hours": h["other_hours"],
                                      "billed_hours": round(billed, 1), "usd": round(billed * rate + 6 * cfg["disk_usd_per_hour"])}
        return runs
    out["whole_run"] = {"configuration": cfg["name"], "usd_per_billed_hour": round(rate, 3),
                        "the_rhv_replay_rows_include_the_stock_tool_on": "%d random modules and every prefix module, as an earlier design had it" % stock_sample,
                        "rhv_replay_cost_per_module_before_the_closure_term": {"seconds": round(fixed, 2), "source": "the fit's fixed term (no run of rhv-replay was given)"},
                        "by_method_for_the_whole_tree": whole_run(fixed)}
    drv = []
    for d in a.driver_run:
        f = os.path.join(d, "c3_results.tsv.gz")
        if not os.path.exists(f):
            continue
        ph = phases(os.path.join(d, "phases.tsv"))
        allrows = [r for r in results(f, "rhv-replay") if r[1] == 0]
        windows = []
        # Every window in which rhv-replay ran: the trials and the main pass. A window's rate is taken between
        # its first and its last result, which leaves out the time the script spends planning before the first.
        for k, (t, label, _rest) in enumerate(ph):
            if not label.startswith(("check_trial:N=", "check:N=", "check_second:N=")):
                continue
            end = next((t2 for t2, l2, _r in ph[k + 1:] if t2 >= t and l2 != label), None)
            if end is None:
                continue
            rows = [r for r in allrows if t < r[3] <= end]
            if len(rows) < 20:
                continue
            jobs = int(label.split("=")[1])
            span = max(r[3] for r in rows) - min(r[3] for r in rows) or 1
            # A window with few modules for its job count is the tail of a run, with most jobs idle: it is
            # listed, but it is not a measure of throughput.
            windows.append({"window": label, "jobs": jobs, "modules_replayed": len(rows), "all_jobs_busy": len(rows) >= 10 * jobs,
                            "seconds_between_first_and_last_result": span,
                            "modules_per_second": round(len(rows) / span, 1),
                            "job_seconds_per_module": round(jobs * span / len(rows), 2),
                            "mean_seconds_inside_the_replay_per_module": round(statistics.mean(r[2] for r in rows), 2)})
        if windows:
            n = oleans(os.path.join(d, "disk.txt"))
            at32 = [w for w in windows if w["jobs"] == JOBS and w["all_jobs_busy"]]
            entry = {"run": os.path.basename(d.rstrip("/")), "compiled_modules": n, "windows": windows}
            if at32:
                js = sum(w["jobs"] * w["seconds_between_first_and_last_result"] for w in at32) / float(sum(w["modules_replayed"] for w in at32))
                entry["at_32_job_seconds_per_module"] = round(js, 2)
                entry["the_fit_above_had_projected"] = round(fixed, 2)
                # The projection for the whole tree again, with the fixed term replaced by what was measured here.
                # The closure term is still the stock tool's; rhv-replay has not been timed on deep modules.
                sweep = TREE_MODULES * (js + closure) / JOBS / 3600.0
                extra = stock_sample * stock / JOBS / 3600.0 + prefix_pass_hours
                h = est["hours"]["expected"]
                billed = h["build_hours"] + h["other_hours"] + sweep + extra
                entry["whole_tree"] = {"seconds_per_module": round(js + closure, 2), "replay_hours_at_32": round(sweep, 1),
                                       "with_the_stock_tool_on_a_sample_and_the_prefix_modules": round(sweep + extra, 1),
                                       "whole_run_expected_billed_hours": round(billed, 1),
                                       "whole_run_expected_usd": round(billed * rate + 6 * cfg["disk_usd_per_hour"])}
                # What that measurement says about the stock tool: its cost with this many files, less the cost
                # without the listing, is the listing itself, at two sizes of tree. Three ways to carry that to
                # the whole tree bracket the answer.
                l1 = p1["mean_seconds_per_check"] - js
                l2 = p2["mean_seconds_per_check"] - per_import * p2["mean_closure"] - js
                f1, f2 = float(p1["files_on_search_path"]), float(p2["files_on_search_path"])
                if l1 > 0 and l2 > l1:
                    import math
                    expo = math.log(l2 / l1) / math.log(f2 / f1)
                    ways = {"in_proportion_to_the_files_from_the_larger_measurement": l2 * files_tree / f2,
                            "a_line_through_the_two_measurements": l1 + (l2 - l1) * (files_tree - f1) / (f2 - f1),
                            "a_power_law_through_the_two_measurements": l2 * (files_tree / f2) ** expo}
                    entry["what_it_implies_for_leanchecker"] = {
                        "listing_seconds_per_check": {"with_%d_files" % f1: round(l1, 2), "with_%d_files" % f2: round(l2, 2)},
                        "power_law_exponent": round(expo, 2),
                        "whole_tree_replay_hours_at_32": {k: round(TREE_MODULES * (v + js + closure) / JOBS / 3600.0, 1) for k, v in ways.items()}}
            drv.append(entry)
    if drv:
        out["rhv_replay_measured"] = drv
        measured = [e["at_32_job_seconds_per_module"] for e in drv if "at_32_job_seconds_per_module" in e]
        if measured:
            # The whole-run table again, with rhv-replay's cost as measured in the last run given.
            out["whole_run"]["rhv_replay_cost_per_module_before_the_closure_term"] = {
                "seconds": measured[-1], "source": "measured at 32 at a time in " + [e["run"] for e in drv if "at_32_job_seconds_per_module" in e][-1]}
            out["whole_run"]["by_method_for_the_whole_tree"] = whole_run(measured[-1])
    # Runs in which leanchecker had only the module's import closure on its search path. What they measured is
    # compared like with like: the trial at 32 at a time here with the trial at 32 at a time of the run that gave
    # the fit its first point, once as throughput and once as seconds per check. (A main pass is not used: modules
    # are handed out 25 to a worker, and a pass of 635 modules makes 26 workers where 32 were allowed, so its
    # checks ran with fewer in flight and cost less each.)
    clo = []
    for d in a.closure_run:
        f = os.path.join(d, "c3_results.tsv.gz")
        if not os.path.exists(f):
            continue
        allrows = results_by_how(f, "import-closure-directory")
        sizes = closure_sizes(a.graph, [r[0] for r in allrows])
        windows = window_stats(allrows, phases(os.path.join(d, "phases.tsv")), ("check_trial:N=", "check:N="))
        if not windows:
            continue
        for w in windows:
            w["mean_closure"] = round(statistics.mean(sizes[r[0]] for r in w["_rows"]), 1)
            w["largest_closure"] = max(sizes[r[0]] for r in w["_rows"])
        entry = {"run": os.path.basename(d.rstrip("/")), "compiled_modules": oleans(os.path.join(d, "disk.txt")),
                 "modules_passed_this_way": len(allrows),
                 "mean_closure_of_all_of_them": round(statistics.mean(sizes.values()), 1), "largest_closure": max(sizes.values()),
                 "windows": windows}
        trial = [w for w in windows if w["jobs"] == JOBS and w["window"].startswith("check_trial")]
        if trial and r3trial:
            tw, rw = trial[0], r3trial[0]
            files_here = LIBRARY_FILES + tw["mean_closure"] + 1
            fit_here = fixed + per_file * files_here + per_import * tw["mean_closure"] + LINK_SECONDS * tw["mean_closure"]
            fit_ref = fixed + per_file * p1["files_on_search_path"]
            predicted = fit_here / fit_ref
            by_throughput = tw["job_seconds_per_module"] / rw["job_seconds_per_module"]
            by_check = tw["mean_seconds_per_check"] / rw["mean_seconds_per_check"]
            excess = sorted([by_check / predicted - 1, by_throughput / predicted - 1])
            entry["trial_at_32_against_the_same_trial_with_the_whole_library_on_the_path"] = {
                "this_run": {"files_on_the_search_path": int(round(files_here)), "mean_closure": tw["mean_closure"],
                             "modules_checked": tw["modules_checked"], "job_seconds_per_module": tw["job_seconds_per_module"],
                             "mean_seconds_per_check": tw["mean_seconds_per_check"], "mean_checks_in_flight": tw["mean_checks_in_flight"]},
                "the_other_run": {"run": p1["run"], "files_on_the_search_path": p1["files_on_search_path"],
                                  "modules_checked": rw["modules_checked"], "job_seconds_per_module": rw["job_seconds_per_module"],
                                  "mean_seconds_per_check": rw["mean_seconds_per_check"], "mean_checks_in_flight": rw["mean_checks_in_flight"]},
                "this_run_over_the_other": {"the_fit_predicts": round(predicted, 3), "measured_as_throughput": round(by_throughput, 3),
                                            "measured_as_seconds_per_check": round(by_check, 3)},
                "above_what_the_fit_predicts_percent": [round(100 * excess[0], 1), round(100 * excess[1], 1)],
                "whole_tree_replay_hours_at_32_if_that_held": [hours(closure_dir * (1 + excess[0])), hours(closure_dir * (1 + excess[1]))],
                "note": "the fit predicts a saving of %.2f seconds per check from the shorter search path; the two measures put this run "
                        "%.1f and %.1f percent above that, which is no more than a trial and a main pass of one run differ by. The modules "
                        "timed here import %.1f others on average, against %d for the tree: the run says what a check costs with a "
                        "short search path on the cloud machine, and nothing about making the links of a deep module or replaying one"
                        % (fit_ref - fit_here, 100 * excess[0], 100 * excess[1], tw["mean_closure"], round(mean_closure_tree))}
        for w in windows:
            del w["_rows"]
        clo.append(entry)
    for w in r3trial:
        w.pop("_rows", None)
    if clo:
        out["leanchecker_with_import_closure_directories_measured"] = clo
        out["whole_tree"]["leanchecker_with_only_the_import_closure_on_the_search_path"]["note"] = (
            "a projection from the fit. This way of running leanchecker has been timed on the cloud machine only on a "
            "small tree of shallow modules (leanchecker_with_import_closure_directories_measured, below)")
    text = json.dumps(out, indent=1)
    print(text)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
