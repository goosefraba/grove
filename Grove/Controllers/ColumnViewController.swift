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

        browser.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browser)
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
        currentURL = url
        columnItems.removeAll()
        columnPaths.removeAll()

        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] in
            self?.scheduleReload()
        }

        // Build column hierarchy from root URL
        let components = pathHierarchy(for: url)
        for (index, componentURL) in components.enumerated() {
            columnPaths[index] = componentURL
            columnItems[index] = loadItems(at: componentURL)
        }

        browser.loadColumnZero()

        // Select items to reveal columns for the path
        for column in 0..<components.count - 1 {
            guard let items = columnItems[column] else { continue }
            let nextURL = components[column + 1]
            if let row = items.firstIndex(where: { $0.url.standardizedFileURL == nextURL.standardizedFileURL }) {
                browser.selectRow(row, inColumn: column)
            }
        }

        updateStatusBar()
    }

    private func pathHierarchy(for url: URL) -> [URL] {
        // Return just the target URL as column 0
        return [url]
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

    private func sortItems(_ items: inout [FileItem]) {
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

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Reload column 0
            self.columnItems[0] = self.loadItems(at: self.currentURL)
            self.browser.reloadColumn(0)
            self.updateStatusBar()
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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

    private func updateStatusBar() {
        let items = columnItems[0] ?? []
        let count = items.count
        let selectedCount = selectedItems.count
        let itemText = count == 1 ? "1 item" : "\(count) items"
        let selectionText = selectedCount > 0 ? " (\(selectedCount) selected)" : ""
        let diskSpace = FileOperationService.shared.availableDiskSpace(at: currentURL) ?? ""
        let spaceText = diskSpace.isEmpty ? "" : "  —  \(diskSpace) available"
        statusBar.stringValue = "\(itemText)\(selectionText)\(spaceText)"
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
        browserCell.image = ThumbnailCache.shared.iconAsync(for: item.url) { [weak browser] icon in
            browser?.reloadColumn(column)
        }
        browserCell.isLeaf = !(item.isDirectory && !item.isPackage)
    }
}

// MARK: - BrowserCell

private final class BrowserCell: NSBrowserCell {

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
            .font: NSFont.systemFont(ofSize: 13),
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
