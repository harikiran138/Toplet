#!/bin/bash
# Launch a built app, watch it for N seconds (default 40), report, then quit it and make sure
# OSDUIHelper (which Toplet SIGSTOPs while its HUD replacement is active) is not left stopped.
# Does not click anything, does not touch TCC.   local/smoke.sh [path-to-app] [seconds]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$HERE/../dist/Toplet.app}"; SECS="${2:-40}"
fix_osd() { for p in $(pgrep -x OSDUIHelper); do s=$(ps -o state= -p "$p"); case "$s" in T*) kill -CONT "$p"; echo "OSDUIHelper $p was stopped -> SIGCONT";; esac; done; }
fix_osd
before=$(ls ~/Library/Logs/DiagnosticReports | wc -l)
open "$APP"; sleep 8
PID=$(pgrep -x Toplet || true); [ -n "$PID" ] || { echo "FAIL: not running after 8s"; exit 1; }
sleep $((SECS-8))
if kill -0 "$PID" 2>/dev/null; then echo "alive after ${SECS}s: pid $PID $(ps -o rss=,pcpu= -p $PID) (rss KB, %cpu)"; else echo "FAIL: died"; fi
after=$(ls ~/Library/Logs/DiagnosticReports | wc -l); echo "new crash reports: $((after-before))"
echo "OSDUIHelper states: $(for p in $(pgrep -x OSDUIHelper); do ps -o state= -p $p; done | tr '\n' ' ')"
osascript -e 'tell application id "app.toplet.Toplet" to quit' >/dev/null 2>&1; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Toplet >/dev/null || break; sleep 1; done
pgrep -x Toplet >/dev/null && { kill "$(pgrep -x Toplet)"; echo "had to kill"; } || echo "quit cleanly"
fix_osd
echo "OSDUIHelper states after quit: $(for p in $(pgrep -x OSDUIHelper); do ps -o state= -p $p; done | tr '\n' ' ')"
