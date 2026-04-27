import AppKit

final class BrowserWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {

    private let splitVC = MainSplitViewController()
    private var history: NavigationHistory
    private let pathBar = PathBarView()
    private let searchField = NSSearchField()
    private var goToFolderController: GoToFolderPanelController?

    private var backButton: NSToolbarItem?
    private var forwardButton: NSToolbarItem?
    private var hiddenFilesButton: NSButton?

    var currentURL: URL { history.currentURL }

    // Toolbar identifiers
    private let toolbarID = NSToolbar.Identifier("GroveToolbar")
    private let backForwardID = NSToolbarItem.Identifier("BackForward")
    private let pathBarID = NSToolbarItem.Identifier("PathBar")
    private let searchID = NSToolbarItem.Identifier("Search")
    private let hiddenFilesID = NSToolbarItem.Identifier("HiddenFiles")
    private let inspectorID = NSToolbarItem.Identifier("Inspector")

    convenience init() {
        let initialURL = FileManager.default.homeDirectoryForCurrentUser
        self.init(initialURL: initialURL)
    }

    init(initialURL: URL) {
        history = NavigationHistory(initialURL: initialURL)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 600, height: 400)
        window.title = initialURL.displayName
        window.tab.title = initialURL.displayName
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "com.grove.browser"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.center()

        super.init(window: window)

        window.contentViewController = splitVC
        splitVC.navigationDelegate = self
        splitVC.loadViewIfNeeded()

        setupToolbar()
        setupPathBar()
        setupSearchField()
        navigate(to: initialURL, addToHistory: false)
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
        pathBar.onPathComponentClicked = { [weak self] url in
            self?.navigate(to: url, addToHistory: true)
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
        if addToHistory {
            history.navigateTo(url)
        }
        searchField.stringValue = ""
        splitVC.clearToolbarSearch()
        splitVC.navigate(to: url)
        pathBar.update(for: url)
        window?.title = url.displayName
        window?.tab.title = url.displayName
        updateNavigationButtons()
        updateSearchFieldAvailability()
    }

    @objc func goBack(_ sender: Any?) {
        guard let url = history.goBack() else { return }
        navigate(to: url, addToHistory: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let url = history.goForward() else { return }
        navigate(to: url, addToHistory: false)
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
        state["viewMode"] = splitVC.currentViewMode.rawValue
        state["previewPaneVisible"] = splitVC.isPreviewPaneVisible
        state["dualPaneVisible"] = splitVC.isDualPaneVisible
        state["showsHiddenFiles"] = splitVC.showsHiddenFiles
        if let frame = window?.frame {
            state["windowFrame"] = NSStringFromRect(frame)
        }
        if let splitView = splitVC.splitView as NSSplitView? {
            let sidebarWidth = splitView.isSubviewCollapsed(splitView.subviews[0])
                ? 0 : splitView.subviews[0].frame.width
            state["sidebarWidth"] = sidebarWidth
        }
        state["inspectorCollapsed"] = splitVC.inspectorIsCollapsed
        return state
    }

    static func restoreState(from dict: [String: Any]) -> BrowserWindowController? {
        guard let path = dict["currentURL"] as? String else { return nil }
        let url = URL(fileURLWithPath: path)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        let wc = BrowserWindowController(initialURL: url)

        if let frameString = dict["windowFrame"] as? String {
            let frame = NSRectFromString(frameString)
            if frame.width > 0 && frame.height > 0 {
                wc.window?.setFrame(frame, display: false)
            }
        }

        if let sidebarWidth = dict["sidebarWidth"] as? CGFloat, sidebarWidth > 0 {
            wc.splitVC.setSidebarWidth(sidebarWidth)
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
            item.preferredWidthForSearchField = 180
            return item

        case hiddenFilesID:
            let item = NSToolbarItem(itemIdentifier: hiddenFilesID)
            let button = NSButton(image: NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hidden Files") ?? NSImage(), target: self, action: #selector(toggleHiddenFiles(_:)))
            button.setButtonType(.toggle)
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            button.toolTip = "Show hidden files"
            button.setAccessibilityLabel("Show hidden files")
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28)
            ])

            item.view = button
            item.label = "Hidden Files"
            item.paletteLabel = "Show Hidden Files"
            item.toolTip = "Show hidden files"
            hiddenFilesButton = button
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
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    // MARK: - Actions

    @objc func toggleInspector(_ sender: Any?) {
        splitVC.toggleInspector()
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        splitVC.toggleHiddenFiles()
        updateHiddenFilesButtonState()
    }

    func setShowsHiddenFiles(_ visible: Bool) {
        splitVC.setShowsHiddenFiles(visible)
        updateHiddenFilesButtonState()
    }

    private func updateHiddenFilesButtonState() {
        let showsHidden = splitVC.showsHiddenFiles
        hiddenFilesButton?.state = showsHidden ? .on : .off
        hiddenFilesButton?.image = NSImage(
            systemSymbolName: showsHidden ? "eye" : "eye.slash",
            accessibilityDescription: showsHidden ? "Hide Hidden Files" : "Show Hidden Files"
        )
        hiddenFilesButton?.toolTip = showsHidden ? "Hide hidden files" : "Show hidden files"
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

    func splitViewSearchSupportDidChange() {
        updateSearchFieldAvailability()
    }
}
