import AppKit

final class ColumnViewController: NSViewController, FileViewControllerProtocol, NSBrowserDelegate {

    weak var delegate: FileListViewControllerDelegate?

    private let browser = NSBrowser()
    private let statusBar = NSTextField(labelWithString: "")

    private(set) var currentURL: URL = FileManager.default.homeDirectoryForCurrentUser
    var showHiddenFiles: Bool = false

    private var watcher: DirectoryWatcher?
    private var reloadWorkItem: DispatchWorkItem?

    // Cache of items per column path
    private var columnItems: [Int: [FileItem]] = [:]
    private var columnPaths: [Int: URL] = [:]

    private var sortKey: String = "name"
    private var sortAscending: Bool = true

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 600, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupBrowser()
        setupStatusBar()
        loadDirectory(currentURL)
    }

    private func setupBrowser() {
        browser.delegate = self
        browser.setCellClass(BrowserCell.self)
        browser.columnResizingType = .autoColumnResizing
        browser.minColumnWidth = 180
        browser.hasHorizontalScroller = true
        browser.separatesColumns = false
        browser.isTitled = false
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.sendsActionOnArrowKeys = true
        browser.target = self
        browser.action = #selector(browserSingleClick(_:))
        browser.doubleAction = #selector(browserDoubleClick(_:))

        let contextMenu = FileContextMenuBuilder.makeMenu()
        contextMenu.delegate = self
        browser.menu = contextMenu

        browser.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browser)
    }

    // MARK: - File operation responders

    @objc func copy(_ sender: Any?) { copySelectedFiles() }
    @objc func cut(_ sender: Any?) { cutSelectedFiles() }
    @objc func paste(_ sender: Any?) { pasteFiles() }

    private func setupStatusBar() {
        GroveUI.configureFooterStatusLabel(statusBar)
        view.addSubview(statusBar)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: view.topAnchor),
            browser.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -4),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            statusBar.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    func loadDirectory(_ url: URL) {
        reloadWorkItem?.cancel()
        currentURL = url
        columnItems.removeAll()
        columnPaths.removeAll()

        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] changedPaths in
            self?.scheduleReload(changedPaths: changedPaths)
        }

        // Build column hierarchy from root URL
        let components = pathHierarchy(for: url)
        for (index, componentURL) in components.enumerated() {
            columnPaths[index] = componentURL
            var items = loadItems(at: componentURL)
            if index + 1 < components.count {
                items = itemsIncludingPathComponent(components[index + 1], in: items)
            }
            columnItems[index] = items
        }

        browser.loadColumnZero()

        revealPath(components)

        updateStatusBar()
    }

    private func revealPath(_ components: [URL]) {
        guard components.count > 1 else { return }

        for column in 0..<components.count - 1 {
            guard let items = columnItems[column] else { continue }

            let nextURL = components[column + 1].standardizedFileURL
            guard let row = items.firstIndex(where: { $0.url.standardizedFileURL == nextURL }) else { continue }

            browser.selectRow(row, inColumn: column)

            if column + 1 < components.count {
                browser.reloadColumn(column + 1)
            }
        }

        browser.scrollColumnToVisible(components.count - 1)
    }

    private func pathHierarchy(for url: URL) -> [URL] {
        url.pathComponents_
    }

    private func loadItems(at url: URL) -> [FileItem] {
        do {
            var items = try FileOperationService.shared.contentsOfDirectory(at: url, showHidden: showHiddenFiles)
            sortItems(&items)
            return items
        } catch {
            return []
        }
    }

    private func itemsIncludingPathComponent(_ componentURL: URL, in items: [FileItem]) -> [FileItem] {
        let standardizedURL = componentURL.standardizedFileURL
        if items.contains(where: { $0.url.standardizedFileURL == standardizedURL }) {
            return items
        }
        guard let item = FileItem.loadForDirectoryListing(
            from: componentURL,
            name: componentURL.lastPathComponent,
            showHidden: true
        ) else {
            return items
        }

        var updatedItems = items
        updatedItems.append(item)
        sortItems(&updatedItems)
        return updatedItems
    }

    private func sortItems(_ items: inout [FileItem]) {
        FileItem.sort(&items, key: sortKey, ascending: sortAscending)
    }

    private func scheduleReload(changedPaths: [URL]) {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadChangedColumns(changedPaths)
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Reload only the columns whose directory directly contains a changed path, preserving
    /// selection and the rest of the navigation. Falls back to nothing when no column matches.
    private func reloadChangedColumns(_ changedPaths: [URL]) {
        let changedDirs = Set(changedPaths.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        let changedSelf = Set(changedPaths.map { $0.standardizedFileURL.path })
        let affectedColumns = columnPaths.filter { column in
            let path = column.value.standardizedFileURL.path
            return changedDirs.contains(path) || changedSelf.contains(path)
        }.map(\.key)

        for column in affectedColumns {
            reloadColumnAsync(column)
        }
    }

    private func reloadColumnAsync(_ column: Int) {
        guard let dir = columnPaths[column] else { return }
        let requestDir = dir.standardizedFileURL
        let requestShowHidden = showHiddenFiles

        // Capture the current selection by URL so it can be restored if the item survives.
        let selectedURLs: Set<URL>
        if let rows = browser.selectedRowIndexes(inColumn: column), let items = columnItems[column] {
            selectedURLs = Set(rows.compactMap { $0 < items.count ? items[$0].url.standardizedFileURL : nil })
        } else {
            selectedURLs = []
        }

        FileOperationService.shared.contentsOfDirectoryAsync(at: requestDir, showHidden: requestShowHidden) { [weak self] result in
            guard let self = self,
                  self.columnPaths[column]?.standardizedFileURL == requestDir,
                  self.showHiddenFiles == requestShowHidden,
                  case .success(var items) = result else { return }

            self.sortItems(&items)
            // Keep the descendant that feeds the next column visible even if hidden-file rules would drop it.
            if let nextURL = self.columnPaths[column + 1] {
                items = self.itemsIncludingPathComponent(nextURL, in: items)
            }
            self.columnItems[column] = items
            self.browser.reloadColumn(column)

            if !selectedURLs.isEmpty {
                for (row, item) in items.enumerated()
                where selectedURLs.contains(item.url.standardizedFileURL) {
                    self.browser.selectRow(row, inColumn: column)
                }
            }
            self.updateStatusBar()
        }
    }

    func toggleHiddenFiles() {
        showHiddenFiles.toggle()
        loadDirectory(currentURL)
    }

    var selectedItems: [FileItem] {
        let lastColumn = browser.lastColumn
        guard let selectedRows = browser.selectedRowIndexes(inColumn: lastColumn),
              let items = columnItems[lastColumn] else { return [] }
        return selectedRows.compactMap { row in
            row < items.count ? items[row] : nil
        }
    }

    private func renameSelectedFile() {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        FileRenameHelper.presentRenameSheet(for: item, from: self) { [weak self] _ in
            guard let self = self else { return }
            self.loadDirectory(self.currentURL)
        }
    }

    private func updateStatusBar() {
        let items = columnItems[currentColumnIndex] ?? []
        let count = items.count
        let selectedCount = selectedItems.count
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

    private var currentColumnIndex: Int {
        columnPaths.first(where: { $0.value.standardizedFileURL == currentURL.standardizedFileURL })?.key ?? 0
    }

    // MARK: - Actions

    @objc private func browserSingleClick(_ sender: Any?) {
        let column = browser.selectedColumn
        guard column >= 0, let items = columnItems[column] else { return }

        guard let selectedRows = browser.selectedRowIndexes(inColumn: column) else { return }
        if let firstRow = selectedRows.first, firstRow < items.count {
            let item = items[firstRow]
            delegate?.fileListDidSelect(items: [item])

            // If it's a directory, prepare next column
            if item.isDirectory && !item.isPackage {
                let nextColumn = column + 1
                columnPaths[nextColumn] = item.url
                columnItems[nextColumn] = loadItems(at: item.url)
                // Clean up columns beyond next
                let maxCol = columnPaths.keys.max() ?? 0
                for c in (nextColumn + 1)...max(maxCol, nextColumn + 1) {
                    columnPaths.removeValue(forKey: c)
                    columnItems.removeValue(forKey: c)
                }
            }
        }

        updateStatusBar()
    }

    @objc private func browserDoubleClick(_ sender: Any?) {
        let column = browser.clickedColumn
        let row = browser.clickedRow
        guard column >= 0, row >= 0, let items = columnItems[column], row < items.count else { return }

        let item = items[row]
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

    // MARK: - NSBrowserDelegate

    func browser(_ browser: NSBrowser, numberOfRowsInColumn column: Int) -> Int {
        if column == 0 {
            if columnItems[0] == nil {
                columnPaths[0] = currentURL
                columnItems[0] = loadItems(at: currentURL)
            }
            return columnItems[0]?.count ?? 0
        }

        // For subsequent columns, get the selected item in the previous column
        let prevColumn = column - 1
        let selectedRow = browser.selectedRow(inColumn: prevColumn)
        guard selectedRow >= 0,
              let prevItems = columnItems[prevColumn],
              selectedRow < prevItems.count else {
            return 0
        }

        let selectedItem = prevItems[selectedRow]
        guard selectedItem.isDirectory && !selectedItem.isPackage else { return 0 }

        if columnItems[column] == nil {
            columnPaths[column] = selectedItem.url
            columnItems[column] = loadItems(at: selectedItem.url)
        }

        return columnItems[column]?.count ?? 0
    }

    func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let browserCell = cell as? BrowserCell,
              let items = columnItems[column],
              row < items.count else { return }

        let item = items[row]
        browserCell.stringValue = item.name
        browserCell.representedURL = item.url
        let itemURL = item.url
        browserCell.image = ThumbnailCache.shared.iconAsync(for: itemURL) { [weak browser, weak browserCell] icon in
            // Match by URL, not filename, so same-named files in different columns don't collide.
            guard let browserCell, browserCell.representedURL == itemURL else { return }
            browserCell.image = icon
            // Invalidate only this cell's rect instead of the whole browser.
            browser?.setNeedsDisplay(browser?.frame(ofRow: row, inColumn: column) ?? .zero)
        }
        browserCell.isLeaf = !(item.isDirectory && !item.isPackage)
    }
}

// MARK: - Context menu

extension ColumnViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let event = NSApp.currentEvent, browser.lastColumn >= 0 else { return }
        for column in 0...browser.lastColumn {
            guard let matrix = browser.matrix(inColumn: column) else { continue }
            let point = matrix.convert(event.locationInWindow, from: nil)
            guard matrix.bounds.contains(point) else { continue }
            var row = -1
            var col = -1
            if matrix.getRow(&row, column: &col, for: point), row >= 0 {
                browser.selectRow(row, inColumn: column)
                browserSingleClick(nil)
            }
            return
        }
    }
}

extension ColumnViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateFileOperationMenuItem(menuItem)
    }
}

// MARK: - BrowserCell

private final class BrowserCell: NSBrowserCell {

    // Identifies the file this (recycled) cell currently represents, so async icon
    // completions can verify they still apply before drawing.
    var representedURL: URL?

    override init(textCell string: String) {
        super.init(textCell: string)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var imageRect = NSRect.zero
        var textRect = cellFrame

        if let img = image {
            let imageSize = NSSize(width: 16, height: 16)
            imageRect = NSRect(
                x: cellFrame.origin.x + 4,
                y: cellFrame.origin.y + (cellFrame.height - imageSize.height) / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            img.draw(in: imageRect, from: NSRect(origin: .zero, size: img.size),
                     operation: .sourceOver, fraction: 1.0, respectFlipped: true,
                     hints: nil)
            textRect.origin.x = imageRect.maxX + 4
            textRect.size.width = cellFrame.maxX - textRect.origin.x
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: GroveUI.contentFontSize),
            .foregroundColor: isHighlighted ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
        ]
        let attrString = NSAttributedString(string: stringValue, attributes: attributes)
        let drawRect = NSRect(
            x: textRect.origin.x,
            y: textRect.origin.y + (textRect.height - attrString.size().height) / 2,
            width: textRect.width,
            height: attrString.size().height
        )
        attrString.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
