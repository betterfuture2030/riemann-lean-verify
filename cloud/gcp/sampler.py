#!/usr/bin/env python3
"""Passive sampler for the pilot. Reads /proc only; never touches the build.

modules.tsv  one row per `lean` / `leanchecker` process that has disappeared, with its CPU seconds, peak
             sampled memory (total resident, and private anonymous), peak thread count, and the module it
             was working on. A process that was killed at the end of a time-boxed window also disappears,
             so a row is NOT proof that the module finished: the analysis must drop rows whose t_end falls
             within about a second of a window's end (phases.tsv) or cross-check against Lake's log.
system.tsv   one row every few seconds with machine-wide CPU, memory, disk and the build tool's own CPU.

CPU is read at each sample, so the last sample before exit under-counts by up to one interval per process.
The current phase label is read from <dir>/phase.
"""
import os, re, sys, time

D = sys.argv[1]
HZ = os.sysconf('SC_CLK_TCK'); PAGE = os.sysconf('SC_PAGE_SIZE')
INTERVAL = 0.25; SYS_EVERY = 5.0; ANON_EVERY = 4      # anonymous memory is read every 4th scan (1 s)
WHOLE_DISK = re.compile(r'^(nvme\d+n\d+|sd[a-z]+|vd[a-z]+)$')
ANON = re.compile(r'^RssAnon:\s+(\d+) kB', re.M)
live = {}       # (pid, starttime) -> record
done_count = 0

def phase():
    try:
        return open(os.path.join(D, 'phase')).read().strip() or 'none'
    except OSError:
        return 'none'

def read(path, mode='r'):
    try:
        with open(path, mode) as f:
            return f.read()
    except OSError:
        return None

def module_of(pid, comm):
    raw = read('/proc/%s/cmdline' % pid, 'rb')
    if not raw:
        return '?'
    args = [a.decode('utf-8', 'replace') for a in raw.split(b'\0') if a]
    if comm == 'leanchecker':
        return args[-1] if len(args) > 1 else '?'
    for a in args[1:]:
        if a.endswith('.lean') and not a.startswith('-'):
            i = a.rfind('/src/')
            rel = a[i + 5:] if i >= 0 else os.path.basename(a)
            return rel[:-5].replace('/', '.')
    return '?'

def scan(now, mf, tick):
    global done_count
    seen = set(); lake = None
    for d in os.listdir('/proc'):
        if not d.isdigit():
            continue
        s = read('/proc/%s/stat' % d)
        if not s:
            continue
        rp = s.rfind(')'); comm = s[s.find('(') + 1:rp]
        if comm not in ('lean', 'leanchecker', 'lake'):
            continue
        f = s[rp + 2:].split()     # f[0] is the state, i.e. field 3 of the documented layout
        try:
            ut, st, nthr, start, rss = int(f[11]), int(f[12]), int(f[17]), int(f[19]), int(f[21]) * PAGE
        except (IndexError, ValueError):
            continue
        if comm == 'lake':
            if lake is None or ut + st > lake[0] + lake[1]:
                lake = (ut, st, nthr, rss)
            continue
        key = (d, start); seen.add(key)
        r = live.get(key)
        if r is None:
            r = live[key] = dict(comm=comm, mod=module_of(d, comm), t0=now, ph=phase(), rss=0, anon=0, thr=0, n=0)
        r['t1'] = now; r['ut'] = ut; r['st'] = st; r['n'] += 1
        if rss > r['rss']: r['rss'] = rss
        if nthr > r['thr']: r['thr'] = nthr
        if tick % ANON_EVERY == 0:
            m = ANON.search(read('/proc/%s/status' % d) or '')
            if m:
                a = int(m.group(1))
                if a > r['anon']: r['anon'] = a
    for key in [k for k in live if k not in seen]:
        r = live.pop(key); done_count += 1
        mf.write('%s\t%s\t%s\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%d\t%d\t%d\t%d\n' % (
            r['ph'], r['comm'], r['mod'], r['t0'], r['t1'], r['t1'] - r['t0'] + INTERVAL, r['ut'] / HZ, r['st'] / HZ,
            r['rss'] // 1048576, r['anon'] // 1024, r['thr'], r['n']))
    return lake

def meminfo():
    out = {}
    for line in (read('/proc/meminfo') or '').splitlines():
        k, _, v = line.partition(':')
        if k in ('MemAvailable', 'Cached', 'Dirty', 'AnonPages', 'Mapped', 'Shmem'):
            out[k] = int(v.split()[0]) // 1024
    return out

def disk_bytes():
    tot_w = tot_r = 0
    for line in (read('/proc/diskstats') or '').splitlines():
        p = line.split()
        if len(p) > 9 and WHOLE_DISK.match(p[2]):
            tot_r += int(p[5]); tot_w += int(p[9])
    return tot_r * 512, tot_w * 512

def main():
    mf = open(os.path.join(D, 'modules.tsv'), 'a', buffering=1)
    sf = open(os.path.join(D, 'system.tsv'), 'a', buffering=1)
    if mf.tell() == 0:
        mf.write('phase\tkind\tmodule\tt_start\tt_end\twall_s\tuser_s\tsys_s\tpeak_rss_mb\tpeak_anon_mb\tpeak_threads\tsamples\n')
    if sf.tell() == 0:
        sf.write('t\tphase\tcpu_user\tcpu_nice\tcpu_sys\tcpu_idle\tcpu_iowait\tload1\tmem_avail_mb\tcached_mb\tdirty_mb\tanon_mb\tfile_nr\t'
                 'disk_read_bytes\tdisk_written_bytes\tlake_user_s\tlake_sys_s\tlake_threads\tlake_rss_mb\tlive_procs\tfinished_total\n')
    last_sys = 0.0; tick = 0
    while True:
        now = time.time(); tick += 1
        try:
            lake = scan(now, mf, tick)
        except Exception as e:      # never let the sampler die
            sys.stderr.write('scan error: %r\n' % (e,)); lake = None
        if now - last_sys >= SYS_EVERY:
            last_sys = now
            try:
                c = (read('/proc/stat') or 'cpu 0 0 0 0 0').splitlines()[0].split()
                m = meminfo(); dr, dw = disk_bytes()
                fn = (read('/proc/sys/fs/file-nr') or '0').split()[0]
                l1 = (read('/proc/loadavg') or '0').split()[0]
                lk = lake or (0, 0, 0, 0)
                sf.write('%.1f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%.1f\t%.1f\t%d\t%d\t%d\t%d\n' % (
                    now, phase(), c[1], c[2], c[3], c[4], c[5], l1, m.get('MemAvailable', 0), m.get('Cached', 0), m.get('Dirty', 0),
                    m.get('AnonPages', 0), fn, dr, dw, lk[0] / HZ, lk[1] / HZ, lk[2], lk[3] // 1048576, len(live), done_count))
            except Exception as e:
                sys.stderr.write('system sample error: %r\n' % (e,))
        time.sleep(max(0.0, INTERVAL - (time.time() - now)))

if __name__ == '__main__':
    main()
