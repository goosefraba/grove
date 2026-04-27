import AppKit

final class IconViewController: NSViewController, FileViewControllerProtocol,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {

    weak var delegate: FileListViewControllerDelegate?

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let statusBar = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Empty Folder")

    private var items: [FileItem] = []
    private(set) var currentURL: URL = FileManager.default.homeDirectoryForCurrentUser
    var showHiddenFiles: Bool = false

    private var watcher: DirectoryWatcher?
    private var reloadWorkItem: DispatchWorkItem?

    private var sortKey: String = "name"
    private var sortAscending: Bool = true

    private static let itemIdentifier = NSUserInterfaceItemIdentifier("IconItem")

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 600, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        setupStatusBar()
        setupEmptyLabel()
        loadDirectory(currentURL)
    }

    private func setupCollectionView() {
        let flowLayout = NSCollectionViewFlowLayout()
        flowLayout.itemSize = NSSize(width: 90, height: 80)
        flowLayout.minimumInteritemSpacing = 8
        flowLayout.minimumLineSpacing = 8
        flowLayout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]

        collectionView.register(IconCollectionViewItem.self, forItemWithIdentifier: Self.itemIdentifier)

        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
    }

    private func setupStatusBar() {
        statusBar.font = .systemFont(ofSize: 11)
        statusBar.textColor = .secondaryLabelColor
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        view.addSubview(statusBar)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -4),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            statusBar.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func setupEmptyLabel() {
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    func loadDirectory(_ url: URL) {
        currentURL = url

        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] _ in
            self?.scheduleReload()
        }

        reloadContents()
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadContents()
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reloadContents() {
        let selectedURLs = Set(selectedItems.map(\.url))
        do {
            items = try FileOperationService.shared.contentsOfDirectory(at: currentURL, showHidden: showHiddenFiles)
            sortItems()
            collectionView.reloadData()
            // Restore selection
            let newSelection = Set(items.indices.filter { selectedURLs.contains(items[$0].url) }.map {
                IndexPath(item: $0, section: 0)
            })
            if !newSelection.isEmpty {
                collectionView.selectionIndexPaths = newSelection
            }
            updateStatusBar()
            emptyLabel.stringValue = "This folder is empty"
            emptyLabel.isHidden = !items.isEmpty
        } catch {
            items = []
            collectionView.reloadData()
            updateStatusBar()
            emptyLabel.stringValue = "Unable to load folder contents."
            emptyLabel.isHidden = false
        }
    }

    private func sortItems() {
        items.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            let result: Bool
            switch sortKey {
            case "name":
                result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case "date":
                result = a.dateModified < b.dateModified
            case "size":
                result = a.size < b.size
            case "kind":
                result = a.kind.localizedCaseInsensitiveCompare(b.kind) == .orderedAscending
            default:
                result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return sortAscending ? result : !result
        }
    }

    func toggleHiddenFiles() {
        showHiddenFiles.toggle()
        reloadContents()
    }

    var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths.compactMap { indexPath in
            let row = indexPath.item
            return row < items.count ? items[row] : nil
        }
    }

    private func selectItem(at url: URL) {
        guard let index = items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [indexPath]
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
        delegate?.fileListDidSelect(items: selectedItems)
        updateStatusBar()
    }

    private func renameSelectedFile() {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        FileRenameHelper.presentRenameSheet(for: item, from: self) { [weak self] newURL in
            self?.reloadContents()
            self?.selectItem(at: newURL)
        }
    }

    private func updateStatusBar() {
        let count = items.count
        let selectedCount = collectionView.selectionIndexPaths.count
        let itemText = count == 1 ? "1 item" : "\(count) items"
        let selectionText = selectedCount > 0 ? " (\(selectedCount) selected)" : ""
        let diskSpace = FileOperationService.shared.availableDiskSpace(at: currentURL) ?? ""
        let spaceText = diskSpace.isEmpty ? "" : "  —  \(diskSpace) available"
        statusBar.stringValue = "\(itemText)\(selectionText)\(spaceText)"
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: indexPath)
        guard let iconItem = item as? IconCollectionViewItem, indexPath.item < items.count else { return item }

        let fileItem = items[indexPath.item]
        iconItem.configure(with: fileItem)
        return iconItem
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        delegate?.fileListDidSelect(items: selectedItems)
        updateStatusBar()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        delegate?.fileListDidSelect(items: selectedItems)
        updateStatusBar()
    }

    // Double-click handling
    override func viewDidAppear() {
        super.viewDidAppear()
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(collectionViewDoubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)
    }

    @objc private func collectionViewDoubleClicked(_ sender: NSClickGestureRecognizer) {
        let point = sender.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              indexPath.item < items.count else { return }

        let item = items[indexPath.item]
        if item.isDirectory && !item.isPackage {
            delegate?.fileListDidNavigate(to: item.url.resolvingSymlinksInPath())
        } else {
            FileOperationService.shared.openFile(item.url)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.control) {
            renameSelectedFile()
            return
        }

        super.keyDown(with: event)
    }

    // MARK: - Drag and Drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard indexPath.item < items.count else { return nil }
        return items[indexPath.item].url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let index = proposedDropIndexPath.pointee.item

        // If dropping on a specific item, only accept if it's a navigable directory
        if proposedDropOperation.pointee == .on {
            if index < items.count && items[index].isDirectory && !items[index].isPackage {
                return draggingInfo.draggingSourceOperationMask.contains(.move) ? .move : .copy
            }
            // Re-target to the whole collection (drop into current directory)
            proposedDropOperation.pointee = .before
            return draggingInfo.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }

        return draggingInfo.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }

        let destination: URL
        if dropOperation == .on && indexPath.item < items.count && items[indexPath.item].isDirectory {
            destination = items[indexPath.item].url
        } else {
            destination = currentURL
        }

        do {
            let conflictPrompt = FileConflictResolutionPrompt(window: view.window)
            if draggingInfo.draggingSourceOperationMask.contains(.move) {
                _ = try FileOperationService.shared.moveResolvingConflicts(urls, to: destination) { conflict in
                    conflictPrompt.resolve(conflict)
                }
            } else {
                _ = try FileOperationService.shared.copyResolvingConflicts(urls, to: destination) { conflict in
                    conflictPrompt.resolve(conflict)
                }
            }
            reloadContents()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    private func showError(_ error: Error) {
        guard let window = view.window else {
            let alert = NSAlert(error: error)
            alert.runModal()
            return
        }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}

// MARK: - IconCollectionViewItem

final class IconCollectionViewItem: NSCollectionViewItem {

    private let iconImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 80))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconImageView)

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconImageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            iconImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 48),
            iconImageView.heightAnchor.constraint(equalToConstant: 48),

            nameLabel.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
        ])
    }

    func configure(with fileItem: FileItem) {
        let icon = NSWorkspace.shared.icon(forFile: fileItem.url.path)
        icon.size = NSSize(width: 48, height: 48)
        iconImageView.image = icon
        nameLabel.stringValue = fileItem.name
    }

    override var isSelected: Bool {
        didSet {
            if isSelected {
                view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
                view.layer?.cornerRadius = 6
            } else {
                view.layer?.backgroundColor = nil
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        view.wantsLayer = true
    }
}
