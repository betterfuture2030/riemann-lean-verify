#!/usr/bin/env python3
"""scrub.py - privacy gate for this repository. Python 3 standard library only.

Usage:
  python3 scripts/dev/scrub.py check [paths...]
  python3 scripts/dev/scrub.py clean <infile> <outfile>
  python3 scripts/dev/scrub.py selftest

check
  Read-only. Scans the given files or directories. With no paths it scans
  every file git would track (git ls-files --cached --others
  --exclude-standard, run in the repository root), each file's path, the
  staged copy of any file whose working copy differs from it, the author
  and committer identity the next commit would carry (git var), and the
  author, committer and message of any existing commits. It lists every
  hit and exits 1 if there is one, 0 if there is none, 2 on a usage error.
  It does not scan file contents of earlier commits: a string that was
  committed once and later removed is still in the history.
  A hit is any of:
    private-pattern   a literal line (case-insensitive) from the git-ignored
                      file .private-patterns in the repository root; if that
                      file is absent the tool warns and skips this rule
    config-value      the values of GCP_PROJECT and GCP_BUCKET from the
                      git-ignored config.env, and of RH_WORKDIR when it
                      lies outside the repository
    home-path         a home directory under the macOS or Linux home root,
                      unless the account name is a placeholder such as <name>
    volume-path       a macOS mounted-volume path with a real volume name
    session-path      agent session and scratch directories, the macOS
                      private temporary directory, per-user temp folders
    email             any e-mail address other than the public contact
                      address, the commit co-author address, a GitHub
                      no-reply address, or an address at example.com
    billing-account   three groups of six hex characters joined by hyphens
    project-number    a 12-digit number next to the word project(s)
    credential        private key blocks, OAuth access tokens, GitHub tokens,
                      AWS access key IDs, Google API keys
  Files that start with the gzip magic bytes are decompressed and their
  contents scanned. JSON files are also scanned in decoded form, so that
  escape sequences cannot hide a string.

clean
  Writes a sanitised copy of a text or JSON file to <outfile> (via
  <outfile>.scrub-tmp and a rename) and changes nothing else. A name ending
  in .gz is read or written through gzip, with no timestamp. Replacements,
  in this order:
    working directory (RH_WORKDIR)        -> <WORKDIR>
    repository root                       -> <REPO>
    GCP_BUCKET / GCP_PROJECT values       -> <BUCKET> / <PROJECT_ID>
    session, scratch and temp paths       -> <SCRATCH>
    home directories                      -> <HOME>
    other mounted-volume paths            -> <VOLUME>
    disallowed e-mail addresses           -> <EMAIL>
    billing account identifiers           -> <BILLING_ACCOUNT>
    project numbers                       -> <PROJECT_NUMBER>
    credentials                           -> <CREDENTIAL>
    every private pattern                 -> <REDACTED>
  The result is then put through the same scan as check. If anything is left
  the output is not written and the exit status is 1.

selftest
  Exercises every rule and the clean pipeline on synthetic strings built at
  run time. Reads this file only; writes nothing.

The private patterns are never stored here: they are read at run time.
Run time: well under a second for ordinary files. Measured on a laptop:
about 12 seconds to check 85 MB of JSON, so a whole-repository check takes
10 to 15 seconds while the compressed import graph is present; cleaning
and compressing that file takes about 20 seconds.
"""

import gzip
import io
import json
import os
import re
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
PATTERN_FILE = os.path.join(REPO_ROOT, ".private-patterns")
CONFIG_FILE = os.path.join(REPO_ROOT, "config.env")

ALLOWED_EMAILS = frozenset(["peter.lowes@sie.life", "noreply@anthropic.com"])
# users.noreply.github.com: the address GitHub gives an account that keeps its e-mail private; commits here use it.
ALLOWED_EMAIL_DOMAINS = frozenset(["example.com", "users.noreply.github.com"])
# Account names that are obviously placeholders, not people.
PLACEHOLDER_USERS = frozenset([
    "user", "username", "you", "yourname", "your-name", "your_name",
    "name", "me", "example", "shared",
])

MAX_SHOWN = 10          # hits printed per file and rule
MIN_BINARY_LITERAL = 6  # shortest literal pattern searched in a binary file
TOKEN_LIMIT = 4096      # longest path token the cleaner will swallow

# A character that can continue a path token.
_TOK = r"""[^\s"'`<>|;,:()\[\]{}\\]"""
_TOK_RE = re.compile(_TOK)
# The same, but stopping at a slash: one path segment.
_SEG = r"""[^\s"'`<>|;,:()\[\]{}\\/]"""
_NAME = r"[A-Za-z0-9][A-Za-z0-9._-]*"


class ScrubError(Exception):
    pass


# --------------------------------------------------------------------------
# Rules. Each rule finds spans in a text. The cleaner replaces each span with
# the rule's placeholder (or with whatever its 'repl' hook returns).
# Regexes are written so that they do not match their own source text.
# --------------------------------------------------------------------------

class Rule(object):
    def __init__(self, rid, pattern, placeholder, needles=None, group=0,
                 accept=None, repl=None, secret=False, flags=0):
        self.rid = rid
        self.regex = re.compile(pattern, flags)
        self.placeholder = placeholder
        self.needles = needles      # run only if one of these is in the text
        self.group = group
        self.accept = accept        # accept(match, text) -> bool
        self.repl = repl            # repl(text, start, end) -> (start, end, new)
        self.secret = secret        # mask the match when printing

    def find(self, text):
        if self.needles and not any(n in text for n in self.needles):
            return []
        out = []
        for m in self.regex.finditer(text):
            if self.accept is not None and not self.accept(m, text):
                continue
            out.append((m.start(self.group), m.end(self.group)))
        return out


def _accept_home(m, text):
    return m.group(1).lower() not in PLACEHOLDER_USERS


def _accept_email(m, text):
    addr = m.group(0).lower()
    local, _, domain = addr.rpartition("@")
    if addr in ALLOWED_EMAILS or domain in ALLOWED_EMAIL_DOMAINS:
        return False
    if local == "git" and text[m.end():m.end() + 1] == ":":
        return False                # SSH remote syntax, not an address
    return True


def _expand_token(text, start, end):
    """Grow a span to the whole path token around it (bounded)."""
    lo = start
    floor = max(0, start - TOKEN_LIMIT)
    while lo > floor and _TOK_RE.match(text[lo - 1]):
        lo -= 1
    hi = end
    ceil = min(len(text), end + TOKEN_LIMIT)
    while hi < ceil and _TOK_RE.match(text[hi]):
        hi += 1
    return lo, hi


def _repl_agent_tmp(text, start, end):
    # Keep what follows the scratch directory; drop everything before it,
    # because the directory names encode the account and the session.
    lo, hi = start, end
    while hi < min(len(text), end + TOKEN_LIMIT) and _TOK_RE.match(text[hi]):
        hi += 1
    token = text[lo:hi]
    cut = token.find("/scratchpad")
    tail = token[cut + len("/scratchpad"):] if cut >= 0 else ""
    return lo, hi, "<SCRATCH>" + tail


def _repl_dot_dir(text, start, end):
    lo, hi = _expand_token(text, start, end)
    return lo, hi, "<SCRATCH>"


_KEY_END = re.compile(r"-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----$")


def _repl_private_key(text, start, end):
    if not _KEY_END.search(text[start:end]):
        raise ScrubError("private key header without an END line; refusing "
                         "to write a file that would still hold key material")
    return start, end, "<CREDENTIAL>"


_BOUND = r"(?<![A-Za-z0-9_.~-])"

RULES = [
    Rule("session-path",
         r"(?:/private)?/tmp[/]claude" + _TOK + r"*",
         "<SCRATCH>", needles=("/tmp/",), repl=_repl_agent_tmp),
    Rule("session-path",
         r"(?<![A-Za-z0-9_])[.]claude/",
         "<SCRATCH>", needles=("claude/",), repl=_repl_dot_dir),
    Rule("session-path",
         r"/private[/]tmp(?![A-Za-z0-9_.-])",
         "<SCRATCH>", needles=("/private/",)),
    Rule("session-path",
         r"(?:/private)?/var/folders/[A-Za-z0-9_+]{2}/[A-Za-z0-9_+]{6,}(?:/[TC0](?![A-Za-z0-9_.-]))?",
         "<SCRATCH>", needles=("/var/folders/",)),
    Rule("home-path",
         _BOUND + r"/(?:Users|home)/(" + _NAME + r")",
         "<HOME>", needles=("/Users/", "/home/"), accept=_accept_home),
    Rule("volume-path",
         _BOUND + r"/Volumes/[A-Za-z0-9_]" + _SEG + r"*",
         "<VOLUME>", needles=("/Volumes/",)),
    Rule("email",
         r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9][A-Za-z0-9._%+-]*@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}",
         "<EMAIL>", needles=("@",), accept=_accept_email),
    Rule("billing-account",
         r"(?<![0-9A-Za-z])[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}(?![0-9A-Za-z])",
         "<BILLING_ACCOUNT>", needles=("-",)),
    Rule("project-number",
         r"(?i)projects?[^0-9\n]{0,16}?(?<![0-9])([0-9]{12})(?![0-9])",
         "<PROJECT_NUMBER>", group=1),
    Rule("project-number",
         r"(?i)(?<![0-9])([0-9]{12})(?![0-9])[^0-9A-Za-z\n]{0,4}projects?",
         "<PROJECT_NUMBER>", group=1),
    Rule("credential",
         r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"
         r"(?:.*?-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----)?",
         "<CREDENTIAL>", needles=("-----BEGIN",), repl=_repl_private_key,
         secret=True, flags=re.S),
    Rule("credential",
         r"(?<![A-Za-z0-9])ya29\.[0-9A-Za-z_-]{8,}",
         "<CREDENTIAL>", needles=("ya29",), secret=True),
    Rule("credential",
         r"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})",
         "<CREDENTIAL>", needles=("gh", "github_pat_"), secret=True),
    Rule("credential",
         r"(?<![A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Z0-9])",
         "<CREDENTIAL>", needles=("AKIA", "ASIA"), secret=True),
    Rule("credential",
         r"(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])",
         "<CREDENTIAL>", needles=("AIza",), secret=True),
]


# --------------------------------------------------------------------------
# Context: the run-time private inputs (patterns, config values, paths).
# --------------------------------------------------------------------------

def load_patterns(path=PATTERN_FILE):
    """Return the list of private patterns, or None if the file is absent."""
    if not os.path.isfile(path):
        return None
    pats = []
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            s = line.strip()
            if s and not s.startswith("#"):
                pats.append(s)
    return pats


def parse_config(text, repo_root=REPO_ROOT):
    """Parse KEY=value lines of a shell-style env file. No shell is run."""
    cfg = {}
    for line in text.splitlines():
        m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not m:
            continue
        v = m.group(2).strip()
        if v[:1] in ('"', "'"):
            close = v.find(v[0], 1)
            v = v[1:close] if close > 0 else v[1:]
        else:
            v = re.split(r"\s+#", v, maxsplit=1)[0].strip()
        v = v.replace("${REPO_ROOT}", repo_root).replace("$REPO_ROOT", repo_root)
        cfg[m.group(1)] = v
    return cfg


def load_config(path=CONFIG_FILE):
    if not os.path.isfile(path):
        return {}
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return parse_config(fh.read())


class Context(object):
    def __init__(self, patterns=None, workdirs=(), repo_root=None, config_literals=()):
        self.patterns_missing = patterns is None
        self.patterns = [p for p in (patterns or []) if p]
        subs = []
        for w in workdirs:
            if w and (w, "<WORKDIR>") not in subs:
                subs.append((w, "<WORKDIR>"))
        if repo_root:
            subs.append((repo_root, "<REPO>"))
        # Longest first, so a working directory inside the repository wins.
        self.path_subs = sorted(subs, key=lambda s: -len(s[0]))
        # (value, placeholder) pairs that are flagged by check and replaced by clean.
        self.config_literals = sorted(
            [(v, ph) for v, ph in config_literals if v and len(v) >= 4],
            key=lambda s: -len(s[0]))


def default_context():
    cfg = load_config()
    workdir = os.environ.get("RH_WORKDIR") or cfg.get("RH_WORKDIR") or os.path.join(REPO_ROOT, "work")
    workdir = workdir.rstrip("/") or workdir
    workdirs = [workdir]
    try:
        real = os.path.realpath(workdir)
        if real != workdir:
            workdirs.append(real)
    except OSError:
        pass
    literals = [(cfg.get("GCP_BUCKET", ""), "<BUCKET>"),
                (cfg.get("GCP_PROJECT", ""), "<PROJECT_ID>")]
    for w in workdirs:
        if not (w == REPO_ROOT or w.startswith(REPO_ROOT + os.sep)):
            literals.append((w, "<WORKDIR>"))
    return Context(load_patterns(), workdirs, REPO_ROOT, literals)


# --------------------------------------------------------------------------
# Scanning
# --------------------------------------------------------------------------

def find_literals(text, literals, lowered=None):
    """Case-insensitive literal search. Returns merged, sorted (start, end)."""
    if not literals:
        return []
    low = text.lower() if lowered is None else lowered
    spans = []
    if len(low) == len(text):
        for lit in literals:
            ll = lit.lower()
            pos = low.find(ll)
            while pos >= 0:
                spans.append((pos, pos + len(ll)))
                pos = low.find(ll, pos + 1)
    else:   # lower() changed the length (rare Unicode case): slower, exact
        for lit in literals:
            for m in re.finditer(re.escape(lit), text, re.I):
                spans.append((m.start(), m.end()))
    spans.sort()
    merged = []
    for s, e in spans:
        if merged and s <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else:
            merged.append((s, e))
    return merged


def scan_text(text, ctx, min_literal_len=1):
    """Return a sorted list of (start, end, rule_id, secret) hits."""
    hits = []
    for rule in RULES:
        for s, e in rule.find(text):
            hits.append((s, e, rule.rid, rule.secret))
    low = text.lower()
    cfg = [v for v, _ in ctx.config_literals if len(v) >= min_literal_len]
    for s, e in find_literals(text, cfg, low):
        hits.append((s, e, "config-value", False))
    pats = [p for p in ctx.patterns if len(p) >= min_literal_len]
    for s, e in find_literals(text, pats, low):
        hits.append((s, e, "private-pattern", False))
    hits.sort(key=lambda h: (h[0], -h[1]))
    kept = []
    last_end = {}
    for h in hits:
        if h[1] <= last_end.get(h[2], -1):
            continue            # inside an earlier hit of the same rule
        last_end[h[2]] = h[1]
        kept.append(h)
    return kept


def try_json(text):
    """Return (object, True) if the text is a JSON object or array."""
    if not re.match(r"\s*[\[{]", text):
        return None, False
    try:
        return json.loads(text), True
    except ValueError:
        return None, False


def json_strings(text, obj=None):
    """All decoded strings (keys and values) of a JSON text, or None.

    None also when nothing is escaped, because then the raw text already
    shows every string exactly as a JSON parser would."""
    if "\\" not in text:
        return None
    if obj is None:
        obj, ok = try_json(text)
        if not ok:
            return None
    out = []
    stack = [obj]
    while stack:
        o = stack.pop()
        if isinstance(o, str):
            out.append(o)
        elif isinstance(o, list):
            stack.extend(o)
        elif isinstance(o, dict):
            out.extend(o.keys())
            stack.extend(o.values())
    return out


def scan_document(text, ctx, min_literal_len=1, obj=None):
    """Hits in the raw text, plus hits visible only after JSON decoding.

    Returns (raw_hits, decoded_text, decoded_only_hits)."""
    raw = scan_text(text, ctx, min_literal_len)
    strings = json_strings(text, obj)
    if strings is None:
        return raw, None, []
    decoded = "\n".join(strings)
    seen = set((rid, text[s:e]) for s, e, rid, _ in raw)
    extra = [h for h in scan_text(decoded, ctx, min_literal_len)
             if (h[2], decoded[h[0]:h[1]]) not in seen]
    return raw, decoded, extra


def _excerpt(text, s, e, secret):
    before = text[max(0, s - 30):s]
    shown = text[s:e]
    if secret:
        shown = shown[:8] + "...[masked]"
    elif len(shown) > 80:
        shown = shown[:80] + "..."
    after = text[e:e + 30]
    line = before + ">>" + shown + "<<" + after
    return re.sub(r"[\r\n\t]+", " ", line)


def format_hits(label, text, hits, suffix=""):
    """Lines describing hits; at most MAX_SHOWN per rule."""
    lines = []
    shown = {}
    total = {}
    for s, e, rid, secret in hits:
        total[rid] = total.get(rid, 0) + 1
        if shown.get(rid, 0) >= MAX_SHOWN:
            continue
        shown[rid] = shown.get(rid, 0) + 1
        line_no = text.count("\n", 0, s) + 1
        col = s - (text.rfind("\n", 0, s) + 1) + 1
        lines.append("HIT %s%s:%d:%d [%s] %s" % (label, suffix, line_no, col, rid,
                                                  _excerpt(text, s, e, secret)))
    for rid in sorted(total):
        if total[rid] > shown[rid]:
            lines.append("HIT %s%s [%s] ... and %d more" % (label, suffix, rid,
                                                            total[rid] - shown[rid]))
    return lines


def decode_payload(data):
    """Return (text, is_binary) for file contents; gzip is decompressed."""
    if data[:2] == b"\x1f\x8b":
        try:
            data = gzip.decompress(data)
        except (OSError, EOFError, ValueError, zlib.error):
            pass                # not really gzip: scan the bytes as they are
    if b"\0" in data[:8192]:
        return data.decode("latin-1"), True
    return data.decode("utf-8", "replace"), False


def check_file(path, label, ctx, data=None):
    """Return (hit_lines, n_hits, warning_or_None) for one file or blob."""
    try:
        if data is not None:
            text, binary = decode_payload(data)
        elif os.path.islink(path):
            text, binary = os.readlink(path), False     # the link target is what git stores
        else:
            with open(path, "rb") as fh:
                text, binary = decode_payload(fh.read())
    except (OSError, IOError) as exc:
        return [], 0, "cannot read %s: %s" % (label, exc)
    minlen = MIN_BINARY_LITERAL if binary else 1
    raw, decoded, extra = scan_document(text, ctx, minlen)
    lines = format_hits(label, text, raw)
    if extra:
        lines += format_hits(label, decoded, extra, " (JSON-decoded strings)")
    warn = None
    if binary:
        warn = ("%s is binary: scanned as raw bytes, literal patterns shorter "
                "than %d characters skipped" % (label, MIN_BINARY_LITERAL))
    return lines, len(raw) + len(extra), warn


def _git(args):
    try:
        proc = subprocess.Popen(["git"] + args, cwd=REPO_ROOT,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, _ = proc.communicate()
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return out


def _walk(path):
    if os.path.isdir(path) and not os.path.islink(path):
        for root, dirs, files in os.walk(path):
            dirs[:] = sorted(d for d in dirs if d != ".git")
            for f in sorted(files):
                yield os.path.join(root, f)
    else:
        yield path


def cmd_check(paths):
    ctx = default_context()
    warnings = []
    if ctx.patterns_missing:
        warnings.append("%s not found: private-pattern rule skipped, generic "
                        "rules still applied" % os.path.basename(PATTERN_FILE))
    targets = []        # (path on disk, label)
    staged = []         # (label, bytes): index copies that differ from the work tree
    virtual = []        # (label, text)
    default_mode = not paths
    if default_mode:
        out = _git(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
        if out is None:
            warnings.append("git ls-files failed: scanning every file under the "
                            "repository root instead (ignored files included)")
            for p in _walk(REPO_ROOT):
                targets.append((p, os.path.relpath(p, REPO_ROOT)))
        else:
            for rel in sorted(set(x for x in out.decode("utf-8", "replace").split("\0") if x)):
                targets.append((os.path.join(REPO_ROOT, rel), rel))
        diff = _git(["diff", "--name-only", "-z"])
        for rel in sorted(set(x for x in (diff or b"").decode("utf-8", "replace").split("\0") if x)):
            blob = _git(["show", ":" + rel])
            if blob is not None:
                staged.append(("<staged copy of %s>" % rel, blob))
        for var, label in (("GIT_AUTHOR_IDENT", "<next commit: author identity>"),
                           ("GIT_COMMITTER_IDENT", "<next commit: committer identity>")):
            ident = _git(["var", var])
            if ident is None:
                warnings.append("git var %s failed: identity not checked" % var)
            else:
                ident = ident.decode("utf-8", "replace").strip()
                virtual.append((label, re.sub(r"\s+\d+\s+[+-]\d{4}$", "", ident)))
        log = _git(["log", "--all", "--format=%H%n%an <%ae>%n%cn <%ce>%n%B"])
        if log:
            virtual.append(("<existing commits: author, committer, message>",
                            log.decode("utf-8", "replace")))
    else:
        for p in paths:
            if not os.path.lexists(p):
                sys.stderr.write("scrub check: no such file or directory: %s\n" % p)
                return 2
            for f in _walk(p):
                targets.append((f, f))

    all_lines = []
    files_with_hits = 0
    total = 0
    for path, label in targets:
        if not os.path.lexists(path):
            continue            # listed by git but deleted in the work tree
        lines, n, warn = check_file(path, label, ctx)
        name_hits = scan_text(label, ctx) if default_mode else []
        if name_hits:
            lines += format_hits(label, label, name_hits, " (file name)")
            n += len(name_hits)
        if warn:
            warnings.append(warn)
        if n:
            files_with_hits += 1
            total += n
            all_lines += lines
    for label, blob in staged:
        lines, n, warn = check_file(None, label, ctx, data=blob)
        if warn:
            warnings.append(warn)
        if n:
            files_with_hits += 1
            total += n
            all_lines += lines
    for label, text in virtual:
        hits = scan_text(text, ctx)
        if hits:
            files_with_hits += 1
            total += len(hits)
            all_lines += format_hits(label, text, hits)

    for w in warnings:
        sys.stderr.write("scrub check: warning: %s\n" % w)
    for line in all_lines:
        print(line)
    scope = "%d file(s)" % len(targets)
    if default_mode:
        scope += ", %d staged version(s), commit identity and commit metadata" % len(staged)
    if total:
        print("scrub check: FAILED - %d hit(s) in %d place(s); scanned %s"
              % (total, files_with_hits, scope))
        return 1
    print("scrub check: OK - no hits; scanned %s" % scope)
    return 0


# --------------------------------------------------------------------------
# Cleaning
# --------------------------------------------------------------------------

def _apply(text, edits):
    """Apply non-overlapping (start, end, replacement) edits."""
    if not edits:
        return text
    edits = sorted(edits)
    out = []
    pos = 0
    for s, e, new in edits:
        if s < pos:
            continue            # overlaps an earlier edit: already covered
        out.append(text[pos:s])
        out.append(new)
        pos = e
    out.append(text[pos:])
    return "".join(out)


def _bump(counts, key, n):
    if n:
        counts[key] = counts.get(key, 0) + n


def clean_text(text, ctx):
    """Return (sanitised_text, counts_by_placeholder)."""
    counts = {}
    for path, ph in ctx.path_subs:
        rx = re.compile(_BOUND + re.escape(path) + r"(?![A-Za-z0-9_.-])")
        text, n = rx.subn(lambda m, ph=ph: ph, text)
        _bump(counts, ph, n)
    for value, ph in ctx.config_literals:
        spans = find_literals(text, [value])
        text = _apply(text, [(s, e, ph) for s, e in spans])
        _bump(counts, ph, len(spans))
    for rule in RULES:
        edits = []
        for s, e in rule.find(text):
            if rule.repl is not None:
                edits.append(rule.repl(text, s, e))
            else:
                edits.append((s, e, rule.placeholder))
        text = _apply(text, edits)
        _bump(counts, rule.placeholder, len(edits))
    spans = find_literals(text, ctx.patterns)
    text = _apply(text, [(s, e, "<REDACTED>") for s, e in spans])
    _bump(counts, "<REDACTED>", len(spans))
    return text, counts


def _json_style(text):
    """Guess (indent, ensure_ascii) used to write a JSON text."""
    m = re.match(r"\s*[\[{]\n( +)\S", text)
    indent = len(m.group(1)) if m else None
    ensure_ascii = all(ord(c) < 128 for c in text[:200000])
    return indent, ensure_ascii


def clean_document(text, ctx):
    """Sanitise a text or JSON document.

    Replacement is done on the raw text, so the output is identical to the
    input outside the replaced spans. For JSON that is not always enough: an
    escape sequence can hide a string from the raw scan, or sit directly in
    front of a replaced span. In those cases every decoded string is
    sanitised instead and the document is re-serialised.

    Returns (new_text, counts, residual_hit_lines)."""
    new, counts = clean_text(text, ctx)
    obj, is_json = try_json(new)
    raw = decoded = extra = None
    if is_json:
        raw, decoded, extra = scan_document(new, ctx, obj=obj)
        rewrite = bool(extra)
    else:
        rewrite = try_json(text)[1]     # raw replacement broke the JSON syntax
    if rewrite:
        counts = {}

        def walk(o):
            if isinstance(o, str):
                cleaned, c = clean_text(o, ctx)
                for k, v in c.items():
                    _bump(counts, k, v)
                return cleaned
            if isinstance(o, list):
                return [walk(x) for x in o]
            if isinstance(o, dict):
                d = dict((walk(k), walk(v)) for k, v in o.items())
                if len(d) != len(o):
                    raise ScrubError("two JSON keys became identical after cleaning")
                return d
            return o
        indent, ensure_ascii = _json_style(text)
        new = json.dumps(walk(json.loads(text)), indent=indent, ensure_ascii=ensure_ascii)
        if text.endswith("\n"):
            new += "\n"
        counts["(JSON re-serialised)"] = 1
        raw = None
    if raw is None:
        raw, decoded, extra = scan_document(new, ctx)
    residual = format_hits("output", new, raw)
    if extra:
        residual += format_hits("output", decoded, extra, " (JSON-decoded strings)")
    return new, counts, residual


def cmd_clean(infile, outfile):
    ctx = default_context()
    if ctx.patterns_missing:
        sys.stderr.write("scrub clean: warning: %s not found: no private patterns "
                         "applied, generic rules only\n" % os.path.basename(PATTERN_FILE))
    if os.path.abspath(infile) == os.path.abspath(outfile):
        sys.stderr.write("scrub clean: input and output are the same file\n")
        return 2
    try:
        with open(infile, "rb") as fh:
            data = fh.read()
        if infile.endswith(".gz") or data[:2] == b"\x1f\x8b":
            data = gzip.decompress(data)
    except (OSError, IOError, EOFError, zlib.error) as exc:
        sys.stderr.write("scrub clean: cannot read %s: %s\n" % (infile, exc))
        return 2
    if b"\0" in data[:8192]:
        sys.stderr.write("scrub clean: %s looks binary; only text and JSON are supported\n" % infile)
        return 2
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        sys.stderr.write("scrub clean: %s is not UTF-8 text: %s\n" % (infile, exc))
        return 2
    try:
        new, counts, residual = clean_document(text, ctx)
    except ScrubError as exc:
        sys.stderr.write("scrub clean: %s: %s\n" % (infile, exc))
        return 1
    if residual:
        for line in residual:
            print(line)
        sys.stderr.write("scrub clean: FAILED - sensitive strings remain after "
                         "cleaning; %s not written\n" % outfile)
        return 1
    payload = new.encode("utf-8")
    if outfile.endswith(".gz"):
        buf = io.BytesIO()
        with gzip.GzipFile(filename="", mode="wb", fileobj=buf, compresslevel=9, mtime=0) as gz:
            gz.write(payload)
        payload = buf.getvalue()
    out_dir = os.path.dirname(os.path.abspath(outfile))
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    tmp = outfile + ".scrub-tmp"
    with open(tmp, "wb") as fh:
        fh.write(payload)
    os.rename(tmp, outfile)
    summary = " ".join("%s=%d" % (k, counts[k]) for k in sorted(counts)) or "no replacements"
    print("scrub clean: wrote %s (%d bytes): %s" % (outfile, len(payload), summary))
    return 0


# --------------------------------------------------------------------------
# Self-test. Every sensitive-looking string is assembled at run time, so this
# file contains none and passes its own check.
# --------------------------------------------------------------------------

def cmd_selftest():
    failures = []
    passed = [0]

    def ok(cond, what):
        if cond:
            passed[0] += 1
        else:
            failures.append(what)

    sl = "/"
    users = sl + "Users" + sl
    home_lin = sl + "home" + sl
    vol = sl + "Volumes" + sl
    ptmp = sl + "private" + sl + "tmp"
    agent = sl + "tmp" + sl + "claude"
    dotdir = "." + "claude" + sl
    at = "@"
    secret_pat = "Zq" + "Xsecret"
    work = sl + "data" + sl + "rh-work"
    repo = sl + "srv" + sl + "repo"
    project = "proj-" + "synthetic-1"
    bucket = project + "-bkt"
    ctx = Context(patterns=[secret_pat, "tiny"], workdirs=[work], repo_root=repo,
                  config_literals=[(bucket, "<BUCKET>"), (project, "<PROJECT_ID>"),
                                   (work, "<WORKDIR>")])
    bare = Context(patterns=None)

    def rules_hit(text, context=ctx):
        return sorted(set(h[2] for h in scan_text(text, context)))

    positives = [
        ("home-path", "see " + users + "alice/proj/a.txt"),
        ("home-path", "HOME=" + home_lin + "bob"),
        ("volume-path", "cd " + vol + "Disk_One/build"),
        ("session-path", "log at " + ptmp + "/run/x.log"),
        ("session-path", agent + "-501/-x-y/abc/scratchpad/t.py"),
        ("session-path", "in ~/" + dotdir + "projects/x"),
        ("session-path", sl + "var" + sl + "folders" + sl + "ab/cdefgh12345/T/x"),
        ("email", "mail carol" + at + "corp.invalid now"),
        ("email", "sa-1" + at + "p.iam.gserviceaccount.com"),
        ("billing-account", "billing 0A1B2C" + "-3D4E5F" + "-6A7B8C here"),
        ("project-number", "projects/" + "1234" + "56789012" + "/locations"),
        ("project-number", '"projectNumber": "' + "9876" + "54321098" + '"'),
        ("project-number", "9876" + "54321098" + " (project)"),
        ("credential", "-----BEGIN " + "RSA PRIVATE KEY-----\nabc\n-----END " + "RSA PRIVATE KEY-----"),
        ("credential", "token ya" + "29." + "A" * 30),
        ("credential", "gh" + "p_" + "a1B2" * 9),
        ("credential", "github" + "_pat_" + "a1B2_" * 6),
        ("credential", "AK" + "IA" + "ABCDEFGH12345678"),
        ("credential", "AI" + "za" + "x" * 35),
        ("private-pattern", "owner is " + secret_pat.upper() + "!"),
        ("config-value", "gs://" + bucket + "/x"),
        ("config-value", "--project " + project),
        ("config-value", "ls " + work + "/logs"),
    ]
    for rid, text in positives:
        ok(rid in rules_hit(text), "expected a %s hit in synthetic case %d"
           % (rid, positives.index((rid, text))))

    negatives = [
        users + "<name>/work",
        home_lin + "$USER/work and " + home_lin + "user/x and " + users + "Shared/x",
        "https://example.org" + home_lin + "page/index.html",
        vol + "<name>/work and " + vol + "...",
        "write to peter.lowes" + at + "sie.life or noreply" + at + "anthropic.com",
        "someone" + at + "example.com",
        "git" + at + "github.com:owner/repo.git",
        "simp only [foo] " + at + "bar and x " + at + "Nat.succ y",
        "sha256 9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc",
        "epoch=1795191515 size 239275554 project budget 40",
        "uuid 123e4567-e89b-12d3-a456-426614174000",
        "<HOME>/.elan and <WORKDIR>/logs and <SCRATCH>/x and <VOLUME>/y",
        "the " + "tmp" + " directory and a file named claude.md",
    ]
    for i, text in enumerate(negatives):
        got = rules_hit(text)
        ok(not got, "unexpected hit %s in synthetic negative %d" % (got, i))

    ok(rules_hit("x " + secret_pat + " y", bare) == [], "absent pattern file must not flag literals")
    ok(bare.patterns_missing and not ctx.patterns_missing, "pattern-file presence flag")

    # clean: every positive must come out with no hits
    for i, (rid, text) in enumerate(positives):
        new, counts, residual = clean_document(text, ctx)
        ok(not residual, "clean left a hit in synthetic case %d (%s)" % (i, rid))
        ok(new != text, "clean changed nothing in synthetic case %d (%s)" % (i, rid))

    def cleaned(text):
        return clean_document(text, ctx)[0]

    ok(cleaned("a " + work + "/logs/x b") == "a <WORKDIR>/logs/x b", "workdir placeholder")
    ok(cleaned(repo + "/scripts/x.sh") == "<REPO>/scripts/x.sh", "repo placeholder")
    inside = Context(patterns=[], workdirs=[repo + "/work"], repo_root=repo)
    ok(clean_document(repo + "/work/logs " + repo + "/workshop " + repo + "-old", inside)[0]
       == "<WORKDIR>/logs <REPO>/workshop " + repo + "-old", "path placeholders end at a path boundary")
    ok(cleaned(users + "alice/.elan/bin") == "<HOME>/.elan/bin", "home placeholder keeps the tail")
    ok(cleaned(vol + "Disk_One/build/x") == "<VOLUME>/build/x", "volume placeholder keeps the tail")
    ok(cleaned(agent + "-501/-U-a/s1/scratchpad/t.py:3") == "<SCRATCH>/t.py:3", "scratchpad tail kept")
    ok(cleaned('"' + agent + '-501/-U-a/s1/other/t.py"') == '"<SCRATCH>"', "agent temp path swallowed")
    ok(cleaned("(" + users + "alice/p/" + dotdir + "w/t/f.txt)") == "(<SCRATCH>)", "dot-directory token")
    ok(cleaned(ptmp + "/x") == "<SCRATCH>/x", "private temp placeholder")
    ok(cleaned("to carol" + at + "corp.invalid, peter.lowes" + at + "sie.life")
       == "to <EMAIL>, peter.lowes" + at + "sie.life", "email placeholder and allowlist")
    ok(cleaned("gs://" + bucket + "/o in " + project) == "gs://<BUCKET>/o in <PROJECT_ID>",
       "bucket is replaced before the project id it contains")
    ok(cleaned("projects/" + "1234" + "56789012" + "/x") == "projects/<PROJECT_NUMBER>/x",
       "project number placeholder")
    ok(cleaned("id 0A1B2C" + "-3D4E5F" + "-6A7B8C.") == "id <BILLING_ACCOUNT>.", "billing placeholder")
    ok(cleaned("k=" + secret_pat.lower() + ";") == "k=<REDACTED>;", "private pattern, case-insensitive")
    ok(cleaned("plain text, nothing to do\n") == "plain text, nothing to do\n", "clean text untouched")
    key = "-----BEGIN " + "PRIVATE KEY-----\nMIIabc\n-----END " + "PRIVATE KEY-----"
    ok(cleaned("k: " + key + " end") == "k: <CREDENTIAL> end", "whole private key block replaced")
    try:
        clean_document("-----BEGIN " + "PRIVATE KEY-----\nMIIabc", ctx)
        ok(False, "truncated private key must be refused")
    except ScrubError:
        ok(True, "")

    # JSON: byte-for-byte outside the replaced spans; escapes cannot hide a string
    doc = json.dumps({"log": work + "/logs/a.log", "n": 1.50, "who": users + "alice"}, indent=1)
    new = cleaned(doc)
    ok(json.loads(new) == {"log": "<WORKDIR>/logs/a.log", "n": 1.5, "who": "<HOME>"}, "JSON values cleaned")
    ok(new.count("\n") == doc.count("\n"), "JSON layout preserved")
    hidden = ('{"p": "' + users.replace("/", "\\/") + 'alice\\/x", "q": "log\\n' + users + 'bob/y", '
              '"u": "\\u0063arol' + at + 'corp.invalid"}')
    raw, decoded, extra = scan_document(hidden, ctx)
    ok(sorted(set(h[2] for h in extra)) == ["email", "home-path"] and len(extra) == 3,
       "escaped JSON strings are found after decoding")
    new, counts, residual = clean_document(hidden, ctx)
    ok(not residual and json.loads(new) == {"p": "<HOME>/x", "q": "log\n<HOME>/y", "u": "<EMAIL>"},
       "escaped JSON strings cleaned by re-serialising")
    ok(clean_document('{"a": 1, "b": [true, null, "x"]}', ctx)[0] == '{"a": 1, "b": [true, null, "x"]}',
       "clean JSON untouched")

    # gzip round trip, in memory
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(("x " + users + "alice y").encode("utf-8"))
    ok(gzip.decompress(buf.getvalue()).decode("utf-8") == "x " + users + "alice y", "gzip round trip")
    ok(buf.getvalue()[4:8] == b"\0\0\0\0", "gzip written without a timestamp")

    # binary payloads skip short literals only
    blob = "\0\0" + "tiny " + secret_pat
    ok([h[2] for h in scan_text(blob, ctx, MIN_BINARY_LITERAL)] == ["private-pattern"],
       "short literals skipped in binary scan, long ones kept")

    # config parsing (no shell involved)
    cfg = parse_config('# c\nRH_WORKDIR="$REPO_ROOT/work"\nGCP_PROJECT=\'p-1\'  # note\n'
                       'export RH_JOBS=8 # n\nGCP_BUCKET=""\nnot a setting\n', repo)
    ok(cfg == {"RH_WORKDIR": repo + "/work", "GCP_PROJECT": "p-1", "RH_JOBS": "8", "GCP_BUCKET": ""},
       "config parsing")

    # this file must pass its own generic rules (no private patterns involved)
    with io.open(os.path.abspath(__file__), encoding="utf-8") as fh:
        own = fh.read()
    own_hits = scan_text(own, bare)
    ok(not own_hits, "scrub.py triggers its own rules: %s"
       % sorted(set(h[2] for h in own_hits)))

    if failures:
        for f in failures:
            print("selftest FAIL: %s" % f)
        print("scrub selftest: FAILED - %d of %d checks failed"
              % (len(failures), len(failures) + passed[0]))
        return 1
    print("scrub selftest: OK - %d checks passed" % passed[0])
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "check":
        return cmd_check(argv[2:])
    if len(argv) == 4 and argv[1] == "clean":
        return cmd_clean(argv[2], argv[3])
    if len(argv) == 2 and argv[1] == "selftest":
        return cmd_selftest()
    if len(argv) == 2 and argv[1] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0
    sys.stderr.write("usage: scrub.py check [paths...]\n"
                     "       scrub.py clean <infile> <outfile>\n"
                     "       scrub.py selftest\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
