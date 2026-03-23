import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowControllers: [BrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        let wc = BrowserWindowController()
        wc.showWindow(nil)
        windowControllers.append(wc)
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

    // MARK: - Window Management

    @objc func newWindow(_ sender: Any?) {
        let wc = BrowserWindowController()
        wc.showWindow(nil)
        windowControllers.append(wc)
    }

    @objc func newTab(_ sender: Any?) {
        guard let currentWindow = NSApp.keyWindow else {
            newWindow(sender)
            return
        }

        let currentWC = currentWindow.windowController as? BrowserWindowController
        let initialURL = currentWC?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser

        let wc = BrowserWindowController(initialURL: initialURL)
        windowControllers.append(wc)
        guard let newWindow = wc.window else { return }
        currentWindow.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }

    @objc private func windowDidClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windowControllers.removeAll { $0.window === window }
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
        let current = bc.currentURL.standardizedFileURL
        let parent = current.deletingLastPathComponent().standardizedFileURL
        guard parent != current else { return }
        bc.navigate(to: parent, addToHistory: true)
    }

    @objc func copyFiles(_ sender: Any?) {
        currentFileListVC?.copySelectedFiles()
    }

    @objc func cutFiles(_ sender: Any?) {
        currentFileListVC?.cutSelectedFiles()
    }

    @objc func pasteFiles(_ sender: Any?) {
        currentFileListVC?.pasteFiles()
    }

    @objc func deleteFiles(_ sender: Any?) {
        currentFileListVC?.deleteSelectedFiles()
    }

    @objc func createNewFolder(_ sender: Any?) {
        currentFileListVC?.createNewFolder()
    }

    @objc func openFile(_ sender: Any?) {
        currentFileListVC?.openSelectedFile()
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        currentFileListVC?.toggleHiddenFiles()
    }

    @objc func toggleInspector(_ sender: Any?) {
        currentBrowserController?.toggleInspector(sender)
    }

    private var currentBrowserController: BrowserWindowController? {
        NSApp.keyWindow?.windowController as? BrowserWindowController
    }

    private var currentFileListVC: FileListViewController? {
        guard let wc = currentBrowserController,
              let splitVC = wc.contentViewController as? MainSplitViewController else { return nil }
        return splitVC.fileListVC
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
        let closeItem = fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = .command
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(cutFiles(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(copyFiles(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(pasteFiles(_:)), keyEquivalent: "v")
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
        let hiddenItem = viewMenu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHiddenFiles(_:)), keyEquivalent: ".")
        hiddenItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        let inspectorItem = viewMenu.addItem(withTitle: "Toggle Inspector", action: #selector(toggleInspector(_:)), keyEquivalent: "i")
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
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
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
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
