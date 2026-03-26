import AppKit
import QuickLookUI
import UniformTypeIdentifiers

protocol FileListViewControllerDelegate: AnyObject {
    func fileListDidNavigate(to url: URL)
    func fileListDidSelect(items: [FileItem])
}

final class FileListViewController: NSViewController, FileViewControllerProtocol,
    NSTableViewDataSource, NSTableViewDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    weak var delegate: FileListViewControllerDelegate?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let statusBar = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Empty Folder")
    private let searchScopeLabel = NSTextField(labelWithString: "")
    private let loadingSpinner = NSProgressIndicator()

    private var allItems: [FileItem] = []
    private var items: [FileItem] = []
    private var sortKey: String = "name"
    private var sortAscending: Bool = true
    private(set) var currentURL: URL = FileManager.default.homeDirectoryForCurrentUser
    var showHiddenFiles: Bool = false
    private var isShowingSearchResults: Bool = false

    var filterText: String = "" {
        didSet {
            applyFilter()
        }
    }

    private var fileUndoManager: UndoManager? {
        view.window?.undoManager
    }

    private var watcher: DirectoryWatcher?
    private var reloadWorkItem: DispatchWorkItem?
    private var clipboard: (urls: [URL], isCut: Bool)?
    private var editingRow: Int = -1

    // Column identifiers
    private let nameColumn = NSUserInterfaceItemIdentifier("NameColumn")
    private let dateColumn = NSUserInterfaceItemIdentifier("DateColumn")
    private let sizeColumn = NSUserInterfaceItemIdentifier("SizeColumn")
    private let kindColumn = NSUserInterfaceItemIdentifier("KindColumn")

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 600, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTableView()
        setupStatusBar()
        setupEmptyLabel()
        setupLoadingSpinner()
        setupSearchScopeLabel()
        setupAccessibility()
        loadDirectory(currentURL)
    }

    private func setupTableView() {
        let nameCol = NSTableColumn(identifier: nameColumn)
        nameCol.title = "Name"
        nameCol.width = 300
        nameCol.minWidth = 150
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        tableView.addTableColumn(nameCol)

        let dateCol = NSTableColumn(identifier: dateColumn)
        dateCol.title = "Date Modified"
        dateCol.width = 160
        dateCol.minWidth = 100
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: false)
        tableView.addTableColumn(dateCol)

        let sizeCol = NSTableColumn(identifier: sizeColumn)
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 60
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
        tableView.addTableColumn(sizeCol)

        let kindCol = NSTableColumn(identifier: kindColumn)
        kindCol.title = "Kind"
        kindCol.width = 120
        kindCol.minWidth = 80
        kindCol.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        tableView.addTableColumn(kindCol)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .fullWidth
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))
        tableView.target = self

        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
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

    private func setupLoadingSpinner() {
        loadingSpinner.style = .spinning
        loadingSpinner.isIndeterminate = true
        loadingSpinner.controlSize = .regular
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.isHidden = true
        view.addSubview(loadingSpinner)

        NSLayoutConstraint.activate([
            loadingSpinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    private func setupSearchScopeLabel() {
        searchScopeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        searchScopeLabel.textColor = .secondaryLabelColor
        searchScopeLabel.backgroundColor = .controlBackgroundColor
        searchScopeLabel.drawsBackground = true
        searchScopeLabel.alignment = .center
        searchScopeLabel.translatesAutoresizingMaskIntoConstraints = false
        searchScopeLabel.isHidden = true
        view.addSubview(searchScopeLabel)

        NSLayoutConstraint.activate([
            searchScopeLabel.topAnchor.constraint(equalTo: view.topAnchor),
            searchScopeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchScopeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchScopeLabel.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func setupAccessibility() {
        tableView.setAccessibilityRole(.table)
        tableView.setAccessibilityLabel("File list")
        tableView.setAccessibilityIdentifier("fileListTable")
        scrollView.setAccessibilityIdentifier("fileListScrollView")
        statusBar.setAccessibilityIdentifier("fileListStatusBar")
        emptyLabel.setAccessibilityIdentifier("fileListEmptyLabel")
    }

    // MARK: - Search & Filter

    func applyFilter() {
        if filterText.isEmpty {
            items = allItems
        } else {
            items = allItems.filter {
                $0.name.localizedCaseInsensitiveContains(filterText)
            }
        }
        sortItems()
        tableView.reloadData()
        updateStatusBar()
        emptyLabel.isHidden = !items.isEmpty
        if items.isEmpty && !filterText.isEmpty {
            emptyLabel.stringValue = "No items match \"\(filterText)\""
        }
    }

    func performSpotlightSearch(_ query: String) {
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        isShowingSearchResults = true
        searchScopeLabel.stringValue = "Searching in: \(currentURL.lastPathComponent)"
        searchScopeLabel.isHidden = false
        updateScrollViewTop()

        SearchService.shared.search(query: query, in: currentURL) { [weak self] results in
            guard let self = self, self.isShowingSearchResults else { return }
            self.allItems = results
            self.items = results
            self.sortItems()
            self.tableView.reloadData()
            self.updateStatusBar()
            self.emptyLabel.isHidden = !results.isEmpty
            if results.isEmpty {
                self.emptyLabel.stringValue = "No results for \"\(query)\""
            }
        }
    }

    func clearSearch() {
        isShowingSearchResults = false
        searchScopeLabel.isHidden = true
        updateScrollViewTop()
        SearchService.shared.stop()
        filterText = ""
        reloadContents()
    }

    private func updateScrollViewTop() {
        for constraint in view.constraints {
            if constraint.firstItem === scrollView && constraint.firstAnchor === scrollView.topAnchor {
                constraint.isActive = false
            }
        }
        if searchScopeLabel.isHidden {
            scrollView.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        } else {
            scrollView.topAnchor.constraint(equalTo: searchScopeLabel.bottomAnchor).isActive = true
        }
        view.needsLayout = true
    }

    // MARK: - Directory Loading

    func loadDirectory(_ url: URL) {
        currentURL = url
        filterText = ""
        isShowingSearchResults = false
        searchScopeLabel.isHidden = true
        SearchService.shared.stop()

        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] in
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
        guard !isShowingSearchResults else { return }
        let selectedURLs = Set(selectedItems.map(\.url))

        loadingSpinner.isHidden = false
        loadingSpinner.startAnimation(nil)
        emptyLabel.isHidden = true

        FileOperationService.shared.contentsOfDirectoryAsync(at: currentURL, showHidden: showHiddenFiles) { [weak self] result in
            guard let self = self else { return }
            self.loadingSpinner.stopAnimation(nil)
            self.loadingSpinner.isHidden = true

            switch result {
            case .success(let loadedItems):
                self.allItems = loadedItems
                self.applyFilter()
                // Restore selection
                let newSelection = IndexSet(self.items.indices.filter { selectedURLs.contains(self.items[$0].url) })
                if !newSelection.isEmpty {
                    self.tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
                }
                if self.items.isEmpty && self.filterText.isEmpty {
                    self.emptyLabel.stringValue = "This folder is empty"
                    self.emptyLabel.isHidden = false
                }
                // Folder sizes calculated on-demand for visible rows only
            case .failure(let error):
                self.allItems = []
                self.items = []
                self.tableView.reloadData()
                self.updateStatusBar()
                if let nsError = error as NSError?, nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
                    self.emptyLabel.stringValue = "You don't have permission to access this folder."
                } else {
                    self.emptyLabel.stringValue = "Unable to load folder contents."
                }
                self.emptyLabel.isHidden = false
            }
        }
    }

    private func sortItems() {
        items.sort { a, b in
            // Directories first
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

    private func updateStatusBar() {
        let count = items.count
        let selectedCount = tableView.selectedRowIndexes.count
        let itemText = count == 1 ? "1 item" : "\(count) items"
        let selectionText = selectedCount > 0 ? " (\(selectedCount) selected)" : ""
        let diskSpace = FileOperationService.shared.availableDiskSpace(at: currentURL) ?? ""
        let spaceText = diskSpace.isEmpty ? "" : "  —  \(diskSpace) available"
        statusBar.stringValue = "\(itemText)\(selectionText)\(spaceText)"
    }

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { row in
            row < items.count ? items[row] : nil
        }
    }

    // MARK: - Actions

    @objc private func tableViewDoubleClicked(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]

        if item.isDirectory && !item.isPackage {
            delegate?.fileListDidNavigate(to: item.url.resolvingSymlinksInPath())
        } else {
            FileOperationService.shared.openFile(item.url)
        }
    }

    func copySelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        clipboard = (urls: urls, isCut: false)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    func cutSelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        clipboard = (urls: urls, isCut: true)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    func pasteFiles() {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else { return }

        let isCut = clipboard?.isCut == true && clipboard?.urls == urls
        let destination = currentURL

        // Use progress sheet for operations with more than 3 files
        if urls.count > 3, let window = view.window {
            let progressVC = FileProgressViewController()

            presentAsSheet(progressVC)

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    if isCut {
                        try FileOperationService.shared.moveWithProgress(urls, to: destination, progress: { value, name in
                            DispatchQueue.main.async {
                                progressVC.updateProgress(value, fileName: name)
                            }
                        }, cancelled: { progressVC.isCancelled })
                        DispatchQueue.main.async {
                            self?.clipboard = nil
                            self?.registerUndoMove(originalURLs: urls, destination: destination)
                        }
                    } else {
                        try FileOperationService.shared.copyWithProgress(urls, to: destination, progress: { value, name in
                            DispatchQueue.main.async {
                                progressVC.updateProgress(value, fileName: name)
                            }
                        }, cancelled: { progressVC.isCancelled })
                        DispatchQueue.main.async {
                            let copiedURLs = urls.map { destination.appendingPathComponent($0.lastPathComponent) }
                            self?.registerUndoCopy(copiedURLs: copiedURLs)
                        }
                    }
                    DispatchQueue.main.async {
                        window.endSheet(window.attachedSheet ?? NSWindow())
                        self?.dismiss(progressVC)
                    }
                } catch {
                    DispatchQueue.main.async {
                        window.endSheet(window.attachedSheet ?? NSWindow())
                        self?.dismiss(progressVC)
                        self?.showError(error)
                    }
                }
            }
        } else {
            do {
                if isCut {
                    try FileOperationService.shared.move(urls, to: destination)
                    clipboard = nil
                    registerUndoMove(originalURLs: urls, destination: destination)
                } else {
                    try FileOperationService.shared.copy(urls, to: destination)
                    let copiedURLs = urls.map { destination.appendingPathComponent($0.lastPathComponent) }
                    registerUndoCopy(copiedURLs: copiedURLs)
                }
            } catch {
                showError(error)
            }
        }
    }

    func deleteSelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Are you sure you want to move \"\(urls[0].lastPathComponent)\" to the Trash?"
            : "Are you sure you want to move \(urls.count) items to the Trash?"
        alert.informativeText = "You can restore items from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                let trashURLs = try FileOperationService.shared.moveToTrash(urls)
                self?.registerUndoTrash(originalURLs: urls, trashURLs: trashURLs)
            } catch {
                self?.showError(error)
            }
        }
    }

    func createNewFolder() {
        do {
            let folderURL = try FileOperationService.shared.createNewFolder(in: currentURL)
            reloadContents()
            // Select and start renaming the new folder
            if let index = items.firstIndex(where: { $0.url == folderURL }) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                tableView.scrollRowToVisible(index)
                startRenaming(at: index)
            }
        } catch {
            showError(error)
        }
    }

    func openSelectedFile() {
        for item in selectedItems {
            if item.isDirectory && !item.isPackage {
                delegate?.fileListDidNavigate(to: item.url.resolvingSymlinksInPath())
                return
            } else {
                FileOperationService.shared.openFile(item.url)
            }
        }
    }

    func startRenaming(at row: Int) {
        guard row >= 0, row < items.count else { return }
        guard let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let textField = cellView.textField else { return }
        editingRow = row
        textField.isEditable = true
        textField.delegate = self
        textField.selectText(nil)
        view.window?.makeFirstResponder(textField)
    }

    func toggleHiddenFiles() {
        showHiddenFiles.toggle()
        reloadContents()
    }

    func duplicateSelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }

        var duplicatedURLs: [URL] = []
        do {
            for url in urls {
                let newURL = try FileOperationService.shared.duplicate(url)
                duplicatedURLs.append(newURL)
            }
            registerUndoCopy(copiedURLs: duplicatedURLs)
        } catch {
            showError(error)
        }
    }

    func batchRenameSelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard urls.count > 1 else { return }

        let batchVC = BatchRenameViewController(urls: urls)
        batchVC.delegate = self
        presentAsSheet(batchVC)
    }

    // MARK: - Undo Registration

    private func registerUndoTrash(originalURLs: [URL], trashURLs: [URL]) {
        guard let undoManager = fileUndoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            do {
                for (original, trashURL) in zip(originalURLs, trashURLs) {
                    let destination = original.deletingLastPathComponent()
                    try FileOperationService.shared.move([trashURL], to: destination)
                }
            } catch {
                target.showError(error)
            }
        }
        undoManager.setActionName("Move to Trash")
    }

    private func registerUndoMove(originalURLs: [URL], destination: URL) {
        guard let undoManager = fileUndoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            do {
                let movedURLs = originalURLs.map { destination.appendingPathComponent($0.lastPathComponent) }
                for (movedURL, original) in zip(movedURLs, originalURLs) {
                    let originalDir = original.deletingLastPathComponent()
                    try FileOperationService.shared.move([movedURL], to: originalDir)
                }
            } catch {
                target.showError(error)
            }
        }
        undoManager.setActionName("Move")
    }

    private func registerUndoRename(originalURL: URL, newURL: URL) {
        guard let undoManager = fileUndoManager else { return }
        let originalName = originalURL.lastPathComponent
        undoManager.registerUndo(withTarget: self) { target in
            do {
                _ = try FileOperationService.shared.rename(newURL, to: originalName)
            } catch {
                target.showError(error)
            }
        }
        undoManager.setActionName("Rename")
    }

    private func registerUndoCopy(copiedURLs: [URL]) {
        guard let undoManager = fileUndoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            do {
                _ = try FileOperationService.shared.moveToTrash(copiedURLs)
            } catch {
                target.showError(error)
            }
        }
        undoManager.setActionName("Copy")
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

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        sortKey = key
        sortAscending = descriptor.ascending
        sortItems()
        tableView.reloadData()

        // Update sort indicator
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: column)
        }
        if let column = tableView.tableColumns.first(where: { $0.sortDescriptorPrototype?.key == key }) {
            tableView.highlightedTableColumn = column
            let indicatorName = descriptor.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
            if let indicator = NSImage(named: NSImage.Name(indicatorName)) {
                tableView.setIndicatorImage(indicator, in: column)
            }
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < items.count else { return nil }
        return items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on && row < items.count && items[row].isDirectory && !items[row].isPackage {
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }
        if dropOperation == .above {
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let destination = (dropOperation == .on && row < items.count && items[row].isDirectory) ? items[row].url : currentURL
        do {
            if info.draggingSourceOperationMask.contains(.move) {
                try FileOperationService.shared.move(urls, to: destination)
            } else {
                try FileOperationService.shared.copy(urls, to: destination)
            }
            return true
        } catch {
            showError(error)
            return false
        }
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count, let columnID = tableColumn?.identifier else { return nil }
        let item = items[row]

        let cellID = NSUserInterfaceItemIdentifier("Cell_\(columnID.rawValue)")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = cellID

        if cell.textField == nil {
            if columnID == nameColumn {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(iv)
                cell.imageView = iv

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                tf.isEditable = false
                cell.addSubview(tf)
                cell.textField = tf

                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            } else {
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                tf.isEditable = false
                cell.addSubview(tf)
                cell.textField = tf

                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
        }

        switch columnID {
        case nameColumn:
            cell.textField?.stringValue = item.name
            let itemURL = item.url
            cell.imageView?.image = ThumbnailCache.shared.iconAsync(for: itemURL) { [weak self] icon in
                guard let self = self else { return }
                // Find current row for this URL and reload if visible
                guard let currentRow = self.items.firstIndex(where: { $0.url == itemURL }) else { return }
                let visibleRows = self.tableView.rows(in: self.tableView.visibleRect)
                if visibleRows.contains(currentRow) {
                    let columnIndex = self.tableView.column(withIdentifier: self.nameColumn)
                    if columnIndex >= 0 {
                        self.tableView.reloadData(forRowIndexes: IndexSet(integer: currentRow), columnIndexes: IndexSet(integer: columnIndex))
                    }
                }
            }
            cell.setAccessibilityLabel("\(item.name), \(item.kind)\(item.isDirectory ? ", folder" : "")")
        case dateColumn:
            cell.textField?.stringValue = item.formattedDateModified
            cell.setAccessibilityLabel("Modified: \(item.formattedDateModified)")
        case sizeColumn:
            cell.textField?.stringValue = item.formattedSize
            cell.setAccessibilityLabel("Size: \(cell.textField?.stringValue ?? item.formattedSize)")
        case kindColumn:
            cell.textField?.stringValue = item.kind
            cell.setAccessibilityLabel("Kind: \(item.kind)")
        default:
            break
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        24
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier == nameColumn, row < items.count else { return nil }
        return items[row].name
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        delegate?.fileListDidSelect(items: selectedItems)
        updateStatusBar()
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 125: // Cmd+Down — open selected
                openSelectedFile()
            case 126: // Cmd+Up — enclosing folder
                let parent = currentURL.deletingLastPathComponent()
                delegate?.fileListDidNavigate(to: parent)
            case 51: // Cmd+Delete — trash
                deleteSelectedFiles()
            default:
                super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case 36: // Enter — rename
            let row = tableView.selectedRow
            if row >= 0 {
                startRenaming(at: row)
            }
        case 49: // Space — Quick Look
            toggleQuickLook()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Quick Look

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard index < selectedItems.count else { return nil }
        return selectedItems[index].url as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event = event else { return false }
        if event.type == .keyDown {
            let keyCode = event.keyCode
            // Arrow up (126) or arrow down (125)
            if keyCode == 125 || keyCode == 126 {
                tableView.keyDown(with: event)
                return true
            }
        }
        return false
    }
}

// MARK: - NSTextFieldDelegate (rename)

extension FileListViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard let textField = control as? NSTextField else { return true }
        let newName = textField.stringValue
        let row = editingRow
        guard row >= 0, row < items.count else { return true }
        let item = items[row]

        if newName != item.name && !newName.isEmpty {
            do {
                let newURL = try FileOperationService.shared.rename(item.url, to: newName)
                registerUndoRename(originalURL: item.url, newURL: newURL)
            } catch {
                showError(error)
            }
        }

        textField.isEditable = false
        editingRow = -1
        return true
    }
}

// MARK: - NSMenuDelegate (context menu)

extension FileListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = tableView.clickedRow

        if clickedRow < 0 || clickedRow >= items.count {
            // Background context menu
            let newFolderItem = menu.addItem(withTitle: "New Folder", action: #selector(contextNewFolder(_:)), keyEquivalent: "")
            newFolderItem.target = self

            let pb = NSPasteboard.general
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                let pasteItem = menu.addItem(withTitle: "Paste", action: #selector(contextPaste(_:)), keyEquivalent: "")
                pasteItem.target = self
            }

            menu.addItem(.separator())
            let infoItem = menu.addItem(withTitle: "Get Info", action: #selector(contextGetInfoCurrentFolder(_:)), keyEquivalent: "")
            infoItem.target = self

            menu.addItem(.separator())
            let terminalItem = menu.addItem(withTitle: "Open in Terminal", action: #selector(contextOpenInTerminal(_:)), keyEquivalent: "")
            terminalItem.target = self
            terminalItem.representedObject = currentURL
            return
        }

        // If clicked row is not in selection, select it
        if !tableView.selectedRowIndexes.contains(clickedRow) {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        menu.addItem(withTitle: "Open", action: #selector(contextOpen(_:)), keyEquivalent: "")

        // Open With submenu
        if let clickedItem = clickedRow < items.count ? items[clickedRow] : nil {
            let openWithSubmenu = buildOpenWithSubmenu(for: clickedItem.url)
            let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWithItem.submenu = openWithSubmenu
            menu.addItem(openWithItem)
        }

        menu.addItem(withTitle: "Quick Look", action: #selector(contextQuickLook(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy", action: #selector(contextCopy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Cut", action: #selector(contextCut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Duplicate", action: #selector(contextDuplicate(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        // Copy Path submenu
        let copyPathSubmenu = NSMenu()
        let posixItem = copyPathSubmenu.addItem(withTitle: "POSIX Path", action: #selector(contextCopyPosixPath(_:)), keyEquivalent: "")
        posixItem.target = self
        let urlItem = copyPathSubmenu.addItem(withTitle: "File URL", action: #selector(contextCopyFileURL(_:)), keyEquivalent: "")
        urlItem.target = self
        let tildeItem = copyPathSubmenu.addItem(withTitle: "Tilde Path", action: #selector(contextCopyTildePath(_:)), keyEquivalent: "")
        tildeItem.target = self

        let copyPathMainItem = NSMenuItem(title: "Copy Path", action: #selector(contextCopyPosixPath(_:)), keyEquivalent: "")
        copyPathMainItem.target = self

        let copyPathAsItem = NSMenuItem(title: "Copy Path as...", action: nil, keyEquivalent: "")
        copyPathAsItem.submenu = copyPathSubmenu
        menu.addItem(copyPathMainItem)
        menu.addItem(copyPathAsItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename", action: #selector(contextRename(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Move to Trash", action: #selector(contextTrash(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        // Tags submenu
        let tagsSubmenu = buildTagsSubmenu()
        let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        tagsItem.submenu = tagsSubmenu
        menu.addItem(tagsItem)

        // Compress / Extract
        menu.addItem(.separator())
        let selected = selectedItems
        let allZips = selected.allSatisfy { $0.url.pathExtension.lowercased() == "zip" }
        if allZips && !selected.isEmpty {
            let extractItem = menu.addItem(withTitle: "Extract Here", action: #selector(contextExtract(_:)), keyEquivalent: "")
            extractItem.target = self
            let extractWithPwItem = menu.addItem(withTitle: "Extract with Password…", action: #selector(contextExtractWithPassword(_:)), keyEquivalent: "")
            extractWithPwItem.target = self
        }
        let compressItem = menu.addItem(withTitle: "Compress…", action: #selector(contextCompress(_:)), keyEquivalent: "")
        compressItem.target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(contextGetInfo(_:)), keyEquivalent: "")

        // Open in Terminal
        let terminalItem = NSMenuItem(title: "Open in Terminal", action: #selector(contextOpenInTerminal(_:)), keyEquivalent: "")
        terminalItem.target = self
        if let clickedItem = clickedRow < items.count ? items[clickedRow] : nil {
            if clickedItem.isDirectory && !clickedItem.isPackage {
                terminalItem.representedObject = clickedItem.url
            } else {
                terminalItem.representedObject = clickedItem.url.deletingLastPathComponent()
            }
        }
        menu.addItem(terminalItem)

        for item in menu.items where item.target == nil && item.action != nil && item.submenu == nil {
            item.target = self
        }
    }

    @objc private func contextOpen(_ sender: Any?) {
        openSelectedFile()
    }

    @objc private func contextQuickLook(_ sender: Any?) {
        toggleQuickLook()
    }

    @objc private func contextCopy(_ sender: Any?) {
        copySelectedFiles()
    }

    @objc private func contextCut(_ sender: Any?) {
        cutSelectedFiles()
    }

    @objc private func contextRename(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        startRenaming(at: row)
    }

    @objc private func contextTrash(_ sender: Any?) {
        deleteSelectedFiles()
    }

    @objc private func contextGetInfo(_ sender: Any?) {
        for item in selectedItems {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
    }

    @objc private func contextNewFolder(_ sender: Any?) {
        createNewFolder()
    }

    @objc private func contextPaste(_ sender: Any?) {
        pasteFiles()
    }

    @objc private func contextGetInfoCurrentFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([currentURL])
    }

    @objc private func contextDuplicate(_ sender: Any?) {
        duplicateSelectedFiles()
    }

    // MARK: - Open With

    private func buildOpenWithSubmenu(for url: URL) -> NSMenu {
        let submenu = NSMenu()

        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: url)

        for appURL in appURLs {
            let appName = FileManager.default.displayName(atPath: appURL.path)
            let menuItem = NSMenuItem(title: appName, action: #selector(contextOpenWith(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = appURL
            if let icon = NSWorkspace.shared.icon(forFile: appURL.path).copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                menuItem.image = icon
            }
            submenu.addItem(menuItem)
        }

        if !appURLs.isEmpty {
            submenu.addItem(.separator())
        }

        let otherItem = NSMenuItem(title: "Other...", action: #selector(contextOpenWithOther(_:)), keyEquivalent: "")
        otherItem.target = self
        submenu.addItem(otherItem)

        return submenu
    }

    @objc private func contextOpenWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }

        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)
    }

    @objc private func contextOpenWithOther(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = "Choose an application to open the selected file(s)."

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let appURL = panel.url else { return }
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)
        }
    }

    // MARK: - Copy Path

    @objc private func contextCopyPosixPath(_ sender: Any?) {
        let paths = selectedItems.map(\.url.path)
        guard !paths.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc private func contextCopyFileURL(_ sender: Any?) {
        let urls = selectedItems.map(\.url.absoluteString)
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.joined(separator: "\n"), forType: .string)
    }

    @objc private func contextCopyTildePath(_ sender: Any?) {
        let paths = selectedItems.map { (item: FileItem) -> String in
            (item.url.path as NSString).abbreviatingWithTildeInPath
        }
        guard !paths.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Open in Terminal

    @objc private func contextOpenInTerminal(_ sender: NSMenuItem) {
        let targetURL: URL
        if let url = sender.representedObject as? URL {
            targetURL = url
        } else {
            targetURL = currentURL
        }

        let escapedPath = targetURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"cd \\\"\\(escapedPath)\\\"\"\nend tell"

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    // MARK: - Tags

    private func buildTagsSubmenu() -> NSMenu {
        let menu = NSMenu()
        let selected = selectedItems
        let currentTags: Set<String> = {
            guard let first = selected.first else { return [] }
            if selected.count == 1 { return Set(first.tags) }
            // For multiple selection, show common tags as checked
            return Set(first.tags).intersection(selected.dropFirst().reduce(Set(first.tags)) { $0.intersection(Set($1.tags)) })
        }()

        let standardTags = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
        for tagName in standardTags {
            let item = NSMenuItem(title: tagName, action: #selector(toggleTag(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tagName

            // Add colored dot image
            let dotImage = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                TagColors.nsColor(for: tagName).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
            item.image = dotImage

            if currentTags.contains(tagName) {
                item.state = .on
            }
            menu.addItem(item)
        }

        return menu
    }

    @objc private func toggleTag(_ sender: NSMenuItem) {
        guard let tagName = sender.representedObject as? String else { return }
        let selected = selectedItems
        guard !selected.isEmpty else { return }

        for item in selected {
            var tags = item.tags
            if tags.contains(tagName) {
                tags.removeAll { $0 == tagName }
            } else {
                tags.append(tagName)
            }
            do {
                try FileItem.setTags(tags, for: item.url)
            } catch {
                showError(error)
            }
        }

        // Reload to reflect tag changes
        reloadContents()
    }

    // MARK: - Compress / Extract

    @objc private func contextCompress(_ sender: Any?) {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        showCompressPanel(for: selected.map(\.url))
    }

    @objc private func contextExtract(_ sender: Any?) {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        extractArchives(selected.map(\.url), password: nil)
    }

    @objc private func contextExtractWithPassword(_ sender: Any?) {
        let selected = selectedItems
        guard !selected.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Enter Password"
        alert.informativeText = "Enter the password for the archive."
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        passwordField.placeholderString = "Password"
        alert.accessoryView = passwordField
        alert.window.initialFirstResponder = passwordField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = passwordField.stringValue
        guard !password.isEmpty else { return }
        extractArchives(selected.map(\.url), password: password)
    }

    private func extractArchives(_ urls: [URL], password: String?) {
        for url in urls {
            let destination = url.deletingLastPathComponent()
            FileOperationService.shared.decompress(url, to: destination, password: password) { [weak self] result in
                switch result {
                case .success:
                    self?.reloadContents()
                case .failure(let error):
                    self?.showError(error)
                }
            }
        }
    }

    private func showCompressPanel(for urls: [URL]) {
        guard let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = "Compress"
        alert.informativeText = urls.count == 1 ? "Compress \"\(urls[0].lastPathComponent)\"" : "Compress \(urls.count) items"
        alert.addButton(withTitle: "Compress")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 80))

        let levelLabel = NSTextField(labelWithString: "Compression:")
        levelLabel.frame = NSRect(x: 0, y: 52, width: 90, height: 20)
        container.addSubview(levelLabel)

        let levelPopup = NSPopUpButton(frame: NSRect(x: 94, y: 48, width: 180, height: 28), pullsDown: false)
        for level in FileOperationService.CompressionLevel.allCases {
            levelPopup.addItem(withTitle: level.label)
            levelPopup.lastItem?.tag = level.rawValue
        }
        levelPopup.selectItem(at: 2) // Normal
        container.addSubview(levelPopup)

        let passwordLabel = NSTextField(labelWithString: "Password:")
        passwordLabel.frame = NSRect(x: 0, y: 16, width: 90, height: 20)
        container.addSubview(passwordLabel)

        let passwordField = NSSecureTextField(frame: NSRect(x: 94, y: 12, width: 180, height: 24))
        passwordField.placeholderString = "Optional"
        container.addSubview(passwordField)

        alert.accessoryView = container

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let levelTag = levelPopup.selectedItem?.tag ?? 5
            let level = FileOperationService.CompressionLevel(rawValue: levelTag) ?? .normal
            let password = passwordField.stringValue.isEmpty ? nil : passwordField.stringValue

            guard let self = self else { return }

            // Build archive name
            let archiveName: String
            if urls.count == 1 {
                archiveName = urls[0].deletingPathExtension().lastPathComponent + ".zip"
            } else {
                archiveName = "Archive.zip"
            }

            var archiveURL = self.currentURL.appendingPathComponent(archiveName)
            var counter = 1
            while FileManager.default.fileExists(atPath: archiveURL.path) {
                let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
                archiveURL = self.currentURL.appendingPathComponent("\(base) \(counter).zip")
                counter += 1
            }

            FileOperationService.shared.compress(urls, to: archiveURL, level: level, password: password) { [weak self] result in
                switch result {
                case .success:
                    self?.reloadContents()
                case .failure(let error):
                    self?.showError(error)
                }
            }
        }
    }
}

// MARK: - BatchRenameViewControllerDelegate

extension FileListViewController: BatchRenameViewControllerDelegate {
    func batchRenameDidComplete() {
        reloadContents()
    }
}
