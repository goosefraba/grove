# Storage dashboard

Open **View → Show Storage** (⌥⌘S), or the pie-chart button above Trash in the sidebar rail. Storage opens as a native tab in the current browser window. Reopening Storage selects the existing Storage tab in that window; existing file tabs keep their location and view settings. Choose a folder, or press Analyze for the current folder. Folder rows, chart segments, and breadcrumbs explore the hierarchy. Open in Grove and file rows browse the folder in the same tab. Back returns to the retained dashboard and then walks its folder trail; context menus also reveal items in Finder.

Volume cards show system-reported capacity, independently of folder analysis. Choose a folder on a volume using its arrow button. Analyze Home and Downloads provide shortcuts. Scans start explicitly. ⌘R rescans, ⌘. stops, and closing the Storage tab cancels an active scan. Restored Storage tabs wait for Analyze before scanning again. ⌘T opens a file-browsing tab at the analyzed folder.

The dashboard includes allocated and logical file sizes, file and folder counts, a clickable item breakdown, estimated file types, filterable folder contents, and the largest descendant files. Empty, scanning, stopped, unavailable, and partial results have distinct states. Read-error details remain available under About this measurement. Selecting the folder again can grant macOS access; permissions remain controlled by macOS.

## Measurement

- Allocated file bytes are the primary metric throughout charts, rows, categories, and largest files. Logical file length is shown separately. Resource values supply allocation, with `st_blocks * 512` as a fallback; zero allocation is valid for sparse files and cloud placeholders.
- Hidden files and package contents are included. No file contents are opened. Descendant symbolic links and nested mounts are skipped. No privileged helper or shell command is used.
- Hard-linked regular files share allocation once per root scan, keyed by device and inode. Logical length and file counts describe paths. A separately scanned subfolder can therefore differ from its contribution to a parent scan.
- Folder analysis excludes directory metadata. APFS clone sharing, snapshots, other volumes, and unreadable paths prevent reconciliation with the volume's Used figure. These are observed sizes, not reclaimable-space estimates.
- A scan of `/` is limited to that filesystem and reports excluded mounts; macOS Data firmlinks can be excluded too. Analyze Home or an explicit folder for user data; the dashboard does not claim whole-startup-disk classification.
- File types are estimated from extensions and known package/dependency paths, rather than macOS Storage categories.

A serial utility worker owns traversal. Cancellation is checked between metadata calls; an already-blocked filesystem call cannot be interrupted. Progress is throttled and all main-thread deliveries are gated by a generation identifier. Retained state consists of immediate children, 32 largest files, 40 error examples, aggregates, and identities of multiply-linked files. A bounded session cache retains up to 12 complete root results with timestamps; Rescan bypasses it. No disk cache or telemetry is written.

## Research and implementation

The user requested Mole's approach. Astra xhigh researched Grove and the open-source CLI at revision `7f83db8a97f4ab754887176b6f7d22c14e955fba`; Claude Code Sonnet 5.5 xhigh provided inspect-only UI/UX advice. Grove adopts largest-first exploration, cancellable scans, bounded large-file results, and explicit coverage states. The implementation is independently written in Swift using Foundation, AppKit, SwiftUI, and Swift Charts; no Mole code or assets are incorporated.

Upstream references: [scanner](https://github.com/tw93/Mole/blob/7f83db8a97f4ab754887176b6f7d22c14e955fba/cmd/analyze/scanner.go), [live publication](https://github.com/tw93/Mole/blob/7f83db8a97f4ab754887176b6f7d22c14e955fba/cmd/analyze/live_scan.go), [cache and bounds](https://github.com/tw93/Mole/blob/7f83db8a97f4ab754887176b6f7d22c14e955fba/cmd/analyze/constants.go), [GPL-3.0 license](https://github.com/tw93/Mole/blob/7f83db8a97f4ab754887176b6f7d22c14e955fba/LICENSE).

## Native-tab verification (2026-10-17)

- Full Grove XCTest suite: **206 passed, 0 failed, 0 skipped**, arm64 on macOS 27 / Xcode 27. Deployment target remains macOS 14 (not run on that OS).
- Native AppKit integration tests cover tab grouping/reuse, preserving the original browser's view and panes, same-tab Open in Grove and Back/Forward, folder-trail navigation, read-only command routing, closing-tab cancellation, session restoration without automatic scanning, and dual-pane hidden-file preferences. Dashboard creation leaves the unrelated file list unloaded.
- Native hosted-view renders at 600- and 1200-point browser widths were visually inspected. Cards and charts stack in the narrow center pane; full-size views retain the side-by-side breakdown. Rendered fixtures and independent Astra source review are under the ignored `.build/storage-tabs-verification/` directory. Both review findings were resolved.
- The computer-use service failed to start (`Sky Computer Use native pipe startup failed`), so installed-app click-through verification of the new tab flow was unavailable. Native AppKit tests and hosted-view rendering provide the tab/layout evidence; release signature, installed binary, and process checks are separate.

## Original dashboard verification (2026-10-17, before tab integration)

- Full Grove XCTest suite: **201 passed, 0 failed, 0 skipped**, arm64 on macOS 27 / Xcode 27; Debug test command exited 0. Deployment target remains macOS 14 (not run on that OS).
- Scanner regressions cover hidden/package data, sparse allocation, hard links, symbolic links and loops, root path aliases, injected read errors and mount boundaries, cancellation, bounded ranking/errors, overflow, stale navigation, failed-rescan cache invalidation, and window/context integration.
- Native preview verified sidebar entry and initial folder, direct donut-segment drill-down, breadcrumbs and native Go → Back, file-folder handoff to Grove, normal/narrow/wide layouts, scrolling, and ⌘. cancellation. A real build-tree scan measured 51,138 files / 6,584 folders in 3.8 seconds on this Mac; this is one observation, not a benchmark guarantee.
- Independent Astra source review closed its findings; requested Sonnet 5.5 xhigh UI/UX advice was inspect-only. Research/advice/review/test records are under the ignored `.build/storage-dashboard-verification/` directory.
- Native permission dialogs and a physical external-volume ejection were not exercised; scanner error and mount behavior use deterministic fixtures. A separate local preview was used for feature runtime verification; installed-release verification is a separate release step.
