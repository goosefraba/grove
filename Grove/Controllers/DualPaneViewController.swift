import AppKit

final class DualPaneViewController: NSViewController {

    private let splitView = NSSplitView()
    let leftPane = FileListViewController()
    let rightPane = FileListViewController()
    private(set) var activePane: FileListViewController

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

        leftPane.onBecomeFirstResponder = { [weak self] in
            guard let self else { return }
            self.setActivePane(self.leftPane)
        }
        rightPane.onBecomeFirstResponder = { [weak self] in
            guard let self else { return }
            self.setActivePane(self.rightPane)
        }
    }

    func loadDirectory(_ url: URL) {
        leftPane.loadDirectory(url)
        rightPane.loadDirectory(url)
    }

    /// Loads a directory into only the active pane (used for all navigation
    /// after the initial dual-pane activation, which loads both panes).
    func loadActivePane(_ url: URL) {
        activePane.loadDirectory(url)
    }

    func createNewFolder() {
        activePane.createNewFolder()
    }

    func switchActivePane() {
        let target = (activePane === leftPane) ? rightPane : leftPane
        target.focusFileList()
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd+Option+Left / Cmd+Option+Right toggle the active pane. Command-modified
        // keys are dispatched as key equivalents and never reach keyDown, so handle
        // them here. Tab is left to the focused table view for intra-pane navigation.
        if mods == [.command, .option], event.keyCode == 123 || event.keyCode == 124 {
            switchActivePane()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - FileListViewControllerDelegate

extension DualPaneViewController: FileListViewControllerDelegate {
    func fileListDidNavigate(to url: URL) {
        navigationDelegate?.splitViewDidNavigate(to: url)
    }

    func fileListDidSelect(items: [FileItem]) {
        selectionDelegate?.fileListDidSelect(items: items)
    }
}
