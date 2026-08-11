import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var windowControllers: [BrowserWindowController] = []
    private var didPresentArchiveQuarantineWarning = false
    private var archiveQuarantineObserver: NSObjectProtocol?
    var archiveQuarantineAlertPresenterForTesting: ((NSAlert) -> Void)?
    // States of browser windows closed since the last fresh session start.
    // Lets us restore the full last session when the user closes every window before quitting.
    private var closedWindowStates: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        setupMainMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            beginObservingArchiveQuarantineAttention()
            FileOperationService.shared.startArchiveQuarantineLifecycle()
        }

        // Restore previous window states or open default
        if restoreWindowStates() {
            // Windows restored successfully
        } else {
            let wc = BrowserWindowController()
            wc.showWindow(nil)
            windowControllers.append(wc)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            newWindow(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveWindowStates()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    deinit {
        if let archiveQuarantineObserver {
            NotificationCenter.default.removeObserver(archiveQuarantineObserver)
        }
    }

    // MARK: - Window Management

    @objc func newWindow(_ sender: Any?) {
        // Opening a window into an empty app starts a fresh session; forget prior closes.
        if windowControllers.isEmpty {
            closedWindowStates.removeAll()
        }
        let wc = BrowserWindowController()
        wc.showWindow(nil)
        windowControllers.append(wc)
    }

    @objc func newTab(_ sender: Any?) {
        guard let currentWC = activeBrowserWindowController(),
              let currentWindow = currentWC.window else {
            newWindow(sender)
            return
        }

        let wc = BrowserWindowController(initialLocation: currentWC.currentLocation)
        windowControllers.append(wc)
        guard let newWindow = wc.window else { return }
        currentWindow.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }

    @objc func closeCurrentWindow(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        // Close all tabs in the window group, then the window itself
        let tabbedWindows = window.tabbedWindows ?? [window]
        for tab in tabbedWindows {
            tab.close()
        }
    }

    @objc private func windowDidClose(_ notification: Notification) {
        // Only react to tracked browser windows; ignore panels, sheets, etc.
        guard let window = notification.object as? NSWindow,
              let index = windowControllers.firstIndex(where: { $0.window === window }) else { return }
        // Capture the closing window's state so the full session can be restored even
        // if every window is closed before the app quits. Persistence happens on terminate.
        closedWindowStates.append(windowControllers[index].saveState())
        windowControllers.remove(at: index)
    }

    func beginObservingArchiveQuarantineAttention() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard archiveQuarantineObserver == nil else { return }
        archiveQuarantineObserver = NotificationCenter.default.addObserver(
            forName: FileOperationService.archiveQuarantineNeedsAttentionNotification,
            object: FileOperationService.shared,
            queue: .main
        ) { [weak self] notification in
            self?.presentArchiveQuarantineAttention(notification)
        }
    }

    private func presentArchiveQuarantineAttention(_ notification: Notification) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !didPresentArchiveQuarantineWarning else { return }
        didPresentArchiveQuarantineWarning = true
        let recordCount = (notification.userInfo?["records"] as? [FileOperationService.ArchiveQuarantineRecord])?.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Archive cleanup needs attention"
        alert.informativeText = recordCount.map {
            "Grove safely retained \($0) archive cleanup item(s). Their contents were restricted; details remain available in Grove's cleanup registry."
        } ?? "Grove could not complete or verify archive cleanup. Details remain available in Grove's cleanup registry."
        if let archiveQuarantineAlertPresenterForTesting {
            archiveQuarantineAlertPresenterForTesting(alert)
        } else if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Window State Save/Restore

    private func saveWindowStates() {
        windowControllers.removeAll { $0.window == nil }
        // Prefer the currently-open windows; if none are open (user closed all before
        // quitting), fall back to the states captured as they closed. Never persist empty.
        let states = windowControllers.isEmpty
            ? closedWindowStates
            : windowControllers.map { $0.saveState() }
        guard !states.isEmpty else { return }
        UserDefaults.standard.set(states, forKey: BrowserWindowController.windowStatesKey)
    }

    private func activeBrowserWindowController() -> BrowserWindowController? {
        if let keyController = NSApp.keyWindow?.windowController as? BrowserWindowController {
            return keyController
        }
        return windowControllers.reversed().first { $0.window?.isVisible == true }
    }

    private func restoreWindowStates() -> Bool {
        guard let states = UserDefaults.standard.array(forKey: BrowserWindowController.windowStatesKey) as? [[String: Any]],
              !states.isEmpty else {
            return false
        }

        var restored = false
        for state in states {
            if let wc = BrowserWindowController.restoreState(from: state) {
                wc.showWindow(nil)
                windowControllers.append(wc)
                restored = true
            }
        }
        return restored
    }

    // MARK: - Menu Actions

    @objc func goBack(_ sender: Any?) {
        currentBrowserController?.goBack(sender)
    }

    @objc func goForward(_ sender: Any?) {
        currentBrowserController?.goForward(sender)
    }

    @objc func goEnclosingFolder(_ sender: Any?) {
        guard let bc = currentBrowserController else { return }
        guard let parent = bc.currentLocation.parent else { return }
        bc.navigate(to: parent, addToHistory: true)
    }

    @objc func goToFolder(_ sender: Any?) {
        currentBrowserController?.goToFolder(sender)
    }

    @objc func copyFiles(_ sender: Any?) {
        currentContentVC?.copySelectedFiles()
    }

    @objc func cutFiles(_ sender: Any?) {
        currentContentVC?.cutSelectedFiles()
    }

    @objc func pasteFiles(_ sender: Any?) {
        currentContentVC?.pasteFiles()
    }

    @objc func deleteFiles(_ sender: Any?) {
        currentContentVC?.deleteSelectedFiles()
    }

    @objc func duplicateFiles(_ sender: Any?) {
        currentContentVC?.duplicateSelectedFiles()
    }

    @objc func batchRenameFiles(_ sender: Any?) {
        currentContentVC?.batchRenameSelectedFiles()
    }

    @objc func renameFile(_ sender: Any?) {
        currentContentVC?.renameSelectedItem()
    }

    @objc func createNewFolder(_ sender: Any?) {
        currentSplitVC?.createNewFolder()
    }

    @objc func openFile(_ sender: Any?) {
        currentContentVC?.openSelectedFile()
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        currentBrowserController?.toggleHiddenFiles(sender)
    }

    @objc func toggleInspector(_ sender: Any?) {
        currentBrowserController?.toggleInspector(sender)
    }

    // MARK: - View Mode Actions

    @objc func viewAsList(_ sender: Any?) {
        currentSplitVC?.switchViewMode(.list)
    }

    @objc func viewAsColumns(_ sender: Any?) {
        currentSplitVC?.switchViewMode(.columns)
    }

    @objc func viewAsIcons(_ sender: Any?) {
        currentSplitVC?.switchViewMode(.icons)
    }

    @objc func viewAsGallery(_ sender: Any?) {
        currentSplitVC?.switchViewMode(.gallery)
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        currentSplitVC?.togglePreviewPane()
    }

    @objc func toggleDualPane(_ sender: Any?) {
        currentSplitVC?.toggleDualPane()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyFiles(_:)),
             #selector(cutFiles(_:)),
             #selector(deleteFiles(_:)),
             #selector(duplicateFiles(_:)),
             #selector(openFile(_:)):
            return hasLocalSelection
        case #selector(renameFile(_:)):
            return hasLocalSelection && currentContentVC?.selectedItems.count == 1
        case #selector(batchRenameFiles(_:)):
            return hasLocalSelection && (currentContentVC?.selectedItems.count ?? 0) > 1
        case #selector(pasteFiles(_:)):
            return currentContentVC != nil
                && currentSplitVC?.currentLocation.isLocal == true
                && FileOperationClipboard.read() != nil
        case #selector(createNewFolder(_:)):
            return currentSplitVC?.currentCapabilities.contains(.createFolder) ?? false
        case #selector(goEnclosingFolder(_:)):
            return currentBrowserController?.currentLocation.parent != nil
        case #selector(toggleHiddenFiles(_:)):
            let showsHiddenFiles = currentSplitVC?.showsHiddenFiles ?? false
            menuItem.state = showsHiddenFiles ? .on : .off
            menuItem.title = showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files"
            return currentSplitVC?.currentCapabilities.contains(.showHiddenFiles) ?? false
        case #selector(viewAsColumns(_:)),
             #selector(viewAsIcons(_:)),
             #selector(viewAsGallery(_:)),
             #selector(toggleDualPane(_:)):
            return currentSplitVC?.currentLocation.isLocal ?? false
        default:
            return true
        }
    }

    private var currentBrowserController: BrowserWindowController? {
        NSApp.keyWindow?.windowController as? BrowserWindowController
    }

    private var currentSplitVC: MainSplitViewController? {
        guard let wc = currentBrowserController else { return nil }
        return wc.contentViewController as? MainSplitViewController
    }

    private var currentContentVC: (NSViewController & FileViewControllerProtocol)? {
        currentSplitVC?.activeContentViewController
    }

    /// True when the active view is a local file view with at least one selected item.
    private var hasLocalSelection: Bool {
        guard let vc = currentContentVC,
              currentSplitVC?.currentLocation.isLocal == true else { return false }
        return !vc.selectedItems.isEmpty
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Grove", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Grove", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Grove", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        let newTabItem = fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        newTabItem.keyEquivalentModifierMask = .command
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "New Folder", action: #selector(createNewFolder(_:)), keyEquivalent: "N")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Open", action: #selector(openFile(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Duplicate", action: #selector(duplicateFiles(_:)), keyEquivalent: "d")
        let batchRenameItem = fileMenu.addItem(withTitle: "Batch Rename...", action: #selector(batchRenameFiles(_:)), keyEquivalent: "R")
        batchRenameItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        let closeItem = fileMenu.addItem(withTitle: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = .command
        let closeWindowItem = fileMenu.addItem(withTitle: "Close Window", action: #selector(closeCurrentWindow(_:)), keyEquivalent: "W")
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let deleteItem = NSMenuItem(title: "Move to Trash", action: #selector(deleteFiles(_:)), keyEquivalent: "\u{8}")
        deleteItem.keyEquivalentModifierMask = .command
        editMenu.addItem(deleteItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        viewMenu.addItem(withTitle: "as List", action: #selector(viewAsList(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "as Columns", action: #selector(viewAsColumns(_:)), keyEquivalent: "2")
        viewMenu.addItem(withTitle: "as Icons", action: #selector(viewAsIcons(_:)), keyEquivalent: "3")
        viewMenu.addItem(withTitle: "as Gallery", action: #selector(viewAsGallery(_:)), keyEquivalent: "4")
        viewMenu.addItem(.separator())

        let hiddenItem = viewMenu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHiddenFiles(_:)), keyEquivalent: ".")
        hiddenItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())

        let inspectorItem = viewMenu.addItem(withTitle: "Toggle Inspector", action: #selector(toggleInspector(_:)), keyEquivalent: "i")
        inspectorItem.keyEquivalentModifierMask = [.command, .option]

        let previewItem = viewMenu.addItem(withTitle: "Show Preview Pane", action: #selector(togglePreviewPane(_:)), keyEquivalent: "p")
        previewItem.keyEquivalentModifierMask = [.command, .shift]

        viewMenu.addItem(.separator())

        let dualPaneItem = viewMenu.addItem(withTitle: "Dual Pane", action: #selector(toggleDualPane(_:)), keyEquivalent: "d")
        dualPaneItem.keyEquivalentModifierMask = [.command, .option]

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Go menu
        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        let backItem = goMenu.addItem(withTitle: "Back", action: #selector(goBack(_:)), keyEquivalent: "[")
        backItem.keyEquivalentModifierMask = .command
        let forwardItem = goMenu.addItem(withTitle: "Forward", action: #selector(goForward(_:)), keyEquivalent: "]")
        forwardItem.keyEquivalentModifierMask = .command
        let enclosingItem = NSMenuItem(title: "Enclosing Folder", action: #selector(goEnclosingFolder(_:)), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        enclosingItem.keyEquivalentModifierMask = .command
        goMenu.addItem(enclosingItem)
        goMenu.addItem(.separator())
        let goToFolderItem = goMenu.addItem(withTitle: "Go to Folder...", action: #selector(goToFolder(_:)), keyEquivalent: "g")
        goToFolderItem.keyEquivalentModifierMask = [.command, .shift]
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Show All Tabs", action: #selector(NSWindow.toggleTabOverview(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}")
        windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{")
        windowMenu.addItem(withTitle: "Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // Help menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Grove Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}
