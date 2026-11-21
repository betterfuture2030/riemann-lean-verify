#!/usr/bin/env python3
"""Turn the calibration pilot's measurements into an estimate for a full build and a full kernel replay
on the same machine type.

Usage:
  pilot_estimate.py PILOT_RESULTS_DIR IMPORT_GRAPH_JSON[.gz] [--vcpus 32] [--out FILE]
                    [--config NAME:USD_PER_HOUR:DISK_GB] ...

  PILOT_RESULTS_DIR holds modules.tsv, system.tsv, phases.tsv, import_only.tsv, import_probe.tsv and
  disk.txt, plain or gzipped. USD_PER_HOUR is the machine alone; disks are priced separately from DISK_GB.
  With no --config, one configuration is priced: the pilot's machine, on demand, with the pilot's disk.

Method (the reasoning, and the review that shaped it, are in docs/cloud-notes.md section 8):
  1. Keep compiler processes that finished. In a window stopped by its time limit, a row whose end falls
     within 3 s of the window's end was killed, not finished. Which windows ran to completion instead is
     read from lake_log_summary.tsv, or from the last line of each lake_<window>.log if that is absent.
  2. Cost model for compiling one module, in CPU seconds at the full job count:
         cpu = E + s * closure
     where closure is the number of project modules the module imports directly or indirectly.
     A plain regression of cpu on closure gives a slope that cannot be told apart from zero, because in
     the pilot's sample closure size is mixed up with how heavy each module's own content is. So s is
     taken from the import probes (single processes importing modules of known closure), scaled by the
     measured cost of running the full job count at once, and E is set so that the model reproduces the
     pilot's mean. The plain regression and a regression on the largest closures alone are reported and
     used for the low and high cases.
  3. Apply the model to a random sample of the whole tree. Mean times module count is the CPU needed.
  4. Convert CPU to wall-clock with the measured useful CPU per machine thread-second: the CPU found in
     compiler processes during the interior of a window, divided by threads times seconds.
  5. The kernel checker is treated the same way from its own phase.
  6. Low, expected and high differ in the slope, the utilisation and the fixed allowances, all listed in
     the output under "cases".
"""
import collections, csv, gzip, json, os, random, statistics as st, sys

def arg(flag, default):
    return type(default)(sys.argv[sys.argv.index(flag) + 1]) if flag in sys.argv else default
def args(flag):
    return [sys.argv[i + 1] for i, a in enumerate(sys.argv[:-1]) if a == flag]
def op(d, name):
    p = os.path.join(d, name)
    return open(p) if os.path.exists(p) else gzip.open(p + '.gz', 'rt')

D, GRAPH = sys.argv[1], sys.argv[2]
VCPUS = arg('--vcpus', 32); OUT = arg('--out', '')
CONFIGS = [c.split(':') for c in args('--config')] or [['n4d-highmem-32 on demand, 440 GB disk', '1.78', '440']]

g = json.load((gzip.open if GRAPH.endswith('.gz') else open)(GRAPH, 'rt'))
names = sorted(g); idx = {m: i for i, m in enumerate(names)}
dl = [[idx[d] for d in g[m] if d in idx] for m in names]
N = len(names)
_cache = {}
def closure(i):
    if i in _cache: return _cache[i]
    seen = {i}; stk = [i]
    while stk:
        x = stk.pop()
        for w in dl[x]:
            if w not in seen: seen.add(w); stk.append(w)
    _cache[i] = len(seen) - 1
    return _cache[i]
def lib_of(name): return '.'.join(name.split('.')[:2])

# ---- phases: window starts, ends and job counts
ends = {}; jobs = {}; starts = {}
for line in op(D, 'phases.tsv'):
    p = line.rstrip('\n').split('\t')
    if len(p) < 2: continue
    if p[1].endswith(':end'): ends[p[1][:-4]] = int(p[0])
    elif ':N=' in p[1]:
        base, n = p[1].split(':N='); jobs[base] = int(n); starts[base] = int(p[0])
BUILD = [b for b in jobs if b != 'check']
# A window whose build ran to completion (exit code 0) killed nothing; one stopped by its time limit did.
# The guest script ends each build log with a line "rc=<exit code>"; the records keep a summary of the logs instead.
completed = set()
try:
    for r in csv.DictReader(op(D, 'lake_log_summary.tsv'), delimiter='\t'):
        if r['exit_code'] == '0': completed.add(r['log'].replace('lake_', ''))
except OSError:
    for base in BUILD:
        try:
            if any(l.strip() == 'rc=0' for l in collections.deque(op(D, 'lake_%s.log' % base), maxlen=3)): completed.add(base)
        except (OSError, UnicodeDecodeError):
            pass

# ---- processes
procs = []
for r in csv.DictReader(op(D, 'modules.tsv'), delimiter='\t'):
    base = r['phase'].split(':')[0]
    if base not in jobs: continue
    t0, t1 = float(r['t_start']), float(r['t_end'])
    procs.append(dict(mod=r['module'], kind=r['kind'], phase=base, n=jobs[base], t0=t0, t1=t1,
                      cpu=float(r['user_s']) + float(r['sys_s']), sys=float(r['sys_s']),
                      anon=int(r['peak_anon_mb']), rss=int(r['peak_rss_mb']), thr=int(r['peak_threads']), killed=base not in completed and t1 >= ends.get(base, 1e18) - 3.0))
compilers = [p for p in procs if p['kind'] == 'lean' and p['phase'] in BUILD]
finished = [p for p in compilers if not p['killed']]
lean = {}; chk = {}
for p in procs:
    if p['killed'] or p['mod'] not in idx: continue
    if p['kind'] == 'lean' and p['phase'] in BUILD: lean[p['mod']] = p
    elif p['kind'] == 'leanchecker' and p['phase'] == 'check': chk[p['mod']] = p
for d in (lean, chk):
    for p in d.values(): p['c'] = closure(idx[p['mod']])

def ols(xs, ys):
    mx, my = st.mean(xs), st.mean(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    a = my - b * mx
    se = (sum((y - a - b * x) ** 2 for x, y in zip(xs, ys)) / max(1, len(xs) - 2) / sxx) ** 0.5
    return a, b, se
def bins(recs):
    out = []
    for lo, hi in ((0, 0), (1, 100), (101, 1000), (1001, 3000), (3001, 8000), (8001, 10 ** 9)):
        v = [r['cpu'] for r in recs if lo <= r['c'] <= hi]
        if v: out.append(dict(closure='%d-%s' % (lo, hi if hi < 10 ** 9 else 'max'), n=len(v), median=round(st.median(v), 2), mean=round(st.mean(v), 2)))
    return out

# ---- compile cost model
full = [p for p in lean.values() if p['n'] == VCPUS]
a_fit, b_fit, se_fit = ols([p['c'] for p in full], [p['cpu'] for p in full])
tail = [p for p in full if p['c'] > 8000]
_, b_tail, se_tail = ols([p['c'] for p in tail], [p['cpu'] for p in tail])
mean_cpu = st.mean(p['cpu'] for p in full); mean_c = st.mean(p['c'] for p in full); max_obs = max(p['c'] for p in full)

probe = [r for r in csv.DictReader(op(D, 'import_probe.tsv'), delimiter='\t') if r['module'] in idx]
def probe_fit(kind):
    rows = [(closure(idx[r['module']]), float(r['user_s']) + float(r['sys_s'])) for r in probe if r['kind'] == kind and r['failures'] == '0']
    return ols([x for x, _ in rows], [y for _, y in rows]) + (len(rows),)
imp_a, imp_b, imp_se, imp_n = probe_fit('import')
io = list(csv.DictReader(op(D, 'import_only.tsv'), delimiter='\t'))
def per_proc(n): return st.mean((float(r['user_s']) + float(r['sys_s'])) / n for r in io if int(r['n']) == n)
contention = per_proc(VCPUS) / per_proc(1)            # CPU per import when the full job count runs at once, over alone
s_phys = imp_b * contention

lib = collections.defaultdict(list)
for p in full: lib[lib_of(p['mod'])].append(p['cpu'] - (a_fit + b_fit * p['c']))
lib_shrunk = {k: st.mean(v) * len(v) / (len(v) + 200) for k, v in lib.items()}   # small samples pulled towards zero

random.seed(20261120)
sample = random.sample(range(N), min(N, 8000))
cs = [closure(i) for i in sample]
mean_closure = st.mean(cs)
def tree_cpu_h(slope, stratified=False):
    E = mean_cpu - slope * mean_c                      # reproduces the pilot's mean at the pilot's mean closure
    v = [E + slope * c + (lib_shrunk.get(lib_of(names[i]), 0.0) if stratified else 0.0) for i, c in zip(sample, cs)]
    return N * st.mean(v) / 3600

# ---- useful CPU per machine thread-second, from the interior of each window
def efficiency(base, kind):
    t0, t1 = starts[base] + 20, ends[base] - 20
    tot = 0.0
    for p in procs:
        if p['phase'] != base or p['kind'] != kind: continue
        w = p['t1'] - p['t0']
        if w <= 0: continue
        tot += p['cpu'] * max(0.0, min(p['t1'], t1) - max(p['t0'], t0)) / w
    return tot / (VCPUS * (t1 - t0))
S = list(csv.DictReader(op(D, 'system.tsv'), delimiter='\t'))
def machine(base):
    X = [r for r in S if r['phase'].split(':')[0] == base]
    if len(X) < 8: return None
    a0, b0 = X[4], X[-4]
    d = {k: int(b0[k]) - int(a0[k]) for k in ('cpu_user', 'cpu_nice', 'cpu_sys', 'cpu_idle', 'cpu_iowait')}
    tot = sum(d.values()) or 1; T = float(b0['t']) - float(a0['t'])
    return dict(busy=round((d['cpu_user'] + d['cpu_nice'] + d['cpu_sys']) / tot, 3), sys_share=round(d['cpu_sys'] / tot, 3),
                write_mb_s=round((int(b0['disk_written_bytes']) - int(a0['disk_written_bytes'])) / T / 1e6, 1),
                read_mb_s=round((int(b0['disk_read_bytes']) - int(a0['disk_read_bytes'])) / T / 1e6, 3),
                min_avail_gb=round(min(int(r['mem_avail_mb']) for r in X) / 1024), max_open_files=max(int(r['file_nr']) for r in X))
windows = {}
for base in sorted(jobs):
    kind = 'leanchecker' if base == 'check' else 'lean'
    done = [p for p in procs if p['phase'] == base and p['kind'] == kind and not p['killed']]
    T = ends[base] - starts[base]
    first = min((p['t1'] for p in done), default=None)
    m = machine(base) or {}
    lk = [float(r['lake_user_s']) + float(r['lake_sys_s']) for r in S if r['phase'].split(':')[0] == base]
    if lk and done and kind == 'lean':               # the build tool's own CPU; its counters restart with each window
        m['build_tool_cpu_s_per_module'] = round(max(lk) / len(done), 3); m['build_tool_cores'] = round(max(lk) / T, 2)
    windows[base] = dict(jobs=jobs[base], seconds=T, finished=len(done), per_second=round(len(done) / T, 2),
                         useful_cpu_per_thread_second=round(efficiency(base, kind), 3),
                         mean_cpu_s=round(st.mean(p['cpu'] for p in done), 2) if done else None,
                         seconds_to_first=round(first - starts[base], 1) if first else None, **m)
full_windows = [b for b in BUILD if jobs[b] == VCPUS]
eff_expected = windows['deepB']['useful_cpu_per_thread_second'] if 'deepB' in windows else st.mean(windows[b]['useful_cpu_per_thread_second'] for b in full_windows)
eff_best = max(windows[b]['useful_cpu_per_thread_second'] for b in full_windows)

# ---- kernel checker
c_a, c_b, c_se = ols([p['c'] for p in chk.values()], [p['cpu'] for p in chk.values()])
chk_a, chk_b, chk_se, chk_n = probe_fit('checker')
eff_check = windows['check']['useful_cpu_per_thread_second']
def check_cpu_h(slope_factor=1.0): return N * st.mean(c_a + c_b * slope_factor * c for c in cs) / 3600

# ---- memory and open files, against closure size
allc = list(lean.values())
sh_a, sh_b, sh_se = ols([p['c'] for p in allc], [p['rss'] - p['anon'] for p in allc])     # file-backed pages: compiled files mapped and touched
pr_a, pr_b, pr_se = ols([p['c'] for p in allc], [p['anon'] for p in allc])                # private memory
TOP = N - 1                                                                              # the last module imports every other one
named = [p for p in compilers if p['mod'] in idx]
for p in named: p.setdefault('c', closure(idx[p['mod']]))
rows_of = collections.defaultdict(list)
for p in named: rows_of[p['phase']].append(p)
base_files = int(S[0]['file_nr'])
X = []
for r in S:
    ph = r['phase'].split(':')[0]
    if ph not in ('cold', 'deepA', 'deepB'): continue
    t = float(r['t'])
    live = [p['c'] for p in rows_of[ph] if p['t0'] + 1.5 <= t <= p['t1'] - 0.5]
    if len(live) >= 8: X.append((len(live), sum(live), int(r['file_nr']) - base_files))
snn = sum(n * n for n, c, y in X); scc = sum(c * c for n, c, y in X); snc = sum(n * c for n, c, y in X)
sny = sum(n * y for n, c, y in X); scy = sum(c * y for n, c, y in X); det = snn * scc - snc * snc
of_base = (sny * scc - scy * snc) / det; of_per = (snn * scy - snc * sny) / det        # system-wide open files = base * processes + per * imports

# ---- disk
disk = dict(l.split(' ', 1) for l in op(D, 'disk.txt').read().splitlines() if ' ' in l and not l.startswith('/'))
ole_mb = int(disk['lib_bytes']) / int(disk['oleans']) / 1e6
json_mb = int(disk['setup_json_bytes']) / int(disk['setup_json_files']) / 1e6
B0 = 5.36                                              # MB: setup file of a module importing Mathlib only (rehearsal mean)
built_mean_c = st.mean(p['c'] for p in lean.values())
b1 = max(0.0, (json_mb - B0) / max(1.0, built_mean_c))
setup_tb = N * (B0 + b1 * mean_closure) / 1e6; ole_tb = N * ole_mb / 1e6

# ---- cases
#           slope used for compiling            stratified  efficiency          checker slope  fixed hours: setup, top of graph, criterion C2, slack
CASES = dict(
    low=dict(slope=b_fit, strat=True, eff=eff_best, eff_chk=eff_check, chk_slope=1.0, setup=0.3, top=0.2, c2=0.2, slack=0.0),
    expected=dict(slope=s_phys, strat=False, eff=eff_expected, eff_chk=eff_check, chk_slope=1.0, setup=0.5, top=0.4, c2=0.5, slack=0.5),
    high=dict(slope=max(b_tail, s_phys) * 1.10, strat=False, eff=eff_expected * 0.95, eff_chk=eff_check * 0.95, chk_slope=1.5, setup=1.0, top=1.0, c2=2.0, slack=3.0),
)
def disk_usd_per_hour(gb, iops=6000, mbps=300, boot_gb=50):
    # Hyperdisk Balanced list prices per month: capacity 0.08 per GB, 0.005 per IOPS above 3,000, 0.04 per MB/s above 140
    return (gb * 0.08 + max(0, iops - 3000) * 0.005 + max(0, mbps - 140) * 0.04 + boot_gb * 0.08) / 730
hours = {}
for name, c in CASES.items():
    cpu_b = tree_cpu_h(c['slope'], c['strat']); cpu_c = check_cpu_h(c['chk_slope'])
    bh = cpu_b / (VCPUS * c['eff']) + c['top']; ch = cpu_c / (VCPUS * c['eff_chk'])
    hours[name] = dict(compile_cpu_hours=round(cpu_b), check_cpu_hours=round(cpu_c), build_hours=round(bh, 1), check_hours=round(ch, 1),
                       other_hours=round(c['setup'] + c['c2'] + c['slack'], 1), billed_hours=round(bh + ch + c['setup'] + c['c2'] + c['slack'], 1))
configs = []
for name, rate, gb in CONFIGS:
    rate = float(rate); gb = float(gb); d = disk_usd_per_hour(gb)
    row = dict(name=name, machine_usd_per_hour=rate, disk_gb=gb, disk_usd_per_hour=round(d, 3))
    for k, h in hours.items():
        # disks are kept for 6 hours after the machine stops, to copy results off
        row[k + '_usd'] = round(h['billed_hours'] * (rate + d) + 6 * d)
    configs.append(row)

res = dict(
    machine=dict(vcpus=VCPUS),
    observed=dict(compiler_processes_finished=len(finished), compiler_processes_killed_at_window_ends=len(compilers) - len(finished),
                  distinct_modules_compiled=len(lean), of_which_at_full_jobs=len(full), largest_closure_compiled=max_obs,
                  checker_modules=len(chk), mean_closure_compiled=round(mean_c),
                  peak_private_memory_mb=dict(median=st.median(p['anon'] for p in full), p99=sorted(p['anon'] for p in full)[int(len(full) * 0.99)], max=max(p['anon'] for p in full)),
                  threads_per_compiler=dict(median=st.median(p['thr'] for p in full), max=max(p['thr'] for p in full))),
    compile_model=dict(mean_cpu_seconds=round(mean_cpu, 2),
                       plain_regression=dict(base=round(a_fit, 3), per_1000_imports=round(b_fit * 1000, 3), standard_error=round(se_fit * 1000, 3)),
                       largest_closures_only=dict(n=len(tail), per_1000_imports=round(b_tail * 1000, 3), standard_error=round(se_tail * 1000, 3)),
                       import_probe=dict(n=imp_n, base=round(imp_a, 3), per_1000_imports=round(imp_b * 1000, 3), standard_error=round(imp_se * 1000, 3)),
                       contention_at_full_jobs=round(contention, 3), slope_used_per_1000_imports=round(s_phys * 1000, 3),
                       by_closure=bins(full)),
    tree=dict(modules=N, mean_closure=round(mean_closure), sample=len(cs),
              share_with_closure_beyond_compiled=round(sum(1 for c in cs if c > max_obs) / len(cs), 3)),
    windows=windows,
    checker=dict(base=round(c_a, 3), per_1000_imports=round(c_b * 1000, 3), standard_error=round(c_se * 1000, 3), by_closure=bins(list(chk.values())),
                 kernel_share_of_cpu=round(sum(p['sys'] for p in chk.values()) / sum(p['cpu'] for p in chk.values()), 3),
                 alone=dict(n=chk_n, base=round(chk_a, 3), per_1000_imports=round(chk_b * 1000, 3))),
    disk=dict(compiled_mb_per_module=round(ole_mb, 2), setup_file_mb_per_module=round(json_mb, 2), setup_files_tb_full_tree=round(setup_tb, 2),
              compiled_tb_full_tree=round(ole_tb, 3), peak_gb_if_setup_files_are_deleted_as_modules_finish=round(ole_tb * 1000 + 25)),
    memory=dict(file_backed_mb=dict(base=round(sh_a), per_import=round(sh_b, 3), projected_for_last_module_gb=round((sh_a + sh_b * TOP) / 1024)),
                private_mb=dict(base=round(pr_a), per_import=round(pr_b, 4), projected_for_last_module_gb=round((pr_a + pr_b * TOP) / 1024, 1)),
                whole_machine=dict(peak_anonymous_gb=round(max(int(r['anon_mb']) for r in S) / 1024, 1),
                                   least_available_gb=round(min(int(r['mem_avail_mb']) for r in S) / 1024),
                                   most_cached_gb=round(max(int(r['cached_mb']) for r in S) / 1024))),
    open_files=dict(samples=len(X), per_process_base=round(of_base), per_imported_project_module=round(of_per, 2),
                    projected_for_last_module=round(of_base + of_per * TOP), note='system-wide count regressed on live processes and their imports; noisy'),
    cases={k: {kk: (round(vv, 6) if isinstance(vv, float) else vv) for kk, vv in c.items()} for k, c in CASES.items()},
    hours=hours,
    configurations=configs,
)
if OUT: json.dump(res, open(OUT, 'w'), indent=1)
print(json.dumps(res, indent=1))
