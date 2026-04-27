import AppKit

final class DualPaneViewController: NSViewController {

    private let splitView = NSSplitView()
    let leftPane = FileListViewController()
    let rightPane = FileListViewController()
    private var activePane: FileListViewController

    private let leftContainer = NSView()
    private let rightContainer = NSView()

    weak var navigationDelegate: MainSplitViewControllerDelegate?
    weak var selectionDelegate: FileListViewControllerDelegate?

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        activePane = leftPane
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 800, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSplitView()
        setupPanes()
        updateActivePaneHighlight()
    }

    private func setupSplitView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupPanes() {
        leftContainer.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.translatesAutoresizingMaskIntoConstraints = false

        leftContainer.wantsLayer = true
        rightContainer.wantsLayer = true

        splitView.addSubview(leftContainer)
        splitView.addSubview(rightContainer)

        addChild(leftPane)
        leftPane.view.translatesAutoresizingMaskIntoConstraints = false
        leftContainer.addSubview(leftPane.view)

        addChild(rightPane)
        rightPane.view.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.addSubview(rightPane.view)

        NSLayoutConstraint.activate([
            leftPane.view.topAnchor.constraint(equalTo: leftContainer.topAnchor),
            leftPane.view.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor),
            leftPane.view.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
            leftPane.view.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor),

            rightPane.view.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            rightPane.view.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
            rightPane.view.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            rightPane.view.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
        ])

        leftPane.delegate = self
        rightPane.delegate = self
    }

    func loadDirectory(_ url: URL) {
        leftPane.loadDirectory(url)
        rightPane.loadDirectory(url)
    }

    func setShowsHiddenFiles(_ visible: Bool) {
        leftPane.setShowsHiddenFiles(visible)
        rightPane.setShowsHiddenFiles(visible)
    }

    func switchActivePane() {
        setActivePane((activePane === leftPane) ? rightPane : leftPane)
        view.window?.makeFirstResponder(activePane.view)
    }

    private func setActivePane(_ pane: FileListViewController) {
        guard activePane !== pane else { return }
        activePane = pane
        updateActivePaneHighlight()
    }

    private func updateActivePaneHighlight() {
        let activeColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        let inactiveColor = CGColor.clear

        leftContainer.layer?.backgroundColor = (activePane === leftPane) ? activeColor : inactiveColor
        rightContainer.layer?.backgroundColor = (activePane === rightPane) ? activeColor : inactiveColor

        leftContainer.layer?.borderColor = (activePane === leftPane) ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : CGColor.clear
        leftContainer.layer?.borderWidth = (activePane === leftPane) ? 1 : 0

        rightContainer.layer?.borderColor = (activePane === rightPane) ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : CGColor.clear
        rightContainer.layer?.borderWidth = (activePane === rightPane) ? 1 : 0
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48: // Tab
            switchActivePane()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - FileListViewControllerDelegate

extension DualPaneViewController: FileListViewControllerDelegate {
    func fileListDidNavigate(to url: URL) {
        navigationDelegate?.splitViewDidNavigate(to: url)
    }

    func fileListDidSelect(items: [FileItem]) {
        if leftPane.selectedItems == items, rightPane.selectedItems != items {
            setActivePane(leftPane)
        } else if rightPane.selectedItems == items, leftPane.selectedItems != items {
            setActivePane(rightPane)
        }
        selectionDelegate?.fileListDidSelect(items: items)
    }
}
