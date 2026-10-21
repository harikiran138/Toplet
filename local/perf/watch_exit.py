#!/usr/bin/env python3
"""Record *why* a running Atoll disappears.

  python3 local/perf/watch_exit.py [APP_EXE_SUBSTRING] [--out docs/logs]

Polls once a second for a process whose command contains APP_EXE_SUBSTRING (default '/Atoll.app/Contents/MacOS/Atoll').
Every 15 s it logs system memory/swap/disk state. When the process vanishes it writes a report with: the time, the state
trend before the exit, system-wide memory pressure and swap, the top memory consumers, any new crash report for the app,
and the unified-log lines about the app/pid in the 90 s around the exit (kernel jetsam/memorystatus, launchd, runningboardd).
Read-only: sends no signals, touches nothing.
"""
import subprocess, sys, time, os, datetime, re
sub = '/Atoll.app/Contents/MacOS/Atoll'; out = 'docs/logs'
args = sys.argv[1:]
if args and not args[0].startswith('--'): sub = args.pop(0)
if '--out' in args: out = args[args.index('--out') + 1]
os.makedirs(out, exist_ok=True)
def sh(*a): return subprocess.run(a, capture_output=True, text=True).stdout
def find():
    for l in sh('ps', '-axo', 'pid,etime,command').splitlines()[1:]:
        p = l.strip().split(None, 2)
        if len(p) == 3 and sub in p[2] and 'watch_exit' not in p[2]: return int(p[0])
def state():
    sw = sh('sysctl', '-n', 'vm.swapusage').strip()
    mp = re.search(r'free percentage: (\d+)%', sh('memory_pressure'))
    df = sh('df', '-h', os.path.expanduser('~')).splitlines()[-1].split()[3]
    return f"swap[{sw}] sysfree={mp[1] + '%' if mp else '?'} diskfree={df}"
reports0 = set(os.listdir(os.path.expanduser('~/Library/Logs/DiagnosticReports')))
pid = None
while pid is None: pid = find() or (time.sleep(2) or None)
start = datetime.datetime.now(); trail = []; last = 0
print(f"watching pid {pid}", flush=True)
def alive(pid):
    # Ask about THIS pid only (a one-off empty/failed process listing must never be read as an exit).
    try: os.kill(pid, 0)
    except ProcessLookupError: return False
    except PermissionError: return True
    return True
misses = 0
while True:
    misses = 0 if alive(pid) else misses + 1
    if misses >= 3: break        # gone for 3 consecutive 1 s checks
    if time.time() - last > 15:
        last = time.time(); rss = sh('ps', '-o', 'rss=', '-p', str(pid)).strip()
        trail.append(f"{datetime.datetime.now():%H:%M:%S} rss={int(rss or 0)//1024}MB {state()}")
        trail = trail[-60:]
    time.sleep(1)
end = datetime.datetime.now(); fn = os.path.join(out, f"atoll-exit-{end:%Y%m%d-%H%M%S}.txt")
new = sorted(set(os.listdir(os.path.expanduser('~/Library/Logs/DiagnosticReports'))) - reports0)
lines = [f"Atoll pid {pid} disappeared at {end:%H:%M:%S} after {end - start}", "", "== state trend (every 15 s, last 15 min)"] + trail[-60:]
lines += ["", "== system now", state(), sh('memory_pressure').split('\n\n')[0][:600], "", "== top memory consumers"]
lines += sh('ps', '-axo', 'rss,pcpu,comm', '-m').splitlines()[:9]
lines += ["", f"== new crash/diagnostic reports: {new or 'none'}", "", "== unified log 90 s around the exit"]
t0 = (end - datetime.timedelta(seconds=75)).strftime('%Y-%m-%d %H:%M:%S'); t1 = (end + datetime.timedelta(seconds=15)).strftime('%Y-%m-%d %H:%M:%S')
pred = f'eventMessage CONTAINS "Atoll" OR eventMessage CONTAINS "pid={pid}" OR eventMessage CONTAINS "[{pid}]" OR eventMessage CONTAINS " {pid} " OR process == "appleeventsd" OR (process == "kernel" AND (eventMessage CONTAINS "memorystatus" OR eventMessage CONTAINS "jetsam" OR eventMessage CONTAINS "killing"))'
lines += sh('/usr/bin/log', 'show', '--start', t0, '--end', t1, '--style', 'compact', '--predicate', pred).splitlines()[:200]
open(fn, 'w').write('\n'.join(lines)); print('wrote', fn, flush=True)
