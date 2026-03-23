import AppKit

protocol MainSplitViewControllerDelegate: AnyObject {
    func splitViewDidNavigate(to url: URL)
}

final class MainSplitViewController: NSSplitViewController {

    weak var navigationDelegate: MainSplitViewControllerDelegate?

    let sidebarVC = SidebarViewController()
    let fileListVC = FileListViewController()
    let inspectorVC = InspectorViewController()

    private var inspectorItem: NSSplitViewItem!

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebarVC.delegate = self
        fileListVC.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 150
        sidebarItem.canCollapse = true

        let contentItem = NSSplitViewItem(viewController: fileListVC)
        contentItem.minimumThickness = 300

        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        inspectorItem.minimumThickness = 200
        inspectorItem.maximumThickness = 350
        inspectorItem.isCollapsed = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
    }

    func navigate(to url: URL) {
        fileListVC.loadDirectory(url)
        sidebarVC.selectItem(for: url)
    }

    func toggleInspector() {
        inspectorItem.animator().isCollapsed.toggle()
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

    func fileListDidSelect(item: FileItem?) {
        inspectorVC.updateSelection(item)
    }
}
