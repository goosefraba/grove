# Grove Roadmap

This file tracks the current public roadmap for Grove.

It is intentionally lightweight: shipped capabilities are documented here for orientation, and the open sections focus on what still needs attention rather than preserving old implementation history.

## Current State

Grove already includes:

- Native macOS windows and tabs
- Sidebar favorites and mounted locations
- List, column, icon, and gallery views
- Optional preview pane and dual-pane browsing
- Breadcrumb navigation and Go to Folder
- Toolbar filtering and deep search where supported
- Copy, move, duplicate, rename, batch rename, compress, and extract actions
- Quick Look integration
- Drag and drop
- Window state restoration
- Finder tag display and general accessibility coverage

## Next Up

- Search parity across all views
  Make filtering and deeper search behavior feel consistent in list, icon, column, gallery, and dual-pane modes.

- Inspector and preview depth
  Expand metadata coverage, improve multi-selection summaries, and make previews more useful for common file types.

- File operation polish
  Tighten edge cases around long-running operations, cancellation, undo behavior, and conflict handling.

- View-mode refinement
  Continue aligning column, icon, gallery, and dual-pane behaviors so selection, keyboard navigation, and refresh logic feel equally mature.

- Packaging and distribution
  Improve release packaging, app installation ergonomics, and public documentation for direct macOS distribution.

## Good First Issues

- Documentation fixes that improve setup or explain behavior more clearly
- Small UX inconsistencies between view modes
- Keyboard shortcut regressions or discoverability gaps
- Accessibility labeling improvements
- Error-message clarity for file operation failures

## Out Of Scope For Now

- Mac App Store packaging
- Cross-platform ports
- Automatic CI builds that require paid macOS runners
