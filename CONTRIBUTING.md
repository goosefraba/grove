# Contributing To Grove

## Scope

Grove is a native macOS file browser built with Swift and AppKit. Contributions should keep that focus: native behavior, predictable file operations, and clear keyboard-first workflows.

## Prerequisites

- macOS 14.0 or newer
- Xcode 15 or newer
- GitHub account for pull requests

## Local Setup

```bash
git clone https://github.com/goosefraba/grove.git
cd grove
./run.sh
```

For a local app install instead of a direct run:

```bash
./install.sh
```

## Development Notes

- Prefer native AppKit patterns for core browser UI and window behavior.
- Keep SwiftUI usage limited to places where it is already the established pattern.
- Avoid adding third-party dependencies unless there is a strong project-level reason.
- Preserve Finder-like expectations for file handling, navigation, and shortcuts where practical.
- Keep changes scoped. Small, reviewable pull requests are preferred over broad refactors.

## Before Opening A Pull Request

- Build the app locally with `./run.sh` or `xcodebuild`.
- Manually test the behavior you changed.
- Update documentation when the user-facing behavior changes.
- Call out any known limitations or follow-up work in the pull request description.

## Pull Request Guidelines

- Use a clear title and describe the user-visible change.
- Include validation steps that a reviewer can repeat locally.
- Keep unrelated cleanup out of feature or bug-fix pull requests.
- If a change affects file operations or navigation, mention regression risk explicitly.

## Issues And Roadmap

If you plan to work on a larger feature or behavior change, open an issue or discussion first so the approach can be aligned before implementation.

## Licensing

By contributing to Grove, you agree that your contributions will be licensed under the MIT License included in this repository.
