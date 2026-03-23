# Grove — Feature Backlog

## Performance

- [ ] Async directory loading — move `contentsOfDirectory` off main thread to avoid UI freeze on large dirs
- [ ] Async icon loading — fetch icons in background with placeholder, update cells on completion
- [ ] File operation progress — show progress indicator for long copy/move operations with cancel support

## File Operations

- [ ] Undo/Redo — register undo actions for trash, move, rename, copy
- [ ] Duplicate (Cmd+D) — duplicate selected files in place
- [ ] Batch rename — regex/pattern-based renaming of multiple files
- [ ] Folder size calculation — background computation of actual folder sizes

## Views

- [ ] Column view (NSBrowser) — Finder's Miller columns mode
- [ ] Icon view (NSCollectionView) — grid view with large thumbnails
- [ ] Gallery view — image preview mode with large preview and filmstrip
- [ ] Preview pane — inline file preview (text, images, markdown) without Quick Look
- [ ] Dual pane mode — side-by-side directories for easy copy/move

## Search

- [ ] Filename filter — toolbar search field filtering current directory by name
- [ ] Spotlight integration — deep search via NSMetadataQuery

## Context Menu

- [ ] Open With submenu — app picker for opening files
- [ ] Copy Path — copy file path to clipboard
- [ ] Open in Terminal — open Terminal.app at current directory

## Sidebar

- [ ] Drag to add favorites — drop folders onto sidebar to bookmark them
- [ ] Remove/reorder favorites — right-click to remove, drag to reorder
- [ ] Persist favorites — save custom favorites to UserDefaults

## Inspector

- [ ] Multi-selection summary — show aggregate info (count, total size) for multiple selected files
- [ ] Permissions display — show rwx/octal permissions
- [ ] Image dimensions — show width/height for image files

## Navigation

- [ ] Go to Folder (Cmd+Shift+G) — type a path to navigate directly
- [ ] Breadcrumb dropdowns — click path bar segments to browse sibling directories

## Window Management

- [ ] Window state restoration — reopen windows at last browsed location after quit

## System Integration

- [ ] Finder tags — read/write macOS color tags
- [ ] Accessibility — VoiceOver labels and identifiers on all custom views
