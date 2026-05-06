---
name: grove-macos-release-install
description: Build, sign, notarize, verify, and install the Grove macOS app into /Applications using the repo's release automation and local Apple signing credentials.
---

# Grove macOS Release Install

Use this skill whenever the user wants a real installed macOS Grove app, not a development build from `run.sh` or Xcode.

The correct path is automated. Do not hand-copy `.derivedData` products for release, and do not create new bundle IDs, certificates, or Apple credentials unless the existing setup is clearly missing or broken.

## Fixed Project Facts

- macOS bundle ID: `com.goosefraba.grove`
- Apple Developer team ID: `PT9PGWUBJ7`
- Signing identity: `Developer ID Application: goosefraba GmbH (PT9PGWUBJ7)`
- Xcode project: `Grove.xcodeproj`
- Scheme: `Grove`
- Entitlements file: `Grove/Resources/Grove.entitlements`
- Release script: `scripts/release_macos.sh`
- Local private env file: `.grove.env`
- Shared notarization env fallback: `../namodb/.tauri.env`
- Installed app path: `/Applications/Grove.app`
- Release artifacts: `/tmp/grove-macos-release/Grove.app` and `/tmp/grove-macos-release/Grove.app.zip`

## Before Releasing

1. Confirm the branch and local edits:

   ```bash
   git status --short --branch
   ```

2. Confirm local release credentials are present. Private values must stay in ignored env files:

   ```bash
   APPLE_ID=...
   APPLE_TEAM_ID=PT9PGWUBJ7
   APPLE_PASSWORD=...
   ```

   The script sources `release.env`, then `.grove.env`, then `../namodb/.tauri.env`, so existing release-machine notarization credentials can be reused without duplicating secrets.

3. Run preflight:

   ```bash
   ./scripts/release_macos.sh --check --ship
   ```

   If intentionally releasing a dirty worktree, add `--allow-dirty`.

## Standard Release Command

From the repo root, run:

```bash
./scripts/release_macos.sh --ship
```

`--ship` expands to:

- build the Xcode Release app
- copy the built app into a release artifact directory
- sign with Developer ID, hardened runtime, and Grove entitlements
- verify the signature
- zip and submit for Apple notarization
- staple the notarization ticket
- install the app into `/Applications/Grove.app`
- verify the installed signature and Gatekeeper assessment
- register with Launch Services and import into Spotlight

If the user explicitly wants to install uncommitted local changes, run:

```bash
./scripts/release_macos.sh --ship --allow-dirty
```

## What Success Looks Like

The script should finish with:

```text
Release artifacts ready
  App bundle: /tmp/grove-macos-release/Grove.app
  Zip:        /tmp/grove-macos-release/Grove.app.zip
  Installed:  /Applications/Grove.app
```

The installed app should pass:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/Grove.app
spctl --assess --type execute --verbose=2 /Applications/Grove.app
mdfind 'kMDItemCFBundleIdentifier == "com.goosefraba.grove"'
```

## Useful Alternatives

Build, sign, and zip without notarizing or installing:

```bash
./scripts/release_macos.sh --allow-dirty
```

Build and notarize but do not install:

```bash
./scripts/release_macos.sh --notarize --allow-dirty
```

Install an already-built signed app bundle after rerunning packaging:

```bash
./scripts/release_macos.sh --skip-build --install --allow-dirty
```

Build, notarize, install, and immediately launch:

```bash
./scripts/release_macos.sh --ship --launch --allow-dirty
```

## Common Failure Modes

- If preflight says the Developer ID identity is missing, confirm the `PT9PGWUBJ7` Developer ID Application certificate is installed in Keychain.
- If notarization fails, check `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_PASSWORD` in the ignored local env files.
- If `/Applications` is not writable, stop and ask the user to make the install destination writable. Do not use destructive cleanup.
- If Spotlight does not find Grove immediately, run `mdimport /Applications/Grove.app` and wait briefly; Launch Services registration already runs during `--install`.
