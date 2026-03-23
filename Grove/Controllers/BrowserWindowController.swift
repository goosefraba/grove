import AppKit

final class BrowserWindowController: NSWindowController, NSToolbarDelegate {

    private let splitVC = MainSplitViewController()
    private var history: NavigationHistory
    private let pathBar = PathBarView()

    private var backButton: NSToolbarItem?
    private var forwardButton: NSToolbarItem?

    var currentURL: URL { history.currentURL }

    // Toolbar identifiers
    private let toolbarID = NSToolbar.Identifier("GroveToolbar")
    private let backForwardID = NSToolbarItem.Identifier("BackForward")
    private let pathBarID = NSToolbarItem.Identifier("PathBar")
    private let searchID = NSToolbarItem.Identifier("Search")
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
        window.tabbingMode = .preferred
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.center()

        super.init(window: window)

        window.contentViewController = splitVC
        splitVC.navigationDelegate = self

        setupToolbar()
        setupPathBar()
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

    // MARK: - Navigation

    func navigate(to url: URL, addToHistory: Bool) {
        if addToHistory {
            history.navigateTo(url)
        }
        splitVC.navigate(to: url)
        pathBar.update(for: url)
        window?.title = url.displayName
        updateNavigationButtons()
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

            let forward = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("Forward"))
            forward.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
            forward.label = "Forward"
            forward.target = self
            forward.action = #selector(goForward(_:))
            forward.isEnabled = false

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
            item.minSize = NSSize(width: 150, height: 22)
            item.maxSize = NSSize(width: 500, height: 22)
            item.visibilityPriority = .low
            return item

        case inspectorID:
            let item = NSToolbarItem(itemIdentifier: inspectorID)
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Inspector")
            item.label = "Inspector"
            item.target = self
            item.action = #selector(toggleInspector(_:))
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

    @objc func newTab(_ sender: Any?) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.newTab(sender)
    }
}

extension BrowserWindowController: MainSplitViewControllerDelegate {
    func splitViewDidNavigate(to url: URL) {
        navigate(to: url, addToHistory: true)
    }
}
