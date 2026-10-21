#!/usr/bin/env python3
"""Sync canonical Agents sources to the integrated AI checkout, preserving integration glue."""
from pathlib import Path
import shutil
import sys
source = Path(__file__).resolve().parents[1]
target = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else source.parent / 'Atoll-ai'
if not (target / 'Toplet/managers/AgentsIntegration.swift').exists():
    raise SystemExit('Target must have the existing Agents integration; refusing to create an incomplete app.')
for file in (source / 'AtollAgents').rglob('*'):
    if file.is_file():
        out = target / 'AtollAgents' / file.relative_to(source / 'AtollAgents')
        out.parent.mkdir(parents=True, exist_ok=True)
        if not out.exists() or out.read_bytes() != file.read_bytes():
            shutil.copy2(file, out)
for folder, dest in [('Core', 'managers/Agents'), ('Hooks', 'managers/Agents'), ('UI', 'components/Notch/Agents')]:
    for file in (source / 'AtollAgents' / folder).glob('*.swift'):
        text = file.read_text().replace('UsageSnapshot', 'AgentUsageSnapshot')
        if file.name == 'AgentsComponents.swift':
            text = text.replace('var uiFinishedUnseen: Bool { AgentsUnseenFixture.ids.contains(id) }', 'var uiFinishedUnseen: Bool { hasUnseenCompletion }')
        out = target / 'Toplet' / dest / file.name
        if not out.exists() or out.read_text() != text:
            out.write_text(text)
print('Synced Agents dashboard sources to', target)
