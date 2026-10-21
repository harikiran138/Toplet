#!/usr/bin/env python3
"""Mechanical Swift source transformations used by local/prepare.py.

Only ever applied to COPIES under local/.work/. Never run against the repo's
own Toplet/ sources.

1. strip_previews(text): remove `#Preview ... { ... }` macro blocks.
   Reason: PreviewsMacros (the compiler plugin behind #Preview) ships only with
   full Xcode. Replaced by blank lines so line numbers in diagnostics stay valid.
2. rename_state(text): `@State` -> `@AtollState`, `State(initialValue:)` /
   `State(wrappedValue:)` -> `AtollState(...)`.
   Reason: on SDK 27, `State` is also a compiler macro (SwiftUIMacros.StateMacro,
   plugin only in full Xcode) and the macro wins attribute lookup even over a
   local type of the same name. `AtollState` is a typealias to the real
   `SwiftUI.State<Value>` struct (see local/shims/AtollState.swift), so runtime
   semantics are exactly SwiftUI's own State, just without the macro expansion.
"""
import re
import sys


def _skip_string(src, i):
    """src[i] is the first char of a string literal start (either `"` or `#`*`"`).
    Return index just past the literal. Handles raw (#"..."#), multi-line
    (\"\"\"), and \\( ) interpolation (nested)."""
    n = len(src)
    hashes = 0
    j = i
    while j < n and src[j] == '#':
        hashes += 1
        j += 1
    assert src[j] == '"'
    multiline = src.startswith('"""', j)
    j += 3 if multiline else 1
    close = ('"""' if multiline else '"') + '#' * hashes
    esc = '\\' + '#' * hashes
    while j < n:
        if src.startswith(esc + '(', j):
            j = _skip_balanced(src, j + len(esc), '(', ')')
            continue
        if src[j] == '\\' and hashes == 0:
            j += 2
            continue
        if src.startswith(close, j):
            return j + len(close)
        j += 1
    raise ValueError('unterminated string literal')


def _skip_balanced(src, i, open_c, close_c):
    """src[i] == open_c. Return index just past the matching close_c, skipping
    strings and comments."""
    n = len(src)
    assert src[i] == open_c, (src[i:i + 20], open_c)
    depth = 0
    j = i
    while j < n:
        c = src[j]
        if c == '/' and src.startswith('//', j):
            k = src.find('\n', j)
            j = n if k < 0 else k
            continue
        if c == '/' and src.startswith('/*', j):
            # nested block comments
            d = 1
            j += 2
            while j < n and d:
                if src.startswith('/*', j):
                    d += 1
                    j += 2
                elif src.startswith('*/', j):
                    d -= 1
                    j += 2
                else:
                    j += 1
            continue
        if c == '"' or (c == '#' and re.match(r'#+"', src[j:j + 40] or '')):
            j = _skip_string(src, j)
            continue
        if c == open_c:
            depth += 1
        elif c == close_c:
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    raise ValueError('unbalanced ' + open_c)


PREVIEW_RE = re.compile(r'^[ \t]*#Preview\b', re.M)


def strip_previews(text):
    out = []
    pos = 0
    count = 0
    while True:
        m = PREVIEW_RE.search(text, pos)
        if not m:
            out.append(text[pos:])
            break
        out.append(text[pos:m.start()])
        i = m.end()
        # optional argument list
        k = i
        while k < len(text) and text[k] in ' \t':
            k += 1
        if k < len(text) and text[k] == '(':
            i = _skip_balanced(text, k, '(', ')')
        # trailing closure
        k = i
        while k < len(text) and text[k] in ' \t\r\n':
            k += 1
        if k >= len(text) or text[k] != '{':
            raise ValueError('#Preview without trailing closure near offset %d' % m.start())
        end = _skip_balanced(text, k, '{', '}')
        removed = text[m.start():end]
        out.append('// [local-build] #Preview removed (PreviewsMacros needs full Xcode)\n' +
                   '\n' * removed.count('\n'))
        # swallow one trailing newline of the original block end if present
        pos = end
        if text.startswith('\n', pos):
            pos += 1
        count += 1
    return ''.join(out), count


STATE_ATTR_RE = re.compile(r'@State\b(?!Object)')
STATE_CTOR_RE = re.compile(r'(?<![\w.@])State(?=\((?:initialValue|wrappedValue):)')


def rename_state(text):
    n1 = len(STATE_ATTR_RE.findall(text))
    text = STATE_ATTR_RE.sub('@AtollState', text)
    n2 = len(STATE_CTOR_RE.findall(text))
    text = STATE_CTOR_RE.sub('AtollState', text)
    return text, n1, n2


if __name__ == '__main__':
    src = open(sys.argv[1], encoding='utf-8').read()
    t, c = strip_previews(src)
    t, a, b = rename_state(t)
    sys.stdout.write('previews=%d state_attr=%d state_ctor=%d\n' % (c, a, b))
