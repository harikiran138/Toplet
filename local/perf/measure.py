#!/usr/bin/env python3
"""Measure an Atoll build's idle cost without Xcode/Instruments.

  python3 local/perf/measure.py APP_PATH [--seconds 120] [--warmup 20] [--label NAME] [--json OUT.json]

Launches a fresh instance (`open -n`, so it never touches an Atoll you are already running when the build uses a different
bundle id), waits for warm-up, then samples with `top` every 2 s. Reports CPU mean / p95 / max, idle wake-ups per second,
resident memory start/end/growth, thread count, child processes (count + CPU), and quits the instance afterwards, making
sure OSDUIHelper is not left stopped. Reads only process statistics; clicks nothing, touches no permissions.
"""
import argparse, json, os, re, signal, subprocess, sys, time, statistics

def sh(*a, **k): return subprocess.run(a, capture_output=True, text=True, **k).stdout

def pid_of(app):
    exe = os.path.join(app, 'Contents', 'MacOS')
    for line in sh('ps', '-axo', 'pid,command').splitlines()[1:]:
        pid, _, cmd = line.strip().partition(' ')
        if cmd.startswith(exe + '/'): return int(pid)
    return None

def resume_osd():
    for line in sh('ps', '-axo', 'pid,stat,comm').splitlines()[1:]:
        p = line.split()
        if len(p) >= 3 and p[2].endswith('OSDUIHelper') and p[1].startswith('T'):
            os.kill(int(p[0]), signal.SIGCONT)

def children(pid):
    out = []
    for line in sh('ps', '-axo', 'pid,ppid,pcpu,rss,comm').splitlines()[1:]:
        p = line.split(None, 4)
        if len(p) == 5 and int(p[1]) == pid: out.append(p)
    return out

def mem_kb(s):  # '125M', '7473K', '1G', with trailing +/-
    m = re.match(r'([\d.]+)([KMGB])', s)
    if not m: return None
    return float(m[1]) * {'K': 1, 'M': 1024, 'G': 1024 * 1024, 'B': 1 / 1024}[m[2]]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('app'); ap.add_argument('--seconds', type=int, default=120); ap.add_argument('--warmup', type=int, default=20)
    ap.add_argument('--label', default=''); ap.add_argument('--json')
    a = ap.parse_args()
    app = os.path.abspath(a.app)
    if pid_of(app): sys.exit('an instance of this exact app path is already running; quit it first')
    resume_osd()
    subprocess.run(['open', '-n', app], check=True)
    pid = None
    for _ in range(30):
        pid = pid_of(app)
        if pid: break
        time.sleep(1)
    if not pid: sys.exit('app did not start')
    try:
        time.sleep(a.warmup)
        n = max(2, a.seconds // 2)
        top = sh('top', '-pid', str(pid), '-l', str(n + 1), '-s', '2', '-stats', 'pid,cpu,mem,threads,idlew')
        rows = [l.split() for l in top.splitlines() if re.match(r'^\s*%d\s' % pid, l)][1:]  # first sample is since-launch, drop it
        cpu = [float(r[1]) for r in rows]
        mem = [mem_kb(r[2]) for r in rows]
        thr = [int(r[3].split('/')[0].rstrip('+-')) for r in rows]
        wake = [int(r[4].rstrip('+-')) for r in rows]
        dur = 2 * (len(rows) - 1)
        kids = children(pid)
        res = {
            'label': a.label, 'app': app, 'seconds': a.seconds, 'samples': len(rows),
            'cpu_mean': round(statistics.mean(cpu), 2), 'cpu_p95': round(sorted(cpu)[int(len(cpu) * .95) - 1], 2), 'cpu_max': max(cpu),
            'wakeups_per_s': round((wake[-1] - wake[0]) / dur, 1) if dur else None,
            'rss_mb_start': round(mem[0] / 1024, 1), 'rss_mb_end': round(mem[-1] / 1024, 1), 'rss_mb_growth': round((mem[-1] - mem[0]) / 1024, 1),
            'threads_max': max(thr), 'child_processes': len(kids),
            'child_cpu_sum': round(sum(float(k[2]) for k in kids), 1), 'children': [k[4].split('/')[-1] for k in kids],
            'footprint': (re.findall(r'phys_footprint: ([\d.]+ \w+)', sh('footprint', '-p', str(pid))) or ['?'])[0],
        }
        print(json.dumps(res, indent=1))
        if a.json: json.dump(res, open(a.json, 'w'), indent=1)
    finally:
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
        for _ in range(10):
            if not pid_of(app): break
            time.sleep(1)
        if pid_of(app): os.kill(pid_of(app), signal.SIGKILL)
        time.sleep(1); resume_osd()

main()
