#!/usr/bin/env python3
"""Build the app's loose Resources/ tree without actool / xcstringstool.

Stands in for what Xcode does with: Assets.xcassets, Localizable.xcstrings,
the sound/animation/JSON files, the Perl MediaRemote adapter + framework and
the six Lottie JSONs listed in the Xcode Resources phase.

Output (--out): a directory whose CONTENTS are copied into Atoll.app/Contents/Resources:
  <imageset-name>.<ext>[@2x]   loose images, found by NSImage(named:) and by the
                               Image(_:String) shim in local/shims/AtollAssets.swift
  AppIcon.icns, AppIconDev.icns, ...   (iconutil from the .appiconset PNGs)
  <lang>.lproj/Localizable.strings     (from Localizable.xcstrings)
  <lang>.lproj/InfoPlist.strings       (tr only; copied)
  *.mp3 *.m4a *.json  BluetoothHUDAnimations/*.mov  mediaremote-adapter.pl
  MediaRemoteAdapter.framework
  asset-conversion-report.txt  (what was converted / what cannot be supported)

Asset kinds that cannot be supported without actool are listed in the report.
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys

report = []


def note(msg):
    report.append(msg)
    print(msg)


def convert_imagesets(xcassets, out):
    for d in sorted(glob.glob(os.path.join(xcassets, '*.imageset'))):
        name = os.path.basename(d)[:-len('.imageset')]
        info = json.load(open(os.path.join(d, 'Contents.json')))
        wrote = 0
        for img in info.get('images', []):
            fn = img.get('filename')
            if not fn:
                continue
            if img.get('appearances'):
                note('  SKIP %s: appearance variant %s (dark/hc variants unsupported)' % (name, img['appearances']))
                continue
            ext = os.path.splitext(fn)[1].lower()
            scale = img.get('scale')
            suffix = {'2x': '@2x', '3x': '@3x'}.get(scale, '')
            if ext == '.svg' and suffix:
                continue  # vector: 1x copy is sufficient
            dst = os.path.join(out, name + suffix + ext)
            if os.path.exists(dst):
                continue
            shutil.copy2(os.path.join(d, fn), dst)
            wrote += 1
        props = info.get('properties', {})
        if wrote == 0:
            note('  EMPTY %s: imageset has no image files (Xcode would also render nothing)' % name)
        else:
            note('  image %-20s -> %d file(s)%s' % (name, wrote,
                 '  [template-rendering-intent=%s NOT preserved]' % props['template-rendering-intent']
                 if props.get('template-rendering-intent') else ''))


def png_size(path):
    o = subprocess.check_output(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path]).decode()
    w = int(o.split('pixelWidth:')[1].split()[0])
    h = int(o.split('pixelHeight:')[1].split()[0])
    return w, h


def convert_appicons(xcassets, out, tmp):
    for d in sorted(glob.glob(os.path.join(xcassets, '*.appiconset'))):
        name = os.path.basename(d)[:-len('.appiconset')]
        info = json.load(open(os.path.join(d, 'Contents.json')))
        iconset = os.path.join(tmp, name + '.iconset')
        os.makedirs(iconset, exist_ok=True)
        for img in info['images']:
            if img.get('idiom') != 'mac' or not img.get('filename'):
                continue
            base = int(img['size'].split('x')[0])
            scale = int(img['scale'][0])
            px = base * scale
            dst = os.path.join(iconset, 'icon_%dx%d%s.png' % (base, base, '@2x' if scale == 2 else ''))
            src = os.path.join(d, img['filename'])
            if png_size(src) != (px, px):
                subprocess.check_call(['sips', '-z', str(px), str(px), src, '--out', dst],
                                      stdout=subprocess.DEVNULL)
            else:
                shutil.copy2(src, dst)
        subprocess.check_call(['iconutil', '-c', 'icns', iconset, '-o', os.path.join(out, name + '.icns')])
        note('  appicon %-16s -> %s.icns (iconutil)' % (name, name))


def esc(s):
    return (s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t'))


def convert_strings(xcstrings, out):
    d = json.load(open(xcstrings, encoding='utf-8'))
    per_lang = {}
    skipped = 0
    for key, entry in d['strings'].items():
        if entry.get('shouldTranslate') is False:
            continue
        for lang, loc in entry.get('localizations', {}).items():
            su = loc.get('stringUnit')
            if not su or not su.get('value'):
                skipped += 1
                continue
            per_lang.setdefault(lang, {})[key] = su['value']
    for lang, kv in sorted(per_lang.items()):
        dd = os.path.join(out, lang + '.lproj')
        os.makedirs(dd, exist_ok=True)
        with open(os.path.join(dd, 'Localizable.strings'), 'w', encoding='utf-8') as f:
            for k in sorted(kv):
                f.write('"%s" = "%s";\n' % (esc(k), esc(kv[k])))
    note('  strings: %d languages from %s (%d empty/variation entries skipped); '
         'keys without a translation fall back to the key itself (= English source text)' %
         (len(per_lang), os.path.basename(xcstrings), skipped))


def copy_misc(repo, out):
    src = os.path.join(repo, 'Toplet')
    n = 0
    for pat in ('*.mp3', '*.m4a'):
        for f in glob.glob(os.path.join(src, pat)):
            shutil.copy2(f, out)
            n += 1
    shutil.copy2(os.path.join(src, 'managers/LLMUsage/pricing.json'), out)
    shutil.copytree(os.path.join(src, 'BluetoothHUDAnimations'), os.path.join(out, 'BluetoothHUDAnimations'))
    for f in glob.glob(os.path.join(repo, 'LottieAnimations', '*.json')):
        shutil.copy2(f, out)
        n += 1
    shutil.copy2(os.path.join(repo, 'mediaremote-adapter', 'mediaremote-adapter.pl'), out)
    # Xcode project: Frameworks/MediaRemoteAdapter.framework is in the *Resources* phase
    shutil.copytree(os.path.join(repo, 'Frameworks', 'MediaRemoteAdapter.framework'),
                    os.path.join(out, 'MediaRemoteAdapter.framework'), symlinks=True)
    tr = os.path.join(src, 'tr.lproj', 'InfoPlist.strings')
    os.makedirs(os.path.join(out, 'tr.lproj'), exist_ok=True)
    shutil.copy2(tr, os.path.join(out, 'tr.lproj', 'InfoPlist.strings'))
    note('  copied %d sound/animation files, pricing.json, BluetoothHUDAnimations/, mediaremote-adapter.pl, '
         'MediaRemoteAdapter.framework, tr.lproj/InfoPlist.strings' % n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    if os.path.isdir(a.out):
        shutil.rmtree(a.out)
    os.makedirs(a.out)
    tmp = os.path.join(a.out, '..', 'resources-tmp')
    tmp = os.path.normpath(tmp)
    os.makedirs(tmp, exist_ok=True)
    xc = os.path.join(a.repo, 'Toplet', 'Assets.xcassets')
    note('resources:')
    convert_imagesets(xc, a.out)
    convert_appicons(xc, a.out, tmp)
    cs = os.path.join(xc, 'AccentColor.colorset', 'Contents.json')
    colors = json.load(open(cs))['colors']
    if not any('color' in c for c in colors):
        note('  colorset AccentColor has no colour value (Xcode: system accent); nothing to convert. '
             'No other colorsets exist, and Color("...")/NSColor(named:) are never called.')
    convert_strings(os.path.join(a.repo, 'Toplet', 'Localizable.xcstrings'), a.out)
    copy_misc(a.repo, a.out)
    shutil.rmtree(tmp)
    with open(os.path.join(a.out, 'asset-conversion-report.txt'), 'w') as f:
        f.write('\n'.join(report) + '\n')


if __name__ == '__main__':
    main()
