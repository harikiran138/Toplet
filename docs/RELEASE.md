# Releasing Toplet

How a Toplet version goes from `main` to a download on GitHub Releases. The short checklist to
follow on release day is [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md).

## Versioning

[Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

- **PATCH**: fixes only. **MINOR**: new features, nothing removed. **MAJOR**: something users
  relied on changes or goes away (settings reset, minimum macOS raised, a feature removed).
- The version lives in the Xcode project (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`);
  `local/assemble.py` copies it into the app bundle.
- Every release has a `CHANGELOG.md` section; the release notes are taken from it.

## What gets published

| File | Purpose |
|---|---|
| `Toplet-<version>.dmg` | Drag-to-Applications installer (the main download) |
| `Toplet-<version>.zip` | Same app, zipped, for scripts and Homebrew |
| `Toplet-<version>.sha256` | SHA-256 checksums of both |

Build them with:

```bash
BUILD=1 local/release.sh
```

The script prints the architectures, whether the app is Developer ID signed, and whether it was
notarized. **Never publish a release that claims to be signed or notarized unless that output says so.**

## Signing and notarization

Toplet cannot be distributed through the Mac App Store (it uses private macOS APIs and is not
sandboxed), so it is distributed directly. For other Macs to open it without a Gatekeeper warning it
must be **signed with a Developer ID certificate and notarized by Apple**. That needs an Apple
Developer Program membership.

1. Create a *Developer ID Application* certificate in the Apple Developer portal and install it in
   your login keychain.
2. Store notarization credentials once (an app-specific password or an API key):
   ```bash
   xcrun notarytool store-credentials toplet-notary --apple-id "<you@example.com>" --team-id "<TEAMID>"
   ```
3. Release:
   ```bash
   SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=toplet-notary BUILD=1 local/release.sh
   ```

Signing identities, certificates, passwords and API keys **never go into the repository**, and CI
only gets them as encrypted repository secrets once a maintainer sets that up.

**Current status:** no Developer ID is configured for Toplet yet, so releases are ad-hoc signed.
That is the honest blocker for a public release: users would see a Gatekeeper warning, and we will
not ask anyone to disable Gatekeeper. Until then, building from source is the supported install.

## Architectures

`local/release.sh` reports the binary's architectures. The local build currently produces the
builder's architecture (arm64 on Apple silicon). A universal build (arm64 + x86_64) needs
`swift build --arch arm64 --arch x86_64` in `local/build.sh` and roughly twice the build disk space;
it is on the roadmap. The Xcode project can archive a universal build today.

## Updates (Sparkle)

The app contains Sparkle, but updates are **off** until Toplet publishes its own feed:

1. Generate a Sparkle EdDSA key pair (`generate_keys` from the Sparkle distribution). Keep the
   private key secret; put the public key in `Toplet/Info.plist` as `SUPublicEDKey`.
2. Publish `appcast.xml` (signed with the private key) next to the releases, e.g. in an `Updates/`
   folder on `main`.
3. Set `TopletProject.updatesFeedBase` in `Toplet/models/TopletProject.swift` to that
   folder's raw URL. The updater starts only when this is set.

Upstream Atoll's feed and key are removed on purpose, so an Atoll release can never install over Toplet.

## Homebrew

Once there is a signed, notarized release, a cask can point at the ZIP or DMG and its SHA-256.
Not before: Homebrew's main cask repository expects apps that pass Gatekeeper, so an
unsigned build would at best need a separate tap and a user-side workaround we do not want to recommend.
