#!/usr/bin/env python3
"""spot_resume_model.py - what a resumable Spot run costs if Google takes the machine back every M hours on average.

The question it answers: at what reclaim frequency does Spot stop being worth it? Google publishes no reclaim
  rate, so the mean time between reclaims, M, is the free variable. For each M in a list the script simulates
  many runs of the full-spot design (the launcher's `launch full-spot` and the guest's Spot path) and
  reports what they bill, how often the launcher's rules pause them, and what is lost to reclaims.

What it models, attempt by attempt, as the design does it:
  - Every attempt is a fresh machine: boot and setup each time, then a restore of the saved parts whose length
    grows with the share of the build already saved (before the seal), or a fixed restore plus the seal's
    steps again (after it).
  - The build can be split: archives ("parts") are cut every checkpoint interval, and a reclaim loses
    everything since the last part whose upload had finished. The top of the import graph is treated as
    units that cannot be split, as are the seal, the axiom checks and the replay trials: a unit cut short is
    run again from zero. The main replay can be split: its results are saved every twenty minutes, each time
    after a full hash of the compiled files on the same machine has confirmed that nothing changed; a reclaim
    loses the results since the last save. Each axiom check ends with one such hash before it is recorded.
  - A reclaim gives no notice the model relies on. At its own deadline (15 minutes before Google deletes it)
    an attempt saves what it has and pauses; a unit cut short there is still lost.
  - The launcher (watch) sizes each attempt to what the cap leaves, starts no attempt shorter than the minimum,
    and pauses the run when: the attempt limit is reached; three attempts in a row saved nothing; the cap
    leaves no room for an attempt of the minimum length; or the give-up time has passed.
  The time to the next reclaim is drawn afresh for each attempt (each is a new machine). With the default
  shape 1 that is a Poisson process of reclaims; another --shape gives a Weibull time to reclaim with the same
  mean, which bunches reclaims early (shape < 1) or late (shape > 1) in a machine's life.

  Two regimes are reported for each M. "To finish": the launcher's pause rules and the cap switched off, so
  every run finishes and its full cost shows. "Under the launcher's rules": cap, attempt limit, no-progress
  rule and give-up time as configured, so some runs pause. A paused run loses nothing that was saved: it can
  be continued once the owner allows more.

Every input has a label: "measured" (a recorded run timed it), "estimated" (a projection from records),
  "guess" (no record supports the figure), or "setting" (a value the design or the owner chose). The sources
  are named in the output.

Deterministic: the same inputs give the same output, byte for byte (fixed seed; the same random numbers are
  used for every M, so the curves are smooth in M). Standard library only; Python 3.9 or later.

What it changes on disk: writes the JSON named by --out, if given. Nothing else. It reads nothing.
How long it takes: about half a minute with the defaults.

Usage: python3 analysis/spot_resume_model.py [--out FILE] [--runs N] [--seed S] [--<input> VALUE]...
       (python3 analysis/spot_resume_model.py --out records/cloud/spot_resume_model.json writes the record)
"""
import argparse
import json
import math
import random
import statistics
import sys

# name, default, label, source, meaning. Every one becomes a command-line option (--name-with-dashes).
INPUTS = [
    # Per attempt
    ("setup_h", 0.10, "estimated",
     "setup.tsv of the pilot and six rehearsals: 76-137 s from guest start to first compile (measured); plus about "
     "236 s of boot and teardown, from rehearsal 6's 1,487 s billed against 1,251 s elapsed in the guest (derived)",
     "boot, setup and teardown of one attempt's fresh machine, hours"),
    ("restore_before_seal_h", 0.15, "guess",
     "no restore has been timed; about 140 GB of compiled files, about 41 GB as zstd parts (0.23 MB a module in "
     "the rehearsals' keep archives, measured small)",
     "restore of the whole tree's parts before the seal, hours; scaled by the share of the build saved"),
    ("restore_after_seal_h", 0.25, "guess",
     "restore of every part plus the seal's steps again on the new machine; the seal took 28 s on 1,663 modules "
     "(rehearsal 6 phases.tsv) and has not been timed at full scale",
     "restore plus the seal's steps again, on an attempt that starts after the seal, hours"),
    # Stages
    ("build_h", 15.6, "estimated",
     "records/cloud/replay_cost.json whole_run, expected (low 13.7, high 17.9)",
     "the build, hours, including the top of the import graph"),
    ("top_h", 0.4, "estimated",
     "allowance for the top of the import graph in records/cloud/replay_cost.json (0.2 / 0.4 / 1.0); nothing with "
     "an import closure above 17,860 has been compiled",
     "the part of the build at the top of the import graph that is treated as units that cannot be split, hours"),
    ("top_units", 1, "guess",
     "modelling choice: one unit is the harshest reading (a reclaim anywhere in it loses all of it)",
     "how many equal units the top of the import graph is split into"),
    ("ckpt_min", 10.0, "setting",
     "GCP_SPOT_CKPT_EVERY = 600 s",
     "minutes between parts during the build"),
    ("ckpt_lag_min", 1.0, "guess",
     "settle margin 5 s, then compressing and uploading about 10 minutes of compiled output (about 1.4 GB, about "
     "0.4 GB as a part); upload throughput to the bucket has not been measured",
     "minutes from a part's cut to its manifest upload finishing, during which its work is not yet saved"),
    ("seal_h", 0.25, "guess",
     "28 s on 1,663 modules in rehearsal 6 (measured small); not timed at full scale",
     "the seal, hours (cannot be split)"),
    ("c2_plain_h", 0.1, "guess",
     "the plain and deep axiom checks together have an allowance of 0.2 / 0.5 / 2.0 h (analysis/pilot_estimate.py); "
     "5 s in rehearsal probe mode; the split between them is a guess",
     "the plain axiom check, hours (cannot be split)"),
    ("trials_h", 0.25, "estimated",
     "the full run spends the first 15 minutes of its replay on trials (docs/cloud-notes.md); about 90 s each in "
     "the rehearsals",
     "the replay trials and the choice of job count, hours (cannot be split)"),
    ("c2_deep_h", 0.5, "estimated",
     "allowance 0.5 h expected, 2 h high (time box 7,200 s); never run on the full tree",
     "the deep axiom check, hours (cannot be split)"),
    ("replay_h", 8.8, "estimated",
     "8.5 h from the fit in records/cloud/replay_cost.json, plus the rehearsal's 4-8 % excess",
     "the main replay, hours"),
    ("replay_save_min", 20.0, "setting",
     "GCP_SPOT_CONFIRM_EVERY = 1200 s: the replay's results are saved only after a full hash of the compiled files, "
     "the toolchain copy and the library files on the same machine confirms that nothing changed (docs/cloud-notes.md section 10)",
     "minutes between saves of the replay's results"),
    ("confirm_min", 5.0, "guess",
     "a full hash of about 0.13 TB of compiled files with four processes while the replay runs; never timed at full "
     "scale (the end check's hash took 3 s on 1,663 modules in rehearsal 6)",
     "minutes one confirming hash takes: results written during it wait for the next save, and each axiom check ends with one"),
    ("confirm_share", 0.125, "setting",
     "four hashing processes on a machine of 32 threads",
     "share of the machine a confirming hash takes from the replay while it runs"),
    # Ending an attempt
    ("deadline_margin_h", 0.25, "setting",
     "the guest's deadline is 900 s before the attempt's maximum run time (cloud/gcp/pilot_local.sh)",
     "the guest's own deadline comes this long before Google deletes the machine, hours"),
    ("pause_winddown_h", 0.1, "guess",
     "last part, uploads, status PAUSED, and the watcher's delete after the guest's deadline",
     "billed time after the guest's deadline in an attempt that pauses, hours"),
    ("detect_lag_h", 0.02, "guess",
     "watch polls every 45 s (facts on the launcher), then deletes and verifies",
     "time after a reclaim that the ledger still counts (Google bills nothing for it), hours"),
    ("gap_h", 0.1, "guess",
     "the watcher notices, closes the row and creates the next machine; capacity waits are not modelled",
     "wall-clock time between attempts (counts towards the give-up time; bills nothing), hours"),
    # The launcher's rules
    ("max_attempts", 24, "setting", "GCP_SPOT_MAX_ATTEMPTS", "the run pauses when this many attempts have been started"),
    ("noprogress_limit", 3, "setting", "the pause rules of `watch` (cloud/gcp/pilot_local.sh)", "the run pauses after this many attempts in a row that saved nothing"),
    ("min_attempt_h", 1.5, "setting", "GCP_SPOT_MIN_ATTEMPT_SECONDS = 5400", "no attempt shorter than this is started, hours"),
    ("giveup_h", 120.0, "setting", "GCP_SPOT_GIVEUP_HOURS", "no attempt starts later than this after the first launch, hours"),
    ("mode_limit_h", 42.0, "setting", "151200 s for full-spot (cloud/gcp/pilot_local.sh)", "the longest attempt, hours"),
    # Money
    ("cap_usd", 50.0, "setting", "docs/cloud-notes.md section 8.6", "the spending cap, USD"),
    ("spent_usd", 9.86, "measured", "the launcher's ledger after the sixth rehearsal (docs/cloud-notes.md section 8.6)", "recorded spend before the run, USD"),
    ("reserve_usd", 1.00, "setting", "GCP_SPOT_RESERVE_USD: held back for bucket storage of the parts", "held back from the cap, USD"),
    ("spot_list_usd_h", 1.10, "estimated",
     "us-central1 list prices read 2026-11-20/21: machine 1.0136 Spot, disks 0.083, address 0.0025 (1.097-1.105 all-in); "
     "Spot prices can change daily",
     "what Google charges for an hour of a Spot attempt, all in, USD"),
    ("spot_ledger_usd_h", 1.20, "setting", "GCP_SPOT_RATE_USD_PER_HOUR", "what the ledger and the cap count for an hour of a Spot attempt, USD"),
    ("od_list_usd_h", 1.87, "estimated", "us-central1 list prices: 1.862-1.868 all-in on demand (docs/cloud-notes.md)", "on demand, list, all in, USD an hour"),
    ("od_ledger_usd_h", 2.00, "setting", "GCP_RATE_USD_PER_HOUR default (docs/cloud-notes.md section 8.6)", "on demand, as the ledger counts it, USD an hour"),
    ("shape", 1.0, "guess",
     "1 is a Poisson process; Google publishes nothing on how reclaims are spread over a machine's life",
     "shape of the Weibull time to reclaim of one attempt (1 = exponential); the mean is M whatever the shape"),
]
INT_INPUTS = ("top_units", "max_attempts", "noprogress_limit")
M_LIST = [0.5, 1, 2, 3, 4, 6, 8, 12, 24, 48, None]          # None: never reclaimed
SAFETY_ATTEMPTS = 400                                        # "to finish" runs give up here (counted, reported)
INF = float("inf")


def r(x, n=2):
    return None if x is None else (round(x, n) if x != INF else "inf")


def pct(xs, q):
    """Nearest-rank percentile of a list (deterministic, no interpolation)."""
    s = sorted(xs)
    if not s:
        return None
    k = max(0, min(len(s) - 1, int(math.ceil(q * len(s))) - 1))
    return s[k]


class Plan(object):
    """The work of one run: stages in order, each (name, splittable, hours, save_every_h, save_lag_h, group)."""

    def __init__(self, stages, setup, restore, first_setup=True, exposed=True):
        self.stages = stages
        self.setup = setup
        self.restore = restore          # function (stage index, saved hours in that stage) -> hours
        self.first_setup = first_setup  # does attempt 1 pay the setup? (False only in a check)
        self.exposed = exposed          # can a reclaim strike during setup and restore? (False only in a check)
        self.work = sum(s[2] for s in stages)
        self.base = self.work + (setup if first_setup else 0.0)
        self.od_base = self.base        # the same work on demand: design_plan lowers it by the confirming hashes


def design_plan(p):
    k = max(1, int(p["top_units"]))
    stages = [("build", True, p["build_h"] - p["top_h"], p["ckpt_min"] / 60.0, p["ckpt_lag_min"] / 60.0, "build")]
    for j in range(k):
        stages.append(("top of the import graph", False, p["top_h"] / k, 0.0, 0.0, "build"))
    # What only a Spot run pays: a confirming hash after each axiom check, and one every save interval during the
    # replay, which takes a share of the machine from the replay while it runs.
    c = p["confirm_min"] / 60.0
    slow = 1.0 + p["confirm_share"] * p["confirm_min"] / p["replay_save_min"] if p["replay_save_min"] > 0 else 1.0
    stages += [("seal", False, p["seal_h"], 0.0, 0.0, "seal"),
               ("axiom check, plain", False, p["c2_plain_h"] + c, 0.0, 0.0, "after"),
               ("replay trials", False, p["trials_h"], 0.0, 0.0, "after"),
               ("axiom check, deep", False, p["c2_deep_h"] + c, 0.0, 0.0, "after"),
               ("main replay", True, p["replay_h"] * slow, p["replay_save_min"] / 60.0, c, "after")]
    stages = [s for s in stages if s[2] > 0]
    confirms = 2.0 * c + p["replay_h"] * (slow - 1.0)
    seal_i = [i for i, s in enumerate(stages) if s[5] == "seal"][0]
    before = []
    acc = 0.0
    for s in stages:
        before.append(acc)
        if s[5] == "build":
            acc += s[2]
    build_total = acc

    def restore(i, done):
        if i > seal_i:
            return p["restore_after_seal_h"]
        saved = before[min(i, len(before) - 1)] + (done if stages[i][5] == "build" else 0.0)
        return p["restore_before_seal_h"] * saved / build_total

    plan = Plan(stages, p["setup_h"], restore)
    plan.od_base = plan.base - confirms
    return plan


class Rules(object):
    def __init__(self, p, limits):
        self.limits = limits
        self.p = p
        self.cap_avail_usd = p["cap_usd"] - p["spent_usd"] - p["reserve_usd"] - 0.01


def draw(M, shape, rng):
    if M is None:
        return INF
    e = -math.log(1.0 - rng.random())
    if shape == 1.0:
        return M * e
    return M / math.gamma(1.0 + 1.0 / shape) * e ** (1.0 / shape)


def run_once(plan, rules, M, shape, rng):
    p = rules.p
    stages, n = plan.stages, len(plan.stages)
    i, done = 0, 0.0
    billed = ledger = wall = 0.0
    attempts = noprog = 0
    over = redo = wind = lag = 0.0
    outcome = None
    while True:
        if rules.limits:
            if attempts >= p["max_attempts"]:
                outcome = "attempt limit"
                break
            if noprog >= p["noprogress_limit"]:
                outcome = "no progress"
                break
            if wall >= p["giveup_h"]:
                outcome = "give-up time"
                break
            avail = rules.cap_avail_usd - ledger * p["spot_ledger_usd_h"]
            by_cap = math.floor(3600.0 * avail / p["spot_ledger_usd_h"] + 1e-9) / 3600.0 - 120 / 3600.0
            by_giveup = p["giveup_h"] - wall
            maxrun = min(p["mode_limit_h"], by_giveup, by_cap)
            if maxrun < p["min_attempt_h"]:
                outcome = "cap" if by_cap <= by_giveup else "give-up time"
                break
        else:
            if attempts >= SAFETY_ATTEMPTS:
                outcome = "safety stop"
                break
            maxrun = p["mode_limit_h"]
        if attempts:
            wall += p["gap_h"]
        attempts += 1
        deadline = maxrun - p["deadline_margin_h"]
        overhead = (plan.setup if (attempts > 1 or plan.first_setup) else 0.0) + plan.restore(i, done)
        tr = draw(M, shape, rng)
        if not plan.exposed:
            tr += overhead
        reclaimed = tr <= deadline
        end = tr if reclaimed else deadline
        progressed = False
        if end <= overhead:
            over += end
            t = end
        else:
            over += overhead
            t = overhead
            while i < n:
                _name, split, h, every, slag, _g = stages[i]
                rem = h - done
                if t + rem <= end + 1e-12:
                    t += rem
                    i += 1
                    done = 0.0
                    progressed = True
                    continue
                w = end - t
                if split:
                    if reclaimed:
                        saved = every * math.floor(max(0.0, w - slag) / every + 1e-12) if every > 0 else 0.0
                        saved = min(saved, rem)
                    else:
                        saved = w                      # the attempt's own deadline: the last part is cut and kept
                    done += saved
                    redo += w - saved
                    if saved > 0:
                        progressed = True
                else:
                    redo += w                          # a unit cut short is run again from zero
                t = end
                break
        finished = i >= n
        if finished:
            a_billed = t
            a_lag = 0.0
        elif reclaimed:
            a_billed = end
            a_lag = p["detect_lag_h"]
        else:
            a_billed = min(deadline + p["pause_winddown_h"], maxrun)
            wind += a_billed - deadline
            a_lag = 0.0
        a_ledger = min(a_billed + a_lag, maxrun + 120 / 3600.0)
        lag += a_ledger - a_billed
        billed += a_billed
        ledger += a_ledger
        wall += a_billed
        noprog = 0 if progressed else noprog + 1
        if finished:
            outcome = "finished"
            break
    if rules.limits:
        # Recorded spend may never pass the cap (less the reserve): the launcher's sizing guarantees it.
        assert p["spent_usd"] + ledger * p["spot_ledger_usd_h"] <= p["cap_usd"] - p["reserve_usd"] + 1e-6
    return {"outcome": outcome, "billed": billed, "ledger": ledger, "attempts": attempts, "wall": wall,
            "over_extra": over - (plan.setup if plan.first_setup else 0.0), "redo": redo, "wind": wind, "lag": lag}


def simulate(plan, rules, M, shape, runs, seed):
    out = []
    for k in range(runs):
        rng = random.Random(seed * 1000003 + k)      # the same numbers for every M: common random numbers
        out.append(run_once(plan, rules, M, shape, rng))
    return out


def summarise(p, plan, fin, ruled):
    od_list = plan.od_base * p["od_list_usd_h"]
    od_ledger = plan.od_base * p["od_ledger_usd_h"]
    ok = [x for x in fin if x["outcome"] == "finished"]
    hrs = [x["billed"] for x in ok]
    att = [x["attempts"] for x in ok]
    usd_l = [x["billed"] * p["spot_list_usd_h"] for x in ok]
    usd_g = [x["ledger"] * p["spot_ledger_usd_h"] for x in ok]
    n = float(len(ruled))
    shares = {}
    for name in ("finished", "attempt limit", "no progress", "cap", "give-up time"):
        shares[name] = round(sum(1 for x in ruled if x["outcome"] == name) / n, 3)
    rspent = [p["spent_usd"] + x["ledger"] * p["spot_ledger_usd_h"] for x in ruled]
    cap_hours = (p["cap_usd"] - p["spent_usd"] - p["reserve_usd"]) / p["spot_ledger_usd_h"]
    to_finish = {
        "runs_that_hit_the_safety_stop": len(fin) - len(ok),
        "billed_hours": {"median": r(statistics.median(hrs), 1), "p90": r(pct(hrs, 0.9), 1), "mean": r(statistics.mean(hrs), 2)},
        "attempts": {"median": statistics.median(att), "p90": pct(att, 0.9), "mean": r(statistics.mean(att), 2)},
        "usd_at_list_rate": {"median": r(statistics.median(usd_l)), "p90": r(pct(usd_l, 0.9)), "mean": r(statistics.mean(usd_l))},
        "usd_at_ledger_rate": {"median": r(statistics.median(usd_g)), "p90": r(pct(usd_g, 0.9)), "mean": r(statistics.mean(usd_g))},
        "saving_against_on_demand_usd": {
            "list": {"median": r(od_list - statistics.median(usd_l)), "p10_worst": r(od_list - pct(usd_l, 0.9))},
            "ledger": {"median": r(od_ledger - statistics.median(usd_g)), "p10_worst": r(od_ledger - pct(usd_g, 0.9))}},
        "share_whose_ledger_hours_fit_under_the_cap": round(sum(1 for x in ok if x["ledger"] <= cap_hours + 1e-9) / float(len(fin)), 3),
        "mean_hours_lost_to_reclaims": {
            "setup_and_restore": r(statistics.mean(x["over_extra"] for x in ok)),
            "redone_work": r(statistics.mean(x["redo"] for x in ok)),
            "pause_wind_down": r(statistics.mean(x["wind"] for x in ok), 3),
            "total": r(statistics.mean(x["billed"] for x in ok) - plan.base),
            "ledger_only_detection_lag": r(statistics.mean(x["lag"] for x in ok), 3)},
    }
    rh = [x["billed"] for x in ruled]
    ra = [x["attempts"] for x in ruled]
    under_rules = {
        "share_by_outcome": shares,
        "billed_hours_all_runs": {"median": r(statistics.median(rh), 1), "p90": r(pct(rh, 0.9), 1)},
        "attempts_all_runs": {"median": statistics.median(ra), "p90": pct(ra, 0.9)},
        "recorded_spend_after_the_run_usd": {"median": r(statistics.median(rspent)), "p90": r(pct(rspent, 0.9)), "max": r(max(rspent))},
    }
    return to_finish, under_rules


def bisect(fn, lo, hi, want_above, iters=16):
    """Smallest M in [lo, hi] (log scale) at which fn(M) is on the good side, given fn is monotone in M.
    want_above(v) is True when v is good. Returns (M, note)."""
    if want_above(fn(lo)):
        return lo, "already good at the lowest M tried"
    if not want_above(fn(hi)):
        return hi, "not good even at the highest M tried"
    a, b = math.log(lo), math.log(hi)
    for _ in range(iters):
        m = 0.5 * (a + b)
        if want_above(fn(math.exp(m))):
            b = m
        else:
            a = m
    return math.exp(b), ""


def thresholds(p, runs, seed):
    plan = design_plan(p)
    free, lim = Rules(p, False), Rules(p, True)
    od_list = plan.od_base * p["od_list_usd_h"]
    od_ledger = plan.od_base * p["od_ledger_usd_h"]
    cache = {}

    def fin(M):
        key = ("f", round(M, 9))
        if key not in cache:
            cache[key] = simulate(plan, free, M, p["shape"], runs, seed)
        return cache[key]

    def ruled(M):
        key = ("r", round(M, 9))
        if key not in cache:
            cache[key] = simulate(plan, lim, M, p["shape"], runs, seed)
        return cache[key]

    def cost(xs, rate, key):
        v = [x[key] * rate if x["outcome"] == "finished" else INF for x in xs]
        return v

    lo, hi = 0.25, 48.0
    m_list, n1 = bisect(lambda M: statistics.mean(cost(fin(M), p["spot_list_usd_h"], "billed")), lo, hi, lambda v: v <= od_list)
    m_ledger, n2 = bisect(lambda M: statistics.mean(cost(fin(M), p["spot_ledger_usd_h"], "ledger")), lo, hi, lambda v: v <= od_ledger)
    m_list90, n3 = bisect(lambda M: pct(cost(fin(M), p["spot_list_usd_h"], "billed"), 0.9), lo, hi, lambda v: v <= od_list)
    share = lambda M: sum(1 for x in ruled(M) if x["outcome"] == "finished") / float(runs)
    m_half, n4 = bisect(share, lo, hi, lambda v: v >= 0.5)
    m_ninety, n5 = bisect(share, lo, hi, lambda v: v >= 0.9)
    return {
        "spot_costs_more_than_on_demand_below_M_hours": {
            "expected_cost_at_list_rates": r(m_list), "expected_cost_at_ledger_rates": r(m_ledger),
            "in_one_run_in_ten_at_list_rates": r(m_list90),
            "notes": [x for x in (n1, n2, n3) if x]},
        "run_usually_cannot_finish_under_the_cap_below_M_hours": {
            "half_of_runs_finish": r(m_half), "nine_runs_in_ten_finish": r(m_ninety),
            "notes": [x for x in (n4, n5) if x]},
    }


def closed_forms(p, plan):
    """Approximations that hold when M is long against every unit (loss per reclaim does not depend on M)."""
    st = plan.stages
    rows = []
    weighted = 0.0
    total = plan.base
    # A reclaim during attempt 1's setup loses on average the half of it already done; the next attempt's setup
    # is the one the run needs in any case.
    rows.append({"stage": "setup of attempt 1", "hours": plan.setup, "can_be_split": False,
                 "setup_and_restore_after_a_reclaim": r(plan.setup / 2.0, 3), "redone_work": 0.0,
                 "hours_lost_per_reclaim": r(plan.setup / 2.0, 3)})
    weighted += plan.setup * (plan.setup / 2.0)
    for i, (name, split, h, every, slag, grp) in enumerate(st):
        # The restore is the average over the stage (it grows through the build).
        ra, rb = plan.restore(i, 0.0), plan.restore(i, h if split else 0.0)
        restore = (ra + rb) / 2.0 if split else ra
        redo = (every / 2.0 + slag) if split else h / 2.0
        loss = plan.setup + restore + redo
        rows.append({"stage": name, "hours": h, "can_be_split": split,
                     "setup_and_restore_after_a_reclaim": r(plan.setup + restore, 3), "redone_work": r(redo, 3),
                     "hours_lost_per_reclaim": r(loss, 3)})
        weighted += h * loss
    mean_loss = weighted / total
    out = {"hours_lost_per_reclaim_by_stage": rows,
           "mean_hours_lost_per_reclaim_weighted_by_time": r(mean_loss, 3),
           "how": "each reclaim costs setup + restore + the work since the last save; billed = base + N x loss and, for a "
                  "Poisson process, N = billed / M, so billed = base / (1 - loss / M)"}
    for tag, sr, odr in (("list", p["spot_list_usd_h"], p["od_list_usd_h"]), ("ledger", p["spot_ledger_usd_h"], p["od_ledger_usd_h"])):
        out["break_even_reclaims_at_%s_rates" % tag] = r((odr * plan.od_base - sr * total) / (sr * mean_loss), 1)
        out["break_even_M_hours_at_%s_rates_first_order" % tag] = r(mean_loss / (1.0 - sr * total / (odr * plan.od_base)), 2)
    cap_hours = (p["cap_usd"] - p["spent_usd"] - p["reserve_usd"]) / p["spot_ledger_usd_h"]
    out["reclaims_the_cap_hours_absorb"] = r((cap_hours - total) / mean_loss, 1)
    out["M_hours_at_which_the_cap_hours_are_used_on_average_first_order"] = r(mean_loss / (1.0 - total / cap_hours), 2)
    out["reclaims_the_attempt_limit_allows"] = int(p["max_attempts"]) - 1
    out["M_hours_at_which_the_attempt_limit_is_reached_on_average_first_order"] = r(mean_loss + total / (p["max_attempts"] - 1), 2)
    # Units that cannot be split: expected time with recovery R, (e^(U/M) - 1)(M + R).
    R = p["setup_h"] + p["restore_after_seal_h"]
    unit = []
    for U in (p["c2_deep_h"], 2.0, p["top_h"], 1.0):
        unit.append({"unit_hours": U, "recovery_hours": R,
                     "expected_hours_by_M": {str(M): r((math.exp(U / M) - 1.0) * (M + R), 2) for M in M_LIST if M is not None}})
    out["unit_that_cannot_be_split"] = {"formula": "(e^(U/M) - 1)(M + R): expected hours to get the unit done, counting "
                                                   "failed tries and recoveries, if the recovery itself is never cut",
                                        "rows": unit}
    return out


def checks(p, runs, seed):
    """The simulation against closed forms in simple cases. Rules off; no deadline matters at these sizes."""
    free = Rules(dict(p, mode_limit_h=1e9, deadline_margin_h=0.0), False)
    out = []
    # 1. One unit of U hours that cannot be split; recovery R paid before every retry and never cut.
    U, R = 2.0, 0.35
    plan = Plan([("unit", False, U, 0.0, 0.0, "x")], R, lambda i, d: 0.0, first_setup=False, exposed=False)
    for M in (1.0, 2.0, 4.0, 8.0):
        sim = statistics.mean(x["billed"] for x in simulate(plan, free, M, 1.0, runs, seed))
        cf = (math.exp(U / M) - 1.0) * (M + R)
        out.append({"case": "unit of %.1f h that cannot be split, recovery %.2f h never cut" % (U, R), "M": M,
                    "simulated": round(sim, 3), "closed_form": round(cf, 3),
                    "difference_percent": round(100.0 * (sim - cf) / cf, 2), "unit": "hours"})
    # 2. W hours that can be split, saved every C hours, no setup: each segment is a unit with no recovery.
    W, C = 4.0, 0.5
    plan = Plan([("work", True, W, C, 0.0, "x")], 0.0, lambda i, d: 0.0, first_setup=False, exposed=True)
    for M in (0.5, 1.0, 2.0, 4.0):
        sim = statistics.mean(x["billed"] for x in simulate(plan, free, M, 1.0, runs, seed))
        cf = (W / C) * M * (math.exp(C / M) - 1.0)
        out.append({"case": "%.0f h that can be split, saved every %.1f h, no setup" % (W, C), "M": M,
                    "simulated": round(sim, 3), "closed_form": round(cf, 3),
                    "difference_percent": round(100.0 * (sim - cf) / cf, 2), "unit": "hours"})
    # 3. The full design: for a Poisson process the mean number of reclaims is the mean billed hours over M.
    plan = design_plan(p)
    free2 = Rules(p, False)
    for M in (2.0, 6.0):
        xs = simulate(plan, free2, M, 1.0, runs, seed)
        sim = statistics.mean(x["attempts"] - 1 for x in xs)
        cf = statistics.mean(x["billed"] for x in xs) / M
        out.append({"case": "the full design: mean reclaims against mean billed hours / M", "M": M,
                    "simulated": round(sim, 3), "closed_form": round(cf, 3),
                    "difference_percent": round(100.0 * (sim - cf) / cf, 2),
                    "unit": "reclaims"})
    # 4. Never reclaimed: billed hours are the sum of the stages exactly.
    x = simulate(plan, free2, None, 1.0, 1, seed)[0]
    out.append({"case": "the full design, never reclaimed: billed hours against the sum of the stages", "M": "never",
                "simulated": round(x["billed"], 3), "closed_form": round(plan.base, 3),
                "difference_percent": round(100.0 * (x["billed"] - plan.base) / plan.base, 2), "unit": "hours"})
    return out


SENSITIVITY = [
    ("defaults", {}),
    ("restore twice as slow", {"restore_before_seal_h": 0.30, "restore_after_seal_h": 0.50}),
    ("deep axiom check 2 h", {"c2_deep_h": 2.0}),
    ("checkpoint every 5 min", {"ckpt_min": 5.0}),
    ("checkpoint every 10 min", {"ckpt_min": 10.0}),
    ("checkpoint every 20 min", {"ckpt_min": 20.0}),
    ("top of the import graph 1.0 h, one unit", {"top_h": 1.0}),
    ("reclaims bunched early (Weibull shape 0.7)", {"shape": 0.7}),
    ("attempt limit 12", {"max_attempts": 12}),
    ("attempt limit 48", {"max_attempts": 48}),
    ("replay results saved every 10 min", {"replay_save_min": 10.0}),
    ("replay results saved every 40 min", {"replay_save_min": 40.0}),
    ("a confirming hash takes 15 min", {"confirm_min": 15.0}),
]
SENS_M = [2, 4, 8, 24]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="", help="write the JSON record here")
    ap.add_argument("--runs", type=int, default=4000, help="simulated runs per point of the main table (default 4000)")
    ap.add_argument("--sens-runs", type=int, default=1000, help="runs per point in the thresholds and the sensitivity table (default 1000)")
    ap.add_argument("--seed", type=int, default=20261121)
    for name, default, label, source, meaning in INPUTS:
        ap.add_argument("--" + name.replace("_", "-"), dest=name, type=int if name in INT_INPUTS else float,
                        default=default, help="%s (default %s; %s)" % (meaning, default, label))
    a = ap.parse_args()
    p = {name: getattr(a, name) for name, _d, _l, _s, _m in INPUTS}
    plan = design_plan(p)
    free, lim = Rules(p, False), Rules(p, True)
    cap_hours = (p["cap_usd"] - p["spent_usd"] - p["reserve_usd"]) / p["spot_ledger_usd_h"]

    rows = []
    for M in M_LIST:
        tf, ur = summarise(p, plan, simulate(plan, free, M, p["shape"], a.runs, a.seed),
                           simulate(plan, lim, M, p["shape"], a.runs, a.seed))
        rows.append({"M_hours": "never" if M is None else M, "to_finish": tf, "under_the_launchers_rules": ur})

    th = thresholds(p, a.sens_runs, a.seed)
    sens = []
    for label, over in SENSITIVITY:
        q = dict(p, **over)
        pl = design_plan(q)
        t2 = thresholds(q, a.sens_runs, a.seed)
        at = {}
        for M in SENS_M:
            fin = simulate(pl, Rules(q, False), M, q["shape"], a.sens_runs, a.seed)
            rl = simulate(pl, Rules(q, True), M, q["shape"], a.sens_runs, a.seed)
            ok = [x["billed"] * q["spot_list_usd_h"] for x in fin if x["outcome"] == "finished"]
            at[str(M)] = {"share_finished_under_rules": round(sum(1 for x in rl if x["outcome"] == "finished") / float(len(rl)), 3),
                          "median_usd_list_to_finish": r(statistics.median(ok))}
        sens.append({"variant": label, "changes": over, "base_hours": r(pl.base, 2),
                     "spot_dearer_than_on_demand_below_M_list_expected": t2["spot_costs_more_than_on_demand_below_M_hours"]["expected_cost_at_list_rates"],
                     "half_of_runs_finish_under_the_cap_above_M": t2["run_usually_cannot_finish_under_the_cap_below_M_hours"]["half_of_runs_finish"],
                     "nine_in_ten_finish_above_M": t2["run_usually_cannot_finish_under_the_cap_below_M_hours"]["nine_runs_in_ten_finish"],
                     "at_M": at})

    ck = checks(p, a.runs, a.seed)
    cf = closed_forms(p, plan)
    record = {
        "what": "cost of a resumable Spot run of the full check (full-spot) as a function of the mean time between reclaims M, "
                "by simulation of the design attempt by attempt, with closed forms beside it",
        "how_to_reproduce": "python3 analysis/spot_resume_model.py --out records/cloud/spot_resume_model.json",
        "inputs_as_of": "2026-11-21",
        "seed": a.seed, "runs_per_point": a.runs, "runs_per_point_in_thresholds_and_sensitivity": a.sens_runs,
        "inputs": {name: {"value": p[name], "label": label, "source": source, "meaning": meaning}
                   for name, _d, label, source, meaning in INPUTS},
        "derived": {
            "hours_with_no_reclaim": r(plan.base, 2),
            "hours_on_demand_for_the_same_work": r(plan.od_base, 2),
            "stages": [{"stage": s[0], "hours": r(s[2], 3), "can_be_split": s[1]} for s in plan.stages],
            "ledger_hours_the_cap_allows": r(cap_hours, 2),
            "on_demand_usd_list": r(plan.od_base * p["od_list_usd_h"]), "on_demand_usd_ledger": r(plan.od_base * p["od_ledger_usd_h"]),
            "spot_usd_list_with_no_reclaim": r(plan.base * p["spot_list_usd_h"]),
            "spot_usd_ledger_with_no_reclaim": r(plan.base * p["spot_ledger_usd_h"]),
            "note_on_demand": "on demand is the same stages with no reclaim and without the confirming hashes a Spot run adds; at "
                              "the ledger's 2.00 it would record %.2f USD, more than the %.2f the cap leaves, so on demand does not "
                              "fit the cap of 50 at all (docs/cloud-notes.md section 8.6)"
                              % (plan.od_base * p["od_ledger_usd_h"], p["cap_usd"] - p["spent_usd"])},
        "by_mean_hours_between_reclaims": rows,
        "thresholds": th,
        "closed_forms": cf,
        "checks_against_closed_forms": ck,
        "sensitivity": sens,
        "limits": [
            "Google publishes no reclaim rate for any machine type or zone; M is a free variable, not an estimate. Its capacity advisor "
            "gives only 'estimated uptime' of 60, 10 or 1 minute, and nothing official supports planning on many hours without a reclaim.",
            "Reclaims are unlikely to be a steady Poisson process: they vary by day, zone and time of day and may come in bursts when a zone "
            "runs short. Each attempt draws a fresh time to reclaim; the Weibull row of the sensitivity table is one departure, not the real one.",
            "Several inputs are guesses (labelled): no restore of parts, no seal at full scale, no confirming hash at full scale, no deep "
            "axiom check on the full tree and nothing at the top of the import graph has ever been timed. The build and replay hours are projections.",
            "Losing 'the work since the last part' assumes the build runs at a steady rate; at the top of the import graph few modules run at once.",
            "The top of the import graph is saved when its unit finishes; with more than one unit, a unit's files actually wait for the next part.",
        ],
        "what_this_does_not_cover": [
            "waits for capacity between attempts (they bill nothing but count towards the give-up time and the owner's patience)",
            "attempts outside the bucket's region: their transfer rows and the cap's worst case for them (1.20 USD held back per attempt for the parts at the default limit of 60 GiB, plus the inputs each attempt downloads)",
            "bucket storage of the parts (the 1.00 USD reserve is meant to cover it) and the deletion of the parts afterwards",
            "a machine preempted within its first minute, which Google does not bill",
            "a build or check that fails for its own reasons, and any fault of the resume path itself (a checksum or baseline mismatch is final)",
            "changes to Spot prices, which can change daily",
            "the cost of a rehearsal of the Spot path, which has to come out of the same cap",
        ],
    }
    text = json.dumps(record, indent=1, sort_keys=False)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    print_report(p, plan, cap_hours, rows, th, cf, ck, sens)
    return 0


def print_report(p, plan, cap_hours, rows, th, cf, ck, sens):
    w = sys.stdout.write
    w("Resumable Spot run: %.1f h of work with no reclaim; the cap leaves %.2f ledger hours at %.2f USD/h.\n"
      % (plan.base, cap_hours, p["spot_ledger_usd_h"]))
    w("On demand for the same work (%.1f h, no confirming hashes): %.2f USD at list, %.2f at the ledger's rate.\n\n"
      % (plan.od_base, plan.od_base * p["od_list_usd_h"], plan.od_base * p["od_ledger_usd_h"]))
    w("To finish (pause rules and cap off). Hours and USD: median / 90th percentile. Lost: mean hours of setup+restore / redone work.\n")
    w("%-6s %-12s %-10s %-14s %-8s %-16s %-14s %-8s\n" % ("M h", "billed h", "attempts", "USD list", "USD ledg", "saving list,ledg", "lost s+r/redo", "fit cap"))
    for row in rows:
        t = row["to_finish"]
        w("%-6s %-12s %-10s %-14s %-8s %-16s %-14s %-8s\n" % (
            row["M_hours"], "%s / %s" % (t["billed_hours"]["median"], t["billed_hours"]["p90"]),
            "%s / %s" % (t["attempts"]["median"], t["attempts"]["p90"]),
            "%s / %s" % (t["usd_at_list_rate"]["median"], t["usd_at_list_rate"]["p90"]),
            t["usd_at_ledger_rate"]["median"],
            "%s, %s" % (t["saving_against_on_demand_usd"]["list"]["median"], t["saving_against_on_demand_usd"]["ledger"]["median"]),
            "%s / %s" % (t["mean_hours_lost_to_reclaims"]["setup_and_restore"], t["mean_hours_lost_to_reclaims"]["redone_work"]),
            t["share_whose_ledger_hours_fit_under_the_cap"]))
    w("\nUnder the launcher's rules (cap %g, %d attempts, %d without progress, give-up %d h). Shares of runs.\n"
      % (p["cap_usd"], p["max_attempts"], p["noprogress_limit"], p["giveup_h"]))
    w("%-6s %-9s %-9s %-9s %-7s %-8s %-12s %-14s\n" % ("M h", "finished", "att.limit", "no progr", "cap", "give-up", "billed h", "spend USD med/p90"))
    for row in rows:
        u = row["under_the_launchers_rules"]
        s = u["share_by_outcome"]
        w("%-6s %-9s %-9s %-9s %-7s %-8s %-12s %-14s\n" % (
            row["M_hours"], s["finished"], s["attempt limit"], s["no progress"], s["cap"], s["give-up time"],
            "%s / %s" % (u["billed_hours_all_runs"]["median"], u["billed_hours_all_runs"]["p90"]),
            "%s / %s" % (u["recorded_spend_after_the_run_usd"]["median"], u["recorded_spend_after_the_run_usd"]["p90"])))
    a, b = th["spot_costs_more_than_on_demand_below_M_hours"], th["run_usually_cannot_finish_under_the_cap_below_M_hours"]
    w("\nThresholds (mean hours between reclaims):\n")
    w("  Spot costs more than on demand below M = %s h (expected cost, list), %s h (ledger), %s h (one run in ten, list)\n"
      % (a["expected_cost_at_list_rates"], a["expected_cost_at_ledger_rates"], a["in_one_run_in_ten_at_list_rates"]))
    w("  Under the cap, half the runs finish above M = %s h, nine in ten above M = %s h\n" % (b["half_of_runs_finish"], b["nine_runs_in_ten_finish"]))
    w("\nClosed forms (M long against every unit): mean loss per reclaim %s h; break-even %s reclaims (list), %s (ledger);\n"
      % (cf["mean_hours_lost_per_reclaim_weighted_by_time"], cf["break_even_reclaims_at_list_rates"], cf["break_even_reclaims_at_ledger_rates"]))
    w("  break-even M about %s h (list), %s h (ledger); cap hours used up at M about %s h; attempt limit reached at M about %s h\n"
      % (cf["break_even_M_hours_at_list_rates_first_order"], cf["break_even_M_hours_at_ledger_rates_first_order"],
         cf["M_hours_at_which_the_cap_hours_are_used_on_average_first_order"],
         cf["M_hours_at_which_the_attempt_limit_is_reached_on_average_first_order"]))
    for s in cf["hours_lost_per_reclaim_by_stage"][1:]:
        w("    %-26s %5.2f h  lost per reclaim %s (setup+restore %s, redone %s)\n"
          % (s["stage"], s["hours"], s["hours_lost_per_reclaim"], s["setup_and_restore_after_a_reclaim"], s["redone_work"]))
    w("  A unit that cannot be split, expected hours (e^(U/M) - 1)(M + R), R = %.2f h:\n" % (p["setup_h"] + p["restore_after_seal_h"]))
    for u in cf["unit_that_cannot_be_split"]["rows"]:
        w("    U = %.1f h: %s\n" % (u["unit_hours"], ", ".join("M=%s: %s" % (k, v) for k, v in u["expected_hours_by_M"].items()
                                                         if k in ("1", "2", "4", "8", "24"))))
    w("\nChecks against closed forms:\n")
    for c in ck:
        w("  %-76s M=%-5s simulated %8.3f  closed form %8.3f %-8s (%+.2f %%)\n"
          % (c["case"], c["M"], c["simulated"], c["closed_form"], c["unit"], c["difference_percent"]))
    w("\nSensitivity: Spot dearer below M (list, expected) | half finish under cap above M | nine in ten above M | share finished at M=2,4,8,24\n")
    for s in sens:
        w("  %-44s %-6s %-6s %-6s %s\n" % (s["variant"], s["spot_dearer_than_on_demand_below_M_list_expected"],
                                          s["half_of_runs_finish_under_the_cap_above_M"], s["nine_in_ten_finish_above_M"],
                                          " ".join(str(s["at_M"][str(M)]["share_finished_under_rules"]) for M in SENS_M)))
    w("\nGoogle publishes no reclaim rate; M is free. Reclaims are unlikely to be a steady Poisson process. Several inputs are guesses.\n")


if __name__ == "__main__":
    sys.exit(main())
