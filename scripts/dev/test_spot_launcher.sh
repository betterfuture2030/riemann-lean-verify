#!/bin/bash
# Tests for the Spot side of cloud/gcp/pilot_local.sh (launch full-spot | full-spot-rehearsal, watch, teardown,
# abandon), and a check that the four older modes still do exactly what they do at HEAD.
#
#   bash scripts/dev/test_spot_launcher.sh            (bash 3.2 on macOS, or bash 5; python3 needed)
#
# No network and no cloud: a fake `gcloud` on PATH plays Compute Engine, the bucket and the guest, in a scratch
# directory; fake `date` and `sleep` give a clock that moves only when the launcher sleeps; a fake `git` answers
# the commit rule. Each case runs the launcher from a scratch copy of the repository's tree that has no config.env,
# so the owner's private settings are never read. The HEAD comparison takes HEAD's launcher with `git show`.
# Prints PASS or FAIL per case; exits 1 if any case failed. TEST_SCRATCH=<dir> keeps the scratch files there.
REPO=${TEST_REPO:-"$(cd "$(dirname "$0")/../.." && pwd)"}
WORK=${TEST_SCRATCH:-$(mktemp -d "${TMPDIR:-/tmp}/spot_launcher_test.XXXXXX")}
mkdir -p "$WORK" || exit 2
# The one spelling of the path the launcher itself sees (macOS's TMPDIR ends in "/", which would give "//" here and
# defeat the comparison of paths in the old-mode cases).
WORK=$(cd "$WORK" && pwd -P) || exit 2
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
PY3=$(command -v python3) || { echo "python3 is needed"; exit 2; }
SYSPATH="$(dirname "$PY3"):/usr/bin:/bin:/usr/sbin:/sbin"
T0=1796000000                      # the fake clock's start
COMMIT=1111111111111111111111111111111111111111
NEWSCRIPT="$REPO/cloud/gcp/pilot_local.sh"; NEWLIB="$REPO/scripts/lib.sh"
git -C "$REPO" show HEAD:cloud/gcp/pilot_local.sh > "$WORK/head_pilot_local.sh" || { echo "cannot read HEAD's launcher"; exit 2; }
git -C "$REPO" show HEAD:scripts/lib.sh > "$WORK/head_lib.sh" || { echo "cannot read HEAD's lib.sh"; exit 2; }
for f in "$NEWSCRIPT" "$WORK/head_pilot_local.sh"; do bash -n "$f" || { echo "syntax error in $f"; exit 1; }; done

cat > "$STUBS/fake.py" <<'PYEOF'
# A stand-in for Compute Engine, the bucket and the guest, for scripts/dev/test_spot_launcher.sh. No network.
# World: $FAKE/world.json, $FAKE/clock (epoch seconds), $FAKE/bucket/<object path>, $FAKE/calls.jsonl.
import glob, hashlib, json, os, shutil, sys

F = os.environ["FAKE"]
BK = os.path.join(F, "bucket")


def load():
    with open(os.path.join(F, "world.json")) as f:
        return json.load(f)


def save(w):
    p = os.path.join(F, "world.json")
    with open(p + ".tmp", "w") as f:
        json.dump(w, f, indent=1, sort_keys=True)
    os.replace(p + ".tmp", p)


def clock():
    with open(os.path.join(F, "clock")) as f:
        return int(f.read().strip())


def setclock(t):
    with open(os.path.join(F, "clock"), "w") as f:
        f.write(str(t))


def opath(p):
    return os.path.join(BK, p)


def put(p, data):
    q = opath(p)
    os.makedirs(os.path.dirname(q), exist_ok=True)
    with open(q, "wb") as f:
        f.write(data.encode() if isinstance(data, str) else data)


def get(p):
    q = opath(p)
    if not os.path.isfile(q):
        return None
    with open(q, "rb") as f:
        return f.read()


def sha(p):
    b = get(p)
    return "" if b is None else hashlib.sha256(b).hexdigest()


def plan_for(w, inst):
    if inst.get("legacy"):
        return w["plan"].get("legacy", {"run": 300, "end": "done"})
    return w["plan"].get(str(inst["attempt"]), w["plan"].get("default", {"run": 3600, "end": "reclaim"}))


def status(w, inst, phase, state, msg="-", kind=None):
    d = {"phase": phase, "state": state, "message": msg, "elapsed_s": clock() - inst["created"], "mode": inst["md"].get("pilot-mode", "")}
    if kind:
        d["pause"] = kind
    if not inst.get("legacy"):
        d["attempt"] = inst["attempt"]
        d["spot"] = 1
        put("results/%s/attempt-%d/pilot.log" % (inst["runtag"], inst["attempt"]), "%d %s %s\n" % (clock(), phase, state))
    put("results/%s/status.json" % inst["runtag"], json.dumps(d))


def old_state(rt):
    old = get("ckpt/%s/state.json" % rt)
    return json.loads(old) if old else None


def put_state(rt, inst, prog, rs, final, stage):
    st = {"runtag": rt, "attempt": inst["attempt"], "stage": stage, "progress": prog, "results_saved": rs, "final": bool(final), "attempts": []}
    put("ckpt/%s/state.json" % rt, json.dumps(st, indent=1) + "\n")


def add_part(rt, inst, nbytes):
    m = get("ckpt/%s/manifest.tsv" % rt)
    m = m.decode() if m else "seq\tobject\tsha256\tbytes\tmodules\tcut_epoch\tattempt\n"
    n = m.count("\n")
    m += "%d\tckpt/%s/part-%06d.tar.zst\t%s\t%d\t10\t%d\t%d\n" % (n, rt, n, "0" * 64, nbytes, clock(), inst["attempt"])
    put("ckpt/%s/manifest.tsv" % rt, m)
    put("ckpt/%s/part-%06d.tar.zst" % (rt, n), "x" * 10)


def save_ckpt(w, inst, final=False):
    # The fake guest's own checkpoint objects. A plan with "ckpt": false writes none (the contract case puts the
    # real helper's objects in place instead, with "copy_dir").
    if inst.get("legacy") or inst.get("saved"):
        return
    inst["saved"] = True
    p = plan_for(w, inst)
    if p.get("copy_dir"):
        shutil.copytree(p["copy_dir"], BK, dirs_exist_ok=True)
    if not p.get("ckpt", True):
        return
    rt = inst["runtag"]
    old = old_state(rt)
    prog = old["progress"] if old else 0
    rs = old.get("results_saved", 0) if old else 0
    delta = p.get("progress", 100)
    add = p.get("bytes", 10 ** 9)
    if delta or final or old is None:
        put_state(rt, inst, prog + delta, rs, final, p.get("stage", "build"))
    if add:
        add_part(rt, inst, add)


def remove(w, name):
    inst = w["instances"].pop(name, None)
    for d in (inst or {}).get("disks", []):
        w["disks"].pop(d, None)


def death(w, name, how):
    # A VM Google takes back stays listed as STOPPING for w["stopping_calls"] gcloud calls after the guest's
    # RECLAIMED (as a real one does for a few minutes); a delete sent meanwhile fails.
    inst = w["instances"].get(name)
    if inst is None or inst.get("dying"):
        return
    save_ckpt(w, inst)
    w["deaths"].append({"name": name, "attempt": inst.get("attempt"), "how": how, "t": clock()})
    if how == "simulate" or (how == "reclaim" and plan_for(w, inst).get("status_on_reclaim", True)):
        status(w, inst, "build", "RECLAIMED", "reclaimed")
    n = w.get("stopping_calls", 0) if how in ("simulate", "reclaim") else 0
    if n:
        inst["dying"] = True; inst["status"] = "STOPPING"; inst["stopping_left"] = n
    else:
        remove(w, name)


def tick(w):
    now = clock()
    for name in list(w["instances"]):
        inst = w["instances"][name]
        if inst.get("dying") or now < inst.get("hidden_until", 0):
            continue        # a VM not listed yet has not booted either
        p = plan_for(w, inst)
        el = now - inst["created"]
        if not inst.get("legacy") and not inst.get("ended"):
            rt = inst["runtag"]
            if p.get("part_at") is not None and el >= p["part_at"] and not inst.get("part_done"):
                inst["part_done"] = True; add_part(rt, inst, 10 ** 8)     # a part saved during the build
            if p.get("results_at") is not None and el >= p["results_at"] and not inst.get("results_done"):
                inst["results_done"] = True; o = old_state(rt) or {"progress": 0, "results_saved": 0}
                put_state(rt, inst, o["progress"] + 5, o.get("results_saved", 0) + 5, False, "c3")   # replay results saved
        if inst.get("sim_at") is not None and now >= inst["sim_at"] + 30:
            death(w, name, "simulate")
        elif el >= inst["maxrun"]:
            death(w, name, "maxrun")
        elif not inst.get("ended") and el >= p.get("run", 3600):
            inst["ended"] = True
            e = p.get("end", "reclaim")
            if e == "reclaim":
                death(w, name, "reclaim")
            elif e in ("done", "fail", "build_failed", "deadline"):
                save_ckpt(w, inst, final=True)
                status(w, inst, "end", {"done": "DONE", "fail": "FAIL", "build_failed": "BUILD_FAILED", "deadline": "DEADLINE"}[e])
            elif e == "paused":
                # "pause": the kind the guest gives (none: the field is left out); "own_status": false leaves the
                # status to the objects copy_dir put in place (the contract case)
                save_ckpt(w, inst)
                if p.get("own_status", True):
                    status(w, inst, "build", "PAUSED", p.get("pause_msg", "-"), p.get("pause"))
            # "hang" and "silent": nothing more is ever reported
        elif not inst.get("ended") and p.get("end") != "silent":
            ph = "setup"
            for t, name2 in p.get("phases", [[0, "setup"], [300, "build"]]):
                if el >= t:
                    ph = name2
            status(w, inst, ph, "RUNNING", "working")
            put("results/%s/heartbeat" % inst["runtag"], "%d\n" % now)


def fail_rule(w, line):
    # A rule with "after" is armed only by a later call than one whose line holds that text (e.g. the purge's
    # last listing), so that it hits a call made after that point and not an earlier one that matches too.
    for r in w["fail"]:
        if r.get("after") and not r.get("armed"):
            if r["after"] in line:
                r["armed"] = True
            continue
        if r["times"] > 0 and r["match"] in line:
            r["times"] -= 1
            return r
    return None


def opt(args, key):
    for a in args:
        if a.startswith(key + "="):
            return a[len(key) + 1:]
    return None


def positional(args):
    return [a for a in args if not a.startswith("-")]


def ledger_open_rows(path):
    if not path or not os.path.exists(path):
        return -1
    rows = [l.rstrip("\n").split("\t") for l in open(path)][1:]
    return sum(1 for r in rows if len(r) > 6 and r[6] == "")


def gcloud(args):
    w = load()
    args = [a for a in args if not a.startswith("--project=") and a != "--quiet"]
    line = " ".join(args)
    with open(os.path.join(F, "calls.jsonl"), "a") as f:
        f.write(json.dumps({"t": clock(), "args": args}) + "\n")
    for n in list(w["instances"]):
        i = w["instances"][n]
        if i.get("dying"):
            i["stopping_left"] -= 1
            if i["stopping_left"] <= 0:
                remove(w, n)
    # "on_call": [{"match", "times", "put": [object, text]}]: a call whose line holds "match" first puts that object
    # in the bucket ("{rt}" in either is the run's tag)
    for oc in w.get("on_call", []):
        if oc["times"] > 0 and oc["match"] in line:
            oc["times"] -= 1
            put(oc["put"][0].replace("{rt}", w.get("runtag", "")), oc["put"][1].replace("{rt}", w.get("runtag", "")))
    # "on_call_file": [{"match", "times", "path", "text"}]: the same for a file on this machine (written whole)
    for oc in w.get("on_call_file", []):
        if oc["times"] > 0 and oc["match"] in line:
            oc["times"] -= 1
            with open(oc["path"], "w") as f:
                f.write(oc["text"])
    # "kill_launcher_on": text: the first call whose line holds it kills the launcher outright once it is answered
    # (the process named in the lock's info file, which a call made in a $(...) subshell is not a child of)
    if w.get("kill_launcher_on") and w["kill_launcher_on"] in line:
        w["kill_launcher_on"] = ""; KILL_LAUNCHER.append(1)
    # "track_cuts": every change of CUTS_DONE in the state file, as seen at each call: [t, value]
    if w.get("track_cuts") and os.path.exists(w.get("state", "")):
        v = ""
        for l in open(w["state"]):
            if l.startswith("CUTS_DONE="):
                v = l.rstrip("\n").partition("=")[2].strip("'")
        seen = w.setdefault("cuts_seen", [])
        if not seen or seen[-1][1] != v:
            seen.append([clock(), v])
    r = fail_rule(w, line)
    if r and not r.get("create_anyway"):
        save(w)
        sys.stderr.write(r.get("msg", "ERROR: (gcloud) simulated failure of the API") + "\n")
        return 1
    rc = 0
    pos = positional(args)
    if pos[:3] == ["compute", "instances", "list"]:
        flt = opt(args, "--filter"); zs = opt(args, "--zones"); fmt = opt(args, "--format") or ""
        out = []
        for n, i in sorted(w["instances"].items()):
            if flt and flt != "name=" + n:
                continue
            if zs and i["zone"] not in zs.split(","):
                continue
            if clock() < i.get("hidden_until", 0):
                continue        # created, but not listed yet
            if fmt == "value(status)":
                out.append(i["status"])
            elif fmt == "value(status,zone.basename())":
                out.append("%s\t%s" % (i["status"], i["zone"]))
            elif fmt == "value(name)":
                out.append(n)
            elif fmt == "csv[no-heading](name,zone.basename(),status)":
                out.append("%s,%s,%s" % (n, i["zone"], i["status"]))
            elif fmt.startswith("csv[no-heading]"):
                out.append("%s,%s" % (n, i["zone"]))
            else:
                out.append("%s\t%s\t%s" % (n, i["zone"], i["status"]))
        if out:
            print("\n".join(out))
    elif pos[:3] == ["compute", "disks", "list"]:
        fmt = opt(args, "--format") or ""
        out = []
        for n, z in sorted(w["disks"].items()):
            if fmt == "value(name)":
                out.append(n)
            elif fmt.startswith("csv[no-heading]"):
                out.append("%s,%s" % (n, z))
            else:
                out.append("%s\t%s\t100" % (n, z))
        if out:
            print("\n".join(out))
    elif pos[:3] == ["compute", "instances", "create"]:
        name = pos[3]; z = opt(args, "--zone"); now = clock()
        md = {}
        for kv in (opt(args, "--metadata") or "").split(","):
            k, _, v = kv.partition("=")
            md[k] = v
        with open(os.path.join(F, "creates.jsonl"), "a") as f:
            f.write(json.dumps({"t": now, "args": args}) + "\n")
        with open(os.path.join(F, "syncs.log"), "a") as f:
            f.write("CREATE %s\n" % md.get("full-attempt", "-"))
        if w["instances"]:
            w["errors"].append("create of %s while an instance exists: %s" % (name, sorted(w["instances"])))
        if ledger_open_rows(w.get("ledger")) != 1:
            w["errors"].append("create of %s at %d with %d open ledger rows (want exactly 1)" % (name, now, ledger_open_rows(w.get("ledger"))))
        if md.get("full-spot") == "1":
            # At the moment the create is sent, the state on disk names this attempt, says a create may have been
            # sent (STARTING empty), and holds the time it was sent; the open row is this attempt's.
            st = {}
            if os.path.exists(w.get("state", "")):
                for l in open(w["state"]):
                    k, _, v = l.rstrip("\n").partition("=")
                    st[k] = v.strip("'")
            want = {"ATTEMPT": md.get("full-attempt"), "STARTING": "", "CREATE_SENT": str(now)}
            got = {k: st.get(k) for k in want}
            if got != want:
                w["errors"].append("create of attempt %s: the state file holds %s, want %s" % (md.get("full-attempt"), got, want))
            rows = [l.rstrip("\n").split("\t") for l in open(w["ledger"])][1:]
            if not any(len(r) > 6 and r[6] == "" and r[1].endswith("#" + md.get("full-attempt", "")) for r in rows):
                w["errors"].append("create of attempt %s with no open row of that attempt in the ledger" % md.get("full-attempt"))
        if w.get("create_delay"):
            setclock(now + w["create_delay"]); now = clock()      # a create that takes this long to be answered
        once = w.get("nocap_for_attempt", {}).get(md.get("full-attempt", ""), [])
        nocap = z in w["nocap"] or (z in w.get("nocap_until_zones", []) and now < w.get("nocap_until", 0)) or z in once
        if z in once:
            once.remove(z)      # no capacity for this attempt's first try in that zone only
        if nocap:
            if w.get("nocap_leaves_disk"):
                w["disks"][name + "-data"] = z      # the refused request left its data disk behind
            save(w)
            sys.stderr.write("ERROR: (gcloud.compute.instances.create) Could not fetch resource:\n - The zone '%s' does not have enough resources available to fulfill the request. ZONE_RESOURCE_POOL_EXHAUSTED\n" % z)
            return 1
        spot = md.get("full-spot") == "1"
        inst = {"zone": z, "status": "RUNNING", "created": now, "maxrun": int((opt(args, "--max-run-duration") or "0s")[:-1]), "md": md,
                "runtag": md.get("pilot-runtag", ""), "legacy": not spot, "disks": [name]}
        cd = opt(args, "--create-disk")
        if cd:
            inst["disks"].append(dict(x.split("=", 1) for x in cd.split(","))["name"])
        if spot:
            inst["attempt"] = int(md["full-attempt"])
            rt = inst["runtag"]; w["runtag"] = rt
            if inst["attempt"] <= w["last_attempt"]:   # attempt numbers only increase (one that never reached the API is skipped)
                w["errors"].append("attempt %d created after attempt %d" % (inst["attempt"], w["last_attempt"]))
            w["last_attempt"] = inst["attempt"]
            for key, obj in (("full-state-sha", "state.json"), ("full-manifest-sha", "manifest.tsv")):
                if md.get(key, "") != sha("ckpt/%s/%s" % (rt, obj)):
                    w["errors"].append("attempt %d: %s is '%s' but the bucket's %s has sha '%s'" % (inst["attempt"], key, md.get(key), obj, sha("ckpt/%s/%s" % (rt, obj))))
            if opt(args, "--provisioning-model") != "SPOT" or opt(args, "--instance-termination-action") != "DELETE":
                w["errors"].append("attempt %d is not a Spot VM with DELETE" % inst["attempt"])
        if r and r.get("hidden"):
            inst["hidden_until"] = now + r["hidden"]
        w["instances"][name] = inst
        for d in inst["disks"]:
            w["disks"][d] = z
        if r:  # create_anyway: the VM exists but the call reports an error
            save(w)
            sys.stderr.write(r.get("msg", "ERROR: (gcloud) the response was lost") + "\n")
            return 1
        print("Created [%s]." % name)
    elif pos[:3] == ["compute", "instances", "delete"]:
        name = pos[3]
        if name not in w["instances"]:
            sys.stderr.write("ERROR: not found\n"); rc = 1
        elif w["instances"][name].get("dying"):
            w["refused_deletes"] = w.get("refused_deletes", 0) + 1
            sys.stderr.write("ERROR: (gcloud.compute.instances.delete) The resource '%s' is not ready\n" % name); rc = 1
        else:
            death(w, name, "deleted")
    elif pos[:3] == ["compute", "disks", "delete"]:
        if any(i.get("dying") and pos[3] in i["disks"] for i in w["instances"].values()):
            sys.stderr.write("ERROR: (gcloud.compute.disks.delete) The disk resource '%s' is already being used\n" % pos[3]); rc = 1
        elif w["disks"].pop(pos[3], None) is None:
            sys.stderr.write("ERROR: not found\n"); rc = 1
    elif pos[:3] == ["compute", "instances", "reset"]:
        i = w["instances"].get(pos[3])
        if i is None:
            sys.stderr.write("ERROR: not found\n"); rc = 1
        else:
            i["ended"] = True       # a hard reset: the guest is cut off at once and reports nothing more here
            w["resets"].append({"attempt": i.get("attempt"), "t": clock()})
            if w.get("kill_watch_on_reset"):
                w["kill_watch_on_reset"] = False; KILL_PARENT.append(1)    # the watch is killed outright while the reset is in flight
    elif pos[:3] == ["compute", "instances", "simulate-maintenance-event"]:
        i = w["instances"].get(pos[3])
        if i is None:
            sys.stderr.write("ERROR: not found\n"); rc = 1
        else:
            if not w.get("simulate_noop"):     # "simulate_noop": Google accepts the request, and nothing happens
                i["sim_at"] = clock()
            w["simulated"].append({"attempt": i.get("attempt"), "t": clock()})
            if w.get("stop_after_simulate"):   # the watch is stopped (a closed terminal) this many seconds later
                w["stop_watch_at"] = clock() + w["stop_after_simulate"]; w["stop_after_simulate"] = 0
    elif pos[:3] in (["compute", "addresses", "list"], ["compute", "snapshots", "list"]):
        pass
    elif pos[:3] == ["storage", "buckets", "describe"]:
        print(w.get("bucket_location", "US-CENTRAL1"))
    elif pos[:2] == ["storage", "cat"]:
        b = get(pos[2].split("/", 3)[3])
        if b is None:
            sys.stderr.write("ERROR: (gcloud.storage.cat) The following URLs matched no objects or files:\n-%s\n" % pos[2]); rc = 1
        else:
            sys.stdout.write(b.decode())
    elif pos[:2] == ["storage", "cp"]:
        src, dst = pos[2], pos[3]
        if src.startswith("gs://"):
            path = src.split("/", 3)[3]
            if "*" in path:
                pre = path.split("*")[0]
                if "-r" in args:
                    files = [q for q in glob.glob(opath(pre) + "**", recursive=True) if os.path.isfile(q)]
                else:           # without -r a wildcard copies only the objects at that level
                    files = [q for q in glob.glob(opath(pre) + "*") if os.path.isfile(q)]
                if not files:
                    sys.stderr.write("ERROR: The following URLs matched no objects or files:\n-%s\n" % src); rc = 1
                for q in files:
                    rel = os.path.relpath(q, opath(pre))
                    os.makedirs(os.path.dirname(os.path.join(dst, rel)), exist_ok=True)
                    shutil.copyfile(q, os.path.join(dst, rel))
            elif not os.path.isfile(opath(path)):
                sys.stderr.write("ERROR: The following URLs matched no objects or files:\n-%s\n" % src); rc = 1
            else:
                d = os.path.join(dst, os.path.basename(path)) if dst.endswith("/") or os.path.isdir(dst) else dst
                shutil.copyfile(opath(path), d)
        else:
            w["errors"].append("unexpected upload: " + line)
    elif pos[:2] == ["storage", "ls"]:
        pre = pos[2].split("/", 3)[3]
        files = [q for q in glob.glob(opath(pre) + "**", recursive=True) if os.path.isfile(q)]
        if files:
            print("\n".join(sorted(files)))
        else:
            sys.stderr.write("ERROR: One or more URLs matched no objects.\n"); rc = 1
    elif pos[:2] == ["storage", "du"]:
        pre = pos[-1].split("/", 3)[3]
        files = [q for q in glob.glob(opath(pre) + "**", recursive=True) if os.path.isfile(q)]
        print("%d  %s" % (sum(os.path.getsize(q) for q in files), pos[-1]))
    else:
        w["errors"].append("unsupported gcloud call: " + line)
        sys.stderr.write("fake gcloud: unsupported\n"); rc = 2
    save(w)
    return rc


KILL_PARENT = []
KILL_LAUNCHER = []


def main():
    if sys.argv[1] == "gcloud":
        rc = gcloud(sys.argv[2:])
        if KILL_LAUNCHER:
            try:
                os.close(9)
            except OSError:
                pass
            pid = int(open(load()["state"] + ".lock.info").readline())
            os.kill(pid, 9)
        if KILL_PARENT:
            try:
                os.close(9)     # this call must not keep the launcher's lock alive itself
            except OSError:
                pass
            os.kill(os.getppid(), 9)
        sys.exit(rc)
    if sys.argv[1] == "tick":
        w = load()
        secs = int(float(sys.argv[2]))
        w["sleeps"].append(secs)
        t, end = clock(), clock() + secs
        while t < end:          # advance in steps, so that events inside a long sleep happen in order
            t = min(end, t + 15)
            setclock(t)
            tick(w)
        kill = w.get("stop_watch_at", 0) and clock() >= w["stop_watch_at"]
        if kill:
            w["stop_watch_at"] = 0
        save(w)
        if kill:
            print("KILL")
        return
    if sys.argv[1] == "tick0":   # let the guest act at the current time without advancing the clock
        w = load(); tick(w); save(w)


main()
PYEOF
cat > "$STUBS/gcloud" <<'EOF'
#!/bin/bash
exec python3 -I "$(dirname "$0")/fake.py" gcloud "$@"
EOF
cat > "$STUBS/date" <<'EOF'
#!/bin/bash
exec /bin/date -u -r "$(cat "$FAKE/clock")" "$@"
EOF
cat > "$STUBS/sleep" <<'EOF'
#!/bin/bash
# The launcher's sleep: moves the fake clock on and lets the fake guest act. "KILL" plays a closed terminal.
r=$(python3 -I "$(dirname "$0")/fake.py" tick "${1:-1}")
[ "$r" = KILL ] && kill -TERM "$PPID"
exit 0
EOF
cat > "$STUBS/git" <<'EOF'
#!/bin/bash
[ "${1:-}" = -C ] && shift 2
case "${1:-}" in
  rev-parse) cat "$FAKE/git_head" ;;
  status) cat "$FAKE/git_dirty" 2>/dev/null; exit 0 ;;
  show) [ "${2:-}" = HEAD:cloud/gcp/full_guest.sh ] && exec cat "$FAKE/full_guest.sh"; exit 128 ;;
  *) echo "fake git: unsupported: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$STUBS/gcloud" "$STUBS/date" "$STUBS/sleep" "$STUBS/git"
# With PRE="$STUBS/py:" a case sees this python3 first: it logs every flush to disk the launcher asks for (the
# scripts that call F_FULLFSYNC) in $FAKE/syncs.log, and makes them fail while $FAKE/sync_fail exists: all of them
# when it is empty, only the Nth flush of the case when it holds "n=N", only a flush of that file when it holds
# "file=<path>".
mkdir -p "$STUBS/py"
cat > "$STUBS/py/python3" <<EOF
#!/bin/bash
[ "\${1:-}" = -I ] && [ "\${2:-}" = - ] || exec "$PY3" "\$@"
s="\$FAKE/py.\$\$"; cat > "\$s"
if grep -q F_FULLFSYNC "\$s"; then
  echo "SYNC \${*:3}" >> "\$FAKE/syncs.log"
  if [ -e "\$FAKE/sync_fail" ]; then
    rule=\$(cat "\$FAKE/sync_fail"); fail=0
    case "\$rule" in
      '') fail=1 ;;
      n=*) [ "\$(grep -c '^SYNC' "\$FAKE/syncs.log")" = "\${rule#n=}" ] && fail=1 ;;
      file=*) case " \${*:3} " in *" \${rule#file=} "*) fail=1 ;; esac ;;
    esac
    if [ "\$fail" = 1 ]; then rm -f "\$s"; echo "OSError: [Errno 5] Input/output error (made to fail by the test)" >&2; exit 1; fi
  fi
fi
"$PY3" "\$@" < "\$s"; rc=\$?; rm -f "\$s"; exit \$rc
EOF
chmod +x "$STUBS/py/python3"

NPASS=0; NFAIL=0; CASE=""; CFAIL=0
# tree <dir> <launcher> <lib>: a minimal copy of the repository's layout, with no config.env in it.
tree() {
  mkdir -p "$1/scripts" "$1/cloud/gcp" "$1/records/source" "$1/work/analysis/pilot"
  cp "$2" "$1/cloud/gcp/pilot_local.sh"; cp "$3" "$1/scripts/lib.sh"
  echo 'print("sampler")' > "$1/cloud/gcp/sampler.py"
  printf '{"deep_target_a": "A.Deep", "deep_target_b": "B.Deep", "rehearsal_target": "R.Small", "probes": []}\n' > "$1/records/source/pilot_targets.json"
  echo "toolsha0123 $COMMIT" > "$1/work/analysis/pilot/rhv_tools.id"
}
# begin <name> [head]: a fresh tree and a fresh fake world for one case.
begin() {
  CASE=$1; CFAIL=0; C="$WORK/$1"; rm -rf "${C:?}"; mkdir -p "$C"
  TR="$C/tree"; FAKE="$C/fake"; mkdir -p "$FAKE/bucket"
  if [ "${2:-}" = head ]; then tree "$TR" "$WORK/head_pilot_local.sh" "$WORK/head_lib.sh"; else tree "$TR" "$NEWSCRIPT" "$NEWLIB"; fi
  LEDGER="$TR/work/analysis/pilot_ledger.tsv"; STATEF="$TR/work/analysis/pilot_state.env"
  echo "$T0" > "$FAKE/clock"; echo "$COMMIT" > "$FAKE/git_head"; printf '#!/bin/bash\necho guest\n' > "$FAKE/full_guest.sh"
  python3 -I -c 'import json,sys; json.dump({"instances":{},"disks":{},"nocap":[],"nocap_until":0,"nocap_until_zones":[],"nocap_for_attempt":{},"fail":[],"plan":{},"errors":[],"resets":[],"last_attempt":0,"ledger":sys.argv[2],"state":sys.argv[3],"stop_watch_at":0,"deaths":[],"simulated":[],"sleeps":[]}, open(sys.argv[1],"w"))' "$FAKE/world.json" "$LEDGER" "$STATEF"
  ZONES="us-central1-a"; CAP=50; EXTRA=(GCP_SPOT_MIN_ATTEMPT_SECONDS=1500); PRE=""
}
end() {
  local e; e=$(wq 'len(w["errors"])')
  if [ "$e" != 0 ]; then echo "    not ok: the fake recorded errors:"; wq '"\n".join(w["errors"])' | sed 's/^/      /'; CFAIL=1; fi
  if [ "$CFAIL" = 0 ]; then echo "PASS $CASE"; NPASS=$((NPASS + 1)); else echo "FAIL $CASE   (output: $C/all.out)"; NFAIL=$((NFAIL + 1)); fi
}
# pl <args>: run the launcher in this case's tree; output to $C/last.out (and appended to all.out), status in RC.
pl() {
  env -i PATH="$PRE$STUBS:$SYSPATH" HOME="$HOME" TZ=UTC LC_ALL=C FAKE="$FAKE" PILOT_CAFFEINATED=1 RH_WORKDIR="$TR/work" \
    GCP_PROJECT=testproj GCP_BUCKET=testbucket GCP_REGION=us-central1 GCP_ZONES="$ZONES" GCP_SPEND_CAP_USD="$CAP" \
    "${EXTRA[@]}" /bin/bash "$TR/cloud/gcp/pilot_local.sh" "$@" > "$C/last.out" 2>&1
  RC=$?
  { echo "=== $* (exit $RC)"; cat "$C/last.out"; } >> "$C/all.out"
}
wset() { python3 -I -c 'import json,sys; p=sys.argv[1]; w=json.load(open(p)); now=int(open(sys.argv[3]).read()); exec(sys.argv[2]); json.dump(w,open(p,"w"),indent=1)' "$FAKE/world.json" "$1" "$FAKE/clock"; }
wq() { python3 -I -c 'import json,sys; w=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$FAKE/world.json" "$1"; }
guest() { FAKE="$FAKE" python3 -I "$STUBS/fake.py" tick "$1" >/dev/null; }      # time passes with nobody watching
# lq <python expression over rows>: query the ledger (rows: dicts with tag mode machine rate zone created ended secs usd)
lq() { python3 -I -c 'import sys; K="tag mode machine rate zone created ended secs usd".split(); rows=[dict(zip(K,l.rstrip("\n").split("\t"))) for l in open(sys.argv[1])][1:]; print(eval(sys.argv[2]))' "$LEDGER" "$1"; }
# cq <python expression over creates>: query the create calls (c: list of {"t", "args", "md"})
cq() { python3 -I -c '
import json,os,sys
c=[]
if os.path.exists(sys.argv[1]):
    for l in open(sys.argv[1]):
        d=json.loads(l); a=d["args"]
        md=dict(kv.partition("=")[::2] for x in a if x.startswith("--metadata=") for kv in x[len("--metadata="):].split(","))
        d["md"]=md; d["opt"]=dict(x[2:].partition("=")[::2] for x in a if x.startswith("--")); c.append(d)
print(eval(sys.argv[2]))' "$FAKE/creates.jsonl" "$1"; }
fmode() { python3 -I -c 'import os,stat,sys; print("%o" % stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$1"; }    # a file's permissions, as 640
sv() { ( . "$STATEF" 2>/dev/null; eval "printf '%s' \"\${$1:-}\"" ); }      # a value from the state file
ok() { local d=$1; shift; if ! "$@"; then echo "    not ok: $d"; CFAIL=1; fi; }
eq() { [ "$1" = "$2" ] || { echo "      got [$1], want [$2]"; return 1; }; }
has() { grep -q -- "$1" "$C/last.out" || { echo "      output lacks [$1]:"; tail -5 "$C/last.out" | sed 's/^/        /'; return 1; }; }
cap_ok() { # recorded spend never above the cap less the reserve, no row left open
  eq "$(lq 'sum(float(r["usd"]) for r in rows if r["usd"]) <= '"$CAP"' - 1.00 + 1e-9')" True && eq "$(lq 'sum(1 for r in rows if r["ended"]=="")')" 0
}
seed_spent() { printf 'runtag\tmode\tmachine\tusd_per_hour\tzone\tcreated_epoch\tended_epoch\tseconds\tusd\n' > "$LEDGER"
  printf 'earlier\tfull-rehearsal\tn4d-highmem-32\t2.00\tus-east1-b\t1\t2\t3\t%s\n' "$1" >> "$LEDGER"; }

# ---- 1. Sizing at the edges (design 1.4)
begin sizing
seed_spent 9.86; pl launch full-spot
ok "launch with 9.86 spent of 50 starts" eq "$RC" 0
ok "in region: 117270 s" eq "$(cq 'c[-1]["opt"]["max-run-duration"]')" 117270s
ok "guest deadline (117270-900)/60" eq "$(cq 'c[-1]["md"]["pilot-deadline-min"]')" 1939
ok "the row is open before and after the create, at the Spot rate" eq "$(lq '[(r["mode"],r["rate"],r["zone"],r["ended"]) for r in rows[1:]]')" "[('full-spot#1', '1.20', 'us-central1-a', '')]"
ok "worst case fits exactly: one more second would not" eq "$(python3 -I -c 'print(9.86+1.2*(117270+120)/3600+0.01 <= 49+1e-9, 9.86+1.2*(117271+120)/3600+0.01 > 49)')" "True True"
end
begin sizing_out_of_region
seed_spent 9.86; ZONES="us-east1-b"; pl launch full-spot
ok "out of region: 113670 s (1.20 held for transfer)" eq "$(cq 'c[-1]["opt"]["max-run-duration"]')" 113670s
ok "guest deadline" eq "$(cq 'c[-1]["md"]["pilot-deadline-min"]')" 1879
end
begin sizing_too_little
seed_spent 48.50; EXTRA=(); pl launch full-spot
ok "refused" eq "$RC" 1
ok "says why" has "REFUSED: the cap leaves room for an attempt of only 1350 s"
ok "nothing created" eq "$(cq 'len(c)')" 0
ok "no state left" eq "$([ -e "$STATEF" ] && echo yes || echo no)" no
ok "no row opened" eq "$(lq 'len(rows)')" 1
end
begin sizing_limits
CAP=200; pl launch full-spot
ok "mode limit 151200 s" eq "$(cq 'c[-1]["opt"]["max-run-duration"]')" 151200s
end
begin sizing_giveup
CAP=200; EXTRA=(GCP_SPOT_GIVEUP_HOURS=10); pl launch full-spot
ok "give-up limit 36000 s" eq "$(cq 'c[-1]["opt"]["max-run-duration"]')" 36000s
end

# ---- 2. Three attempts, two reclaims, then DONE; attempt 2 has no capacity in region and runs out of region
begin three_attempts
G=1073741824
ZONES="us-central1-a us-east1-b"; mkdir -p "$C/mirror"; EXTRA=(GCP_SPOT_MIN_ATTEMPT_SECONDS=1500 GCP_RESULTS_MIRROR_DIR="$C/mirror")
wset 'w["plan"]={"1":{"run":1200,"end":"reclaim","progress":100,"bytes":2*'$G'},"2":{"run":1500,"end":"reclaim","progress":80,"bytes":3*'$G'},"3":{"run":900,"end":"done","progress":50,"bytes":'$G'}}; w["nocap_for_attempt"]={"2":["us-central1-a"]}'
pl launch full-spot; ok "launch" eq "$RC" 0
pl watch; ok "watch ends the run" eq "$RC" 0
ok "said the run is over" has "the Spot run full-spot-.* is over after 3 attempt"
ok "prints how to delete the checkpoints" has "storage rm -r gs://testbucket/ckpt/full-spot-"
ok "state file removed" eq "$([ -e "$STATEF" ] && echo yes || echo no)" no
ok "rows: one per attempt plus the transfer of attempt 2" eq "$(lq '[(r["mode"],r["zone"]) for r in rows]')" "[('full-spot#1', 'us-central1-a'), ('full-spot#2', 'us-east1-b'), ('full-spot#2-transfer', 'us-east1-b'), ('full-spot#3', 'us-central1-a')]"
ok "transfer = 0.02 x (2 GiB restored + 3 GiB added)" eq "$(lq 'rows[2]["usd"]')" 0.10
ok "each attempt row covers its run and is capped at MAXRUN+120" eq "$(lq 'all(int(r["secs"])>=run and int(r["secs"])<=run+200 for r,run in zip([rows[0],rows[1],rows[3]],[1200,1500,900]))')" True
ok "usd = 1.20 x seconds" eq "$(lq 'all(abs(float(r["usd"])-1.2*int(r["secs"])/3600)<0.006 for r in [rows[0],rows[1],rows[3]])')" True
ok "mirrored during and after the run" eq "$(ls "$C/mirror/$(lq 'rows[0]["tag"]')/ckpt" | tr '\n' ' ')" "manifest.tsv state.json "
ok "spent shown = sum of rows" has "estimated spend so far: \$$(lq '"%.2f" % sum(float(r["usd"]) for r in rows if r["usd"])') of"
ok "no row open; under cap" cap_ok
ok "attempt numbers in metadata (the failed create in region was attempt 2 too)" eq "$(cq '[x["md"]["full-attempt"] for x in c]')" "['1', '2', '2', '3']"
ok "full-spot passes the guest pilot-mode=full and the Spot keys" eq "$(cq 'sorted(set(x["md"]["pilot-mode"] for x in c)), c[-1]["md"]["full-spot"], c[-1]["md"]["full-ckpt-every"], "full-spot-hold" in c[-1]["md"]')" "(['full'], '1', '600', False)"
ok "attempt 1 continues nothing" eq "$(cq 'c[0]["md"]["full-state-sha"]+c[0]["md"]["full-manifest-sha"]')" ""
ok "the stale RECLAIMED of attempt 1 did not end attempt 2" eq "$(wq '[d["how"] for d in w["deaths"]]')" "['reclaim', 'reclaim', 'deleted']"
ok "the parts limit goes only to the attempt outside the bucket's region (60 GiB in bytes)" eq "$(cq '[x["md"].get("full-parts-max-bytes") for x in c]')" "[None, None, '64424509440', None]"
ok "full-spot's confirm interval and watchdog waits" eq "$(cq 'c[-1]["md"]["full-confirm-every"], c[-1]["md"]["full-watchdog-wait"], c[-1]["md"]["full-watchdog-finish-wait"]')" "('1200', '420', '300')"
ok "each attempt's own logs were copied down" eq "$(ls "$TR/work/analysis/pilot/$(lq 'rows[0]["tag"]')" | grep attempt- | tr '\n' ' ')" "attempt-1 attempt-2 attempt-3 "
ok "results were never copied as a whole tree" eq "$(grep -c '"-r", "gs://testbucket/results/[^/]*/\*"' "$FAKE/calls.jsonl")" 0
ok "no temporary ledger file left behind" eq "$(ls "$TR/work/analysis" | grep -c 'ledger.tmp')" 0
end
begin mirror_and_final_teardown
mkdir -p "$C/mirror"; EXTRA=(GCP_SPOT_MIN_ATTEMPT_SECONDS=1500 GCP_RESULTS_MIRROR_DIR="$C/mirror")
wset 'w["plan"]={"default":{"run":1200,"end":"done"}}'
pl launch full-spot; RT=$(sv RUNTAG); guest 1300
pl teardown
ok "teardown after a final status ends the run" has "is over after 1 attempt"
ok "state removed" eq "$([ -e "$STATEF" ] && echo yes || echo no)" no
ok "results mirrored" eq "$(ls "$C/mirror/$RT" | tr '\n' ' ')" "attempt-1 ckpt heartbeat status.json "
ok "the mirrored status is the final one" grep -q '"DONE"' "$C/mirror/$RT/status.json"
end
begin mirror_missing_dir
EXTRA=(GCP_SPOT_MIN_ATTEMPT_SECONDS=1500 GCP_RESULTS_MIRROR_DIR="$C/no-such-dir")
wset 'w["plan"]={"default":{"run":600,"end":"done"}}'
pl launch full-spot; pl watch
ok "a missing mirror folder is reported and changes nothing" eq "$RC $(grep -c 'is not an existing directory' "$C/last.out")" "0 1"
end

# ---- 3. Recorded spend never passes the cap, over random sequences of reclaims, hangs and maximum run times
for seed in 1 2 3 4; do
  begin "random_reclaims_seed$seed"
  ZONES="us-central1-a us-east1-b us-central1-b"
  python3 -I - "$FAKE/world.json" "$seed" "$LEDGER" <<'PY'
import json, random, sys
p, seed, L = sys.argv[1], int(sys.argv[2]), sys.argv[3]
r = random.Random(seed); w = json.load(open(p))
plan = {}
for a in range(1, 13):
    plan[str(a)] = {"run": r.randint(300, 2500), "end": r.choice(["reclaim", "reclaim", "reclaim", "hang", "silent", "paused"]),
                    "progress": r.choice([0, 50, 100]), "bytes": r.randint(0, 8 * 2**30), "status_on_reclaim": r.random() < 0.7}
plan[str(r.randint(4, 12))]["end"] = "done"
w["plan"] = plan
w["nocap_for_attempt"] = {str(a): r.sample(["us-central1-a", "us-east1-b", "us-central1-b"], r.randint(0, 2)) for a in range(1, 13)}
json.dump(w, open(p, "w"))
open(L, "w").write("runtag\tmode\tmachine\tusd_per_hour\tzone\tcreated_epoch\tended_epoch\tseconds\tusd\nearlier\tfull\tm\t2.00\tz\t1\t2\t3\t%.2f\n" % r.uniform(42, 46))
PY
  pl launch full-spot
  n=0; while [ "$RC" = 0 ] && [ -e "$STATEF" ] && [ $n -lt 6 ]; do pl watch; n=$((n + 1)); [ "$RC" = 3 ] && { pl watch; }; done
  ok "ends by pausing or finishing (last exit $RC)" eq "$(if [ "$RC" = 0 ] || [ "$RC" = 3 ]; then echo y; else echo "n$RC"; fi)" y
  ok "recorded spend <= cap - reserve; no row open" cap_ok
  ok "nothing left running" eq "$(wq 'len(w["instances"])+len(w["disks"])')" 0
  end
done

# ---- 4. Pause after three attempts in a row without progress; a watch run again after the pause starts one more
begin no_progress_pause
wset 'w["plan"]={"default":{"run":600,"end":"reclaim","progress":0,"bytes":0},"4":{"run":600,"end":"done","progress":10}}'
pl launch full-spot; pl watch
ok "pauses with exit 3" eq "$RC" 3
ok "says why" has "PAUSED: 3 attempts in a row saved no progress"
ok "three attempts" eq "$(cq 'len(c)')" 3
ok "PAUSED is in the state" eq "$(sv PAUSED)" "3 attempts in a row saved no progress"
ok "the pause says bucket storage still bills, and how much" has "GiB; at 0.020 USD per GiB-month they cost about"
ok "  ... and that the checkpoints are kept" has "bucket storage still bills"
ok "nothing left running, no row open" eq "$(wq 'len(w["instances"])')$(lq 'sum(1 for r in rows if r["ended"]=="")')" 00
pl watch
ok "watch after the pause continues and finishes" eq "$RC" 0
ok "continued the paused run" grep -q "continuing the paused run" "$C/all.out"
ok "four attempts in all" eq "$(cq 'len(c)')" 4
end

# ---- 5. Pause at the attempt limit
begin attempt_limit
EXTRA=(GCP_SPOT_MIN_ATTEMPT_SECONDS=1500 GCP_SPOT_MAX_ATTEMPTS=2)
wset 'w["plan"]={"default":{"run":600,"end":"reclaim","progress":100}}'
pl launch full-spot; pl watch
ok "pauses" eq "$RC" 3
ok "says why" has "PAUSED: 2 attempts have been started"
ok "two attempts" eq "$(cq 'len(c)')" 2
end

# ---- 6. The give-up time limits an attempt's length, then pauses the run
begin giveup
EXTRA=(GCP_SPOT_MIN_ATTEMPT_SECONDS=1500 GCP_SPOT_GIVEUP_HOURS=1)
wset 'w["plan"]={"1":{"run":1800,"end":"reclaim"},"default":{"run":9000,"end":"reclaim"}}'
pl launch full-spot; pl watch
ok "pauses" eq "$RC" 3
ok "says why" has "PAUSED: the give-up time has passed"
ok "attempt 2 ends by the give-up time" eq "$(cq 'c[1]["t"]+int(c[1]["opt"]["max-run-duration"][:-1]) <= '"$T0"'+3600')" True
ok "Google's deletion ended attempt 2" eq "$(wq '[d["how"] for d in w["deaths"]]')" "['reclaim', 'maxrun']"
ok "under cap, no row open" cap_ok
end

# ---- 7. No capacity in any zone: wait (nothing open), then start
begin no_capacity_wait
ZONES="us-central1-a us-east1-b"
wset 'w["plan"]={"1":{"run":600,"end":"reclaim"},"2":{"run":600,"end":"done"}}'
pl launch full-spot; ok "launch" eq "$RC" 0
wset 'w["nocap_until_zones"]=["us-central1-a","us-east1-b"]; w["nocap_until"]=now+600+1700'    # from just after attempt 1's start
pl watch
ok "finishes" eq "$RC" 0
ok "waited 600 s at least twice" eq "$(wq 'w["sleeps"].count(600)>=2')" True
ok "the waits opened only zero-cost rows, all closed" eq "$(lq 'all(r["usd"]=="0.00" and r["secs"]=="0" for r in rows if r["mode"]=="full-spot#2" and r["zone"]=="pending")')" True
ok "said it would try again" has "no zone has capacity for attempt 2"
ok "under cap, no row open" cap_ok
end

# ---- 8. teardown during a Spot run keeps the state; watch then continues the run
begin teardown_keeps_state
wset 'w["plan"]={"1":{"run":9000,"end":"reclaim"},"2":{"run":600,"end":"done"}}'
pl launch full-spot; guest 900
pl teardown
ok "teardown succeeds" eq "$RC" 0
ok "the state is kept, paused" eq "$(sv PAUSED)" "manual teardown"
ok "the row is closed" eq "$(lq 'rows[-1]["ended"]!=""')" True
ok "nothing left" eq "$(wq 'len(w["instances"])+len(w["disks"])')" 0
pl launch full; ok "an on-demand launch is refused while the Spot run is paused" has "a paused Spot run has its state"
pl watch
ok "watch continues and finishes" eq "$RC" 0
ok "two attempts" eq "$(cq 'len(c)')" 2
end

# ---- 9. abandon
begin abandon
wset 'w["plan"]={"default":{"run":9000,"end":"reclaim"}}'
pl launch full-spot
pl abandon; ok "refused while the attempt's row is open" eq "$RC" 1
ok "state kept" eq "$([ -e "$STATEF" ] && echo yes || echo no)" yes
pl teardown; pl abandon
ok "abandon after teardown" eq "$RC" 0
ok "state removed" eq "$([ -e "$STATEF" ] && echo yes || echo no)" no
ok "prints how to delete the checkpoints" has "storage rm -r gs://testbucket/ckpt/"
ok "prints what the checkpoints cost a month" has "GiB; at 0.020 USD per GiB-month"
pl abandon; ok "nothing left to abandon" has "no run state found"
end

# ---- 10. watch stopped mid-attempt (terminal closed), the attempt ends unwatched, watch started again
begin watch_reentry
wset 'w["plan"]={"1":{"run":2000,"end":"reclaim","progress":100},"2":{"run":900,"end":"done"}}; w["stop_watch_at"]=now+800'
pl launch full-spot; pl watch
ok "watch stopped by the signal" eq "$RC" 130
ok "says the VM is still running" has "Attempt 1 is still running"
ok "nothing was torn down" eq "$(wq 'len(w["instances"])')" 1
guest 3000
pl watch
ok "watch picks up and finishes" eq "$RC" 0
ok "says the row may over-count the unwatched time" grep -q "nobody saw attempt 1's VM during the last .* minutes before its row was closed" "$C/all.out"
ok "two attempts, one VM at a time (the fake checks)" eq "$(cq 'len(c)')" 2
ok "under cap, no row open" cap_ok
end

# ---- 11. The checkpoints cannot be read after the attempt ends: stop with nothing running; a second watch accounts once
begin account_reentry
ZONES="us-east1-b"
wset 'w["plan"]={"1":{"run":600,"end":"reclaim","progress":100,"bytes":2**30},"2":{"run":600,"end":"done"}}; w["fail"]=[{"match":"storage cp gs://testbucket/ckpt/","times":1,"msg":"ERROR: network unreachable"}]'
pl launch full-spot; pl watch
ok "stops" eq "$RC" 1
ok "says what to do" has "could not read the run's checkpoints"
ok "the row is closed (the VM was verified gone first)" eq "$(lq 'rows[-1]["ended"]!=""')" True
ok "no second VM" eq "$(cq 'len(c)')" 1
pl watch
ok "second watch finishes" eq "$RC" 0
ok "attempt 1 counted as progress exactly once" grep -q "attempt 1 accounted for: progress 100 (attempts in a row without progress: 0)" "$C/all.out"
ok "one transfer row for attempt 1" eq "$(lq 'sum(1 for r in rows if r["mode"]=="full-spot#1-transfer")')" 1
end

# ---- 12. Ambiguous API answers
begin ambiguous_create
wset 'w["plan"]={"default":{"run":600,"end":"done"}}; w["fail"]=[{"match":"instances create","times":1},{"match":"instances list --filter","times":1}]'
pl launch full-spot
ok "launch stops when it cannot tell whether the VM exists" eq "$RC" 1
ok "row left open" eq "$(lq 'rows[-1]["ended"]')" ""
pl watch
ok "watch finds it gone, accounts for attempt 1 (no create reached the API), and starts attempt 2" eq "$(cq '[x["md"]["full-attempt"] for x in c]')" "['2']"
ok "finishes" eq "$RC" 0
end
begin create_reports_error_but_vm_exists
wset 'w["plan"]={"default":{"run":600,"end":"done"}}; w["fail"]=[{"match":"instances create","times":1,"create_anyway":True}]'
pl launch full-spot
ok "launch watches the VM that exists" has "exists in us-central1-a (status RUNNING) although create reported an error"
ok "zone filled in" eq "$(lq 'rows[-1]["zone"]')" us-central1-a
pl watch; ok "finishes" eq "$RC" 0
end
begin purge_not_verified
wset 'w["plan"]={"1":{"run":600,"end":"reclaim"},"2":{"run":600,"end":"done"}}; w["fail"]=[{"match":"disks list --format=value(name,zone.basename(),sizeGb)","times":1000}]'
pl launch full-spot; pl watch
ok "watch stops after 10 minutes of failed listings" eq "$RC" 1
ok "it kept trying for 10 minutes" eq "$(wq 'w["sleeps"].count(15) >= 40')" True
wset 'w["fail"]=[]'
ok "says so" has "NOT VERIFIED that attempt 1 is gone"
ok "row stays open" eq "$(lq 'rows[-1]["ended"]')" ""
ok "no second VM" eq "$(cq 'len(c)')" 1
pl watch; ok "second watch finishes" eq "$RC" 0
ok "two attempts" eq "$(cq 'len(c)')" 2
end

# ---- 13. The rehearsal's cuts: build:simulate once a part of this attempt is saved, seal:delete, c3:reset once
# replay results are saved (the default GCP_SPOT_REHEARSAL_CUTS)
begin rehearsal_cuts
EXTRA=()
wset 'w["plan"]={"default":{"run":1500,"end":"done","part_at":400,"results_at":1000,"phases":[[0,"setup"],[200,"build"],[700,"seal"],[900,"c3"]]}}; w["track_cuts"]=True'
pl launch full-spot-rehearsal; ok "launch" eq "$RC" 0
pl watch
ok "finishes" eq "$RC" 0
ok "four attempts" eq "$(cq 'len(c)')" 4
ok "attempt 1 cut by a simulated reclaim, only once it had saved a part" eq "$(wq '[(s["attempt"], s["t"]-'"$T0"' >= 400) for s in w["simulated"]]')" "[(1, True)]"
ok "the simulated reclaim was sent with --async" grep -q '"simulate-maintenance-event", "lean-full-spot-rehearsal", "--zone=us-central1-a", "--async"' "$FAKE/calls.jsonl"
ok "attempt 3 cut by a hard reset, only once it had saved replay results" eq "$(wq '[r["attempt"] for r in w["resets"]]') $(( $(wq 'w["resets"][0]["t"]') - $(cq 'c[2]["t"]') >= 1000 ))" "[3] 1"
ok "attempts 2 and 3 deleted by the watcher" eq "$(wq '[(d["attempt"],d["how"]) for d in w["deaths"]]')" "[(1, 'simulate'), (2, 'deleted'), (3, 'deleted'), (4, 'deleted')]"
ok "polls every 20 s" eq "$(wq 'w["sleeps"].count(20) > 50 and 45 not in w["sleeps"]')" True
ok "rehearsal metadata" eq "$(cq 'c[0]["md"]["pilot-mode"], c[0]["md"]["full-keep-oleans"], c[0]["md"]["full-spot-hold"], c[0]["md"]["full-ckpt-every"], c[0]["md"]["full-confirm-every"], int(c[0]["opt"]["max-run-duration"][:-1])<=4500, int(c[0]["md"]["pilot-deadline-min"])==(int(c[0]["opt"]["max-run-duration"][:-1])-900)//60')" "('full-rehearsal', '0', 'seal:90', '120', '45', True, True)"
RT=$(lq 'rows[0]["tag"]')
ok "the cuts report: all three done as configured" eq "$(grep -c ': done as configured' "$C/last.out") $(grep -c 'NOT DONE\|fallback\|DID NOT EXERCISE' "$C/last.out")" "3 0"
ok "  ... and kept in the results folder" eq "$(cat "$TR/work/analysis/pilot/$RT/cuts.txt" 2>/dev/null | tr '\n' '|')" "build:simulate: done as configured|seal:delete: done as configured|c3:reset: done as configured|"
ok "the simulate was pending in the state from its request until the guest's RECLAIMED, and done only after that" eq "$(wq '[v for t, v in w["cuts_seen"]][:3]') $(wq 'next(t for t, v in w["cuts_seen"] if v == "build:simulate") >= w["deaths"][0]["t"] > next(t for t, v in w["cuts_seen"] if v == "build:simulate>pending") >= w["simulated"][0]["t"]')" "['', 'build:simulate>pending', 'build:simulate'] True"
ok "the delete cut was pending until its deletion had been verified" eq "$(wq '[v for t, v in w["cuts_seen"]][3:5]') $(wq 'next(t for t, v in w["cuts_seen"] if v == "build:simulate seal:delete") >= w["deaths"][1]["t"]')" "['build:simulate seal:delete>pending', 'build:simulate seal:delete'] True"
end
begin rehearsal_simulate_refused
EXTRA=(GCP_SPOT_REHEARSAL_CUTS=build:simulate)
wset 'w["plan"]={"default":{"run":1500,"end":"done","part_at":400,"phases":[[0,"setup"],[200,"build"]]}}; w["fail"]=[{"match":"simulate-maintenance-event","times":1}]'
pl launch full-spot-rehearsal; pl watch
ok "finishes, with exit status 4: the cut was not done as configured" eq "$RC" 4
ok "a refused simulated reclaim falls back to deleting, after a look at the VM" has "the simulated reclaim was refused, lean-full-spot-rehearsal is RUNNING; deleting instead"
ok "two attempts; the cut is not made again" eq "$(cq 'len(c)') $(grep -c 'rehearsal cut build:simulate in attempt' "$C/all.out")" "2 1"
ok "the fallback is reported as such" has "build:simulate: done by fallback (delete)"
ok "  ... with the line that says the rehearsal did not exercise it" has "THE REHEARSAL DID NOT EXERCISE WHAT IT WAS CONFIGURED TO: 1 of its cuts"
ok "  ... and in cuts.txt" eq "$(cat "$TR/work/analysis/pilot/$(lq 'rows[0]["tag"]')/cuts.txt" 2>/dev/null)" "build:simulate: done by fallback (delete)"
end
begin rehearsal_c3_never
mkdir -p "$C/mirror"; EXTRA=(GCP_RESULTS_MIRROR_DIR="$C/mirror")
wset 'w["plan"]={"default":{"run":1500,"end":"done","part_at":400,"phases":[[0,"setup"],[200,"build"],[700,"seal"],[900,"c3"]]}}'
pl launch full-spot-rehearsal; pl watch
RT=$(lq 'rows[0]["tag"]')
ok "a rehearsal whose c3 gate never opens finishes with exit status 4" eq "$RC" 4
ok "  ... printing NOT DONE for c3 and done for the other two" eq "$(grep -c 'c3:reset: NOT DONE' "$C/last.out") $(grep -c ': done as configured' "$C/last.out")" "1 2"
ok "  ... with cuts.txt in the results folder and the mirror" eq "$(grep -c NOT "$TR/work/analysis/pilot/$RT/cuts.txt") $(cmp -s "$TR/work/analysis/pilot/$RT/cuts.txt" "$C/mirror/$RT/cuts.txt" && echo same)" "1 same"
ok "  ... and the run itself is over" eq "$(grep -c 'is over after 3 attempt' "$C/last.out") $([ -e "$STATEF" ] && echo yes || echo no)" "1 no"
end
begin rehearsal_cuts_on_pause
EXTRA=(GCP_SPOT_MAX_ATTEMPTS=1)
wset 'w["plan"]={"default":{"run":1500,"end":"done","part_at":400,"phases":[[0,"setup"],[200,"build"],[700,"seal"],[900,"c3"]]}}'
pl launch full-spot-rehearsal; pl watch
ok "a paused rehearsal reports its cuts so far" eq "$RC $(grep -c 'build:simulate: done as configured' "$C/last.out") $(grep -c 'seal:delete: NOT DONE' "$C/last.out")" "3 1 1"
pl abandon
ok "  ... and so does abandon" eq "$RC $(grep -c 'c3:reset: NOT DONE' "$C/last.out") $(grep -c NOT "$TR/work/analysis/pilot/$(lq 'rows[0]["tag"]')/cuts.txt")" "0 1 2"
end
begin rehearsal_simulate_no_effect
# Google accepts the simulated reclaim and nothing happens: the VM is still RUNNING 5 minutes later and is deleted
EXTRA=(GCP_SPOT_REHEARSAL_CUTS=build:simulate)
wset 'w["plan"]={"default":{"run":1500,"end":"done","part_at":400,"phases":[[0,"setup"],[200,"build"]]}}; w["simulate_noop"]=True'
pl launch full-spot-rehearsal; pl watch
ok "finishes with exit status 4" eq "$RC" 4
ok "  ... the attempt ended 5 minutes after the accepted simulate, by a delete" has "attempt 1 is over: the VM was still there 5 minutes after the simulated reclaim (deleting instead)"
ok "  ... one simulate sent, and the VM deleted by the watcher" eq "$(wq 'len(w["simulated"])') $(wq '[(d["attempt"],d["how"]) for d in w["deaths"]][0]')" "1 (1, 'deleted')"
ok "  ... reported as done by fallback (delete)" has "build:simulate: done by fallback (delete)"
ok "  ... with the line that says the rehearsal did not exercise it" has "THE REHEARSAL DID NOT EXERCISE WHAT IT WAS CONFIGURED TO: 1 of its cuts"
end
begin rehearsal_cut_interrupted
# The watch is killed outright while the fake's reset is in flight; the reset reached Google, but the watch never
# learned how it ended
EXTRA=(GCP_SPOT_REHEARSAL_CUTS=build:reset)
wset 'w["plan"]={"default":{"run":1500,"end":"done","part_at":400,"phases":[[0,"setup"],[200,"build"]]}}; w["kill_watch_on_reset"]=True'
pl launch full-spot-rehearsal; { pl watch; } 2>/dev/null       # (the shell's own "Killed: 9" notice is not wanted here)
ok "the watch was killed during the reset" eq "$RC $(wq 'len(w["resets"])')" "137 1"
ok "  ... the cut is recorded as pending, for this attempt" eq "$(sv CUTS_DONE) $(sv CUT_ATTEMPT)" "build:reset>pending 1"
pl watch
ok "the next watch takes the lock at once and finishes, with exit status 4" eq "$RC" 4
ok "  ... the cut was never sent again, in this attempt or the next" eq "$(wq 'len(w["resets"])') $(cq 'len(c)') $(grep -c 'rehearsal cut build:reset in attempt' "$C/all.out")" "1 2 1"
ok "  ... and is reported NOT DONE (interrupted, or never seen to take effect)" has "build:reset: NOT DONE (interrupted, or never seen to take effect)"
ok "  ... in cuts.txt too" eq "$(cat "$TR/work/analysis/pilot/$(lq 'rows[0]["tag"]')/cuts.txt" 2>/dev/null)" "build:reset: NOT DONE (interrupted, or never seen to take effect)"
ok "under cap, no row open" cap_ok
end
begin rehearsal_delete_cut_purge_fails
# A delete cut, then the purge cannot list for 10 minutes: the watch stops with the row open and the cut pending.
# The next watch does not go back to polling the attempt: it deletes it, verifies, and the cut is done; the run goes on.
EXTRA=(GCP_SPOT_REHEARSAL_CUTS=seal:delete)
wset 'w["plan"]={"default":{"run":3000,"end":"done","phases":[[0,"setup"],[200,"build"],[700,"seal"],[2500,"c3"]]}}; w["fail"]=[{"match":"--format=csv[no-heading](name,zone.basename())","times":100},{"match":"--format=value(name,zone.basename(),status)","times":100}]'
pl launch full-spot-rehearsal; ok "launch" eq "$RC" 0
pl watch
ok "the watch stops: the purge after the cut could not verify" eq "$RC $(grep -c 'rehearsal cut seal:delete in attempt 1' "$C/last.out") $(grep -c 'NOT VERIFIED that attempt 1 is gone' "$C/last.out")" "1 1 1"
ok "  ... the cut pending for attempt 1, the VM still there and its row open" eq "$(sv CUTS_DONE) $(sv CUT_ATTEMPT) $(sv CUT_ITEM) $(wq 'len(w["instances"])') $(lq 'sum(1 for r in rows if r["ended"]=="")')" "seal:delete>pending 1 seal:delete 1 1"
wset 'w["fail"]=[]'; t2=$(cat "$FAKE/clock")
pl watch
ok "the next watch finishes" eq "$RC" 0
ok "  ... ending attempt 1 at once, without polling it again" has "attempt 1 is over: rehearsal cut seal:delete (its deletion is not verified yet)"
ok "  ... deleting it before any time passed" eq "$(wq '[(d["attempt"], d["how"], d["t"]) for d in w["deaths"]][0]')" "(1, 'deleted', $t2)"
ok "  ... the run went on to the next attempt, which was not cut" eq "$(cq 'len(c) >= 2') $(grep -c 'rehearsal cut seal:delete in attempt' "$C/all.out")" "True 1"
ok "  ... and the cut is done as configured" eq "$(grep -c 'seal:delete: done as configured' "$C/last.out") $(grep -c 'NOT DONE\|fallback\|DID NOT EXERCISE' "$C/last.out")" "1 0"
ok "  ... in cuts.txt too" eq "$(cat "$TR/work/analysis/pilot/$(lq 'rows[0]["tag"]')/cuts.txt" 2>/dev/null)" "seal:delete: done as configured"
ok "under cap, no row open" cap_ok
end
begin rehearsal_simulate_watch_restarted
# Google accepts the simulated reclaim and nothing happens; the watch is stopped 160 s after the request and started
# again: the fallback still fires 300 s after the request was sent
EXTRA=(GCP_SPOT_REHEARSAL_CUTS=build:simulate)
wset 'w["plan"]={"default":{"run":1500,"end":"done","part_at":400,"phases":[[0,"setup"],[200,"build"]]}}; w["simulate_noop"]=True; w["stop_after_simulate"]=160'
pl launch full-spot-rehearsal; pl watch
ok "the watch is stopped after the simulate" eq "$RC $(wq 'len(w["simulated"])')" "130 1"
d=$(( $(cat "$FAKE/clock") - $(sv CUT_AT) ))
ok "  ... with the cut pending and its send time in the state" eq "$(sv CUTS_DONE) $(sv CUT_ITEM) $(( $(sv CUT_AT) == $(wq 'w["simulated"][0]["t"]') )) $(( d >= 160 && d < 200 ))" "build:simulate>pending build:simulate 1 1"
pl watch
ok "the next watch finishes with exit status 4" eq "$RC" 4
ok "  ... the fallback fired 300 s after the simulate was sent, not 300 s after this watch began" eq "$(wq '(lambda d, s: (d["attempt"], d["how"], 300 <= d["t"] - s < 340))(w["deaths"][0], w["simulated"][0]["t"])')" "(1, 'deleted', True)"
ok "  ... saying why" has "attempt 1 is over: the VM was still there 5 minutes after the simulated reclaim (deleting instead)"
ok "  ... the simulate was not sent again" eq "$(wq 'len(w["simulated"])')" 1
ok "  ... reported as done by fallback (delete)" has "build:simulate: done by fallback (delete)"
ok "  ... with the line that says the rehearsal did not exercise it" has "THE REHEARSAL DID NOT EXERCISE WHAT IT WAS CONFIGURED TO: 1 of its cuts"
ok "  ... and in cuts.txt" eq "$(cat "$TR/work/analysis/pilot/$(lq 'rows[0]["tag"]')/cuts.txt" 2>/dev/null)" "build:simulate: done by fallback (delete)"
end
begin rehearsal_simulate_then_done
# Google accepts the simulated reclaim and nothing happens; the guest reports DONE within the 300 s
EXTRA=(GCP_SPOT_REHEARSAL_CUTS=build:simulate)
wset 'w["plan"]={"default":{"run":600,"end":"done","part_at":400,"phases":[[0,"setup"],[200,"build"]]}}; w["simulate_noop"]=True'
pl launch full-spot-rehearsal; pl watch
ok "finishes with exit status 4" eq "$RC" 4
ok "  ... the attempt ended by the guest's DONE, less than 300 s after the accepted simulate" eq "$(grep -c 'attempt 1 is over: the guest reported DONE' "$C/last.out") $(wq '(lambda s: 0 < w["deaths"][0]["t"] - s < 300)(w["simulated"][0]["t"])') $(cq 'len(c)')" "1 True 1"
ok "  ... reported NOT DONE: the simulate was never seen to take effect" has "build:simulate: NOT DONE (interrupted, or never seen to take effect)"
ok "  ... with the line that says the rehearsal did not exercise it" has "THE REHEARSAL DID NOT EXERCISE WHAT IT WAS CONFIGURED TO: 1 of its cuts"
ok "  ... and in cuts.txt" eq "$(cat "$TR/work/analysis/pilot/$(lq 'rows[0]["tag"]')/cuts.txt" 2>/dev/null)" "build:simulate: NOT DONE (interrupted, or never seen to take effect)"
end

# ---- 14. The commit rule across attempts
begin commit_rule
wset 'w["plan"]={"default":{"run":600,"end":"reclaim"}}'
pl launch full-spot
echo 2222222222222222222222222222222222222222 > "$FAKE/git_head"
pl watch
ok "a new HEAD with the old staged archive pauses" has "PAUSED: the staged scripts are from commit 1111"
echo "toolsha0456 2222222222222222222222222222222222222222" > "$TR/work/analysis/pilot/rhv_tools.id"
pl watch
ok "a new commit, staged, still pauses" has "PAUSED: this run began at commit 1111"
ok "no second VM" eq "$(cq 'len(c)')" 1
end

# ---- 15. launch refusals
begin launch_refusals
wset 'w["plan"]={"default":{"run":9000,"end":"reclaim"}}'
pl launch full-spot
pl launch full-spot; ok "refused while a state exists" has "'bash .* watch' continues it, 'bash .* abandon' ends it"
mv "$STATEF" "$STATEF.x"; pl launch full-spot; ok "refused while a row is open" has "a run is still open in the ledger"
end
begin launch_refuses_instance
wset 'w["instances"]={"other":{"zone":"us-central1-a","status":"RUNNING","created":0,"maxrun":99999,"md":{},"runtag":"x","legacy":True,"disks":[]}}'
pl launch full-spot; ok "refused while an instance exists" has "an instance already exists in the project (other)"
ok "nothing created" eq "$(cq 'len(c)')" 0
ok "  ... and no run state is left" eq "$([ -e "$STATEF" ] && echo yes || echo no)" no
end
begin launch_refuses_commit
echo " M scripts/x.sh" > "$FAKE/git_dirty"
pl launch full-spot
ok "a Spot launch refused at the commit rule" eq "$RC $(cq 'len(c)')" "1 0"
ok "  ... saying why" has "scripts/ or cloud/ has uncommitted or untracked files"
ok "  ... leaves no run state and no row" eq "$([ -e "$STATEF" ] && echo yes || echo no) $(lq 'len(rows)')" "no 0"
end

# ---- 15b. One Spot command at a time: a lock the kernel keeps. Held by a live process, it refuses every Spot
# command and they change nothing; once that process is killed outright the next command takes it at once; of
# eight takers at once exactly one gets it; the lock file an earlier run left does not block; old modes take none.
# lockrun <lock file> <command> <seconds to hold, -1 for ever>: a bash running a copy of the launcher's own
# spot_lock, which then holds the lock while it sleeps (its sleeps started with the descriptor closed, as the
# launcher's are). Prints GOT once it holds it, DIED: <sentence> when refused.
{ echo 'die() { echo "DIED: $*"; exit 1; }'
  awk '/^spot_lock\(\) \{/ {on = 1} on {print} on && /^}/ {on = 0}' "$NEWSCRIPT"
  echo 'SPOT_LOCK=$1; SELF=x; spot_lock "$2" && echo GOT; n=$3; while [ "$n" != 0 ]; do /bin/sleep 1 9>&-; n=$((n - 1)); done'
} > "$WORK/lockrun.sh"
# lockorphan <lock file> <command> <seconds>: the same, but the bash that took the lock exits at once and leaves a
# child holding it (a sleep with the descriptor open, as a gcloud child would); prints GOT and CHILD <its pid>.
{ echo 'die() { echo "DIED: $*"; exit 1; }'
  awk '/^spot_lock\(\) \{/ {on = 1} on {print} on && /^}/ {on = 0}' "$NEWSCRIPT"
  echo 'SPOT_LOCK=$1; SELF=x; spot_lock "$2" && echo GOT; /bin/sleep "$3" & echo "CHILD $!"'
} > "$WORK/lockorphan.sh"
# lock_free <lock file> [tries]: "free" once a lock of it can be taken (tried every 0.1 s, 100 times by default), else "held"
lock_free() { python3 -I -c 'import fcntl, os, sys, time
for i in range(int(sys.argv[2])):
    fd = os.open(sys.argv[1], os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); print("free"); sys.exit(0)
    except OSError:
        time.sleep(0.1)
    finally:
        os.close(fd)
print("held")' "$1" "${2:-100}"; }
holder() { # holder <command>: a live process holding this case's lock for ever, as $LP
  /bin/bash "$WORK/lockrun.sh" "$STATEF.lock" "$1" -1 > "$C/holder.out" 2>&1 & LP=$!
  local n=0; while ! grep -q GOT "$C/holder.out" && [ $n -lt 50 ]; do /bin/sleep 0.1; n=$((n + 1)); done
}
ncalls() { if [ -e "$FAKE/calls.jsonl" ]; then wc -l < "$FAKE/calls.jsonl" | tr -d ' '; else echo 0; fi; }
same_files() { cmp -s "$1" "$2" || { echo "      $1 changed"; return 1; }; }
begin lock
ok "the launcher's spot_lock was found" eq "$(grep -c '^spot_lock() {' "$WORK/lockrun.sh") $(grep -c 'fcntl.flock' "$WORK/lockrun.sh")" "1 1"
wset 'w["plan"]={"1":{"run":900,"end":"reclaim"},"2":{"run":600,"end":"done"}}'
pl launch full-spot; ok "launch" eq "$RC" 0
ok "the lock file is a regular file, left by launch" eq "$([ -f "$STATEF.lock" ] && echo file)" file
/bin/bash "$WORK/lockrun.sh" "$STATEF.lock" watch -1 > "$C/holder.out" 2>&1 & LP=$!
n=0; while ! grep -q GOT "$C/holder.out" && [ $n -lt 50 ]; do /bin/sleep 0.1; n=$((n + 1)); done
ok "a live process holds the lock" eq "$(cat "$C/holder.out")" GOT
cp "$STATEF" "$C/state.before"; cp "$LEDGER" "$C/ledger.before"; ncalls=$(wc -l < "$FAKE/calls.jsonl")
for cmd in teardown watch abandon "launch full-spot"; do
  pl $cmd
  ok "$cmd refused while a live process holds the lock" eq "$RC" 1
  ok "  ... naming the holder's command and process, what to do, and to try again in a few minutes" has "another command of this Spot run is running: 'watch' (process $LP).*Ctrl-C.*kill $LP), then run: bash .* teardown.*try again in a few minutes"
  ok "  ... and changing nothing (state, ledger, no call to the cloud)" eq "$(same_files "$C/state.before" "$STATEF" && same_files "$C/ledger.before" "$LEDGER" && wc -l < "$FAKE/calls.jsonl" | tr -d ' ') $(wq 'len(w["instances"])')" "$(echo $ncalls) 1"
done
kill -KILL "$LP"; wait "$LP" 2>/dev/null
nsleeps=$(wq 'len(w["sleeps"])')
pl teardown
ok "after the holder is killed with -9, the next command takes the lock at once" eq "$RC $(wq 'len(w["instances"])') $(wq 'len(w["sleeps"])')" "0 0 $nsleeps"
ok "  ... with no word of a stale lock or a takeover" eq "$(grep -ci 'stale\|taking over' "$C/last.out")" 0
ok "  ... and it names itself in the info file" eq "$(sed -n 2p "$STATEF.lock.info")" teardown
pl watch; ok "watch then finishes the run" eq "$RC" 0
ok "the lock file is never removed" eq "$([ -f "$STATEF.lock" ] && echo kept)" kept
wset 'w["last_attempt"]=0'      # a new run counts its attempts from 1 again
pl launch full-spot
ok "the lock file left by an earlier run does not block a new run" eq "$RC $(cq 'len(c)')" "0 3"
end
begin lock_race
mkdir -p "$C/race"; bad=""
for r in 1 2 3 4 5 6 7 8 9 10; do
  L="$C/race/lock$r"; pids=""
  for i in 1 2 3 4 5 6 7 8; do /bin/bash "$WORK/lockrun.sh" "$L" "race$i" 3 > "$C/race/$r.$i.out" 2>&1 & pids="$pids $!"; done
  for p in $pids; do wait "$p"; done
  g=$(cat "$C/race/$r".*.out | grep -c '^GOT'); d=$(cat "$C/race/$r".*.out | grep -c '^DIED: another command of this Spot run is running')
  [ "$g $d" = "1 7" ] || bad="$bad round $r: $g got it, $d refused;"
  cat "$C/race/$r".*.out >> "$C/all.out"
done
ok "of eight takers of a free lock at once, exactly one gets it and seven are refused, ten rounds out of ten" eq "$bad" ""
end
begin lock_old_modes
CAP=200; EXTRA=(); wset 'w["plan"]={"legacy":{"run":400,"end":"done"}}'
pl launch rehearsal; ok "launch rehearsal (an old mode) runs" eq "$RC" 0
pl watch
ok "  ... and neither it nor its watch and teardown creates a lock file" eq "$(ls "$TR/work/analysis" | grep -c 'lock')" 0
end
begin lock_held_old_modes
# A Spot command has run here (the lock file exists) and one holds the lock: old-mode launch and teardown are refused
CAP=200; EXTRA=(); wset 'w["plan"]={"legacy":{"run":400,"end":"done"}}'
holder watch
ok "a live process holds the lock" eq "$(cat "$C/holder.out")" GOT
pl launch rehearsal
ok "old-mode launch rehearsal is refused while the lock is held" eq "$RC" 1
ok "  ... with the lock's refusal" has "another command of this Spot run is running: 'watch' (process $LP)"
ok "  ... before anything: no call to the cloud, no row, no state" eq "$(ncalls) $(lq 'len(rows)') $([ -e "$STATEF" ] && echo yes || echo no)" "0 0 no"
pl teardown
ok "the old-path teardown is refused too, with no call to the cloud" eq "$RC $(ncalls) $(grep -c "another command of this Spot run is running: 'watch'" "$C/last.out")" "1 0 1"
kill -KILL "$LP"; wait "$LP" 2>/dev/null
end
begin launch_killed_early_watch
# A Spot launch killed outright at its first call to the cloud has already written the run's state (ATTEMPT=0):
# while a (pretend) launch holds the lock with that state, teardown is refused and the state is intact; once it is
# gone, watch continues the run
wset 'w["plan"]={"default":{"run":600,"end":"done"}}; w["kill_launcher_on"]="compute instances list"'
{ pl launch full-spot; } 2>/dev/null
ok "the launch is killed at its first call to the cloud" eq "$RC $(ncalls) $(cq 'len(c)')" "137 1 0"
ok "  ... after writing the run's state: a Spot run with no attempt, and no row" eq "$(sv SPOT) $(sv ATTEMPT) $(sv MODE) $(sv STARTING)- $(lq 'len(rows)')" "1 0 full-spot - 0"
ok "  ... and the lock is free again" eq "$(lock_free "$STATEF.lock")" free
holder "launch full-spot"
cp "$STATEF" "$C/state.before"; n0=$(ncalls)
pl teardown
ok "teardown is refused while the launch holds the lock" eq "$RC" 1
ok "  ... naming it" has "another command of this Spot run is running: 'launch full-spot' (process $LP)"
ok "  ... and the state is intact, with no call to the cloud" eq "$(same_files "$C/state.before" "$STATEF" && ncalls)" "$n0"
pl launch rehearsal
ok "old-mode launch is refused too" eq "$RC $(ncalls) $(grep -c "another command of this Spot run is running: 'launch full-spot'" "$C/last.out")" "1 $n0 1"
kill -KILL "$LP"; wait "$LP" 2>/dev/null
pl watch
ok "watch continues the run from that state: attempt 1 starts, and the run finishes" eq "$RC $(cq 'len(c)') $(cq 'c[0]["md"]["full-attempt"]') $([ -e "$STATEF" ] && echo state || echo none)" "0 1 1 none"
ok "under cap, no row open" cap_ok
end
begin launch_killed_early_abandon
wset 'w["plan"]={"default":{"run":600,"end":"done"}}; w["kill_launcher_on"]="compute instances list"'
{ pl launch full-spot; } 2>/dev/null
ok "the launch is killed after writing the run's state" eq "$RC $(sv SPOT) $(sv ATTEMPT)" "137 1 0"
pl abandon
ok "abandon ends that run: no state, nothing created, no row" eq "$RC $([ -e "$STATEF" ] && echo state || echo none) $(cq 'len(c)') $(lq 'len(rows)')" "0 none 0 0"
ok "  ... saying so" has "abandoned full-spot-.* after 0 attempt(s)"
end
begin old_teardown_keeps_spot_state
# A Spot state appears while the old-path teardown runs (here, written during its last listing): it is kept
CAP=200; EXTRA=(); wset 'w["plan"]={"legacy":{"run":9000,"end":"done"}}'
pl launch rehearsal; ok "launch rehearsal" eq "$RC" 0
printf "SPOT='1'\nMODE='full-spot'\nRUNTAG='full-spot-x'\n" > "$C/spotstate"
SPOTST="$C/spotstate" STF="$STATEF" wset 'import os; w["on_call_file"]=[{"match":"--format=value(name,zone.basename(),status)","times":1,"path":os.environ["STF"],"text":open(os.environ["SPOTST"]).read()}]'
pl teardown
ok "the teardown verifies and closes the row" eq "$RC $(lq 'sum(1 for r in rows if r["ended"]=="")')" "0 0"
ok "  ... and keeps the Spot run's state, saying so" eq "$(grep -c 'a Spot run was launched meanwhile: its state in .* is kept' "$C/last.out") $(cmp -s "$C/spotstate" "$STATEF" && echo kept)" "1 kept"
end
begin old_teardown_hands_over_a_spot_state
# The first Spot launch ever in a work directory: no lock file yet, and its state appears just after the old-path
# teardown has looked for one. The teardown must not act on that run as if it were an old one (close its row, with
# its VM still being created): it hands over to the Spot teardown, which takes the lock. The state here is one the
# first look does not take for a Spot state (no quotes) but that reads as one, which is how the gap is reached.
printf 'SPOT=1\nMODE=full-spot\nRUNTAG=full-spot-x\nMAXRUN=600\n' > "$STATEF"; cp "$STATEF" "$C/spotstate"
printf 'runtag\tmode\tmachine\tusd_per_hour\tzone\tcreated_epoch\tended_epoch\tseconds\tusd\n' > "$LEDGER"
printf 'full-spot-x\tfull-spot#1\tn4d-highmem-32\t1.20\tpending\t%s\t\t\t\n' "$(cat "$FAKE/clock")" >> "$LEDGER"
pl teardown
ok "the old-path teardown does not act on a Spot run: it stops, having asked Google nothing" eq "$RC $(ncalls)" "1 0"
ok "  ... the run's row is still open and its state untouched" eq "$(lq 'sum(1 for r in rows if r["ended"]=="")') $(cmp -s "$C/spotstate" "$STATEF" && echo kept)" "1 kept"
end
begin launch_refusal_keeps_a_state_not_its_own
# An old-mode launch that started in the same instant has written its own state over the Spot launch's early one;
# the Spot launch, refused at its first look at the project, must leave that state alone.
printf "RUNTAG=rehearsal-x\nNAME=lean-rehearsal\nZONE=us-central1-a\nMODE=rehearsal\nCREATED=1\nMAXRUN=3000\nRATE=2.00\n" > "$C/oldstate"
OLDST="$C/oldstate" STF="$STATEF" wset 'import os; w["instances"]={"lean-rehearsal":{"zone":"us-central1-a","status":"RUNNING","created":0,"maxrun":99999,"md":{},"runtag":"rehearsal-x","legacy":True,"disks":[]}}; w["on_call_file"]=[{"match":"--format=value(name)","times":1,"path":os.environ["STF"],"text":open(os.environ["OLDST"]).read()}]'
pl launch full-spot
ok "the Spot launch is refused" has "an instance already exists in the project (lean-rehearsal)"
ok "  ... and the other run's state is still there, as it was" eq "$RC $(cmp -s "$C/oldstate" "$STATEF" && echo kept) $(cq 'len(c)')" "1 kept 0"
end
begin lock_orphan
# The command that took the lock has ended, but a child of it still holds the lock
/bin/bash "$WORK/lockorphan.sh" "$STATEF.lock" watch 120 > "$C/holder.out" 2>&1
OP=$(sed -n 1p "$STATEF.lock.info"); CP=$(awk '/^CHILD/ {print $2}' "$C/holder.out")
ok "the taker has ended and its child holds the lock" eq "$(grep -c GOT "$C/holder.out") $(kill -0 "$OP" 2>/dev/null && echo alive || echo ended) $(lock_free "$STATEF.lock" 1)" "1 ended held"
for cmd in teardown "launch full-spot"; do
  pl $cmd
  ok "$cmd is refused" eq "$RC $(ncalls)" "1 0"
  ok "  ... saying that the command itself has ended and that a child of it holds the lock for a few minutes" has "'watch' (process $OP), has itself ended, but a child process of it (usually gcloud) still holds the lock and will release it when it finishes, usually within a few minutes"
  ok "  ... and how to see which process holds it" has "to see which process holds the lock: lsof \"$STATEF.lock\""
  ok "  ... without telling the owner to kill the dead process number" eq "$(grep -c "kill $OP\|kill <" "$C/last.out")" 0
done
kill "$CP" 2>/dev/null
ok "once the child has finished, the lock is free" eq "$(lock_free "$STATEF.lock")" free
end
begin lock_directory
# A lock directory left by the round-3 design, at the lock file's path
mkdir "$STATEF.lock"
pl launch full-spot
ok "launch full-spot is refused" eq "$RC" 1
ok "  ... saying that it is a directory left by an earlier version, removable when no Spot command runs" has "the lock file .* is a directory, left by an earlier version of this script, so no Spot command can take the lock; nothing has been done. It can be removed (rm -r .*) when no Spot command is running"
CAP=200; pl launch rehearsal
ok "old-mode launch is refused the same way (the lock's path exists)" eq "$RC $(grep -c 'is a directory, left by an earlier version of this script' "$C/last.out")" "1 1"
ok "  ... and nothing was done" eq "$(ncalls) $([ -e "$STATEF" ] && echo state || echo none) $(lq 'len(rows)')" "0 none 0"
end

# ---- 15c. A ledger that has lost rows stops every start
begin ledger_lost
seed_spent 5.00
wset 'w["plan"]={"1":{"run":900,"end":"reclaim"},"2":{"run":600,"end":"done"}}'
pl launch full-spot; guest 1000; pl teardown
ok "the state remembers the ledger" eq "$(sv LEDGER_ROWS) $(sv SPENT_SEEN)" "2 $(lq '"%.2f" % sum(float(r["usd"]) for r in rows if r["usd"])')"
python3 -I -c 'import sys; L=open(sys.argv[1]).readlines(); open(sys.argv[1],"w").write("".join(L[:1]+L[2:]))' "$LEDGER"
pl watch
ok "watch pauses" eq "$RC" 3
ok "  ... saying the ledger has lost rows" has "PAUSED: the ledger .* has lost rows: it holds 1 rows"
ok "  ... and starts nothing" eq "$(cq 'len(c)')" 1
end

# ---- 15d. A create error that does not show that nothing was created: look again, never try a second zone
begin unclear_create_appears
ZONES="us-central1-a us-east1-b"
wset 'w["plan"]={"default":{"run":600,"end":"done"}}; w["fail"]=[{"match":"instances create","times":1,"create_anyway":True,"hidden":20,"msg":"ERROR: (gcloud.compute.instances.create) Read timed out"}]'
pl launch full-spot
ok "launch finds the VM that appeared 20 s later and watches it" has "lean-full-spot exists in us-central1-a (status RUNNING) although create reported an error"
ok "it waited 30 s before looking" eq "$(wq '30 in w["sleeps"]')" True
pl watch; ok "finishes" eq "$RC" 0
ok "one VM and one attempt row" eq "$(cq 'len(c)') $(lq 'len(rows)') $(lq 'rows[0]["zone"]')" "1 1 us-central1-a"
end
begin unclear_create_late
ZONES="us-central1-a us-east1-b"
wset 'w["plan"]={"default":{"run":900,"end":"done"}}; w["fail"]=[{"match":"instances create","times":1,"create_anyway":True,"hidden":120,"msg":"ERROR: (gcloud.compute.instances.create) Read timed out"}]'
pl launch full-spot
ok "launch stops with the row open when the VM is not listed yet" eq "$RC $(lq 'rows[-1]["ended"]')" "1 "
ok "  ... and says to run watch" has "Run 'bash .* watch' in a few minutes"
ok "no second zone was tried" eq "$(cq 'len(c)')" 1
pl watch; ok "watch then finds the VM and finishes" eq "$RC" 0
ok "one VM, one attempt row" eq "$(cq 'len(c)') $(lq 'len(rows)')" "1 1"
end
begin refusal_with_instance_listed
ZONES="us-central1-a us-east1-b"
wset 'w["plan"]={"default":{"run":600,"end":"done"}}; w["fail"]=[{"match":"instances create","times":1,"create_anyway":True,"msg":"ERROR: ZONE_RESOURCE_POOL_EXHAUSTED"}]'
pl launch full-spot
ok "a refusal while an instance is listed is not taken at its word" has "lean-full-spot exists in us-central1-a (status RUNNING) although create reported an error"
ok "one create" eq "$(cq 'len(c)')" 1
end
begin unclear_create_after_slow_refusals
# Each create takes 200 s to be answered; two zones refuse; the third reports an error but makes the VM, which is
# listed only 260 s after that create was sent (after the launcher's look 30 s after the error). CREATED, the
# row's time, is then more than 600 s old at the first poll, but the create that went unclear is not 300 s old.
ZONES="us-central1-a us-central1-b us-central1-c"
wset 'w["plan"]={"default":{"run":1200,"end":"done"}}; w["create_delay"]=200; w["nocap"]=["us-central1-a","us-central1-b"]; w["fail"]=[{"match":"create lean-full-spot --zone=us-central1-c","times":1,"create_anyway":True,"hidden":60,"msg":"ERROR: (gcloud.compute.instances.create) Read timed out"}]'
pl launch full-spot
ok "launch stops with the row open" eq "$RC $(lq 'rows[-1]["ended"]')" "1 "
ok "  ... the unclear create was sent more than 300 s after the row was opened" eq "$(( $(sv CREATE_SENT) - $(sv CREATED) >= 300 ))" 1
wset 'w["create_delay"]=0'
pl watch
ok "watch waits for the late VM and finishes" eq "$RC" 0
ok "still one VM and one row" eq "$(cq 'len([x for x in c if x["md"]["full-attempt"]=="1"])') $(wq 'len(w["deaths"])') $(lq 'len(rows)')" "3 1 1"
ok "the VM was watched, not taken as gone" has "attempt 1 is over: the guest reported DONE"
end
begin silent_counts_from_create_sent
# Each create takes 300 s to be answered and two zones refuse first, so the create that made the VM was sent 600 s
# after the row was opened. A guest that never reports is given up 25 minutes after THAT create, not after the row.
ZONES="us-central1-a us-central1-b us-central1-c"
wset 'w["plan"]={"1":{"run":99999,"end":"silent"},"2":{"run":600,"end":"done"}}; w["create_delay"]=300; w["nocap_for_attempt"]={"1":["us-central1-a","us-central1-b"]}'
pl launch full-spot; ok "launch" eq "$RC" 0
ok "  ... the create that made the VM was sent 600 s after the row was opened" eq "$(( $(sv CREATE_SENT) - $(sv CREATED) ))" 600
wset 'w["create_delay"]=0'
pl watch
ok "finishes" eq "$RC" 0
ok "  ... attempt 1 given up as silent" has "attempt 1 is over: the guest has reported nothing for this attempt in 25 minutes"
ok "  ... no sooner than 1500 s after its create was sent" eq "$(( $(wq '[d["t"] for d in w["deaths"] if d["attempt"]==1][0]') - $(cq 'c[2]["t"]') > 1500 ))" 1
end
begin refusal_leaves_disk
ZONES="us-central1-a us-east1-b"
wset 'w["plan"]={"default":{"run":600,"end":"done"}}; w["nocap"]=["us-central1-a"]; w["nocap_leaves_disk"]=True'
pl launch full-spot
ok "a refusal that left a disk behind does not go on to the next zone" eq "$RC $(cq 'len(c)') $(cq 'c[0]["opt"]["zone"]')" "1 1 us-central1-a"
ok "  ... says what is left" has "the project is not empty after that refusal: lean-full-spot-data"
ok "  ... and keeps the row open" eq "$(lq 'rows[-1]["ended"]')" ""
wset 'w["nocap"]=[]'
pl watch
ok "watch deletes the disk, closes the row and carries on" eq "$RC $(wq 'len(w["disks"])')" "0 0"
end

# ---- 15e. Google is still deleting a reclaimed VM: wait for it, and do not stop on a refused delete
begin reclaim_stopping_short
wset 'w["plan"]={"1":{"run":900,"end":"reclaim","progress":100},"2":{"run":600,"end":"done"}}; w["stopping_calls"]=8'
pl launch full-spot; pl watch
ok "finishes" eq "$RC" 0
ok "waited for Google's deletion" grep -q "waiting for Google to finish deleting lean-full-spot (status STOPPING)" "$C/all.out"
ok "never NOT VERIFIED; attempt 1 accounted with its progress" eq "$(grep -c 'NOT VERIFIED' "$C/all.out") $(grep -c 'attempt 1 accounted for: progress 100' "$C/all.out")" "0 1"
end
begin reclaim_stopping_long
wset 'w["plan"]={"1":{"run":900,"end":"reclaim","progress":100},"2":{"run":600,"end":"done"}}; w["stopping_calls"]=70'
pl launch full-spot; pl watch
ok "finishes" eq "$RC" 0
ok "a delete was refused while Google was deleting" eq "$(wq 'w.get("refused_deletes",0) >= 1')" True
ok "the purge waited for the listings to empty" grep -q "waiting for the deletions to finish" "$C/all.out"
ok "never NOT VERIFIED; attempt 1 accounted once" eq "$(grep -c 'NOT VERIFIED' "$C/all.out") $(grep -c 'attempt 1 accounted for' "$C/all.out")" "0 1"
ok "under cap, no row open" cap_ok
end

# ---- 15f. The contract with the guest: checkpoint objects made by the real helper, the guest's manifest format and
# a status.json made by the guest's own Spot status(); then an attempt whose RECLAIMED comes before any new
# checkpoint, which counts as no progress
GUEST="$REPO/cloud/gcp/full_guest.sh"; HELPER="$REPO/scripts/spot_checkpoint.sh"
awk '/^status\(\) \{/ {buf = ""; on = 1} on {buf = buf $0 "\n"} on && /^}/ {on = 0; if (buf ~ /"spot"/) printf "%s", buf}' "$GUEST" > "$WORK/guest_status.sh"
HDR=$(grep -o "printf 'seq[^']*'" "$GUEST" | head -1)
ROWFMT=$(grep 'manifest.new' "$GUEST" | grep -o "printf '%s[^;]*\"\$ATTEMPT\"" | head -1)
# guest_status <file> <phase> <state> <attempt> [kind]: run the guest's own status() with its upload pointed at <file>
guest_status() { ( PD=$(mktemp -d "$WORK/pd.XXXXXX"); T0=$(date +%s); DEADLINE=$((T0 + 3600)); MODE=full; NMAX=32; ATTEMPT=$4; SPOT=1; RT=unused
  OUTF=$1; gcs_put() { cp "$1" "$OUTF"; }; . "$WORK/guest_status.sh"; status "$2" "$3" "from the guest's status()" "${5:-}" ); }
# guest_rows <file> <attempt> <bytes>...: the manifest with the guest's header and its row format
guest_rows() { local f=$1 ATTEMPT=$2 seq=0 obj sha bytes mods=3 ep=1796000000; shift 2; eval "$HDR" > "$f"
  for bytes in "$@"; do seq=$((seq + 1)); obj=$(printf 'ckpt/RT/part-%06d.tar.zst' "$seq"); sha=$(printf '%064d' "$seq"); eval "$ROWFMT" >> "$f"; done; }
jv() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("state"), d.get("pause", "-"), d.get("attempt"), d.get("spot"))' "$1"; }
begin contract_real_helper
ok "the guest's Spot status(), its manifest header and its row format were found" eq "$([ -s "$WORK/guest_status.sh" ] && [ -n "$HDR" ] && [ -n "$ROWFMT" ] && echo yes)" yes
guest_status "$C/s1.json" build PAUSED 2 stop; guest_status "$C/s2.json" build PAUSED 2; guest_status "$C/s3.json" build RUNNING 2 stop
ok "the guest's status(): PAUSED with a kind, PAUSED without one (deadline), and no kind for any other state" eq "$(jv "$C/s1.json"); $(jv "$C/s2.json"); $(jv "$C/s3.json")" "PAUSED stop 2 1; PAUSED deadline 2 1; RUNNING - 2 1"
wset 'w["plan"]={"1":{"run":900,"end":"reclaim","ckpt":False,"status_on_reclaim":False,"copy_dir":"'"$C/a1"'"},"2":{"run":900,"end":"reclaim","ckpt":False},"3":{"run":900,"end":"paused","ckpt":False,"own_status":False,"copy_dir":"'"$C/a3"'"},"4":{"run":900,"end":"reclaim","ckpt":False,"status_on_reclaim":False,"copy_dir":"'"$C/a4"'"}}'
pl launch full-spot; RT=$(sv RUNTAG)
mkdir -p "$C/a1/ckpt/$RT" "$C/a1/results/$RT" "$C/a3/results/$RT" "$C/a4/ckpt/$RT" "$C/a4/results/$RT"
bash "$HELPER" state --file "$C/a1/ckpt/$RT/state.json" --runtag "$RT" --attempt 1 --attempt-set zone=us-central1-a --parts-modules 7 --results-saved 5
guest_rows "$C/a1/ckpt/$RT/manifest.tsv" 1 1000 2345
guest_status "$C/a1/results/$RT/status.json" build RECLAIMED 1
guest_status "$C/a3/results/$RT/status.json" build PAUSED 3 retry
cp "$C/a1/ckpt/$RT/state.json" "$C/a4/ckpt/$RT/state.json"
bash "$HELPER" state --file "$C/a4/ckpt/$RT/state.json" --attempt 4 --parts-modules 9 --results-saved 11 --set-json final=true
guest_rows "$C/a4/ckpt/$RT/manifest.tsv" 4 1000 2345 655
guest_status "$C/a4/results/$RT/status.json" c3 RECLAIMED 4
P1=$(bash "$HELPER" state-get --file "$C/a1/ckpt/$RT/state.json" --key progress)
pl watch
ok "finishes on the state's final=true" eq "$RC" 0
ok "the guest's status was read with its attempt" grep -q "attempt 1 is over: the guest reported RECLAIMED" "$C/all.out"
ok "progress, bytes and results_saved read from the helper's state and the guest's manifest" grep -q "attempt 1 accounted for: progress $P1 (attempts in a row without progress: 0), parts 3345 bytes, replay results saved 5;" "$C/all.out"
ok "RECLAIMED before any new checkpoint counts as no progress" grep -q "attempt 2 accounted for: progress $P1 (attempts in a row without progress: 1), parts 3345 bytes, replay results saved 5;" "$C/all.out"
ok "the kind of pause was read from the guest's own PAUSED status (retry: the next attempt starts)" grep -q "attempt 3 is over: the guest reported PAUSED (retry: from the guest's status())" "$C/all.out"
ok "attempt 2 continued from the helper's objects (the fake checks the sha)" eq "$(cq 'c[1]["md"]["full-state-sha"]')" "$(shasum -a 256 "$C/a1/ckpt/$RT/state.json" | cut -d' ' -f1)"
ok "the run ends after attempt 4" has "is over after 4 attempt"
end

# ---- 15g. A watch that died between saving a new attempt and sending its create; and one that died on the
# no-capacity path between putting the state back and closing the row
sset() { python3 -I - "$STATEF" "$@" <<'PY'
import sys
p, k, v = sys.argv[1:4]
L = [l for l in open(p) if not l.startswith(k + "=")]
L.append("%s='%s'\n" % (k, v))
open(p, "w").write("".join(L))
PY
}
openrow() { printf '%s\t%s\tn4d-highmem-32\t1.20\tpending\t%s\t\t\t\n' "$(sv RUNTAG)" "full-spot#$1" "$(cat "$FAKE/clock")" >> "$LEDGER"; }
begin interrupted_start
wset 'w["plan"]={"1":{"run":900,"end":"reclaim","progress":100},"2":{"run":600,"end":"done"}}'
pl launch full-spot; guest 1000; pl teardown
sset ATTEMPT 2; sset STARTING 2; sset CREATED "$(cat "$FAKE/clock")"; sset MAXRUN 9000; sset LAST_SEEN 0; openrow 2
guest 3600; pl watch
ok "finishes" eq "$RC" 0
ok "says attempt 2 was never created" has "attempt 2 was never created"
ok "its row closed at zero" eq "$(lq '[r["secs"] for r in rows if r["mode"]=="full-spot#2"][0]')" 0
ok "not counted as an attempt without progress" eq "$(grep -c 'attempts in a row without progress: 1' "$C/all.out")" 0
ok "the next create is attempt 2" eq "$(cq '[x["md"]["full-attempt"] for x in c]')" "['1', '2']"
end
begin interrupted_nocap
wset 'w["plan"]={"1":{"run":900,"end":"reclaim","progress":100},"2":{"run":600,"end":"done"}}'
pl launch full-spot; guest 1000; pl teardown
sset STARTING 2; openrow 2
guest 3600; pl watch
ok "finishes" eq "$RC" 0
ok "the leftover row is closed at zero" has "closing at zero the row of attempt 2"
ok "  ... with zero seconds" eq "$(lq '[r["secs"] for r in rows if r["mode"]=="full-spot#2"][0]')" 0
ok "under cap, no row open" cap_ok
end

# ---- 15h. The bucket's own region decides what is out of region; a bucket in more than one region is refused
begin bucket_region
wset 'w["bucket_location"]="US"'
pl launch full-spot
ok "a multi-region bucket is refused" eq "$RC $(cq 'len(c)')" "1 0"
ok "  ... leaving no run state" eq "$([ -e "$STATEF" ] && echo yes || echo no)" no
ok "  ... saying why" has "is in 'us', which is not a single region"
wset 'w["bucket_location"]="US-EAST1"'; seed_spent 9.86
pl launch full-spot
ok "a zone in GCP_REGION but not in the bucket's region is sized as out of region" eq "$(cq 'c[-1]["opt"]["max-run-duration"], c[-1]["md"].get("full-parts-max-bytes")')" "('113670s', '64424509440')"
ok "the bucket's region is in the state" eq "$(sv BUCKET_REGION)" us-east1
end

# ---- 15i. Settings that are refused before anything is created
begin settings_refused
EXTRA=(GCP_SPOT_MIN_ATTEMPT_SECONDS=1499); pl launch full-spot
ok "an attempt minimum below the deadline margin + 600 s" eq "$RC $(grep -c 'must be at least 1500' "$C/last.out")" "1 1"
EXTRA=(GCP_SPOT_CONFIRM_EVERY=29); pl launch full-spot
ok "a confirm interval below 30 s" eq "$RC $(grep -c 'at least 30' "$C/last.out")" "1 1"
EXTRA=(GCP_SPOT_CONFIRM_EVERY=1.5); pl launch full-spot-rehearsal
ok "a confirm interval that is not a whole number" eq "$RC $(grep -c 'not a whole number' "$C/last.out")" "1 1"
EXTRA=(GCP_SPOT_REHEARSAL_CUTS=c3:pull); pl launch full-spot-rehearsal
ok "an unknown cut" eq "$RC $(grep -c 'simulate, delete or reset' "$C/last.out")" "1 1"
ok "nothing created, no state" eq "$(cq 'len(c)') $([ -e "$STATEF" ] && echo yes || echo no)" "0 no"
end

# ---- 15j. Only gcloud's own "no such object" means absent: a 404 about something else is a failed fetch
begin fetch_404_is_failure
wset 'w["plan"]={"1":{"run":600,"end":"reclaim"},"2":{"run":600,"end":"done"}}; w["fail"]=[{"match":"storage cp gs://testbucket/ckpt/","times":1,"msg":"ERROR: (gcloud.storage.cp) HTTPError 404: Not Found"}]'
pl launch full-spot; pl watch
ok "stops instead of taking the state as absent" eq "$RC" 1
ok "  ... saying it could not read the checkpoints" has "could not read the run's checkpoints"
pl watch; ok "a second watch finishes" eq "$RC" 0
end

# ---- 15k. The kind of a guest's pause (K7): stop pauses the run, retry and deadline go on, parts-limit keeps
# attempts in the bucket's region
begin pause_stop
wset 'w["plan"]={"1":{"run":900,"end":"paused","pause":"stop","pause_msg":"a state exists that the controller did not see"},"2":{"run":600,"end":"done"}}'
pl launch full-spot; pl watch
ok "stop pauses the run" eq "$RC" 3
ok "  ... with the guest's message" has "PAUSED: the guest stopped attempt 1 and says another attempt would end the same way: a state exists that the controller did not see"
ok "  ... and starts nothing" eq "$(cq 'len(c)') $(wq 'len(w["instances"])+len(w["disks"])') $(lq 'sum(1 for r in rows if r["ended"]=="")')" "1 0 0"
pl watch
ok "a watch by hand then continues as after any pause" eq "$RC $(cq 'len(c)')" "0 2"
end
begin pause_retry_deadline
wset 'w["plan"]={"1":{"run":900,"end":"paused","pause":"retry","pause_msg":"could not fetch inputs/lean.tar.gz"},"2":{"run":900,"end":"paused","pause":"deadline","pause_msg":"deadline"},"3":{"run":900,"end":"paused","pause_msg":"an old guest"},"4":{"run":600,"end":"done"}}'
pl launch full-spot; pl watch
ok "retry, deadline and a PAUSED with no kind each start the next attempt" eq "$RC $(cq 'len(c)')" "0 4"
ok "  ... the retry's message is shown" has "attempt 1 is over: the guest reported PAUSED (retry: could not fetch inputs/lean.tar.gz)"
ok "  ... and no kind counts as deadline" has "attempt 3 is over: the guest reported PAUSED (deadline)"
end
begin pause_unwatched
# The attempt pauses itself; the first watch stops (the checkpoints cannot be read) after the row is closed, and the
# second one finds the attempt ended, unaccounted, and reads the kind from its status.
wset 'w["plan"]={"1":{"run":900,"end":"paused","pause":"stop","pause_msg":"a state exists that the controller did not see"},"2":{"run":600,"end":"done"}}; w["fail"]=[{"match":"storage cp gs://testbucket/ckpt/","times":1,"msg":"ERROR: network unreachable"}]'
pl launch full-spot; pl watch
ok "the first watch stops with the row closed" eq "$RC $(lq 'rows[-1]["ended"]!=""')" "1 True"
pl watch
ok "the second watch accounts for the attempt it finds ended, and pauses on its kind" eq "$RC $(cq 'len(c)')" "3 1"
ok "  ... saying so" has "attempt 1 had been paused by the guest (stop: a state exists"
ok "  ... with the guest's message" has "PAUSED: the guest stopped attempt 1 and says another attempt would end the same way"
end
begin pause_kind_survives_teardown
# The kind is kept in the state between the accounting and acting on it
wset 'w["plan"]={"1":{"run":900,"end":"paused","pause":"stop","pause_msg":"no"},"2":{"run":600,"end":"done"}}'
pl launch full-spot; guest 1000; pl teardown
ok "teardown keeps the kind in the state" eq "$(sv PKIND)" stop
pl watch
ok "the next watch acts on it" eq "$RC $(cq 'len(c)')" "3 1"
end
begin pause_parts_limit_out_of_region
ZONES="us-east1-b"
wset 'w["plan"]={"1":{"run":900,"end":"paused","pause":"parts-limit","pause_msg":"the parts are at the limit"},"2":{"run":600,"end":"done"}}'
pl launch full-spot; pl watch
ok "parts-limit sets PARTS_FULL to the limit that was hit" eq "$(sv PARTS_FULL)" 64424509440
ok "with only zones outside the bucket's region the run pauses" eq "$RC $(cq 'len(c)')" "3 1"
ok "  ... with the parts message" has "PAUSED: the checkpoint parts (0.9 GiB) are at the limit GCP_SPOT_PARTS_MAX_GIB (60 GiB) allows for an attempt outside the bucket's region us-central1, and no zone in GCP_ZONES is in that region"
ok "  ... naming both remedies, and that the cap does not help" has "add zones of region us-central1 to GCP_ZONES, or raise GCP_SPOT_PARTS_MAX_GIB.*raising GCP_SPEND_CAP_USD does not help"
ok "  ... and not the cap message" eq "$(grep -c 'the cap leaves room' "$C/last.out")" 0
ok "  ... the zone's own line gives the reason" has "us-east1-b: the checkpoint parts (0.9 GiB) are at the limit GCP_SPOT_PARTS_MAX_GIB allows for an attempt outside the bucket's region us-central1; no attempt may start in us-east1-b"
pl watch
ok "the same limit: still paused" eq "$RC $(cq 'len(c)')" "3 1"
EXTRA=(GCP_SPOT_MIN_ATTEMPT_SECONDS=1500 GCP_SPOT_PARTS_MAX_GIB=61); pl watch
ok "a larger GCP_SPOT_PARTS_MAX_GIB clears it and the next attempt starts out of region" eq "$RC $(cq 'len(c)') $(sv PARTS_FULL)" "0 2 "
ok "  ... saying so" has "attempts outside the bucket's region us-central1 may start again"
ok "  ... with the new limit" eq "$(cq 'c[-1]["md"]["full-parts-max-bytes"]')" 65498251264
end
begin pause_parts_limit_in_region
ZONES="us-east1-b us-central1-a"
wset 'w["plan"]={"1":{"run":900,"end":"paused","pause":"parts-limit"},"2":{"run":600,"end":"done"}}'
pl launch full-spot; pl watch
ok "after parts-limit the next attempt starts in the bucket's region" eq "$RC $(cq '[x["opt"]["zone"] for x in c]')" "0 ['us-east1-b', 'us-central1-a']"
ok "  ... and carries no parts limit" eq "$(cq '[x["md"].get("full-parts-max-bytes") for x in c]')" "['64424509440', None]"
ok "  ... the zone outside it was passed over for the parts" grep -q "us-east1-b: the checkpoint parts .* no attempt may start in us-east1-b" "$C/all.out"
end
begin pause_parts_limit_raised_meanwhile
# The limit is raised while attempt 1 runs (the watch runs with the new setting); attempt 1 was given the old one,
# so its parts-limit pause does not block the next attempt out of region
ZONES="us-east1-b"
wset 'w["plan"]={"1":{"run":900,"end":"paused","pause":"parts-limit","pause_msg":"the parts are at the limit"},"2":{"run":600,"end":"done"}}'
pl launch full-spot
ok "the limit sent to attempt 1 is in the state, written with CREATE_SENT" eq "$(sv PARTS_SENT) $(cq 'c[0]["md"]["full-parts-max-bytes"]') $([ "$(sv CREATE_SENT)" -gt 0 ] && echo sent)" "64424509440 64424509440 sent"
EXTRA=(GCP_SPOT_MIN_ATTEMPT_SECONDS=1500 GCP_SPOT_PARTS_MAX_GIB=61); pl watch
ok "the pause does not block the next out-of-region attempt" eq "$RC $(cq 'len(c)') $(cq 'c[-1]["opt"]["zone"]') $(cq 'c[-1]["md"]["full-parts-max-bytes"]')" "0 2 us-east1-b 65498251264"
ok "  ... the stop was at the limit attempt 1 was given" has "attempt 1 stopped at the limit on checkpoint parts outside the bucket's region it was given (60.0 GiB)"
ok "  ... and the larger setting cleared it" has "attempts outside the bucket's region us-central1 may start again"
end
begin pause_parts_limit_in_region_sent_none
ZONES="us-central1-a"
wset 'w["plan"]={"1":{"run":900,"end":"paused","pause":"parts-limit"},"2":{"run":600,"end":"done"}}'
pl launch full-spot
ok "an attempt in the bucket's region is given no parts limit, and PARTS_SENT says so" eq "$(sv PARTS_SENT) $(cq 'c[0]["md"].get("full-parts-max-bytes")')" "0 None"
end

# ---- 15k2. The guest's status.json read when an attempt is accounted for: a failed read is an accounting failure,
# and the kind of a pause is never weakened between the poll and that read
PURGED="disks list --format=value(name,zone.basename(),sizeGb)"      # the purge's last listing: the attempt is gone
begin account_status_unreadable
wset 'w["plan"]={"1":{"run":900,"end":"reclaim","progress":100},"2":{"run":600,"end":"done"}}; w["fail"]=[{"match":"storage cat gs://testbucket/results/","times":1,"after":"'"$PURGED"'","msg":"ERROR: network unreachable"}]'
pl launch full-spot; pl watch
ok "watch stops with exit 1" eq "$RC" 1
ok "  ... saying it could not read the status and what to run" has "could not read the guest's status.json from the bucket (ERROR: network unreachable.*). Nothing is running and the row is closed; run 'bash .* watch' again"
ok "  ... the row is closed, the attempt not yet accounted, nothing running" eq "$(lq 'rows[-1]["ended"]!=""') $(sv ACCOUNTED) $(sv ATTEMPT) $(wq 'len(w["instances"])+len(w["disks"])')" "True 0 1 0"
ok "  ... and no second VM" eq "$(cq 'len(c)')" 1
pl watch
ok "the next watch accounts for the attempt and finishes" eq "$RC" 0
ok "  ... accounting once, with its progress" eq "$(grep -c 'attempt 1 ended while nobody was watching' "$C/all.out") $(grep -c 'attempt 1 accounted for: progress 100' "$C/all.out")" "1 1"
end
begin account_kind_not_weakened
# The poll sees PAUSED stop; by the time of the accounting's read, status.json says PAUSED retry
wset 'w["plan"]={"1":{"run":900,"end":"paused","pause":"stop","pause_msg":"no"},"2":{"run":600,"end":"done"}}; w["on_call"]=[{"match":"'"$PURGED"'","times":1,"put":["results/{rt}/status.json","{\"phase\":\"build\",\"state\":\"PAUSED\",\"pause\":\"retry\",\"message\":\"later\",\"elapsed_s\":1,\"attempt\":1,\"spot\":1}"]}]'
pl launch full-spot; pl watch
ok "the poll's stop is kept over the re-read's retry: the run pauses" eq "$RC $(cq 'len(c)')" "3 1"
ok "  ... with the poll's message" has "PAUSED: the guest stopped attempt 1 and says another attempt would end the same way: no"
ok "  ... and the re-read did give retry" grep -q '"retry"' "$FAKE/bucket/results/$(sv RUNTAG)/status.json"
end
begin account_kind_strengthened
# The poll sees PAUSED retry; the accounting's read gives PAUSED stop, which is kept
wset 'w["plan"]={"1":{"run":900,"end":"paused","pause":"retry","pause_msg":"try again"},"2":{"run":600,"end":"done"}}; w["on_call"]=[{"match":"'"$PURGED"'","times":1,"put":["results/{rt}/status.json","{\"phase\":\"build\",\"state\":\"PAUSED\",\"pause\":\"stop\",\"message\":\"stop now\",\"elapsed_s\":1,\"attempt\":1,\"spot\":1}"]}]'
pl launch full-spot; pl watch
ok "the re-read's stop is kept over the poll's retry: the run pauses" eq "$RC $(cq 'len(c)')" "3 1"
ok "  ... with the re-read's message" has "PAUSED: the guest stopped attempt 1 and says another attempt would end the same way: stop now"
ok "  ... after the poll had seen retry" grep -q "attempt 1 is over: the guest reported PAUSED (retry: try again)" "$C/all.out"
end
begin kind_rank_order
ok "the order of the kinds: stop > parts-limit > retry > deadline > none (unknown kinds above all)" eq "$(eval "$(awk '/^spot_kind_rank\(\) \{/' "$NEWSCRIPT")"; for k in "" deadline retry parts-limit stop other; do printf '%s ' "$(spot_kind_rank "$k")"; done)" "0 1 2 3 4 5 "
end

# ---- 15l. Durable before create: the ledger row and the state are flushed to disk before each create is sent
begin durable_start
PRE="$STUBS/py:"; ZONES="us-central1-a us-east1-b"
wset 'w["plan"]={"1":{"run":600,"end":"reclaim"},"2":{"run":600,"end":"done"}}; w["nocap_for_attempt"]={"2":["us-central1-a"]}'
pl launch full-spot; pl watch
ok "finishes (the fake checked at each create that the state names the attempt and its row is open)" eq "$RC" 0
ok "before every create: the state naming the attempt flushed, then the ledger after its row, then the state again" eq "$(python3 -I - "$FAKE/syncs.log" "$LEDGER" "$STATEF" <<'PY'
import sys
out, last = [], []
for l in open(sys.argv[1]):
    l = l.split()
    if l[0] == "CREATE":
        # what was flushed since the previous create (or the start), in order: L the ledger, S the state
        out.append("%s:%s" % (l[1], ",".join(last))); last = []
    elif l[1:] == [sys.argv[2]]: last.append("L")
    elif l[1:] == [sys.argv[3]]: last.append("S")
print(" ".join(out))
PY
)" "1:S,L,S 2:S,L,S 2:S"
end
begin durable_sync_fails
PRE="$STUBS/py:"; echo "file=$LEDGER" > "$FAKE/sync_fail"
wset 'w["plan"]={"default":{"run":600,"end":"done"}}'
pl launch full-spot
ok "a flush of the ledger that fails stops the start before any create" eq "$RC $(cq 'len(c)')" "1 0"
ok "  ... saying what happened and what to run" has "could not flush the ledger .* to disk; attempt 1 is not started.*run 'bash .* watch'"
rm -f "$FAKE/sync_fail"; pl watch
ok "watch closes the row at zero and starts attempt 1 again" eq "$RC $(lq '[(r["mode"], r["secs"]=="0") for r in rows]') $(cq '[x["md"]["full-attempt"] for x in c]')" "0 [('full-spot#1', True), ('full-spot#1', False)] ['1']"
end
begin durable_state_sync_fails
# The flush of the state just before the create (the third of the case: state, ledger, state) fails
PRE="$STUBS/py:"; echo "n=3" > "$FAKE/sync_fail"
wset 'w["plan"]={"default":{"run":600,"end":"done"}}'
pl launch full-spot
ok "a flush of the state that fails stops the start before any create" eq "$RC $(cq 'len(c)')" "1 0"
ok "  ... the failed flush was the state's, after the ledger's" eq "$(grep '^SYNC' "$FAKE/syncs.log" | awk '{print $2}' | sed "s|$STATEF|S|; s|$LEDGER|L|" | tr '\n' ' ')" "S L S "
ok "  ... saying so" has "could not flush the state file .* to disk; the create for attempt 1 in us-central1-a is not sent"
ok "  ... the state says no create was sent for attempt 1, whose row is open" eq "$(sv ATTEMPT) $(sv STARTING) $(lq '[(r["mode"], r["ended"]) for r in rows]')" "1 1 [('full-spot#1', '')]"
rm -f "$FAKE/sync_fail"; pl watch
ok "the next watch closes that row at zero and starts attempt 1 again" eq "$RC $(lq '[(r["mode"], r["secs"]=="0") for r in rows]') $(cq '[x["md"]["full-attempt"] for x in c]')" "0 [('full-spot#1', True), ('full-spot#1', False)] ['1']"
ok "  ... saying it was never created" grep -q "attempt 1 was never created" "$C/all.out"
end
begin durable_first_state_sync_fails
# The first flush of the state, which names the new attempt before its row exists, fails (A31)
PRE="$STUBS/py:"; echo "file=$STATEF" > "$FAKE/sync_fail"
wset 'w["plan"]={"default":{"run":600,"end":"done"}}'
pl launch full-spot
ok "it stops the start before any row or create" eq "$RC $(cq 'len(c)') $(lq 'len(rows)')" "1 0 0"
ok "  ... saying so" has "could not flush the state file .* to disk; attempt 1 is not started and nothing has been created for it"
ok "  ... with the attempt named in the state, no create sent" eq "$(sv ATTEMPT) $(sv STARTING)" "1 1"
rm -f "$FAKE/sync_fail"; pl watch
ok "the next watch starts attempt 1 and finishes" eq "$RC $(lq '[r["mode"] for r in rows]') $(cq '[x["md"]["full-attempt"] for x in c]')" "0 ['full-spot#1'] ['1']"
end

# ---- 15m. Sizing reasons, and the inputs every attempt downloads in the worst case and in the transfer row
inputs() { python3 -I -c 'import os,sys; os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True); f=open(sys.argv[1],"wb"); f.truncate(int(sys.argv[2])); f.close()' "$FAKE/bucket/inputs/lean.tar.gz" "$1"; }
begin sizing_inputs
seed_spent 9.86; ZONES="us-east1-b"; inputs 1073741824; pl launch full-spot
ok "INPUT_BYTES measured at launch" eq "$(sv INPUT_BYTES)" 1073741824
ok "out of region the worst transfer counts the inputs: 0.02 x 61 GiB" eq "$(cq 'c[-1]["opt"]["max-run-duration"]')" 113610s
ok "  ... and says so" has "plus transfer \$1.22"
end
begin transfer_inputs
ZONES="us-east1-b"; inputs 536870912
wset 'w["plan"]={"1":{"run":600,"end":"done","bytes":2*1073741824}}'
pl launch full-spot; pl watch
ok "the transfer row counts parts and inputs: 0.02 x (2 + 0.5) GiB" eq "$RC $(lq '[r["usd"] for r in rows if r["mode"].endswith("-transfer")]')" "0 ['0.05']"
end
begin inputs_unreadable
wset 'w["fail"]=[{"match":"storage du","times":1}]'
pl launch full-spot
ok "launch refuses when the inputs cannot be measured, with nothing created" eq "$RC $(cq 'len(c)') $([ -e "$STATEF" ] && echo yes || echo no) $(lq 'len(rows)')" "1 0 no 0"
ok "  ... saying why" has "could not measure the size of gs://testbucket/inputs/"
end
begin sizing_giveup_reason
EXTRA=(GCP_SPOT_MIN_ATTEMPT_SECONDS=1500 GCP_SPOT_GIVEUP_HOURS=0.75)
wset 'w["plan"]={"default":{"run":900,"end":"reclaim"}}'
pl launch full-spot; pl watch
ok "the give-up time, not the cap, is named when it leaves too little" eq "$RC" 3
ok "  ... per zone" has "us-central1-a: the give-up time (GCP_SPOT_GIVEUP_HOURS after the first launch) leaves room for an attempt of only"
ok "  ... and in the pause" has "PAUSED: the give-up time (GCP_SPOT_GIVEUP_HOURS after the first launch) leaves room for an attempt of only"
end
begin ledger_symlink_and_mode
mkdir -p "$C/elsewhere"; printf 'runtag\tmode\tmachine\tusd_per_hour\tzone\tcreated_epoch\tended_epoch\tseconds\tusd\n' > "$C/elsewhere/ledger.tsv"
chmod 640 "$C/elsewhere/ledger.tsv"; ln -s "$C/elsewhere/ledger.tsv" "$LEDGER"
wset 'w["plan"]={"default":{"run":600,"end":"done"}}'
pl launch full-spot; pl watch
ok "a symlinked ledger is rewritten at its target" eq "$RC $([ -L "$LEDGER" ] && echo link) $(lq 'rows[0]["ended"]!=""')" "0 link True"
ok "  ... keeping its mode" eq "$(fmode "$C/elsewhere/ledger.tsv")" 640
end

# ---- 16. The four older modes do exactly what HEAD does: same create command line, ledger, state, watch and teardown
norm() { python3 -I -c 'import json,sys; t=sys.argv[2]; [print(json.dumps(json.loads(l)["args"]).replace(t,"<T>")) for l in open(sys.argv[1])]' "$1" "$2"; }
for mode in rehearsal pilot full-rehearsal full; do
  for side in head new; do
    if [ $side = head ]; then begin "old_$mode-HEAD" head; else begin "old_$mode-new"; fi
    EXTRA=(); CAP=200
    wset 'w["plan"]={"legacy":{"run":400,"end":"done"}}'
    printf 'runtag\tmode\tmachine\tusd_per_hour\tzone\tcreated_epoch\tended_epoch\tseconds\tusd\n' > "$LEDGER"; chmod 640 "$LEDGER"
    pl launch "$mode"; L1=$RC; cp "$STATEF" "$C/state_after_launch" 2>/dev/null
    pl watch; L2=$RC; eval "M_$side=\$(fmode \"\$LEDGER\")"
    norm "$FAKE/calls.jsonl" "$TR" > "$C/calls.norm"; norm "$FAKE/creates.jsonl" "$TR" > "$C/creates.norm"
    sed "s|$TR|<T>|g" "$C/all.out" > "$C/out.norm"; sed "s|$TR|<T>|g" "$C/state_after_launch" > "$C/state.norm" 2>/dev/null; cp "$LEDGER" "$C/ledger.norm"
    eval "R_$side=\$C; RCS_$side=\"$L1 $L2\""
  done
  begin "old_mode_$mode"
  ok "exit statuses" eq "$RCS_new" "$RCS_head"
  ok "the ledger's mode is unchanged by the run, as at HEAD" eq "$M_head $M_new" "640 640"
  ok "one create" eq "$(wc -l < "$R_new/creates.norm" | tr -d ' ')" 1
  for f in creates.norm calls.norm ledger.norm state.norm out.norm; do
    ok "$f identical to HEAD's" cmp -s "$R_head/$f" "$R_new/$f"; cmp -s "$R_head/$f" "$R_new/$f" || diff "$R_head/$f" "$R_new/$f" | head -6 | sed 's/^/      /'
  done
  end
done
for side in head new; do       # no capacity anywhere, and a cap refusal, in mode full
  if [ $side = head ]; then begin old_full_edges-HEAD head; else begin old_full_edges-new; fi
  EXTRA=(); CAP=200; ZONES="us-central1-a us-east1-b"; wset 'w["nocap"]=["us-central1-a","us-east1-b"]'
  pl launch full; CAP=40; pl launch full
  norm "$FAKE/calls.jsonl" "$TR" > "$C/calls.norm"; sed "s|$TR|<T>|g" "$C/all.out" > "$C/out.norm"; cp "$LEDGER" "$C/ledger.norm"
  eval "R_$side=\$C"
done
begin old_full_edges
for f in calls.norm ledger.norm out.norm; do ok "$f identical to HEAD's" cmp -s "$R_head/$f" "$R_new/$f"; done
end
begin old_rehearsal_lock_free
# A Spot command has run here before (the lock file exists) and nothing holds it: launch rehearsal, its watch and
# its teardown take the lock and otherwise do exactly what HEAD does (the old_rehearsal-HEAD case above)
EXTRA=(); CAP=200
wset 'w["plan"]={"legacy":{"run":400,"end":"done"}}'
printf 'runtag\tmode\tmachine\tusd_per_hour\tzone\tcreated_epoch\tended_epoch\tseconds\tusd\n' > "$LEDGER"; chmod 640 "$LEDGER"
: > "$STATEF.lock"
pl launch rehearsal; cp "$STATEF" "$C/state_after_launch" 2>/dev/null
pl watch
norm "$FAKE/calls.jsonl" "$TR" > "$C/calls.norm"; norm "$FAKE/creates.jsonl" "$TR" > "$C/creates.norm"
sed "s|$TR|<T>|g" "$C/all.out" > "$C/out.norm"; sed "s|$TR|<T>|g" "$C/state_after_launch" > "$C/state.norm" 2>/dev/null; cp "$LEDGER" "$C/ledger.norm"
for f in creates.norm calls.norm ledger.norm state.norm out.norm; do
  ok "$f identical to HEAD's (exit statuses included in out.norm)" cmp -s "$WORK/old_rehearsal-HEAD/$f" "$C/$f"; cmp -s "$WORK/old_rehearsal-HEAD/$f" "$C/$f" || diff "$WORK/old_rehearsal-HEAD/$f" "$C/$f" | head -6 | sed 's/^/      /'
done
ok "the lock was taken (the info file names teardown, the last taker)" eq "$(sed -n 2p "$STATEF.lock.info")" teardown
end

# ---- 17. A Spot attempt's VM is the matching on-demand mode's VM: same disks, scopes, image, labels and guest settings
# cmp_vm <spot creates> <on-demand creates> <key allowed to differ>: "same", or what differs
cmp_vm() { python3 -I - "$1" "$2" "$3" <<'PY'
import json, sys
spot = json.loads(open(sys.argv[1]).read().splitlines()[-1])["args"]; od = json.loads(open(sys.argv[2]).read().splitlines()[-1])["args"]
def split(a):
    o = {x.split("=", 1)[0]: x.split("=", 1)[1] if "=" in x else "" for x in a if x.startswith("--")}
    md = dict(kv.partition("=")[::2] for kv in o.pop("--metadata").split(","))
    o["--create-disk"] = ",".join(x for x in o["--create-disk"].split(",") if not x.startswith("name="))
    return o, md
so, smd = split(spot); oo, omd = split(od)
bad = []
for k in set(so) | set(oo):
    if k in ("--zone", "--provisioning-model", "--max-run-duration", "--metadata-from-file"): continue
    if so.get(k) != oo.get(k): bad.append("arg %s: %s vs %s" % (k, so.get(k), oo.get(k)))
if (so["--provisioning-model"], oo["--provisioning-model"]) != ("SPOT", "STANDARD"): bad.append("provisioning model")
allowed = {"pilot-mode", "pilot-deadline-min", "pilot-runtag", "full-guest-sha", sys.argv[3]}
for k in omd:
    if k not in allowed and smd.get(k) != omd[k]: bad.append("metadata %s: %s vs %s" % (k, smd.get(k), omd[k]))
extra = set(smd) - set(omd)
want = {"full-spot", "full-attempt", "full-ckpt-every", "full-confirm-every", "full-state-sha", "full-manifest-sha"} | ({"full-spot-hold"} if "rehearsal" in sys.argv[2] else {"full-watchdog-wait", "full-watchdog-finish-wait"})
if extra != want: bad.append("extra metadata %s" % sorted(extra))
print("; ".join(bad) or "same")
PY
}
begin spot_vm_matches_on_demand
for pair in "three_attempts old_full-new full-keep-oleans" "rehearsal_cuts old_full-rehearsal-new full-keep-oleans"; do
  set -- $pair
  r=$(cmp_vm "$WORK/$1/fake/creates.jsonl" "$WORK/$2/fake/creates.jsonl" "$3")
  ok "$1 against $2" eq "$r" same
done
end

echo "$NPASS passed, $NFAIL failed"
[ "$NFAIL" = 0 ]
