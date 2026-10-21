#!/usr/bin/env python3
"""Assemble dist/Toplet.app from a `swift build` product + local/.work/resources.

Mirrors what Toplet.xcodeproj produces (see project.pbxproj):
  Contents/MacOS/Toplet                     product executable (SwiftPM product "Atoll", renamed)
  Contents/Info.plist                       Toplet/Info.plist + INFOPLIST_KEY_* + standard keys
  Contents/Resources/**                     local/.work/resources (assets, strings, sounds, Lottie JSON,
                                            mediaremote-adapter.pl, MediaRemoteAdapter.framework)
  Contents/Frameworks/Sparkle.framework     SwiftPM binary artifact (embedded, as Xcode does)
  Contents/Frameworks/Lottie.framework      same (lottie-spm binary artifact is a dynamic framework)
  Contents/Helpers/NowPlayingTestClient     Copy-Files phase "CopyFiles" (dstPath Contents/Helpers)
  Contents/Resources/*.bundle               SwiftPM resource bundles of the vendored packages
                                            (Defaults, KeyboardShortcuts, SwiftTerm)

Local-first changes vs. upstream (all via build-copy Info.plist / entitlements, no source change):
  * SUEnableAutomaticChecks=false, SUAutomaticallyUpdate=false: Sparkle never contacts the feed on its own.
  * entitlements: com.apple.security.mach-services removed (not holdable by an ad-hoc signature).
  * signed ad hoc (identity "-"), inside-out, hardened runtime on.

Usage: local/assemble.py [--config debug|release] [--identity -] [--no-hardened-runtime]
"""
import argparse
import os
import plistlib
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
WORK = os.path.join(HERE, '.work')
DIST = os.path.join(REPO, 'dist')

APP_NAME = 'Toplet'
BUNDLE_ID = os.environ.get('ATOLL_BUNDLE_ID', 'app.toplet.Toplet')   # Release value of PRODUCT_BUNDLE_IDENTIFIER (kept); override only for side-by-side perf test builds
VERSION = open(os.path.join(REPO, 'VERSION')).read().strip() if os.path.exists(os.path.join(REPO, 'VERSION')) else '2.3.3'
BUILD = '1637'                          # CURRENT_PROJECT_VERSION


def sh(*cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


LOCAL_IDENTITY = 'Toplet Local Signing'


def signing_identity():
    """A stable identity keeps macOS permissions across rebuilds; ad hoc changes with every build.
    Create the local one once with local/make-signing-identity.sh."""
    env = os.environ.get('TOPLET_SIGN_IDENTITY')
    if env:
        return env
    try:
        out = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                             capture_output=True, text=True, check=False).stdout
    except OSError:
        return '-'
    return LOCAL_IDENTITY if '"%s"' % LOCAL_IDENTITY in out else '-'


def make_info_plist():
    with open(os.path.join(REPO, 'Toplet', 'Info.plist'), 'rb') as f:
        info = plistlib.load(f)
    # Upstream Atoll's feed and EdDSA key must not reach Toplet: without them Sparkle installs nothing.
    info.pop('SUFeedURL', None)
    info.pop('SUPublicEDKey', None)
    # INFOPLIST_KEY_* build settings from the Release configuration
    info.update({
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleExecutable': APP_NAME,
        'CFBundleIdentifier': BUNDLE_ID,
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': APP_NAME,
        'CFBundleDisplayName': APP_NAME,
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': VERSION,
        'CFBundleVersion': BUILD,
        'CFBundleIconFile': 'AppIcon',
        'LSApplicationCategoryType': 'public.app-category.utilities',
        'LSMinimumSystemVersion': '14.6',
        'LSUIElement': True,
        'NSSupportsAutomaticTermination': False,   # always-on app: never let macOS quit it silently
        'NSSupportsSuddenTermination': False,
        'NSHumanReadableCopyright': '',
        'NSPrincipalClass': 'NSApplication',
        'MetalCaptureEnabled': True,
        'NSAppleEventsUsageDescription': 'Toplet uses AppleScripts to control Spotify, Apple Music, and Notes, and (only when you use the AI Agents tab) to jump to the terminal or editor that hosts an agent session.',
        'NSBluetoothAlwaysUsageDescription': 'Toplet needs Bluetooth access to detect when audio devices connect and display their battery status in the HUD.',
        'NSCalendarsFullAccessUsageDescription': 'Show calender events inside the notch',
        'NSCalendarsUsageDescription': 'Need for Calendar Mode',
        'NSCameraUsageDescription': 'We need your camera for Mirror mode',
        'NSDesktopFolderUsageDescription': 'Toplet needs access to save screenshots to your desktop.',
        'NSDocumentsFolderUsageDescription': 'Toplet needs access to save and read shelf dragged files.',
        'NSDownloadsFolderUsageDescription': 'Toplet needs access to read files in the downloads folder.',
        'NSLocationUsageDescription': 'Toplet uses your location for lock screen weather and, when you ask, to show where you are on the Clock tab map.',
        'NSLocationWhenInUseUsageDescription': 'Toplet uses your location for lock screen weather and, when you ask, to show where you are on the Clock tab map.',
        'NSMicrophoneUsageDescription': 'Toplet needs microphone access to record voice questions for the AI assistant feature.',
        'NSRemindersFullAccessUsageDescription': 'Toplet needs Reminders access to show your reminders',
        'NSRemindersUsageDescription': 'Toplet needs Reminders access to show your reminders',
        # --- local-first: Sparkle never checks on its own ---
        'SUEnableAutomaticChecks': False,
        'SUAutomaticallyUpdate': False,
    })
    return info


def make_entitlements(path):
    with open(os.path.join(REPO, 'Toplet', 'Toplet.entitlements'), 'rb') as f:
        ent = plistlib.load(f)
    removed = ent.pop('com.apple.security.mach-services', None)
    # Hardened runtime needs this standard (non-restricted) entitlement for Core Location (lock-screen weather uses
    # CLLocationManager); upstream omits it, so location access is silently denied under the hardened runtime.
    ent.setdefault('com.apple.security.personal-information.location', True)
    # Xcode expands $(PRODUCT_BUNDLE_IDENTIFIER) when it processes the entitlements file
    for k, v in list(ent.items()):
        if isinstance(v, list):
            ent[k] = [s.replace('$(PRODUCT_BUNDLE_IDENTIFIER)', BUNDLE_ID) if isinstance(s, str) else s for s in v]
    with open(path, 'wb') as f:
        plistlib.dump(ent, f)
    return removed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--config', default='debug', choices=['debug', 'release'])
    ap.add_argument('--identity', default=None,
                    help='codesign identity; default: $TOPLET_SIGN_IDENTITY, else "Toplet Local Signing" if trusted, else ad hoc (-)')
    ap.add_argument('--no-hardened-runtime', action='store_true')
    ap.add_argument('--out', default=os.path.join(DIST, APP_NAME + '.app'))
    a = ap.parse_args()

    products = os.path.join(WORK, '.build', a.config)
    exe = os.path.join(products, 'Atoll')
    if not os.path.exists(exe):
        sys.exit('missing %s - run `swift build --product Atoll` first' % exe)
    app = a.out
    if os.path.exists(app):
        shutil.rmtree(app)
    for d in ('MacOS', 'Resources', 'Frameworks', 'Helpers'):
        os.makedirs(os.path.join(app, 'Contents', d))

    shutil.copy2(exe, os.path.join(app, 'Contents', 'MacOS', APP_NAME))
    with open(os.path.join(app, 'Contents', 'Info.plist'), 'wb') as f:
        plistlib.dump(make_info_plist(), f)
    with open(os.path.join(app, 'Contents', 'PkgInfo'), 'w') as f:
        f.write('APPL????')

    res = os.path.join(app, 'Contents', 'Resources')
    rsrc = os.path.join(WORK, 'resources')
    for entry in os.listdir(rsrc):
        if entry == 'asset-conversion-report.txt':
            continue
        s = os.path.join(rsrc, entry)
        d = os.path.join(res, entry)
        if os.path.isdir(s):
            shutil.copytree(s, d, symlinks=True)
        else:
            shutil.copy2(s, d)
    # SwiftPM resource bundles of vendored packages (Bundle.module looks in Bundle.main.resourceURL)
    for fn in sorted(os.listdir(products)):
        if fn.endswith('.bundle'):
            shutil.copytree(os.path.join(products, fn), os.path.join(res, fn), symlinks=True)

    fw = os.path.join(app, 'Contents', 'Frameworks')
    for name in ('Sparkle.framework', 'Lottie.framework'):
        src = os.path.join(products, name)
        if not os.path.exists(src):
            sys.exit('missing framework ' + src)
        sh('ditto', src, os.path.join(fw, name))
    shutil.copy2(os.path.join(REPO, 'Contents', 'Helpers', 'NowPlayingTestClient'),
                 os.path.join(app, 'Contents', 'Helpers', 'NowPlayingTestClient'))

    # ---- signing, inside -> outside ----
    ent_path = os.path.join(WORK, 'Atoll.local.entitlements')
    removed = make_entitlements(ent_path)
    opts = [] if a.no_hardened_runtime else ['--options', 'runtime']
    ident = a.identity or signing_identity()
    print('signing identity:', 'ad hoc' if ident == '-' else ident)

    def sign(path, entitlements=None, preserve=False):
        cmd = ['codesign', '--force', '--sign', ident] + opts
        if entitlements:
            cmd += ['--entitlements', entitlements]
        if preserve:
            cmd += ['--preserve-metadata=identifier,entitlements']
        sh(*cmd, path, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    sp = os.path.join(fw, 'Sparkle.framework', 'Versions', 'B')
    for x in sorted(os.listdir(os.path.join(sp, 'XPCServices'))) if os.path.isdir(os.path.join(sp, 'XPCServices')) else []:
        sign(os.path.join(sp, 'XPCServices', x), preserve=True)
    sign(os.path.join(sp, 'Autoupdate'), preserve=True)
    sign(os.path.join(sp, 'Updater.app'), preserve=True)
    sign(os.path.join(fw, 'Sparkle.framework'), preserve=True)
    sign(os.path.join(fw, 'Lottie.framework'))
    # Resources/MediaRemoteAdapter.framework and Helpers/NowPlayingTestClient arrive already
    # ad-hoc signed; Xcode does not re-sign files copied by Resources/Copy-Files phases either.
    sign(os.path.join(app, 'Contents', 'MacOS', APP_NAME), entitlements=ent_path)
    sign(app, entitlements=ent_path)
    print('assembled', app)
    print('entitlements removed for ad-hoc signing: mach-services =', removed)


if __name__ == '__main__':
    main()
