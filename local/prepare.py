#!/usr/bin/env python3
"""Generate the build copy under local/.work/ (git-ignored).

Never modifies Toplet/ or any other tracked file. Steps:

  1. copy Toplet/**/*.swift  -> .work/Sources/Atoll/   (+ transforms)
  2. copy audio/*.mm,*.cpp,*.hpp,*.h -> .work/Sources/CAtollAudio/ (C++ target)
  3. bridging header                -> .work/Bridging/
  4. patches in local/patches/*.patch are applied to the Atoll copy (patch -p1)
  5. vendor patched copies of Defaults/KeyboardShortcuts/SkyLightWindow/SwiftTerm
     at their exact pinned revisions (from the SwiftPM cache if present, else
     from GitHub) -> .work/vendor/
  6. assets/resources/strings        -> .work/resources/  (tools/make_resources.py)
  7. Package.swift                   -> .work/Package.swift (+ Package.resolved)

Usage: local/prepare.py            (idempotent; wipes .work/ except .build)
"""
import glob
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
WORK = os.path.join(HERE, '.work')
SRC = os.path.join(REPO, 'Toplet')
sys.path.insert(0, os.path.join(HERE, 'tools'))
import swiftxform  # noqa: E402

LOG = []


def log(msg):
    print(msg, flush=True)
    LOG.append(msg)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def sdk_path():
    return subprocess.check_output(['xcrun', '--show-sdk-path']).decode().strip()


def transform_tree(root, stats, shim_name):
    """Apply strip_previews + rename_state to every .swift file under root;
    if any @State was renamed in a module dir, drop the shim next to it."""
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if not fn.endswith('.swift'):
                continue
            p = os.path.join(dirpath, fn)
            with open(p, encoding='utf-8') as f:
                t = f.read()
            t2, nprev = swiftxform.strip_previews(t)
            t2, n_attr, n_ctor = swiftxform.rename_state(t2)
            if t2 != t:
                with open(p, 'w', encoding='utf-8') as f:
                    f.write(t2)
            stats['previews'] += nprev
            stats['state_attr'] += n_attr
            stats['state_ctor'] += n_ctor
            stats['files_changed'] += int(t2 != t)


def copy_atoll_sources():
    dst = os.path.join(WORK, 'Sources', 'Atoll')
    n = 0
    for dirpath, dirs, files in os.walk(SRC):
        rel = os.path.relpath(dirpath, SRC)
        if rel.split(os.sep)[0] in ('Preview Content',):
            dirs[:] = []
            continue
        for fn in files:
            if fn.endswith('.swift'):
                out = os.path.join(dst, rel, fn) if rel != '.' else os.path.join(dst, fn)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                shutil.copy2(os.path.join(dirpath, fn), out)
                n += 1
    # Idle animation engine: the pure core and the SwiftUI presets live under AtollNotch/ (compiled standalone by
    # AtollNotch/Tests/run_idle.sh) and are copied into the app module here. Narrow on purpose: other AtollNotch files
    # are wired by the integrator.
    notch = os.path.join(REPO, 'AtollNotch')
    # local/sync-notch.sh puts these files inside Toplet/ (so Xcode builds them too); they were
    # copied with the rest of the app above, and copying them again would define every type twice.
    if os.path.isdir(os.path.join(SRC, 'AtollNotchIdle')):
        notch = None
    for sub, prefix in ((('Core', 'IdleAnimation'), ('UI', 'Idle')) if notch else ()):
        d = os.path.join(notch, sub)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if fn.startswith(prefix) and fn.endswith('.swift'):
                out = os.path.join(dst, 'AtollNotchIdle', fn)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                shutil.copy2(os.path.join(d, fn), out)
                n += 1
    log('copied %d Swift files into Sources/Atoll' % n)
    return dst


def copy_audio():
    dst = os.path.join(WORK, 'Sources', 'CAtollAudio')
    os.makedirs(os.path.join(dst, 'include'), exist_ok=True)
    a = os.path.join(SRC, 'audio')
    shutil.copy2(os.path.join(a, 'AudioBridge.h'), os.path.join(dst, 'include', 'AudioBridge.h'))
    for fn in ('AudioBridge.mm', 'AudioProcessor.cpp', 'AudioProcessor.hpp'):
        shutil.copy2(os.path.join(a, fn), os.path.join(dst, fn))
    # Bridging header: same content as the Xcode one, but "audio/AudioBridge.h"
    # is now include/AudioBridge.h.
    os.makedirs(os.path.join(WORK, 'Bridging'), exist_ok=True)
    with open(os.path.join(SRC, 'Toplet-Bridging-Header.h'), encoding='utf-8') as f:
        h = f.read()
    assert '#import "audio/AudioBridge.h"' in h
    h = h.replace('#import "audio/AudioBridge.h"', '#import "AudioBridge.h"')
    with open(os.path.join(WORK, 'Bridging', 'Toplet-Bridging-Header.h'), 'w', encoding='utf-8') as f:
        f.write(h)
    log('audio ObjC++/C++ target + bridging header written')


def rewrite_asset_symbols(atoll):
    """Xcode generates ImageResource symbols (`Image(.github)`) from the asset
    catalog. Without actool those do not exist, and ImageResource would not load
    loose files anyway; rewrite each use to the name-based form handled by
    shims/AtollAssets.swift."""
    import re
    names = {}
    for d in glob.glob(os.path.join(SRC, 'Assets.xcassets', '*.imageset')):
        n = os.path.basename(d)[:-len('.imageset')]
        names[n[0].lower() + n[1:]] = n
    pat = re.compile(r'\bImage\(\.([A-Za-z_][A-Za-z0-9_]*)\)')
    hits = 0
    for dirpath, _, files in os.walk(atoll):
        for fn in files:
            if not fn.endswith('.swift'):
                continue
            p = os.path.join(dirpath, fn)
            t = open(p, encoding='utf-8').read()

            def sub(m):
                nonlocal_hits[0] += 1
                sym = m.group(1)
                if sym not in names:
                    sys.exit('asset symbol .%s not found in Assets.xcassets (%s)' % (sym, p))
                return 'Image("%s")' % names[sym]
            nonlocal_hits = [0]
            t2 = pat.sub(sub, t)
            if t2 != t:
                open(p, 'w', encoding='utf-8').write(t2)
                hits += nonlocal_hits[0]
    log('asset-symbol uses rewritten: %d' % hits)


def apply_patches(target_dir, pattern):
    for p in sorted(glob.glob(os.path.join(HERE, 'patches', pattern))):
        r = subprocess.run(['patch', '-p1', '--no-backup-if-mismatch', '-d', target_dir, '-i', p],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = r.stdout.decode()
        if r.returncode != 0:
            print(out)
            sys.exit('patch failed: ' + p)
        log('applied patch %s' % os.path.basename(p))


PINS = {
    # name: (git url, cache dir prefix, revision)
    'Defaults': ('https://github.com/sindresorhus/Defaults', 'Defaults-', '00c82eff4550c87cf9c547d7e5493a6a97837061'),
    'KeyboardShortcuts': ('https://github.com/sindresorhus/KeyboardShortcuts', 'KeyboardShortcuts-', '045cf174010beb335fa1d2567d18c057b8787165'),
    'SkyLightWindow': ('https://github.com/Lakr233/SkyLightWindow', 'SkyLightWindow-', '4a7e8628c85e6b2ec429b57657a556a2171a4864'),
    'SwiftTerm': ('https://github.com/migueldeicaza/SwiftTerm', 'SwiftTerm-', '8e7a1e154f470e19c709a00a8768df348ba5fc43'),
}


def vendor():
    cache_root = os.path.expanduser('~/Library/Caches/org.swift.swiftpm/repositories')
    stats_all = {}
    for name, (url, prefix, rev) in PINS.items():
        d = os.path.join(WORK, 'vendor', name)
        src = url
        for c in glob.glob(os.path.join(cache_root, prefix + '*')):
            if subprocess.run(['git', '--git-dir', c, 'cat-file', '-e', rev + '^{commit}'],
                              stderr=subprocess.DEVNULL).returncode == 0:
                src = c
                break
        run(['git', 'clone', '-q', '--no-checkout', src, d])
        run(['git', '-C', d, 'checkout', '-q', rev])
        shutil.rmtree(os.path.join(d, '.git'))
        # replacement manifest, if we ship one
        man = os.path.join(HERE, 'package', 'vendor', name, 'Package.swift')
        if os.path.exists(man):
            shutil.copy2(man, os.path.join(d, 'Package.swift'))
        stats = dict(previews=0, state_attr=0, state_ctor=0, files_changed=0)
        sources = os.path.join(d, 'Sources', name)
        transform_tree(sources, stats, 'AtollState')
        if stats['state_attr'] or stats['state_ctor']:
            shutil.copy2(os.path.join(HERE, 'shims', 'AtollState.swift'),
                         os.path.join(sources, 'AtollState.swift'))
        apply_patches(d, 'vendor-%s-*.patch' % name)
        stats_all[name] = stats
        log('vendor %-18s @%s from %s: %s' % (name, rev[:8], 'cache' if src != url else 'GitHub', stats))
    return stats_all


def write_package():
    sdk = sdk_path()
    with open(os.path.join(HERE, 'package', 'Package.swift.in'), encoding='utf-8') as f:
        t = f.read()
    t = t.replace('@WORK@', WORK).replace('@SDKROOT@', sdk)
    with open(os.path.join(WORK, 'Package.swift'), 'w', encoding='utf-8') as f:
        f.write(t)
    # Keep branch-pinned transitive deps (lottie-spm `main`) on the exact revision
    # recorded by the Xcode project.
    with open(os.path.join(REPO, 'Toplet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')) as f:
        resolved = json.load(f)
    keep = {'swift-collections', 'launchatlogin-modern', 'lottieui', 'lottie-spm', 'macrovisionkit',
            'sparkle', 'swiftui-introspect', 'atollextensionkit'}
    resolved['pins'] = [p for p in resolved['pins'] if p['identity'] in keep]
    with open(os.path.join(WORK, 'Package.resolved'), 'w') as f:
        json.dump(resolved, f, indent=2)
    log('Package.swift + Package.resolved written (SDK %s)' % sdk)


def main():
    if os.path.isdir(WORK):
        for entry in os.listdir(WORK):
            if entry == '.build':
                continue
            p = os.path.join(WORK, entry)
            shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    os.makedirs(WORK, exist_ok=True)

    atoll = copy_atoll_sources()
    copy_audio()
    apply_patches(atoll, 'atoll-*.patch')           # patches written against the ORIGINAL sources
    stats = dict(previews=0, state_attr=0, state_ctor=0, files_changed=0)
    transform_tree(atoll, stats, 'AtollState')
    shutil.copy2(os.path.join(HERE, 'shims', 'AtollState.swift'), os.path.join(atoll, 'AtollState.swift'))
    shutil.copy2(os.path.join(HERE, 'shims', 'AtollAssets.swift'), os.path.join(atoll, 'AtollAssets.swift'))
    rewrite_asset_symbols(atoll)
    log('Atoll sources transformed: %s' % stats)
    vendor()
    write_package()
    # Resources / assets step (optional until implemented)
    rp = os.path.join(HERE, 'tools', 'make_resources.py')
    if os.path.exists(rp):
        run([sys.executable, rp, '--repo', REPO, '--out', os.path.join(WORK, 'resources')])
    with open(os.path.join(WORK, 'prepare.log'), 'w') as f:
        f.write('\n'.join(LOG) + '\n')
    log('prepare done: %s' % WORK)


if __name__ == '__main__':
    main()
