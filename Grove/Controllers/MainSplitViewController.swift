import AppKit

protocol MainSplitViewControllerDelegate: AnyObject {
    func splitViewDidNavigate(to url: URL)
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
        if isDualPaneActive {
            dualPaneVC?.loadDirectory(url)
        } else {
            currentContentVC?.loadDirectory(url)
        }
        sidebarVC.selectItem(for: url)
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
            return dualPaneVC?.leftPane.showHiddenFiles ?? false
        }
        return currentContentVC?.showHiddenFiles ?? false
    }

    func setShowsHiddenFiles(_ visible: Bool) {
        guard showsHiddenFiles != visible else { return }
        toggleHiddenFiles()
    }

    func setDualPaneVisible(_ visible: Bool) {
        guard isDualPaneActive != visible else { return }
        toggleDualPane()
    }

    // MARK: - View Mode Switching

    func switchViewMode(_ mode: ViewMode) {
        guard mode != currentViewMode || isDualPaneActive else { return }

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
    }

    // MARK: - Dual Pane

    func toggleDualPane() {
        if isDualPaneActive {
            deactivateDualPane()
        } else {
            activateDualPane()
        }
    }

    private func activateDualPane() {
        let currentURL = currentContentVC?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser

        removeSplitViewItem(contentItem)

        let dual = DualPaneViewController()
        dual.navigationDelegate = navigationDelegate
        dual.selectionDelegate = self
        dualPaneVC = dual

        let dualItem = NSSplitViewItem(viewController: dual)
        dualItem.minimumThickness = 400
        dualPaneSplitViewItem = dualItem

        insertSplitViewItem(dualItem, at: 1)

        dual.loadDirectory(currentURL)
        isDualPaneActive = true
    }

    private func deactivateDualPane() {
        guard let dualItem = dualPaneSplitViewItem else { return }
        removeSplitViewItem(dualItem)
        dualPaneVC = nil
        dualPaneSplitViewItem = nil

        let currentURL = currentContentVC?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser

        let vc = FileListViewController()
        vc.delegate = self
        fileListVC = vc
        currentContentVC = vc

        contentItem = NSSplitViewItem(viewController: vc)
        contentItem.minimumThickness = 300
        insertSplitViewItem(contentItem, at: 1)

        vc.loadDirectory(currentURL)
        isDualPaneActive = false
        currentViewMode = .list
    }

    // MARK: - Hidden Files Toggle forwarding

    func toggleHiddenFiles() {
        if isDualPaneActive {
            dualPaneVC?.leftPane.toggleHiddenFiles()
            dualPaneVC?.rightPane.toggleHiddenFiles()
        } else {
            currentContentVC?.toggleHiddenFiles()
        }
    }
}

extension MainSplitViewController: SidebarViewControllerDelegate {
    func sidebarDidSelect(url: URL) {
        navigationDelegate?.splitViewDidNavigate(to: url)
    }
}

extension MainSplitViewController: FileListViewControllerDelegate {
    func fileListDidNavigate(to url: URL) {
        navigationDelegate?.splitViewDidNavigate(to: url)
    }

    func fileListDidSelect(items: [FileItem]) {
        inspectorVC.updateSelection(items)
        previewPaneVC.updateSelection(items.first)
    }
}
