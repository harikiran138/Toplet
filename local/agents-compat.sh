#!/bin/bash
# Run right AFTER `local/sync-agents.sh <this repo>`: renames the few agent-module symbols that collide with names
# already used by Atoll itself, in the synced copies only (the standalone AtollAgents/ sources are not touched).
#   UsageSnapshot  (agents' cost/context snapshot)  ->  AgentUsageSnapshot   (Atoll has managers/LLMUsage UsageSnapshot)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
files=$(grep -rlw "UsageSnapshot" "$ROOT/Toplet/managers/Agents" "$ROOT/Toplet/components/Notch/Agents" 2>/dev/null || true)
if [ -z "$files" ]; then echo "agents-compat: no UsageSnapshot to rename"; else
  for f in $files; do perl -pi -e 's/\bUsageSnapshot\b/AgentUsageSnapshot/g' "$f"; done
  echo "agents-compat: UsageSnapshot -> AgentUsageSnapshot in $(echo "$files" | wc -l | tr -d ' ') files"
fi

# The UI module ships a fixture-driven stand-in for "finished since you last looked" (AgentsComponents.swift: `uiFinishedUnseen`),
# with the note "INTEGRATION: replace the body with `hasUnseenCompletion`". Core now provides it, so wire the real value.
UI="$ROOT/Toplet/components/Notch/Agents/AgentsComponents.swift"
if grep -q 'AgentsUnseenFixture.ids.contains(id)' "$UI"; then
  perl -pi -e 's/var uiFinishedUnseen: Bool \{ AgentsUnseenFixture\.ids\.contains\(id\) \}/var uiFinishedUnseen: Bool { hasUnseenCompletion }/' "$UI"
  grep -q 'var uiFinishedUnseen: Bool { hasUnseenCompletion }' "$UI" && echo "agents-compat: uiFinishedUnseen -> hasUnseenCompletion" || { echo "agents-compat: FAILED to rewire uiFinishedUnseen" >&2; exit 1; }
fi
