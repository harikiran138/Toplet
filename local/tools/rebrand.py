#!/usr/bin/env python3
"""Rename the user-visible product name in a source tree: "Atoll" -> "Toplet".

Only text inside Swift string literals is changed (a small lexer tracks quotes, escapes, string
interpolation and multi-line literals), plus the String Catalog, InfoPlist.strings and the
Info.plist usage strings in the Xcode project. Comments, type names and the GPL copyright
headers are never touched.

Identifiers that existing data or other programs depend on stay as they are:
  com.ebullioscopic.Atoll.*   Keychain services, extension protocol, XPC/RPC names
  Ebullioscopic/Atoll         upstream URLs
  Atoll.<Name>                menu and window identifiers
  Application Support/Atoll   the support folder (agents board, usage archive)
  appendingPathComponent("Atoll"   same folder, built in code
  Atoll-\\(                    CoreAudio aggregate-device UIDs
Logging subsystems (the bare "com.ebullioscopic.Atoll" literal) move to the new bundle id.

    local/tools/rebrand.py <repo-root> [--dry-run]

Idempotent: a second run changes nothing.
"""
import json
import os
import re
import sys

OLD, NEW = 'Atoll', 'Toplet'
NEW_BUNDLE_ID = 'app.toplet.Toplet'
# Latin-only boundaries: \b would miss "Atoll" glued to Korean, Thai or Chinese text ("Atoll이"),
# while names such as AtollExtensionKit must stay whole.
WORD = re.compile(r'(?<![A-Za-z0-9_])Atoll(?![A-Za-z0-9_])')
# Matches that sit inside one of these spans are left alone.
PROTECTED = [
    re.compile(r'com\.[Ee]bullioscopic\.Atoll[\w.\-]*'),
    re.compile(r'Ebullioscopic/Atoll'),
    re.compile(r'\bAtoll\.[A-Za-z]\w*'),
    re.compile(r'Application Support/Atoll'),
    re.compile(r'appendingPathComponent\("Atoll"'),
    re.compile(r'Atoll-\\\('),
]
LOG_SUBSYSTEM = re.compile(r'"com\.[Ee]bullioscopic\.Atoll(\.dev)?"')


def protected_spans(text):
    spans = []
    for rx in PROTECTED:
        spans += [m.span() for m in rx.finditer(text)]
    return spans


def replace_words(text, allowed):
    """Replace Atoll->Toplet at positions where allowed(start) is true and not protected."""
    spans = protected_spans(text)
    out, last = [], 0
    for m in WORD.finditer(text):
        s = m.start()
        if not allowed(s) or any(a <= s < b for a, b in spans):
            continue
        out.append(text[last:s]); out.append(NEW); last = m.end()
    out.append(text[last:])
    return ''.join(out)


def string_mask(src):
    """Boolean per character: True when the character is literal text inside a Swift string."""
    mask = [False] * len(src)
    i, n = 0, len(src)
    stack = []  # 'code' frames inside interpolation carry a paren depth
    in_str = None  # None, '"' or '"""'
    depth = 0
    while i < n:
        c = src[i]
        if in_str is None:
            if src.startswith('//', i):
                j = src.find('\n', i); i = n if j < 0 else j
                continue
            if src.startswith('/*', i):
                j = src.find('*/', i + 2); i = n if j < 0 else j + 2
                continue
            if stack and c == '(':
                depth += 1
            elif stack and c == ')':
                if depth == 0:
                    in_str, depth = stack.pop()
                    i += 1
                    continue
                depth -= 1
            elif src.startswith('"""', i):
                in_str = '"""'; i += 3; continue
            elif c == '"':
                in_str = '"'; i += 1; continue
            i += 1
            continue
        # inside a string literal
        if c == '\\' and i + 1 < n:
            if src[i + 1] == '(':
                stack.append((in_str, depth)); in_str, depth = None, 0
                i += 2
                continue
            i += 2
            continue
        if src.startswith(in_str, i):
            i += len(in_str); in_str = None
            continue
        mask[i] = True
        i += 1
    return mask


def rebrand_swift(src):
    # Lines naming a pre-rename value (legacyBundleIdentifier, legacySyncFolderName, …) must keep
    # the old name, or the migrations that look for it can no longer find it.
    lines = src.split('\n')
    held = {i: l for i, l in enumerate(lines) if 'legacy' in l.lower()}
    out = _rebrand_swift(src).split('\n')
    if len(out) == len(lines):
        for i, l in held.items():
            out[i] = l
    return '\n'.join(out)


def _rebrand_swift(src):
    src = LOG_SUBSYSTEM.sub(lambda m: '"%s%s"' % (NEW_BUNDLE_ID, m.group(1) or ''), src)
    src = src.replace("subsystem == 'com.Ebullioscopic.Atoll' OR subsystem == 'com.Ebullioscopic.Atoll.dev'",
                      "subsystem == '%s' OR subsystem == '%s.dev'" % (NEW_BUNDLE_ID, NEW_BUNDLE_ID))
    mask = string_mask(src)
    return replace_words(src, lambda s: mask[s])


def rebrand_catalog(path):
    data = json.load(open(path, encoding='utf-8'))
    strings = data.get('strings', {})
    renamed = {}
    for key, entry in strings.items():
        new_key = replace_words(key, lambda s: True)
        text = json.dumps(entry, ensure_ascii=False)
        new_entry = json.loads(replace_words(text, lambda s: True))
        # A key already renamed on an earlier run wins over a stale duplicate.
        if new_key in renamed and new_key != key:
            continue
        renamed[new_key] = new_entry
    data['strings'] = renamed
    return json.dumps(data, ensure_ascii=False, indent=2, separators=(',', ' : ')) + '\n'


def rebrand_pbxproj(src):
    def fix(m):
        return replace_words(m.group(0), lambda s: True)
    return re.sub(r'INFOPLIST_KEY_\w+ = "[^"\n]*";', fix, src)


def main():
    root = sys.argv[1]
    dry = '--dry-run' in sys.argv
    changed = []
    for base in ('Toplet', 'AtollAgents', 'AtollNotch'):
        top = os.path.join(root, base)
        if not os.path.isdir(top):
            continue
        for dirpath, _, files in os.walk(top):
            for fn in files:
                p = os.path.join(dirpath, fn)
                if fn.endswith('.swift'):
                    old = open(p, encoding='utf-8').read(); new = rebrand_swift(old)
                elif fn == 'Localizable.xcstrings':
                    old = open(p, encoding='utf-8').read(); new = rebrand_catalog(p)
                    if json.loads(old) == json.loads(new):
                        new = old
                elif fn in ('InfoPlist.strings', 'Info.plist'):
                    old = open(p, encoding='utf-8').read(); new = replace_words(old, lambda s: True)
                else:
                    continue
                if new != old:
                    changed.append((p, sum(1 for _ in WORD.finditer(old)) - sum(1 for _ in WORD.finditer(new))))
                    if not dry:
                        open(p, 'w', encoding='utf-8').write(new)
    pbx = os.path.join(root, 'Toplet.xcodeproj', 'project.pbxproj')
    if os.path.exists(pbx):
        old = open(pbx, encoding='utf-8').read(); new = rebrand_pbxproj(old)
        if new != old:
            changed.append((pbx, 0))
            if not dry:
                open(pbx, 'w', encoding='utf-8').write(new)
    for p, n in changed:
        print('%s%s  (%d)' % ('would change ' if dry else 'changed ', os.path.relpath(p, root), n))
    print('%d files' % len(changed))


if __name__ == '__main__':
    main()
