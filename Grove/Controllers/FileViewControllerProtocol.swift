import AppKit

enum ViewMode: Int, CaseIterable {
    case list = 0
    case columns = 1
    case icons = 2
    case gallery = 3
}

protocol FileViewControllerProtocol: AnyObject {
    var delegate: FileListViewControllerDelegate? { get set }
    var currentURL: URL { get }
    var currentLocation: StorageLocation { get }
    var showHiddenFiles: Bool { get set }
    var selectedItems: [FileItem] { get }
    var selectedBrowserItems: [BrowserItem] { get }
    var capabilities: StorageCapabilities { get }
    var supportsToolbarSearch: Bool { get }
    func loadDirectory(_ url: URL)
    func loadLocation(_ location: StorageLocation)
    func toggleHiddenFiles()
    func setShowsHiddenFiles(_ visible: Bool)
    func createNewFolder()
    func setToolbarFilterText(_ text: String)
    func performToolbarSearch(_ query: String)
    func clearToolbarSearch()

    // File operations — available in every view, not just list view.
    func copySelectedFiles()
    func cutSelectedFiles()
    func pasteFiles()
    func deleteSelectedFiles()
    func duplicateSelectedFiles()
    func batchRenameSelectedFiles()
    func renameSelectedItem()
    func openSelectedFile()
}

/// Shared file clipboard so copy/cut/paste interoperate across all view modes and match
/// the pasteboard format the list view already uses.
enum FileOperationClipboard {
    static let pasteboardType = NSPasteboard.PasteboardType("com.grove.file-operation")

    static func write(_ urls: [URL], isCut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        pb.setString(isCut ? "cut" : "copy", forType: pasteboardType)
    }

    static func read() -> (urls: [URL], isCut: Bool)? {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        return (urls, pb.string(forType: pasteboardType) == "cut")
    }
}

/// Builds the shared file context menu used by icon, column, and gallery views. Items are
/// nil-targeted so they travel the responder chain to AppDelegate, which routes and validates them.
enum FileContextMenuBuilder {
    static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // Copy/Cut/Paste use the standard responder selectors so the active view's own
        // handlers (and validation) fire; the rest route to AppDelegate.
        let items: [(String, Selector)] = [
            ("Copy", #selector(NSText.copy(_:))),
            ("Cut", #selector(NSText.cut(_:))),
            ("Paste", #selector(NSText.paste(_:))),
            ("Duplicate", Selector(("duplicateFiles:"))),
            ("Rename", Selector(("renameFile:"))),
        ]
        for (title, action) in items {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Move to Trash", action: Selector(("deleteFiles:")), keyEquivalent: ""))
        return menu
    }
}

enum GroveUI {
    static let contentFontSize: CGFloat = 11
    static let sidebarFontSize: CGFloat = 12
    static let sidebarSectionFontSize: CGFloat = 10
    static let statusFontSize: CGFloat = 10
    static let emptyFontSize: CGFloat = 13
    static let pathBarFontSize: CGFloat = 11
    static let listRowHeight: CGFloat = 20
    static let iconLabelFontSize: CGFloat = 10
    static let iconItemSize = NSSize(width: 84, height: 74)
    static let iconSize: CGFloat = 44
    static let sidebarRailWidth: CGFloat = 56
    static let sidebarListWidth: CGFloat = 190

    // Grove's palette intentionally keeps the large surfaces neutral. Blue is reserved
    // for focus, selection, and storage state so the app stays dark rather than navy.
    static let windowBackground = NSColor(srgbRed: 0.030, green: 0.035, blue: 0.038, alpha: 1)
    static let contentBackground = NSColor(srgbRed: 0.042, green: 0.047, blue: 0.050, alpha: 1)
    static let elevatedBackground = NSColor(srgbRed: 0.064, green: 0.070, blue: 0.074, alpha: 1)
    static let sidebarBackground = NSColor(srgbRed: 0.035, green: 0.040, blue: 0.043, alpha: 0.98)
    static let railBackground = NSColor(srgbRed: 0.024, green: 0.028, blue: 0.030, alpha: 1)
    static let alternateRowBackground = NSColor(srgbRed: 0.072, green: 0.078, blue: 0.081, alpha: 0.78)
    static let separator = NSColor(srgbRed: 0.16, green: 0.18, blue: 0.19, alpha: 0.72)
    static let accent = NSColor(srgbRed: 0.16, green: 0.59, blue: 1.0, alpha: 1)
    static let accentSoft = NSColor(srgbRed: 0.39, green: 0.69, blue: 1.0, alpha: 1)
    static let selectionFill = accent.withAlphaComponent(0.09)
    static let selectionStroke = accent.withAlphaComponent(0.78)

    static func configureFooterStatusLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: statusFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        label.setAccessibilityIdentifier("localStatusFooter")
    }

    static func prepareSurface(_ view: NSView, color: NSColor = contentBackground) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
    }
}

final class GroveTableRowView: NSTableRowView {
    private let horizontalInset: CGFloat

    init(horizontalInset: CGFloat = 2) {
        self.horizontalInset = horizontalInset
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        horizontalInset = 2
        super.init(coder: coder)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: horizontalInset, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        GroveUI.selectionFill.setFill()
        path.fill()
        GroveUI.selectionStroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class GroveStorageMeter: NSView {
    var progress: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        GroveUI.separator.setFill()
        track.fill()

        let fillWidth = bounds.width * min(max(progress, 0), 1)
        guard fillWidth > 0 else { return }
        let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        GroveUI.accent.setFill()
        fill.fill()
    }
}

enum TerminalLauncher {
    static func targetDirectory(currentURL: URL, selectedItems: [FileItem]) -> URL {
        guard let selected = selectedItems.first else {
            return currentURL.standardizedFileURL
        }
        if selected.isDirectory && !selected.isPackage {
            return selected.url.standardizedFileURL
        }
        return selected.url.deletingLastPathComponent().standardizedFileURL
    }

    @discardableResult
    static func open(at url: URL, presentingView: NSView?) -> Bool {
        guard let appleScript = NSAppleScript(source: changeDirectoryScript(for: url)) else {
            presentError(from: presentingView)
            return false
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        guard error == nil else {
            presentError(from: presentingView)
            return false
        }
        return true
    }

    static func changeDirectoryScript(for url: URL) -> String {
        let command = "cd \(shellQuotedPath(url.path))"
        return """
        tell application "Terminal"
        activate
        do script "\(appleScriptEscapedString(command))"
        end tell
        """
    }

    private static func shellQuotedPath(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptEscapedString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func presentError(from view: NSView?) {
        let alert = NSAlert()
        alert.messageText = "Couldn't Open Terminal"
        alert.informativeText = "Grove needs permission to control Terminal. Open System Settings > Privacy & Security > Automation and enable Terminal under Grove, then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

enum LocalFooterStatusFormatter {
    static func string(totalItemCount: Int, selectedItemCount: Int, availableDiskSpace: String?) -> String {
        let summary: String
        if selectedItemCount > 0 {
            summary = "\(selectedItemCount) of \(totalItemCount) selected"
        } else {
            summary = totalItemCount == 1 ? "1 item" : "\(totalItemCount) items"
        }

        guard let availableDiskSpace, !availableDiskSpace.isEmpty else {
            return summary
        }

        return "\(summary), \(availableDiskSpace) available"
    }
}

final class LocalFooterDiskSpaceCache {
    static let shared = LocalFooterDiskSpaceCache()

    private struct Entry {
        let value: String?
        let refreshedAt: Date
    }

    private let freshnessInterval: TimeInterval
    private let refreshDelay: TimeInterval
    private let queue: DispatchQueue
    private let diskSpaceProvider: (URL) -> String?
    private var entries: [String: Entry] = [:]
    private var refreshesInFlight: Set<String> = []

    init(
        freshnessInterval: TimeInterval = 10,
        refreshDelay: TimeInterval = 0.5,
        queueLabel: String = "com.grove.local-footer-disk-space",
        diskSpaceProvider: @escaping (URL) -> String? = { FileOperationService.shared.availableDiskSpace(at: $0) }
    ) {
        self.freshnessInterval = freshnessInterval
        self.refreshDelay = refreshDelay
        self.queue = DispatchQueue(label: queueLabel)
        self.diskSpaceProvider = diskSpaceProvider
    }

    func diskSpace(at url: URL) -> String? {
        let key = cacheKey(for: url)
        return queue.sync {
            entries[key]?.value
        }
    }

    func refreshIfNeeded(at url: URL, completion: @escaping (URL) -> Void) {
        let key = cacheKey(for: url)
        let standardizedURL = url.standardizedFileURL
        let now = Date()
        let shouldRefresh = queue.sync { () -> Bool in
            if let entry = entries[key],
               now.timeIntervalSince(entry.refreshedAt) < freshnessInterval {
                return false
            }
            guard !refreshesInFlight.contains(key) else { return false }
            refreshesInFlight.insert(key)
            return true
        }

        guard shouldRefresh else { return }

        queue.asyncAfter(deadline: .now() + refreshDelay) { [weak self] in
            guard let self else { return }
            let value = diskSpaceProvider(standardizedURL)
            let refreshedAt = Date()
            queue.async {
                self.entries[key] = Entry(value: value, refreshedAt: refreshedAt)
                self.refreshesInFlight.remove(key)
                DispatchQueue.main.async {
                    completion(standardizedURL)
                }
            }
        }
    }

    private func cacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}

enum FileDropOperationResolver {
    static func preferredOperation(from sourceMask: NSDragOperation) -> NSDragOperation {
        if sourceMask.contains(.move) {
            return .move
        }
        if sourceMask.contains(.copy) {
            return .copy
        }
        return []
    }

    static func isMove(_ operation: NSDragOperation) -> Bool {
        operation == .move
    }
}

extension FileViewControllerProtocol {
    var currentLocation: StorageLocation { .local(currentURL.standardizedFileURL) }
    var selectedBrowserItems: [BrowserItem] { selectedItems.map(BrowserItem.local) }
    var capabilities: StorageCapabilities { currentLocation.capabilities }
    var supportsToolbarSearch: Bool { false }
    func loadLocation(_ location: StorageLocation) {
        guard case .local(let url) = location else { return }
        loadDirectory(url)
    }
    func setShowsHiddenFiles(_ visible: Bool) {
        guard showHiddenFiles != visible else { return }
        toggleHiddenFiles()
    }
    func createNewFolder() {
        do {
            _ = try FileOperationService.shared.createNewFolder(in: currentURL)
            loadDirectory(currentURL)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
    func setToolbarFilterText(_ text: String) {}
    func performToolbarSearch(_ query: String) {}
    func clearToolbarSearch() {}
}

// Default file operations for view controllers that don't provide their own (icon, column,
// gallery). The list view keeps its richer implementations (progress sheets, undo).
extension FileViewControllerProtocol where Self: NSViewController {
    func copySelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileOperationClipboard.write(urls, isCut: false)
    }

    func cutSelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileOperationClipboard.write(urls, isCut: true)
    }

    func pasteFiles() {
        guard let (urls, isCut) = FileOperationClipboard.read() else { return }
        do {
            if isCut {
                _ = try FileOperationService.shared.move(urls, to: currentURL)
                NSPasteboard.general.clearContents()
            } else {
                _ = try FileOperationService.shared.copy(urls, to: currentURL)
            }
            loadDirectory(currentURL)
        } catch {
            presentFileOperationError(error)
        }
    }

    func deleteSelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty, let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Are you sure you want to move \"\(urls[0].lastPathComponent)\" to the Trash?"
            : "Are you sure you want to move \(urls.count) items to the Trash?"
        alert.informativeText = "You can restore items from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                _ = try FileOperationService.shared.moveToTrash(urls)
                self?.loadDirectory(self?.currentURL ?? urls[0].deletingLastPathComponent())
            } catch {
                self?.presentFileOperationError(error)
            }
        }
    }

    func duplicateSelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        do {
            for url in urls {
                _ = try FileOperationService.shared.duplicate(url)
            }
            loadDirectory(currentURL)
        } catch {
            presentFileOperationError(error)
        }
    }

    func batchRenameSelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard urls.count > 1 else { return }
        // ponytail: no delegate — the directory watcher refreshes the view after renames.
        presentAsSheet(BatchRenameViewController(urls: urls))
    }

    func renameSelectedItem() {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        FileRenameHelper.presentRenameSheet(for: item, from: self) { [weak self] _ in
            guard let self else { return }
            self.loadDirectory(self.currentURL)
        }
    }

    func openSelectedFile() {
        guard let item = selectedItems.first else { return }
        if item.isDirectory && !item.isPackage {
            delegate?.fileListDidNavigate(to: item.url.resolvingSymlinksInPath())
        } else {
            FileOperationService.shared.openFile(item.url)
        }
    }

    func presentFileOperationError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// Enablement for the standard copy/cut/paste menu items handled by this view.
    func validateFileOperationMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(NSText.copy(_:)), #selector(NSText.cut(_:)):
            return !selectedItems.isEmpty
        case #selector(NSText.paste(_:)):
            return FileOperationClipboard.read() != nil
        default:
            return true
        }
    }
}

enum FileRenameHelper {
    static func defaultSelectionRange(for item: FileItem) -> NSRange {
        let name = item.name as NSString
        guard !(item.isDirectory && !item.isPackage) else {
            return NSRange(location: 0, length: name.length)
        }

        let pathExtension = item.url.pathExtension
        guard !pathExtension.isEmpty else {
            return NSRange(location: 0, length: name.length)
        }

        let suffix = ".\(pathExtension)" as NSString
        guard name.length > suffix.length,
              item.name.hasSuffix(suffix as String) else {
            return NSRange(location: 0, length: name.length)
        }

        return NSRange(location: 0, length: name.length - suffix.length)
    }

    static func presentRenameSheet(
        for item: FileItem,
        from viewController: NSViewController,
        completion: @escaping (URL) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = item.name
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: item.name)
        textField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = textField

        let rename: () -> Void = {
            let newName = textField.stringValue
            guard !newName.isEmpty, newName != item.name else { return }

            do {
                let newURL = try FileOperationService.shared.rename(item.url, to: newName)
                completion(newURL)
            } catch {
                showError(error, from: viewController)
            }
        }

        if let window = viewController.view.window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                rename()
            }
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(textField)
                selectDefaultTitlePortion(for: item, in: textField, window: alert.window)
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                rename()
            }
        }
    }

    private static func selectDefaultTitlePortion(for item: FileItem, in textField: NSTextField, window: NSWindow) {
        textField.selectText(nil)
        guard let fieldEditor = window.fieldEditor(true, for: textField) else { return }
        fieldEditor.selectedRange = defaultSelectionRange(for: item)
    }

    private static func showError(_ error: Error, from viewController: NSViewController) {
        let alert = NSAlert(error: error)
        if let window = viewController.view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

/// Runs copy/move transfers on a background queue behind a progress sheet so the UI never
/// blocks, marshalling conflict prompts back to the main thread. Used by all drop and paste
/// entry points. `completion` runs on the main thread with the resulting records, or an error
/// (`.cancelled`/`.partialFailure` carry the records completed before the stop for partial undo).
enum FileTransferCoordinator {
    static func perform(
        urls: [URL],
        to destination: URL,
        isMove: Bool,
        presenter: NSViewController,
        completion: @escaping (Result<[FileOperationService.FileTransferRecord], Error>) -> Void
    ) {
        let progressVC = FileProgressViewController()
        progressVC.configure(operationVerb: isMove ? "Moving" : "Copying")
        presenter.presentAsSheet(progressVC)

        let prompt = FileConflictResolutionPrompt(window: presenter.view.window)
        let resolver: (FileOperationService.FileConflict) -> FileOperationService.ConflictResolution = { conflict in
            if Thread.isMainThread {
                return prompt.resolve(conflict)
            }
            return DispatchQueue.main.sync { prompt.resolve(conflict) }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[FileOperationService.FileTransferRecord], Error>
            do {
                let records = try FileOperationService.shared.transferResolvingConflictsWithProgress(
                    urls,
                    to: destination,
                    isMove: isMove,
                    resolver: resolver,
                    progress: { value, name in
                        DispatchQueue.main.async { progressVC.updateProgress(value, fileName: name) }
                    },
                    cancelled: { progressVC.isCancelled }
                )
                result = .success(records)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                presenter.dismiss(progressVC)
                completion(result)
            }
        }
    }
}

final class FileConflictResolutionPrompt {
    private weak var window: NSWindow?
    private var applyToAllResolution: FileOperationService.ConflictResolution?

    init(window: NSWindow?) {
        self.window = window
    }

    func resolve(_ conflict: FileOperationService.FileConflict) -> FileOperationService.ConflictResolution {
        if let applyToAllResolution,
           applyToAllResolution != .merge || conflict.canMerge {
            return applyToAllResolution
        }

        let alert = NSAlert()
        alert.messageText = "Conflicting item names"
        alert.informativeText = "An item named \"\(conflict.destinationURL.lastPathComponent)\" already exists in this location."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        if conflict.canMerge {
            alert.addButton(withTitle: "Merge")
        }
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Don't Replace")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all conflicts"

        let response: NSApplication.ModalResponse
        if let window {
            response = alert.runModal()
            window.makeKey()
        } else {
            response = alert.runModal()
        }

        let resolution = resolution(for: response, canMerge: conflict.canMerge)
        if alert.suppressionButton?.state == .on {
            applyToAllResolution = resolution
        }
        return resolution
    }

    private func resolution(
        for response: NSApplication.ModalResponse,
        canMerge: Bool
    ) -> FileOperationService.ConflictResolution {
        switch response {
        case .alertFirstButtonReturn:
            return .replace
        case .alertSecondButtonReturn:
            return canMerge ? .merge : .keepBoth
        case .alertThirdButtonReturn:
            return canMerge ? .keepBoth : .skip
        default:
            return .skip
        }
    }
}
