# Release Checklist

Use this checklist for manual Grove releases.

## Before Cutting A Release

- Confirm `main` is in a releasable state.
- Review open issues and decide what is in or out of scope.
- Update `CHANGELOG.md`.
- Update version and build numbers in `Grove/App/Info.plist` and project settings if needed.
- Verify README and install instructions still match reality.

## Validation

- Build locally:

```bash
xcodebuild -project Grove.xcodeproj -scheme Grove -configuration Release -derivedDataPath .derivedData build
```

- Run the app locally and smoke-test:
  - launch and reopen
  - basic navigation
  - file selection and preview
  - file operations on a disposable test folder
  - at least one non-list view

- Validate local installation:

```bash
LAUNCH_AFTER_INSTALL=0 ./install.sh
```

## Release Prep

- Create a Git tag for the release.
- Draft GitHub release notes from `CHANGELOG.md`.
- Attach release artifacts manually if distributing a built app bundle or archive.
- Call out known limitations explicitly in release notes when relevant.

## After Release

- Verify the tag and release page on GitHub.
- Confirm install and run instructions still work from a clean clone.
- Add any post-release regressions or follow-up work back to `BACKLOG.md` or GitHub issues.
