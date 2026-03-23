import AppKit
import QuickLookUI

protocol FileListViewControllerDelegate: AnyObject {
    func fileListDidNavigate(to url: URL)
    func fileListDidSelect(item: FileItem?)
}

final class FileListViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    weak var delegate: FileListViewControllerDelegate?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let statusBar = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Empty Folder")

    private var items: [FileItem] = []
    private var sortKey: String = "name"
    private var sortAscending: Bool = true
    private(set) var currentURL: URL = FileManager.default.homeDirectoryForCurrentUser
    var showHiddenFiles: Bool = false

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

    func loadDirectory(_ url: URL) {
        currentURL = url

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
        let selectedURLs = Set(selectedItems.map(\.url))
        do {
            items = try FileOperationService.shared.contentsOfDirectory(at: currentURL, showHidden: showHiddenFiles)
            sortItems()
            tableView.reloadData()
            // Restore selection
            let newSelection = IndexSet(items.indices.filter { selectedURLs.contains(items[$0].url) })
            if !newSelection.isEmpty {
                tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
            }
            updateStatusBar()
            emptyLabel.stringValue = "This folder is empty"
            emptyLabel.isHidden = !items.isEmpty
        } catch {
            items = []
            tableView.reloadData()
            updateStatusBar()
            if let nsError = error as NSError?, nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
                emptyLabel.stringValue = "You don't have permission to access this folder."
            } else {
                emptyLabel.stringValue = "Unable to load folder contents."
            }
            emptyLabel.isHidden = false
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
        do {
            if isCut {
                try FileOperationService.shared.move(urls, to: currentURL)
                clipboard = nil
            } else {
                try FileOperationService.shared.copy(urls, to: currentURL)
            }
        } catch {
            showError(error)
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
                _ = try FileOperationService.shared.moveToTrash(urls)
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
            cell.imageView?.image = ThumbnailCache.shared.icon(for: item.url)
        case dateColumn:
            cell.textField?.stringValue = item.formattedDateModified
        case sizeColumn:
            cell.textField?.stringValue = item.formattedSize
        case kindColumn:
            cell.textField?.stringValue = item.kind
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
        let selected = selectedItems.first
        delegate?.fileListDidSelect(item: selected)
        updateStatusBar()
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
                _ = try FileOperationService.shared.rename(item.url, to: newName)
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
            return
        }

        // If clicked row is not in selection, select it
        if !tableView.selectedRowIndexes.contains(clickedRow) {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        menu.addItem(withTitle: "Open", action: #selector(contextOpen(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Quick Look", action: #selector(contextQuickLook(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy", action: #selector(contextCopy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Cut", action: #selector(contextCut(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename", action: #selector(contextRename(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Move to Trash", action: #selector(contextTrash(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(contextGetInfo(_:)), keyEquivalent: "")

        for item in menu.items {
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
}
