import AppKit

protocol BrowserWindowFileDropDelegate: AnyObject {
    func browserWindow(_ window: BrowserWindow, validateFileDropWith info: any NSDraggingInfo) -> NSDragOperation
    func browserWindow(_ window: BrowserWindow, acceptFileDropWith info: any NSDraggingInfo) -> Bool
}

final class BrowserWindow: NSWindow, NSDraggingDestination {
    weak var fileDropDelegate: BrowserWindowFileDropDelegate?

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileDropDelegate?.browserWindow(self, validateFileDropWith: sender) ?? []
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileDropDelegate?.browserWindow(self, validateFileDropWith: sender) ?? []
    }

    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        (fileDropDelegate?.browserWindow(self, validateFileDropWith: sender) ?? []).isEmpty == false
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        fileDropDelegate?.browserWindow(self, acceptFileDropWith: sender) ?? false
    }
}

final class BrowserWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation {

    private let splitVC = MainSplitViewController()
    private var history: NavigationHistory
    private let pathBar = PathBarView()
    private let searchField = NSSearchField()
    private var goToFolderController: GoToFolderPanelController?

    private var backButton: NSToolbarItem?
    private var forwardButton: NSToolbarItem?
    private var hiddenFilesItem: NSToolbarItem?
    private var newFolderItem: NSToolbarItem?

    var currentLocation: StorageLocation { history.currentLocation }
    var currentURL: URL { history.currentURL }

    // Toolbar identifiers
    private let toolbarID = NSToolbar.Identifier("GroveToolbar")
    private let backForwardID = NSToolbarItem.Identifier("BackForward")
    private let pathBarID = NSToolbarItem.Identifier("PathBar")
    private let searchID = NSToolbarItem.Identifier("Search")
    private let hiddenFilesID = NSToolbarItem.Identifier("HiddenFiles")
    private let inspectorID = NSToolbarItem.Identifier("Inspector")
    private let newFolderID = NSToolbarItem.Identifier("NewFolder")

    convenience init() {
        let initialURL = FileManager.default.homeDirectoryForCurrentUser
        self.init(initialURL: initialURL)
    }

    convenience init(initialURL: URL) {
        self.init(initialLocation: .local(initialURL.standardizedFileURL))
    }

    init(initialLocation: StorageLocation) {
        self.history = NavigationHistory(initialLocation: initialLocation)

        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 600, height: 400)
        window.title = initialLocation.displayName
        window.tab.title = initialLocation.displayName
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "com.grove.browser"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.center()

        super.init(window: window)
        window.fileDropDelegate = self
        window.registerForDraggedTypes([.fileURL])

        window.contentViewController = splitVC
        splitVC.navigationDelegate = self
        splitVC.loadViewIfNeeded()

        setupToolbar()
        setupPathBar()
        setupSearchField()
        navigate(to: initialLocation, addToHistory: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: toolbarID)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private func setupPathBar() {
        pathBar.onLocationComponentClicked = { [weak self] location in
            self?.navigate(to: location, addToHistory: true)
        }
    }

    private func setupSearchField() {
        searchField.placeholderString = "Filter"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        updateSearchFieldAvailability()
    }

    // MARK: - Navigation

    func navigate(to url: URL, addToHistory: Bool) {
        navigate(to: .local(url.standardizedFileURL), addToHistory: addToHistory)
    }

    func navigate(to location: StorageLocation, addToHistory: Bool) {
        if addToHistory {
            history.navigateTo(location)
        }
        searchField.stringValue = ""
        splitVC.clearToolbarSearch()
        splitVC.navigate(to: location)
        pathBar.update(for: location)
        window?.title = location.displayName
        window?.tab.title = location.displayName
        updateNavigationButtons()
        updateToolbarActionAvailability()
        updateSearchFieldAvailability()
    }

    @objc func goBack(_ sender: Any?) {
        guard let location = history.goBackLocation() else { return }
        navigate(to: location, addToHistory: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let location = history.goForwardLocation() else { return }
        navigate(to: location, addToHistory: false)
    }

    private func updateNavigationButtons() {
        backButton?.isEnabled = history.canGoBack
        forwardButton?.isEnabled = history.canGoForward
    }

    private func updateSearchFieldAvailability() {
        let supportsToolbarSearch = splitVC.supportsToolbarSearch
        searchField.isEnabled = supportsToolbarSearch
        searchField.placeholderString = supportsToolbarSearch ? "Filter" : "Search unavailable in this view"

        if !supportsToolbarSearch, !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            splitVC.clearToolbarSearch()
        }
    }

    // MARK: - Go to Folder

    @objc func goToFolder(_ sender: Any?) {
        guard let window = window else { return }
        let controller = GoToFolderPanelController()
        controller.onNavigate = { [weak self] url in
            self?.navigate(to: url, addToHistory: true)
        }
        goToFolderController = controller
        controller.showPanel(relativeTo: window)
    }

    // MARK: - Window State Save/Restore

    static let windowStatesKey = "windowStates"

    func saveState() -> [String: Any] {
        var state: [String: Any] = [:]
        state["currentURL"] = currentURL.path
        state["currentLocation"] = currentLocation.propertyListRepresentation
        state["viewMode"] = splitVC.currentViewMode.rawValue
        state["previewPaneVisible"] = splitVC.isPreviewPaneVisible
        state["dualPaneVisible"] = splitVC.isDualPaneVisible
        state["showsHiddenFiles"] = splitVC.showsHiddenFiles
        if let frame = window?.frame {
            state["windowFrame"] = NSStringFromRect(frame)
        }
        state["sidebarWidth"] = splitVC.sidebarWidth
        state["inspectorCollapsed"] = splitVC.inspectorIsCollapsed
        return state
    }

    static func restoreState(from dict: [String: Any]) -> BrowserWindowController? {
        let location: StorageLocation
        if let restored = StorageLocation.fromPropertyList(dict["currentLocation"]) {
            location = restored
        } else if let path = dict["currentURL"] as? String {
            location = .local(URL(fileURLWithPath: path).standardizedFileURL)
        } else {
            return nil
        }

        if case .local(let url) = location {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
        }

        let wc = BrowserWindowController(initialLocation: location)

        if let frameString = dict["windowFrame"] as? String {
            let frame = NSRectFromString(frameString)
            if frame.width > 0 && frame.height > 0 {
                wc.window?.setFrame(frame, display: false)
            }
        }

        if let sidebarWidth = Self.cgFloatValue(from: dict["sidebarWidth"]), sidebarWidth > 0 {
            DispatchQueue.main.async {
                wc.splitVC.setSidebarWidth(sidebarWidth)
            }
        }

        if let inspectorCollapsed = dict["inspectorCollapsed"] as? Bool, !inspectorCollapsed {
            wc.splitVC.setInspectorCollapsed(false)
        }

        if let viewModeRaw = dict["viewMode"] as? Int,
           let viewMode = ViewMode(rawValue: viewModeRaw) {
            wc.splitVC.switchViewMode(viewMode)
        }

        if let dualPaneVisible = dict["dualPaneVisible"] as? Bool {
            wc.splitVC.setDualPaneVisible(dualPaneVisible)
        }

        if let previewPaneVisible = dict["previewPaneVisible"] as? Bool {
            wc.splitVC.setPreviewPaneVisible(previewPaneVisible)
        }

        if let showsHiddenFiles = dict["showsHiddenFiles"] as? Bool {
            wc.setShowsHiddenFiles(showsHiddenFiles)
        }

        return wc
    }

    private static func cgFloatValue(from value: Any?) -> CGFloat? {
        if let value = value as? CGFloat {
            return value
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        return nil
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case backForwardID:
            let group = NSToolbarItemGroup(itemIdentifier: backForwardID)

            let back = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("Back"))
            back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
            back.label = "Back"
            back.target = self
            back.action = #selector(goBack(_:))
            back.isEnabled = false
            back.toolTip = "Navigate back"

            let forward = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("Forward"))
            forward.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
            forward.label = "Forward"
            forward.target = self
            forward.action = #selector(goForward(_:))
            forward.isEnabled = false
            forward.toolTip = "Navigate forward"

            group.subitems = [back, forward]
            group.selectionMode = .momentary
            group.controlRepresentation = .automatic

            backButton = back
            forwardButton = forward
            return group

        case pathBarID:
            let item = NSToolbarItem(itemIdentifier: pathBarID)
            item.label = "Path"
            pathBar.translatesAutoresizingMaskIntoConstraints = false
            item.view = pathBar
            NSLayoutConstraint.activate([
                pathBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
                pathBar.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
                pathBar.heightAnchor.constraint(equalToConstant: 22)
            ])
            item.visibilityPriority = .low
            item.toolTip = "Path bar"
            pathBar.setAccessibilityLabel("Path bar")
            pathBar.setAccessibilityIdentifier("pathBar")
            return item

        case searchID:
            let item = NSSearchToolbarItem(itemIdentifier: searchID)
            item.searchField = searchField
            item.preferredWidthForSearchField = 160
            return item

        case hiddenFilesID:
            let item = NSToolbarItem(itemIdentifier: hiddenFilesID)
            item.label = "Hidden Files"
            item.paletteLabel = "Show Hidden Files"
            item.target = self
            item.action = #selector(toggleHiddenFiles(_:))
            hiddenFilesItem = item
            updateHiddenFilesButtonState()
            return item

        case inspectorID:
            let item = NSToolbarItem(itemIdentifier: inspectorID)
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Inspector")
            item.label = "Inspector"
            item.target = self
            item.action = #selector(toggleInspector(_:))
            item.toolTip = "Toggle inspector panel"
            return item

        case newFolderID:
            let item = NSToolbarItem(itemIdentifier: newFolderID)
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Folder")
            item.label = "New Folder"
            item.target = self
            item.action = #selector(createNewFolder(_:))
            item.toolTip = "Create new folder"
            newFolderItem = item
            updateToolbarActionAvailability()
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            backForwardID,
            .flexibleSpace,
            pathBarID,
            .flexibleSpace,
            searchID,
            hiddenFilesID,
            inspectorID,
            newFolderID,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    // MARK: - Actions

    @objc func toggleInspector(_ sender: Any?) {
        splitVC.toggleInspector()
    }

    @objc func createNewFolder(_ sender: Any?) {
        guard splitVC.currentCapabilities.contains(.createFolder) else { return }
        splitVC.createNewFolder()
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        splitVC.toggleHiddenFiles()
        updateHiddenFilesButtonState()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(createNewFolder(_:)):
            return splitVC.currentCapabilities.contains(.createFolder)
        case #selector(toggleHiddenFiles(_:)):
            let showsHidden = splitVC.showsHiddenFiles
            menuItem.state = showsHidden ? .on : .off
            menuItem.title = showsHidden ? "Hide Hidden Files" : "Show Hidden Files"
            return splitVC.currentCapabilities.contains(.showHiddenFiles)
        case #selector(goToFolder(_:)):
            return splitVC.currentLocation.isLocal
        case #selector(goBack(_:)):
            return history.canGoBack
        case #selector(goForward(_:)):
            return history.canGoForward
        default:
            return true
        }
    }

    func setShowsHiddenFiles(_ visible: Bool) {
        splitVC.setShowsHiddenFiles(visible)
        updateHiddenFilesButtonState()
    }

    private func updateHiddenFilesButtonState() {
        let showsHidden = splitVC.showsHiddenFiles
        hiddenFilesItem?.image = NSImage(
            systemSymbolName: showsHidden ? "eye" : "eye.slash",
            accessibilityDescription: showsHidden ? "Hide Hidden Files" : "Show Hidden Files"
        )
        hiddenFilesItem?.label = showsHidden ? "Hide Hidden" : "Show Hidden"
        hiddenFilesItem?.paletteLabel = showsHidden ? "Hide Hidden Files" : "Show Hidden Files"
        hiddenFilesItem?.toolTip = showsHidden ? "Hide hidden files" : "Show hidden files"
        hiddenFilesItem?.isEnabled = splitVC.currentCapabilities.contains(.showHiddenFiles)
    }

    private func updateToolbarActionAvailability() {
        newFolderItem?.isEnabled = splitVC.currentCapabilities.contains(.createFolder)
        hiddenFilesItem?.isEnabled = splitVC.currentCapabilities.contains(.showHiddenFiles)
    }

    @objc override func newWindowForTab(_ sender: Any?) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.newTab(sender)
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        guard splitVC.supportsToolbarSearch else { return }
        let text = field.stringValue
        if text.isEmpty {
            splitVC.clearToolbarSearch()
        } else {
            splitVC.setToolbarFilterText(text)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard splitVC.supportsToolbarSearch else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let query = searchField.stringValue
            if !query.isEmpty {
                splitVC.performToolbarSearch(query)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            searchField.stringValue = ""
            splitVC.clearToolbarSearch()
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

extension BrowserWindowController: MainSplitViewControllerDelegate {
    func splitViewDidNavigate(to url: URL) {
        navigate(to: url, addToHistory: true)
    }

    func splitViewDidNavigate(to location: StorageLocation) {
        navigate(to: location, addToHistory: true)
    }

    func splitViewSearchSupportDidChange() {
        updateSearchFieldAvailability()
        updateToolbarActionAvailability()
    }
}

extension BrowserWindowController: BrowserWindowFileDropDelegate {
    func browserWindow(_ window: BrowserWindow, validateFileDropWith info: any NSDraggingInfo) -> NSDragOperation {
        guard case .local = currentLocation else { return [] }
        guard isFileDropInTabArea(info, of: window),
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    func browserWindow(_ window: BrowserWindow, acceptFileDropWith info: any NSDraggingInfo) -> Bool {
        guard case .local(let destination) = currentLocation else { return false }
        guard isFileDropInTabArea(info, of: window),
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }

        let isMove = info.draggingSourceOperationMask.contains(.move)
        return transferDroppedFiles(urls, to: destination, isMove: isMove)
    }

    private func isFileDropInTabArea(_ info: any NSDraggingInfo, of window: BrowserWindow) -> Bool {
        let point = info.draggingLocation
        let topBandHeight = max(window.frame.height - window.contentRect(forFrameRect: window.frame).height, 64)

        if point.y >= window.frame.height - topBandHeight {
            return true
        }

        let layoutRect = window.contentLayoutRect
        return !layoutRect.isEmpty && point.y >= layoutRect.maxY
    }

    private func transferDroppedFiles(_ urls: [URL], to destination: URL, isMove: Bool) -> Bool {
        do {
            let conflictPrompt = FileConflictResolutionPrompt(window: window)
            let records: [FileOperationService.FileTransferRecord]
            if isMove {
                records = try FileOperationService.shared.moveResolvingConflictsWithRecords(urls, to: destination) { conflict in
                    conflictPrompt.resolve(conflict)
                }
                registerUndoTransfer(records: records, actionName: "Move")
            } else {
                records = try FileOperationService.shared.copyResolvingConflictsWithRecords(urls, to: destination) { conflict in
                    conflictPrompt.resolve(conflict)
                }
                registerUndoTransfer(records: records, actionName: "Copy")
            }
            splitVC.navigate(to: destination)
            return true
        } catch {
            registerUndoForPartialSideEffects(from: error, actionName: isMove ? "Move" : "Copy")
            showError(error)
            return false
        }
    }

    private func registerUndoMove(originalURLs: [URL], movedURLs: [URL]) {
        guard let undoManager = window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            do {
                for (movedURL, originalURL) in zip(movedURLs, originalURLs) {
                    _ = try FileOperationService.shared.moveResolvingConflicts([movedURL], to: originalURL.deletingLastPathComponent()) { _ in
                        .keepBoth
                    }
                }
            } catch {
                target.showError(error)
            }
        }
        undoManager.setActionName("Move")
    }

    private func registerUndoCopy(copiedURLs: [URL]) {
        guard let undoManager = window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            do {
                _ = try FileOperationService.shared.moveToTrash(copiedURLs)
            } catch {
                target.showError(error)
            }
        }
        undoManager.setActionName("Copy")
    }

    private func registerUndoTransfer(records: [FileOperationService.FileTransferRecord], actionName: String) {
        let undoableRecords = records.filter(\.isUndoable)
        guard !undoableRecords.isEmpty, let undoManager = window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            do {
                try FileOperationService.shared.undoTransferRecords(undoableRecords)
            } catch {
                target.showError(error)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func registerUndoForPartialSideEffects(from error: Error, actionName: String) {
        guard case FileOperationService.FileOperationError.partialFailure(let records, _) = error else { return }
        registerUndoTransfer(records: records, actionName: actionName)
    }

    private func showError(_ error: Error) {
        guard let window else {
            NSAlert(error: error).runModal()
            return
        }
        NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
    }
}
