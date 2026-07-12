import AppKit

protocol MainSplitViewControllerDelegate: AnyObject {
    func splitViewDidNavigate(to url: URL)
    func splitViewDidNavigate(to location: StorageLocation)
    func splitViewSearchSupportDidChange()
}

extension MainSplitViewControllerDelegate {
    func splitViewDidNavigate(to location: StorageLocation) {
        guard case .local(let url) = location else { return }
        splitViewDidNavigate(to: url)
    }
}

final class MainSplitViewController: NSSplitViewController {

    weak var navigationDelegate: MainSplitViewControllerDelegate?

    let sidebarVC = SidebarViewController()
    private(set) var fileListVC = FileListViewController()
    let inspectorVC = InspectorViewController()
    private let previewPaneVC = PreviewPaneController()

    private var inspectorItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!
    private var previewPaneItem: NSSplitViewItem!

    private(set) var currentViewMode: ViewMode = .list
    private var currentContentVC: (NSViewController & FileViewControllerProtocol)?
    private var s3BrowserVC: S3BrowserViewController?
    private(set) var currentLocation: StorageLocation = .local(FileManager.default.homeDirectoryForCurrentUser)
    private var lastLocalViewMode: ViewMode = .list
    private var lastLocalShowsHiddenFiles: Bool = false

    private var dualPaneVC: DualPaneViewController?
    private var isDualPaneActive: Bool = false
    private var dualPaneSplitViewItem: NSSplitViewItem?

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebarVC.delegate = self
        fileListVC.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 150
        sidebarItem.canCollapse = true

        contentItem = NSSplitViewItem(viewController: fileListVC)
        contentItem.minimumThickness = 300

        previewPaneItem = NSSplitViewItem(viewController: previewPaneVC)
        previewPaneItem.minimumThickness = 200
        previewPaneItem.maximumThickness = 400
        previewPaneItem.isCollapsed = true
        previewPaneItem.canCollapse = true

        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        inspectorItem.minimumThickness = 200
        inspectorItem.maximumThickness = 350
        inspectorItem.isCollapsed = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(previewPaneItem)
        addSplitViewItem(inspectorItem)

        currentContentVC = fileListVC
    }

    func navigate(to url: URL) {
        navigate(to: .local(url.standardizedFileURL))
    }

    func navigate(to location: StorageLocation) {
        let previousLocation = currentLocation
        currentLocation = location
        switch location {
        case .local:
            ensureLocalContentController()
        case .s3:
            if previousLocation.isLocal {
                lastLocalViewMode = currentViewMode
                lastLocalShowsHiddenFiles = currentContentVC?.showHiddenFiles ?? false
            }
            ensureS3ContentController()
        }

        if isDualPaneActive {
            if case .local(let url) = location {
                dualPaneVC?.loadDirectory(url)
            } else {
                deactivateDualPane()
                currentContentVC?.loadLocation(location)
            }
        } else {
            currentContentVC?.loadLocation(location)
        }
        sidebarVC.selectItem(for: location)
        navigationDelegate?.splitViewSearchSupportDidChange()
    }

    func toggleInspector() {
        inspectorItem.animator().isCollapsed.toggle()
    }

    var inspectorIsCollapsed: Bool {
        inspectorItem.isCollapsed
    }

    func setInspectorCollapsed(_ collapsed: Bool) {
        inspectorItem.isCollapsed = collapsed
    }

    func setSidebarWidth(_ width: CGFloat) {
        guard splitView.subviews.count > 0 else { return }
        splitView.setPosition(width, ofDividerAt: 0)
    }

    var sidebarWidth: CGFloat {
        sidebarVC.view.frame.width
    }

    func togglePreviewPane() {
        previewPaneItem.animator().isCollapsed.toggle()
    }

    var isPreviewPaneVisible: Bool {
        !previewPaneItem.isCollapsed
    }

    func setPreviewPaneVisible(_ visible: Bool) {
        previewPaneItem.isCollapsed = !visible
    }

    var isDualPaneVisible: Bool {
        isDualPaneActive
    }

    var showsHiddenFiles: Bool {
        if isDualPaneActive {
            return dualPaneVC?.activePane.showHiddenFiles ?? false
        }
        return currentContentVC?.showHiddenFiles ?? false
    }

    func setShowsHiddenFiles(_ visible: Bool) {
        guard showsHiddenFiles != visible else { return }
        if isDualPaneActive {
            dualPaneVC?.activePane.setShowsHiddenFiles(visible)
        } else {
            currentContentVC?.setShowsHiddenFiles(visible)
        }
    }

    func setDualPaneVisible(_ visible: Bool) {
        guard isDualPaneActive != visible else { return }
        toggleDualPane()
    }

    var supportsToolbarSearch: Bool {
        !isDualPaneActive && (currentContentVC?.supportsToolbarSearch ?? false)
    }

    var currentCapabilities: StorageCapabilities {
        currentLocation.capabilities
    }

    var activeFileListViewController: FileListViewController? {
        guard !isDualPaneActive else { return nil }
        return currentContentVC as? FileListViewController
    }

    func setToolbarFilterText(_ text: String) {
        currentContentVC?.setToolbarFilterText(text)
    }

    func performToolbarSearch(_ query: String) {
        currentContentVC?.performToolbarSearch(query)
    }

    func clearToolbarSearch() {
        if activeFileListViewController == nil {
            fileListVC.clearToolbarSearch()
        }
        currentContentVC?.clearToolbarSearch()
    }

    func createNewFolder() {
        guard currentCapabilities.contains(.createFolder) else { return }
        if isDualPaneActive {
            dualPaneVC?.createNewFolder()
        } else {
            currentContentVC?.createNewFolder()
        }
    }

    // MARK: - View Mode Switching

    func switchViewMode(_ mode: ViewMode) {
        guard currentLocation.isLocal else { return }
        guard mode != currentViewMode || isDualPaneActive else { return }

        lastLocalViewMode = mode
        if isDualPaneActive {
            deactivateDualPane()
        }

        let currentURL = currentContentVC?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        let showHidden = currentContentVC?.showHiddenFiles ?? false

        removeSplitViewItem(contentItem)

        let newVC: NSViewController & FileViewControllerProtocol

        switch mode {
        case .list:
            let vc = FileListViewController()
            vc.delegate = self
            vc.showHiddenFiles = showHidden
            fileListVC = vc
            newVC = vc
        case .columns:
            let vc = ColumnViewController()
            vc.delegate = self
            vc.showHiddenFiles = showHidden
            newVC = vc
        case .icons:
            let vc = IconViewController()
            vc.delegate = self
            vc.showHiddenFiles = showHidden
            newVC = vc
        case .gallery:
            let vc = GalleryViewController()
            vc.delegate = self
            vc.showHiddenFiles = showHidden
            newVC = vc
        }

        contentItem = NSSplitViewItem(viewController: newVC)
        contentItem.minimumThickness = 300

        insertSplitViewItem(contentItem, at: 1)

        currentContentVC = newVC
        currentViewMode = mode

        newVC.loadDirectory(currentURL)
        navigationDelegate?.splitViewSearchSupportDidChange()
    }

    // MARK: - Dual Pane

    func toggleDualPane() {
        guard currentLocation.isLocal else { return }
        if isDualPaneActive {
            deactivateDualPane()
        } else {
            activateDualPane()
        }
    }

    private func activateDualPane() {
        let currentURL = currentContentVC?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        let showHidden = currentContentVC?.showHiddenFiles ?? false

        removeSplitViewItem(contentItem)

        let dual = DualPaneViewController()
        dual.navigationDelegate = navigationDelegate
        dual.selectionDelegate = self
        dual.leftPane.showHiddenFiles = showHidden
        dual.rightPane.showHiddenFiles = showHidden
        dualPaneVC = dual

        let dualItem = NSSplitViewItem(viewController: dual)
        dualItem.minimumThickness = 400
        dualPaneSplitViewItem = dualItem

        insertSplitViewItem(dualItem, at: 1)

        dual.loadDirectory(currentURL)
        isDualPaneActive = true
        navigationDelegate?.splitViewSearchSupportDidChange()
    }

    private func deactivateDualPane() {
        guard let dualItem = dualPaneSplitViewItem else { return }
        let currentURL = dualPaneVC?.leftPane.currentURL ?? currentContentVC?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        let showHidden = dualPaneVC?.leftPane.showHiddenFiles ?? false

        removeSplitViewItem(dualItem)
        dualPaneVC = nil
        dualPaneSplitViewItem = nil

        let vc = FileListViewController()
        vc.delegate = self
        vc.showHiddenFiles = showHidden
        fileListVC = vc
        currentContentVC = vc

        contentItem = NSSplitViewItem(viewController: vc)
        contentItem.minimumThickness = 300
        insertSplitViewItem(contentItem, at: 1)

        vc.loadDirectory(currentURL)
        isDualPaneActive = false
        currentViewMode = .list
        navigationDelegate?.splitViewSearchSupportDidChange()
    }

    // MARK: - Hidden Files Toggle forwarding

    func toggleHiddenFiles() {
        guard currentCapabilities.contains(.showHiddenFiles) else { return }
        setShowsHiddenFiles(!showsHiddenFiles)
    }

    private func ensureLocalContentController() {
        if isDualPaneActive { return }
        if currentContentVC is S3BrowserViewController {
            removeSplitViewItem(contentItem)
            let vc = localController(for: lastLocalViewMode, showHidden: lastLocalShowsHiddenFiles)
            contentItem = NSSplitViewItem(viewController: vc)
            contentItem.minimumThickness = 300
            insertSplitViewItem(contentItem, at: 1)
            currentContentVC = vc
            currentViewMode = lastLocalViewMode
            if let listVC = vc as? FileListViewController {
                fileListVC = listVC
            }
        }
    }

    private func ensureS3ContentController() {
        if isDualPaneActive {
            deactivateDualPane()
        }
        guard !(currentContentVC is S3BrowserViewController) else { return }
        removeSplitViewItem(contentItem)
        let vc = s3BrowserVC ?? S3BrowserViewController()
        vc.delegate = self
        s3BrowserVC = vc
        contentItem = NSSplitViewItem(viewController: vc)
        contentItem.minimumThickness = 300
        insertSplitViewItem(contentItem, at: 1)
        currentContentVC = vc
        currentViewMode = .list
    }

    private func localController(for mode: ViewMode, showHidden: Bool) -> NSViewController & FileViewControllerProtocol {
        let vc: NSViewController & FileViewControllerProtocol
        switch mode {
        case .list:
            let list = FileListViewController()
            list.delegate = self
            list.showHiddenFiles = showHidden
            fileListVC = list
            vc = list
        case .columns:
            let columns = ColumnViewController()
            columns.delegate = self
            columns.showHiddenFiles = showHidden
            vc = columns
        case .icons:
            let icons = IconViewController()
            icons.delegate = self
            icons.showHiddenFiles = showHidden
            vc = icons
        case .gallery:
            let gallery = GalleryViewController()
            gallery.delegate = self
            gallery.showHiddenFiles = showHidden
            vc = gallery
        }
        return vc
    }
}

extension MainSplitViewController: SidebarViewControllerDelegate {
    func sidebarDidSelect(url: URL) {
        navigationDelegate?.splitViewDidNavigate(to: url)
    }

    func sidebarDidSelect(location: StorageLocation) {
        navigationDelegate?.splitViewDidNavigate(to: location)
    }
}

extension MainSplitViewController: FileListViewControllerDelegate {
    func fileListDidNavigate(to url: URL) {
        navigationDelegate?.splitViewDidNavigate(to: url)
    }

    func fileListDidNavigate(to location: StorageLocation) {
        navigationDelegate?.splitViewDidNavigate(to: location)
    }

    func fileListDidSelect(items: [FileItem]) {
        inspectorVC.updateSelection(items.map(BrowserItem.local))
        previewPaneVC.updateSelection(items.first)
    }

    func fileListDidSelect(browserItems: [BrowserItem]) {
        inspectorVC.updateSelection(browserItems)
        let localItems = browserItems.compactMap(\.fileItem)
        previewPaneVC.updateSelection(localItems.first)
    }
}
