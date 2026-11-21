#!/usr/bin/env python3
"""compare_builds.py - are two builds of the same modules the same files?

What it does: takes two directories of compiled modules (each a `.lake/build/lib/lean` of the project, from two
  machines or two runs) and, for every file present in both, says whether the two copies are byte-for-byte
  identical, by kind of file (.olean, .ilean, their .hash files, .trace). For .olean files that differ it gives
  the differences in size, and with --pairs it writes the list of differing pairs for OleanDiff.lean, which
  compares two compiled files by content (declaration names, their order, types and proof terms) rather than
  by bytes. With --traces it also compares the build tool's own record of each module's inputs.

  Instead of a directory, the second argument may be a manifest: a file of lines "<sha256>  ./<path>", such as
  the lib_sha256.txt.gz a cloud run of this project uploads. Then only byte identity can be reported.

What it changes on disk: writes the files named by --out and --pairs, if given. Nothing else.
How long it takes: about a minute per 2,000 modules on an external drive.

Usage: python3 analysis/compare_builds/compare_builds.py LIB_A LIB_B_OR_MANIFEST [--out FILE] [--pairs FILE] [--traces]
       lean --run analysis/compare_builds/OleanDiff.lean PAIRS_FILE      (run from a directory with the project's lean-toolchain)
"""
import argparse
import collections
import gzip
import hashlib
import json
import os
import sys

KINDS = (".olean.hash", ".ilean.hash", ".olean", ".ilean", ".trace")


def kind(path):
    for k in KINDS:
        if path.endswith(k):
            return k
    return "other"


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def manifest(path):
    out = {}
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line and not line.startswith("not-a-file"):
                h, p = line.split("  ", 1)
                out[p[2:] if p.startswith("./") else p] = h
    return out


def walk(root):
    out = []
    for d, _dirs, files in os.walk(root):
        for f in files:
            out.append(os.path.relpath(os.path.join(d, f), root))
    return out


def flat_inputs(x, pre=""):
    """The inputs a trace records, as {label: hash}. A label that is a source file's absolute path is cut to
    the part from src/ on, so that the same file in two places compares equal."""
    out = {}
    for item in x:
        if isinstance(item, list) and len(item) == 2:
            k, v = item
            if isinstance(k, str) and "/src/" in k:
                k = "src/" + k.split("/src/", 1)[1]
            if isinstance(v, list):
                out.update(flat_inputs(v, pre + str(k) + " > "))
            else:
                out[pre + str(k)] = v
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--out", default="")
    ap.add_argument("--pairs", default="")
    ap.add_argument("--traces", action="store_true")
    args = ap.parse_args()
    b_is_dir = os.path.isdir(args.b)
    b_hashes = None if b_is_dir else manifest(args.b)
    common = sorted(set(walk(args.a)) & (set(walk(args.b)) if b_is_dir else set(b_hashes)))
    same, diff = collections.Counter(), collections.Counter()
    size_delta = collections.Counter()
    pairs = []
    for rel in common:
        k = kind(rel)
        pa = os.path.join(args.a, rel)
        hb = sha(os.path.join(args.b, rel)) if b_is_dir else b_hashes[rel]
        if sha(pa) == hb:
            same[k] += 1
        else:
            diff[k] += 1
            if k == ".olean" and b_is_dir:
                pb = os.path.join(args.b, rel)
                size_delta[os.path.getsize(pa) - os.path.getsize(pb)] += 1
                pairs.append((rel[:-len(".olean")].replace(os.sep, "."), pa, pb))
    res = {"what": "files present in both builds, compared byte for byte (SHA-256)",
           "files_in_both": len(common),
           "by_kind": {k: {"identical": same[k], "different": diff[k]} for k in KINDS + ("other",) if same[k] + diff[k]}}
    if size_delta:
        res["olean_files_that_differ_by_size_difference_in_bytes_a_minus_b"] = {str(k): v for k, v in sorted(size_delta.items())}
    if args.traces and b_is_dir:
        n = dep_same = out_same = 0
        labels = collections.Counter()
        for rel in common:
            if not rel.endswith(".trace"):
                continue
            try:
                ta = json.load(open(os.path.join(args.a, rel), encoding="utf-8"))
                tb = json.load(open(os.path.join(args.b, rel), encoding="utf-8"))
            except (OSError, ValueError):
                continue
            n += 1
            dep_same += ta.get("depHash") == tb.get("depHash")
            out_same += ta.get("outputs", {}).get("o") == tb.get("outputs", {}).get("o")
            fa, fb = flat_inputs(ta.get("inputs", [])), flat_inputs(tb.get("inputs", []))
            for key in set(fa) | set(fb):
                if fa.get(key) != fb.get(key):
                    labels["an imported module's compiled files" if "imports" in key else ("the source file" if key.startswith("src/") else key)] += 1
        res["traces"] = {"modules_with_a_trace_in_both": n, "same_input_hash": dep_same, "same_recorded_olean_hash": out_same,
                         "inputs_that_differ_by_kind": dict(labels.most_common(8))}
    if args.pairs:
        with open(args.pairs, "w", encoding="utf-8") as fh:
            for mod, pa, pb in pairs:
                fh.write("%s\t%s\t%s\n" % (mod, pa, pb))
        res["pairs_written_for_OleanDiff"] = len(pairs)
    text = json.dumps(res, indent=1)
    print(text)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
