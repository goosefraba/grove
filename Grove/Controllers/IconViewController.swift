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
    private var loadGeneration: UInt = 0

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
        flowLayout.itemSize = GroveUI.iconItemSize
        flowLayout.minimumInteritemSpacing = 6
        flowLayout.minimumLineSpacing = 6
        flowLayout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]

        collectionView.register(IconCollectionViewItem.self, forItemWithIdentifier: Self.itemIdentifier)
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(collectionViewDoubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let contextMenu = FileContextMenuBuilder.makeMenu()
        contextMenu.delegate = self
        collectionView.menu = contextMenu

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
    }

    private func setupStatusBar() {
        GroveUI.configureFooterStatusLabel(statusBar)
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
        emptyLabel.font = .systemFont(ofSize: GroveUI.emptyFontSize)
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
        reloadWorkItem?.cancel()
        currentURL = url
        clearLoadedItemsForPendingLoad(message: "Loading folder contents...")

        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] _ in
            self?.scheduleReload()
        }

        reloadContents(preserveSelection: false)
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadContents()
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reloadContents(preserveSelection: Bool = true) {
        loadGeneration += 1
        let generation = loadGeneration
        let requestURL = currentURL.standardizedFileURL
        let requestShowHiddenFiles = showHiddenFiles
        let selectedURLs = preserveSelection ? Set(selectedItems.map(\.url)) : []

        FileOperationService.shared.contentsOfDirectoryAsync(at: requestURL, showHidden: requestShowHiddenFiles) { [weak self] result in
            guard let self = self,
                  self.loadGeneration == generation,
                  self.currentURL.standardizedFileURL == requestURL,
                  self.showHiddenFiles == requestShowHiddenFiles else { return }

            switch result {
            case .success(let loadedItems):
                self.items = FileItem.sorted(loadedItems, key: self.sortKey, ascending: self.sortAscending)
                self.collectionView.reloadData()
            // Restore selection
                let newSelection = Set(self.items.indices.filter { selectedURLs.contains(self.items[$0].url) }.map {
                    IndexPath(item: $0, section: 0)
                })
                if !newSelection.isEmpty {
                    self.collectionView.selectionIndexPaths = newSelection
                }
                self.updateStatusBar()
                self.emptyLabel.stringValue = "This folder is empty"
                self.emptyLabel.isHidden = !self.items.isEmpty
            case .failure:
                self.items = []
                self.collectionView.reloadData()
                self.updateStatusBar()
                self.emptyLabel.stringValue = "Unable to load folder contents."
                self.emptyLabel.isHidden = false
            }
        }
    }

    private func clearLoadedItemsForPendingLoad(message: String) {
        items = []
        collectionView.selectionIndexPaths = []
        collectionView.reloadData()
        updateStatusBar()
        delegate?.fileListDidSelect(items: [])
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    private func sortItems() {
        FileItem.sort(&items, key: sortKey, ascending: sortAscending)
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
        let diskSpace = LocalFooterDiskSpaceCache.shared.diskSpace(at: currentURL)
        statusBar.stringValue = LocalFooterStatusFormatter.string(
            totalItemCount: count,
            selectedItemCount: selectedCount,
            availableDiskSpace: diskSpace
        )
        LocalFooterDiskSpaceCache.shared.refreshIfNeeded(at: currentURL) { [weak self] refreshedURL in
            guard let self,
                  self.currentURL.standardizedFileURL == refreshedURL.standardizedFileURL else { return }
            self.updateStatusBar()
        }
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

    // MARK: - File operation responders

    @objc func copy(_ sender: Any?) { copySelectedFiles() }
    @objc func cut(_ sender: Any?) { cutSelectedFiles() }
    @objc func paste(_ sender: Any?) { pasteFiles() }

    // MARK: - Drag and Drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard indexPath.item < items.count else { return nil }
        return items[indexPath.item].url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard draggingInfo.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        let index = proposedDropIndexPath.pointee.item

        // If dropping on a specific item, only accept if it's a navigable directory
        if proposedDropOperation.pointee == .on {
            if index < items.count && items[index].isDirectory && !items[index].isPackage {
                return FileDropOperationResolver.preferredOperation(from: draggingInfo.draggingSourceOperationMask)
            }
            // Re-target to the whole collection (drop into current directory)
            proposedDropOperation.pointee = .before
            return FileDropOperationResolver.preferredOperation(from: draggingInfo.draggingSourceOperationMask)
        }

        return FileDropOperationResolver.preferredOperation(from: draggingInfo.draggingSourceOperationMask)
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
            let records: [FileOperationService.FileTransferRecord]
            let operation = FileDropOperationResolver.preferredOperation(from: draggingInfo.draggingSourceOperationMask)
            let isMove = FileDropOperationResolver.isMove(operation)
            if isMove {
                records = try FileOperationService.shared.moveResolvingConflictsWithRecords(urls, to: destination) { conflict in
                    conflictPrompt.resolve(conflict)
                }
            } else {
                records = try FileOperationService.shared.copyResolvingConflictsWithRecords(urls, to: destination) { conflict in
                    conflictPrompt.resolve(conflict)
                }
            }
            registerUndoTransfer(records: records, actionName: isMove ? "Move" : "Copy")
            reloadContents()
            return true
        } catch FileOperationService.FileOperationError.partialFailure(let records, let underlying) {
            let isMove = FileDropOperationResolver.isMove(FileDropOperationResolver.preferredOperation(from: draggingInfo.draggingSourceOperationMask))
            registerUndoTransfer(records: records, actionName: isMove ? "Move" : "Copy")
            showError(underlying)
            return false
        } catch {
            showError(error)
            return false
        }
    }

    private func registerUndoTransfer(records: [FileOperationService.FileTransferRecord], actionName: String) {
        let undoableRecords = records.filter(\.isUndoable)
        guard !undoableRecords.isEmpty, let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            do {
                try FileOperationService.shared.undoTransferRecords(undoableRecords)
            } catch {
                target.showError(error)
            }
        }
        undoManager.setActionName(actionName)
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

// MARK: - Context menu

extension IconViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let event = NSApp.currentEvent else { return }
        let point = collectionView.convert(event.locationInWindow, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              !collectionView.selectionIndexPaths.contains(indexPath) else { return }
        collectionView.selectionIndexPaths = [indexPath]
        delegate?.fileListDidSelect(items: selectedItems)
        updateStatusBar()
    }
}

extension IconViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateFileOperationMenuItem(menuItem)
    }
}

// MARK: - IconCollectionViewItem

final class IconCollectionViewItem: NSCollectionViewItem {

    private let iconImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: GroveUI.iconItemSize))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Enable the layer up front so selection styling applied before first layout isn't dropped.
        view.wantsLayer = true

        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconImageView)

        nameLabel.font = .systemFont(ofSize: GroveUI.iconLabelFontSize)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconImageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            iconImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: GroveUI.iconSize),
            iconImageView.heightAnchor.constraint(equalToConstant: GroveUI.iconSize),

            nameLabel.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
        ])
    }

    func configure(with fileItem: FileItem) {
        iconImageView.image = ThumbnailCache.shared.icon(
            for: fileItem.url,
            size: NSSize(width: GroveUI.iconSize, height: GroveUI.iconSize)
        )
        nameLabel.stringValue = fileItem.name
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        if isSelected {
            view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            view.layer?.cornerRadius = 6
        } else {
            view.layer?.backgroundColor = nil
        }
    }
}
