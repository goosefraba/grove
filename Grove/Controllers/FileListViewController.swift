import AppKit
import QuickLookUI
import UniformTypeIdentifiers

private final class FileListTableView: NSTableView {
    var onRenameShortcut: (() -> Void)?
    var onContextMenuRow: ((Int) -> Void)?
    var onCopyFiles: (() -> Void)?
    var onCutFiles: (() -> Void)?
    var onPasteFiles: (() -> Void)?
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onBecomeFirstResponder?() }
        return didBecome
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.isRenameShortcut {
            onRenameShortcut?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.isRenameShortcut {
            onRenameShortcut?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        onContextMenuRow?(row(at: point))
        return super.menu(for: event)
    }

    @objc func copy(_ sender: Any?) {
        onCopyFiles?()
    }

    @objc func cut(_ sender: Any?) {
        onCutFiles?()
    }

    @objc func paste(_ sender: Any?) {
        onPasteFiles?()
    }
}

private final class FileListScrollView: NSScrollView {
    var onBackgroundMenuRequest: (() -> Void)?
    var onValidateBackgroundDrop: ((any NSDraggingInfo) -> NSDragOperation)?
    var onAcceptBackgroundDrop: ((any NSDraggingInfo) -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onBackgroundMenuRequest?()
        return super.menu(for: event) ?? menu
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onValidateBackgroundDrop?(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onValidateBackgroundDrop?(sender) ?? []
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        (onValidateBackgroundDrop?(sender) ?? []).isEmpty == false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onAcceptBackgroundDrop?(sender) ?? false
    }
}

private extension NSEvent {
    var isRenameShortcut: Bool {
        let isReturnOrEnter = keyCode == 36 || keyCode == 76
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        return isReturnOrEnter && modifiers.contains(.control) && !modifiers.contains(.command)
    }
}

protocol FileListViewControllerDelegate: AnyObject {
    func fileListDidNavigate(to url: URL)
    func fileListDidNavigate(to location: StorageLocation)
    func fileListDidSelect(items: [FileItem])
    func fileListDidSelect(browserItems: [BrowserItem])
}

extension FileListViewControllerDelegate {
    func fileListDidNavigate(to location: StorageLocation) {
        guard case .local(let url) = location else { return }
        fileListDidNavigate(to: url)
    }

    func fileListDidSelect(browserItems: [BrowserItem]) {
        fileListDidSelect(items: browserItems.compactMap(\.fileItem))
    }
}

final class FileListViewController: NSViewController, FileViewControllerProtocol,
    NSTableViewDataSource, NSTableViewDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    weak var delegate: FileListViewControllerDelegate?

    private let scrollView = FileListScrollView()
    private let tableView = FileListTableView()
    private let statusBar = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Empty Folder")
    private let searchScopeLabel = NSTextField(labelWithString: "")
    private let loadingSpinner = NSProgressIndicator()
    private let directoryHeader = NSView()
    private let directoryTitleLabel = NSTextField(labelWithString: "")
    private let directoryCountLabel = NSTextField(labelWithString: "")
    private let directoryCapacityLabel = NSTextField(labelWithString: "")
    private let storageMeter = GroveStorageMeter()
    private var directoryStorageUsage: Double?

    // Scroll view top pins to the view (label hidden) or the label's bottom (label shown).
    // Both built once; toggle isActive instead of creating constraints per toggle.
    private var scrollTopToView: NSLayoutConstraint?
    private var scrollTopToLabel: NSLayoutConstraint?

    private var allItems: [FileItem] = []
    private var items: [FileItem] = []
    private var sortKey: String = "name"
    private var sortAscending: Bool = true
    private(set) var currentURL: URL = FileManager.default.homeDirectoryForCurrentUser
    var showHiddenFiles: Bool = false
    private var isShowingSearchResults: Bool = false
    private var isRestoringSortPreference: Bool = false

    var filterText: String = "" {
        didSet {
            applyFilter()
        }
    }

    var supportsToolbarSearch: Bool { true }

    private var fileUndoManager: UndoManager? {
        view.window?.undoManager
    }

    private var watcher: DirectoryWatcher?
    private var reloadWorkItem: DispatchWorkItem?
    private var spinnerWorkItem: DispatchWorkItem?
    private var loadGeneration: UInt = 0
    // Cached set of cut file URLs, derived from the general pasteboard. Recomputed only when
    // the pasteboard's changeCount changes so cell rendering stays cheap.
    private var cachedCutChangeCount: Int = -1
    private var cachedCutURLs: Set<URL> = []
    private var clipboardObservation: PasteboardChangeCoordinator.Observation?
    private var editingRow: Int = -1
    private var editingURL: URL?
    private var pendingSelectionURL: URL?
    private var pendingRenameURL: URL?
    private var contextMenuRow: Int?

    // Column identifiers
    private let nameColumn = NSUserInterfaceItemIdentifier("NameColumn")
    private let dateColumn = NSUserInterfaceItemIdentifier("DateColumn")
    private let sizeColumn = NSUserInterfaceItemIdentifier("SizeColumn")
    private let kindColumn = NSUserInterfaceItemIdentifier("KindColumn")

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 600, height: 400))
        GroveUI.prepareSurface(view)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupDirectoryHeader()
        setupTableView()
        setupStatusBar()
        setupEmptyLabel()
        setupLoadingSpinner()
        setupSearchScopeLabel()
        setupAccessibility()
        clipboardObservation = FileOperationClipboard.observeChanges { [weak self] in
            self?.refreshCutIndication()
        }
        loadDirectory(currentURL)
    }

    private func setupDirectoryHeader() {
        directoryHeader.translatesAutoresizingMaskIntoConstraints = false
        GroveUI.prepareSurface(directoryHeader, color: GroveUI.elevatedBackground)
        view.addSubview(directoryHeader)

        let folderIcon = NSImageView()
        folderIcon.image = NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: "Current folder"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        folderIcon.contentTintColor = GroveUI.accentSoft
        folderIcon.translatesAutoresizingMaskIntoConstraints = false

        directoryTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        directoryTitleLabel.textColor = .labelColor
        directoryTitleLabel.lineBreakMode = .byTruncatingMiddle
        directoryTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for label in [directoryCountLabel, directoryCapacityLabel] {
            label.font = .systemFont(ofSize: GroveUI.statusFontSize, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        storageMeter.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            folderIcon,
            directoryTitleLabel,
            directoryCountLabel,
            directoryCapacityLabel,
            storageMeter,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        directoryHeader.addSubview(stack)

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = GroveUI.separator.cgColor
        directoryHeader.addSubview(separator)

        NSLayoutConstraint.activate([
            directoryHeader.topAnchor.constraint(equalTo: view.topAnchor),
            directoryHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            directoryHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            directoryHeader.heightAnchor.constraint(equalToConstant: 36),

            folderIcon.widthAnchor.constraint(equalToConstant: 16),
            folderIcon.heightAnchor.constraint(equalToConstant: 16),
            storageMeter.widthAnchor.constraint(equalToConstant: 112),
            storageMeter.heightAnchor.constraint(equalToConstant: 5),

            stack.leadingAnchor.constraint(equalTo: directoryHeader.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: directoryHeader.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: directoryHeader.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: directoryHeader.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: directoryHeader.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: directoryHeader.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
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
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .fullWidth
        tableView.rowHeight = GroveUI.listRowHeight
        tableView.backgroundColor = GroveUI.contentBackground
        tableView.gridColor = GroveUI.separator
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))
        tableView.target = self
        tableView.onRenameShortcut = { [weak self] in
            self?.renameSelectedRow()
        }
        tableView.onContextMenuRow = { [weak self] row in
            self?.contextMenuRow = row
        }
        tableView.onCopyFiles = { [weak self] in
            self?.copySelectedFiles()
        }
        tableView.onCutFiles = { [weak self] in
            self?.cutSelectedFiles()
        }
        tableView.onPasteFiles = { [weak self] in
            self?.pasteFiles()
        }
        for column in tableView.tableColumns {
            column.headerCell.font = .systemFont(ofSize: GroveUI.contentFontSize, weight: .semibold)
        }

        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        scrollView.menu = menu
        scrollView.registerForDraggedTypes([.fileURL])
        scrollView.onBackgroundMenuRequest = { [weak self] in
            self?.contextMenuRow = -1
        }
        scrollView.onValidateBackgroundDrop = { [weak self] info in
            self?.validateBackgroundDrop(info) ?? []
        }
        scrollView.onAcceptBackgroundDrop = { [weak self] info in
            self?.acceptBackgroundDrop(info) ?? false
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = GroveUI.contentBackground
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
        searchScopeLabel.font = .systemFont(ofSize: GroveUI.statusFontSize, weight: .medium)
        searchScopeLabel.textColor = .secondaryLabelColor
        searchScopeLabel.backgroundColor = GroveUI.elevatedBackground
        searchScopeLabel.drawsBackground = true
        searchScopeLabel.alignment = .center
        searchScopeLabel.translatesAutoresizingMaskIntoConstraints = false
        searchScopeLabel.isHidden = true
        view.addSubview(searchScopeLabel)

        NSLayoutConstraint.activate([
            searchScopeLabel.topAnchor.constraint(equalTo: directoryHeader.bottomAnchor),
            searchScopeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchScopeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchScopeLabel.heightAnchor.constraint(equalToConstant: 22),
        ])

        scrollTopToView = scrollView.topAnchor.constraint(equalTo: directoryHeader.bottomAnchor)
        scrollTopToLabel = scrollView.topAnchor.constraint(equalTo: searchScopeLabel.bottomAnchor)
        scrollTopToView?.isActive = true
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

    func setToolbarFilterText(_ text: String) {
        filterText = text
    }

    func performToolbarSearch(_ query: String) {
        performSpotlightSearch(query)
    }

    func clearToolbarSearch() {
        clearSearch()
    }

    var onBecomeFirstResponder: (() -> Void)? {
        get { tableView.onBecomeFirstResponder }
        set { tableView.onBecomeFirstResponder = newValue }
    }

    func focusFileList() {
        view.window?.makeFirstResponder(tableView)
    }

    func applyFilter() {
        let selectedURLs = Set(selectedItems.map(\.url))
        if filterText.isEmpty {
            items = allItems
        } else {
            items = allItems.filter {
                $0.name.localizedCaseInsensitiveContains(filterText)
            }
        }
        sortItems()
        tableView.reloadData()
        restoreSelection(previouslySelectedURLs: selectedURLs)
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

        SearchService.shared.search(query: query, in: currentURL) { [weak self] results, moreAvailable in
            guard let self = self, self.isShowingSearchResults else { return }
            self.allItems = results
            self.items = results
            self.sortItems()
            self.tableView.reloadData()
            self.updateStatusBar()
            self.searchScopeLabel.stringValue = moreAvailable
                ? "Searching in: \(self.currentURL.lastPathComponent) (showing first \(results.count), more available)"
                : "Searching in: \(self.currentURL.lastPathComponent)"
            self.emptyLabel.isHidden = !results.isEmpty
            if results.isEmpty {
                self.emptyLabel.stringValue = "No results for \"\(query)\""
            }
        }
    }

    func clearSearch() {
        guard isShowingSearchResults || !searchScopeLabel.isHidden || !filterText.isEmpty else { return }
        isShowingSearchResults = false
        searchScopeLabel.isHidden = true
        updateScrollViewTop()
        SearchService.shared.stop()
        filterText = ""
        reloadContents()
    }

    private func updateScrollViewTop() {
        if searchScopeLabel.isHidden {
            scrollTopToLabel?.isActive = false
            scrollTopToView?.isActive = true
        } else {
            scrollTopToView?.isActive = false
            scrollTopToLabel?.isActive = true
        }
        view.needsLayout = true
    }

    // MARK: - Directory Loading

    func loadDirectory(_ url: URL) {
        reloadWorkItem?.cancel()
        currentURL = url
        refreshDirectoryCapacity()
        updateDirectoryHeader()
        filterText = ""
        isShowingSearchResults = false
        searchScopeLabel.isHidden = true
        SearchService.shared.stop()

        loadSortPreference(for: url)

        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] eventURLs in
            self?.scheduleReload(for: eventURLs)
        }

        clearLoadedItemsForPendingLoad(message: "Loading folder contents...")
        reloadContents(showLoadingIndicator: true, preserveSelection: false)
    }

    private func scheduleReload(for eventURLs: [URL]) {
        guard shouldReload(for: eventURLs) else { return }
        invalidateCaches(for: eventURLs)
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadContents(showLoadingIndicator: false)
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func invalidateCaches(for eventURLs: [URL]) {
        for url in eventURLs {
            ThumbnailCache.shared.invalidate(url)
            FolderSizeService.shared.invalidateCache(for: url)
        }
    }

    private func shouldReload(for eventURLs: [URL]) -> Bool {
        guard !eventURLs.isEmpty else { return true }
        guard !showHiddenFiles else { return true }

        return eventURLs.contains { eventURL in
            let relativeComponents = Array(eventURL.standardizedFileURL.pathComponents.dropFirst(currentURL.standardizedFileURL.pathComponents.count))
            return !relativeComponents.contains(where: { $0.hasPrefix(".") })
        }
    }

    private func reloadContents(showLoadingIndicator: Bool = false, preserveSelection: Bool = true) {
        guard !isShowingSearchResults else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let requestURL = currentURL.standardizedFileURL
        let requestShowHiddenFiles = showHiddenFiles
        let selectedURLs = preserveSelection ? Set(selectedItems.map(\.url)) : []

        spinnerWorkItem?.cancel()
        loadingSpinner.stopAnimation(nil)
        loadingSpinner.isHidden = true
        emptyLabel.isHidden = true

        if showLoadingIndicator {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.loadingSpinner.isHidden = false
                self.loadingSpinner.startAnimation(nil)
            }
            spinnerWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        FileOperationService.shared.contentsOfDirectoryAsync(at: currentURL, showHidden: showHiddenFiles) { [weak self] result in
            guard let self = self else { return }
            guard self.loadGeneration == generation,
                  self.currentURL.standardizedFileURL == requestURL,
                  self.showHiddenFiles == requestShowHiddenFiles else { return }
            self.spinnerWorkItem?.cancel()
            self.loadingSpinner.stopAnimation(nil)
            self.loadingSpinner.isHidden = true

            switch result {
            case .success(let loadedItems):
                self.allItems = loadedItems
                self.applyFilter()
                self.restoreSelection(previouslySelectedURLs: selectedURLs)
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

    private func clearLoadedItemsForPendingLoad(message: String) {
        allItems = []
        items = []
        tableView.deselectAll(nil)
        tableView.reloadData()
        updateStatusBar()
        delegate?.fileListDidSelect(items: [])
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    private func restoreSelection(previouslySelectedURLs: Set<URL>) {
        let requestedSelection = pendingSelectionURL.map { Set([$0]) } ?? previouslySelectedURLs
        let newSelection = IndexSet(items.indices.filter { requestedSelection.contains(items[$0].url) })

        if !newSelection.isEmpty {
            tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }

        if let pendingRenameURL, selectItem(at: pendingRenameURL, startRenaming: true) {
            self.pendingRenameURL = nil
        }

        if pendingSelectionURL != nil, !newSelection.isEmpty {
            pendingSelectionURL = nil
        }
    }

    @discardableResult
    private func selectItem(at url: URL, startRenaming: Bool = false) -> Bool {
        guard let index = items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
            return false
        }

        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)

        guard startRenaming else { return true }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tableView.layoutSubtreeIfNeeded()
            self.tableView.scrollRowToVisible(index)
            self.startRenaming(at: index)
        }

        return true
    }

    private func sortItems() {
        FileItem.sort(&items, key: sortKey, ascending: sortAscending)
    }

    // MARK: - Sort Persistence

    private static let sortPreferencesKey = "directorySortPreferences"
    private static let maxSortPreferences = 200
    // lastAccessed bookkeeping accumulated in memory to avoid a UserDefaults write on every
    // navigation; merged into the persisted dictionary only when a save actually happens.
    private static var pendingAccessTimestamps: [String: TimeInterval] = [:]

    private func saveSortPreference() {
        let defaults = UserDefaults.standard
        var prefs = defaults.dictionary(forKey: Self.sortPreferencesKey) as? [String: [String: Any]] ?? [:]
        // Apply deferred access timestamps so LRU eviction reflects recent navigation.
        for (path, ts) in Self.pendingAccessTimestamps {
            if var entry = prefs[path] {
                entry["lastAccessed"] = ts
                prefs[path] = entry
            }
        }
        Self.pendingAccessTimestamps.removeAll()
        let path = currentURL.path
        prefs[path] = [
            "sortKey": sortKey,
            "sortAscending": sortAscending,
            "lastAccessed": Date().timeIntervalSince1970,
        ]
        if prefs.count > Self.maxSortPreferences {
            let sorted = prefs.sorted { lhs, rhs in
                let lTime = lhs.value["lastAccessed"] as? TimeInterval ?? 0
                let rTime = rhs.value["lastAccessed"] as? TimeInterval ?? 0
                return lTime < rTime
            }
            let toRemove = prefs.count - Self.maxSortPreferences
            for (key, _) in sorted.prefix(toRemove) {
                prefs.removeValue(forKey: key)
            }
        }
        defaults.set(prefs, forKey: Self.sortPreferencesKey)
    }

    private func loadSortPreference(for url: URL) {
        let defaults = UserDefaults.standard
        guard let prefs = defaults.dictionary(forKey: Self.sortPreferencesKey) as? [String: [String: Any]],
              let entry = prefs[url.path],
              let key = entry["sortKey"] as? String,
              let ascending = entry["sortAscending"] as? Bool else {
            sortKey = "name"
            sortAscending = true
            applySortDescriptorToTableView()
            return
        }
        sortKey = key
        sortAscending = ascending
        applySortDescriptorToTableView()

        // Defer lastAccessed bookkeeping to the next save instead of rewriting the whole
        // dictionary on every navigation.
        Self.pendingAccessTimestamps[url.path] = Date().timeIntervalSince1970
    }

    private func applySortDescriptorToTableView() {
        guard let column = tableView.tableColumns.first(where: { $0.sortDescriptorPrototype?.key == sortKey }),
              let prototype = column.sortDescriptorPrototype else { return }
        let descriptor = NSSortDescriptor(key: prototype.key, ascending: sortAscending, selector: prototype.selector)
        isRestoringSortPreference = true
        tableView.sortDescriptors = [descriptor]
        isRestoringSortPreference = false

        for col in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: col)
        }
        tableView.highlightedTableColumn = column
        let indicatorName = sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
        if let indicator = NSImage(named: NSImage.Name(indicatorName)) {
            tableView.setIndicatorImage(indicator, in: column)
        }
    }

    private func updateStatusBar() {
        let count = items.count
        let selectedCount = tableView.selectedRowIndexes.count
        let diskSpace = LocalFooterDiskSpaceCache.shared.diskSpace(at: currentURL)
        statusBar.stringValue = LocalFooterStatusFormatter.string(
            totalItemCount: count,
            selectedItemCount: selectedCount,
            availableDiskSpace: diskSpace
        )
        updateDirectoryHeader()
        LocalFooterDiskSpaceCache.shared.refreshIfNeeded(at: currentURL) { [weak self] refreshedURL in
            guard let self,
                  self.currentURL.standardizedFileURL == refreshedURL.standardizedFileURL else { return }
            self.updateStatusBar()
        }
    }

    private func updateDirectoryHeader() {
        directoryTitleLabel.stringValue = currentURL.displayName
        directoryTitleLabel.toolTip = currentURL.path
        directoryCountLabel.stringValue = items.count == 1 ? "1 item" : "\(items.count) items"
        directoryCapacityLabel.stringValue = LocalFooterDiskSpaceCache.shared.diskSpace(at: currentURL) ?? ""

        if let directoryStorageUsage {
            storageMeter.progress = directoryStorageUsage
            storageMeter.toolTip = "\(Int(directoryStorageUsage * 100))% used"
        } else {
            storageMeter.progress = 0
            storageMeter.toolTip = nil
        }
    }

    private func refreshDirectoryCapacity() {
        guard let values = try? currentURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
        ]),
        let total = values.volumeTotalCapacity,
        total > 0,
        let available = values.volumeAvailableCapacity else {
            directoryStorageUsage = nil
            return
        }
        directoryStorageUsage = min(max(1 - (Double(available) / Double(total)), 0), 1)
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
        FileOperationClipboard.write(urls, isCut: false)
    }

    func cutSelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileOperationClipboard.write(urls, isCut: true)
    }

    /// Set of file URLs currently marked as cut on the general pasteboard.
    private func cutURLs() -> Set<URL> {
        let pb = NSPasteboard.general
        if pb.changeCount != cachedCutChangeCount {
            cachedCutChangeCount = pb.changeCount
            if pb.string(forType: FileOperationClipboard.pasteboardType) == "cut",
               let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                cachedCutURLs = Set(urls.map { $0.standardizedFileURL })
            } else {
                cachedCutURLs = []
            }
        }
        return cachedCutURLs
    }

    /// Redraw visible rows so cut files dim (and previously-cut files un-dim) immediately.
    private func refreshCutIndication() {
        cachedCutChangeCount = -1
        let rows = IndexSet(integersIn: 0..<items.count)
        let cols = IndexSet(integersIn: 0..<tableView.numberOfColumns)
        tableView.reloadData(forRowIndexes: rows, columnIndexes: cols)
    }

    func pasteFiles() {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else { return }

        // Cut vs copy is determined solely by the private pasteboard type written atomically
        // with the URLs, so it stays correct across app relaunch and window boundaries.
        let isCut = pb.string(forType: FileOperationClipboard.pasteboardType) == "cut"
        let destination = currentURL

        performBackgroundTransfer(urls, to: destination, isMove: isCut) {
            guard isCut else { return }
            FileOperationClipboard.clear()
        }
    }

    @objc func copy(_ sender: Any?) {
        copySelectedFiles()
    }

    @objc func cut(_ sender: Any?) {
        cutSelectedFiles()
    }

    @objc func paste(_ sender: Any?) {
        pasteFiles()
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
                let records = try FileOperationService.shared.moveToTrashRecords(urls)
                self?.registerUndoTransfer(records: records, actionName: "Move to Trash")
            } catch {
                self?.registerUndoForCarriedRecords(from: error, actionName: "Move to Trash")
                self?.showError(error)
            }
        }
    }

    func createNewFolder() {
        do {
            let folderURL = try FileOperationService.shared.createNewFolder(in: currentURL)
            pendingSelectionURL = folderURL
            pendingRenameURL = folderURL
            reloadContents()
        } catch {
            showError(error)
        }
    }

    func openSelectedFile() {
        // Partition so a directory in the selection never short-circuits the loop and
        // drops the files after it. Open every file, then navigate to the first selected
        // directory (multiple directories: navigate to the first in selection order).
        let selection = selectedItems
        let directories = selection.filter { $0.isDirectory && !$0.isPackage }
        let files = selection.filter { !($0.isDirectory && !$0.isPackage) }

        for item in files {
            FileOperationService.shared.openFile(item.url)
        }
        if let firstDir = directories.first {
            delegate?.fileListDidNavigate(to: firstDir.url.resolvingSymlinksInPath())
        }
    }

    func startRenaming(at row: Int) {
        guard row >= 0, row < items.count else { return }
        guard let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let textField = cellView.textField else { return }
        editingRow = row
        editingURL = items[row].url
        textField.isEditable = true
        textField.delegate = self
        textField.selectText(nil)
        view.window?.makeFirstResponder(textField)
        selectEditableTitlePortion(for: items[row], in: textField)
    }

    private func selectEditableTitlePortion(for item: FileItem, in textField: NSTextField) {
        guard let fieldEditor = view.window?.fieldEditor(true, for: textField) else { return }
        fieldEditor.selectedRange = FileRenameHelper.defaultSelectionRange(for: item)
    }

    private func renameSelectedRow() {
        let row = tableView.selectedRow
        if row >= 0 {
            startRenaming(at: row)
        }
    }

    func toggleHiddenFiles() {
        showHiddenFiles.toggle()
        reloadContents()
    }

    func duplicateSelectedFiles() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }

        var records: [FileOperationService.FileTransferRecord] = []
        do {
            for url in urls {
                let newURL = try FileOperationService.shared.duplicate(url)
                records.append(FileOperationService.FileTransferRecord(sourceURL: url, destinationURL: newURL, undoBehavior: .trashDestination))
            }
            registerUndoTransfer(records: records, actionName: "Duplicate")
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

    private func registerUndoTransfer(records: [FileOperationService.FileTransferRecord], actionName: String) {
        let undoableRecords = records.filter(\.isUndoable)
        guard !undoableRecords.isEmpty, let undoManager = fileUndoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            do {
                try FileOperationService.shared.undoTransferRecords(undoableRecords)
                target.registerRedoTransfer(records: undoableRecords, actionName: actionName)
            } catch {
                target.showError(error)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func registerRedoTransfer(records: [FileOperationService.FileTransferRecord], actionName: String) {
        guard let undoManager = fileUndoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            do {
                try FileOperationService.shared.redoTransferRecords(records)
                target.registerUndoTransfer(records: records, actionName: actionName)
            } catch {
                target.showError(error)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func registerUndoForCarriedRecords(from error: Error, actionName: String) {
        switch error {
        case FileOperationService.FileOperationError.partialFailure(let records, _),
             FileOperationService.FileOperationError.cancelled(let records):
            registerUndoTransfer(records: records, actionName: actionName)
        default:
            break
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

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isRestoringSortPreference else { return }
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        sortKey = key
        sortAscending = descriptor.ascending
        saveSortPreference()
        let selectedURLs = Set(selectedItems.map(\.url))
        sortItems()
        tableView.reloadData()
        restoreSelection(previouslySelectedURLs: selectedURLs)

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
            return FileDropOperationResolver.preferredOperation(from: info.draggingSourceOperationMask)
        }
        if dropOperation == .above {
            return FileDropOperationResolver.preferredOperation(from: info.draggingSourceOperationMask)
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let destination = (dropOperation == .on && row < items.count && items[row].isDirectory) ? items[row].url : currentURL
        let isMove = FileDropOperationResolver.isMove(FileDropOperationResolver.preferredOperation(from: info.draggingSourceOperationMask))
        return performFileTransfer(urls, to: destination, isMove: isMove)
    }

    private func validateBackgroundDrop(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return FileDropOperationResolver.preferredOperation(from: info.draggingSourceOperationMask)
    }

    private func acceptBackgroundDrop(_ info: any NSDraggingInfo) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let isMove = FileDropOperationResolver.isMove(FileDropOperationResolver.preferredOperation(from: info.draggingSourceOperationMask))
        return performFileTransfer(urls, to: currentURL, isMove: isMove)
    }

    private func performFileTransfer(_ urls: [URL], to destination: URL, isMove: Bool) -> Bool {
        performBackgroundTransfer(urls, to: destination, isMove: isMove)
        return true
    }

    /// Routes every copy/move (drops and pastes) through the background progress coordinator so
    /// the main thread never blocks, then registers undo for the resulting (or partial) records.
    private func performBackgroundTransfer(_ urls: [URL], to destination: URL, isMove: Bool, onSuccess: (() -> Void)? = nil) {
        let actionName = isMove ? "Move" : "Copy"
        FileTransferCoordinator.perform(urls: urls, to: destination, isMove: isMove, presenter: self) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let records):
                onSuccess?()
                self.registerUndoTransfer(records: records, actionName: actionName)
                self.reloadContents()
            case .failure(let error):
                self.registerUndoForCarriedRecords(from: error, actionName: actionName)
                self.reloadContents()
                if !FileListViewController.isCancellation(error) {
                    self.showError(error)
                }
            }
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if case FileOperationService.FileOperationError.cancelled = error { return true }
        return false
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

        cell.textField?.font = .systemFont(ofSize: GroveUI.contentFontSize)
        // Dim rows whose files are currently cut, matching Finder.
        cell.alphaValue = cutURLs().contains(item.url.standardizedFileURL) ? 0.5 : 1.0

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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = GroveTableRowView()
        rowView.backgroundColor = row.isMultiple(of: 2)
            ? GroveUI.contentBackground
            : GroveUI.alternateRowBackground
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        GroveUI.listRowHeight
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
        case 36: // Enter / Ctrl+Enter — rename
            renameSelectedRow()
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
        guard row >= 0 else { return true }
        guard let editedURL = editingURL,
              let item = items.first(where: { $0.url.standardizedFileURL == editedURL.standardizedFileURL }) else {
            textField.isEditable = false
            editingRow = -1
            editingURL = nil
            return true
        }

        if newName != item.name && !newName.isEmpty {
            do {
                let newURL = try FileOperationService.shared.rename(item.url, to: newName)
                registerUndoTransfer(
                    records: [FileOperationService.FileTransferRecord(sourceURL: item.url, destinationURL: newURL, undoBehavior: .moveBackToSource)],
                    actionName: "Rename"
                )
                pendingSelectionURL = newURL
                reloadContents()
            } catch {
                showError(error)
            }
        }

        textField.isEditable = false
        editingRow = -1
        editingURL = nil
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Escape cancels the rename via the field editor without firing textShouldEndEditing,
        // which would otherwise leave editingRow/editingURL/isEditable stale for the next edit.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            control.abortEditing()
            (control as? NSTextField)?.isEditable = false
            editingRow = -1
            editingURL = nil
            view.window?.makeFirstResponder(tableView)
            return true
        }
        return false
    }
}

// MARK: - NSMenuDelegate (context menu)

extension FileListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = contextMenuRow ?? tableView.clickedRow

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
        addCopyPathMenuItem(to: copyPathSubmenu, format: .unix, action: #selector(contextCopyUnixPath(_:)))
        addCopyPathMenuItem(to: copyPathSubmenu, format: .hfs, action: #selector(contextCopyHFSPath(_:)))
        addCopyPathMenuItem(to: copyPathSubmenu, format: .windows, action: #selector(contextCopyWindowsPath(_:)))
        addCopyPathMenuItem(to: copyPathSubmenu, format: .terminal, action: #selector(contextCopyTerminalPath(_:)))
        addCopyPathMenuItem(to: copyPathSubmenu, format: .url, action: #selector(contextCopyURLPath(_:)))
        addCopyPathMenuItem(to: copyPathSubmenu, format: .name, action: #selector(contextCopyName(_:)))

        let copyPathItem = NSMenuItem(title: "Copy Path", action: nil, keyEquivalent: "")
        copyPathItem.submenu = copyPathSubmenu
        menu.addItem(copyPathItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename", action: #selector(contextRename(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Move to Trash", action: #selector(contextTrash(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        // Tags submenu
        let tagsSubmenu = buildTagsSubmenu()
        let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        tagsItem.submenu = tagsSubmenu
        menu.addItem(tagsItem)

        // Calculate Size (folders only)
        let selected = selectedItems
        let allDirectories = selected.allSatisfy { $0.isDirectory && !$0.isPackage }
        if allDirectories && !selected.isEmpty {
            let calcSizeItem = menu.addItem(withTitle: "Calculate Size", action: #selector(contextCalculateSize(_:)), keyEquivalent: "")
            calcSizeItem.target = self
        }

        // Checksum submenu (single file only, not directory)
        if selected.count == 1, let singleItem = selected.first, !singleItem.isDirectory {
            let checksumSubmenu = NSMenu()
            let md5Item = checksumSubmenu.addItem(withTitle: "Copy MD5", action: #selector(contextCopyMD5(_:)), keyEquivalent: "")
            md5Item.target = self
            let sha256Item = checksumSubmenu.addItem(withTitle: "Copy SHA-256", action: #selector(contextCopySHA256(_:)), keyEquivalent: "")
            sha256Item.target = self
            let checksumMenuItem = NSMenuItem(title: "Checksum", action: nil, keyEquivalent: "")
            checksumMenuItem.submenu = checksumSubmenu
            menu.addItem(checksumMenuItem)
        }

        // Compress / Extract
        menu.addItem(.separator())
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

        // Add to Favorites (directories only)
        if let clickedItem = clickedRow < items.count ? items[clickedRow] : nil,
           clickedItem.isDirectory && !clickedItem.isPackage {
            menu.addItem(.separator())
            let favItem = NSMenuItem(title: "Add to Favorites", action: #selector(contextAddToFavorites(_:)), keyEquivalent: "")
            favItem.target = self
            menu.addItem(favItem)
        }

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
        let clickedRow = contextMenuRow ?? tableView.clickedRow
        let row = clickedRow >= 0 ? clickedRow : tableView.selectedRow
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

    private func addCopyPathMenuItem(to menu: NSMenu, format: PathCopyFormat, action: Selector) {
        let item = menu.addItem(withTitle: format.menuTitle, action: action, keyEquivalent: "")
        item.target = self
    }

    @objc private func contextCopyUnixPath(_ sender: Any?) {
        copySelectedPaths(format: .unix)
    }

    @objc private func contextCopyHFSPath(_ sender: Any?) {
        copySelectedPaths(format: .hfs)
    }

    @objc private func contextCopyWindowsPath(_ sender: Any?) {
        copySelectedPaths(format: .windows)
    }

    @objc private func contextCopyTerminalPath(_ sender: Any?) {
        copySelectedPaths(format: .terminal)
    }

    @objc private func contextCopyURLPath(_ sender: Any?) {
        copySelectedPaths(format: .url)
    }

    @objc private func contextCopyName(_ sender: Any?) {
        copySelectedPaths(format: .name)
    }

    private func copySelectedPaths(format: PathCopyFormat) {
        let paths = selectedItems.map { PathCopyFormatter.string(for: $0.url, format: format) }
        guard !paths.isEmpty else { return }
        FileOperationClipboard.writeString(paths.joined(separator: "\n"))
    }

    static func terminalCopyPath(for url: URL) -> String {
        PathCopyFormatter.string(for: url, format: .terminal)
    }

    // MARK: - Calculate Size

    @objc private func contextCalculateSize(_ sender: Any?) {
        let folders = selectedItems.filter { $0.isDirectory && !$0.isPackage }
        guard !folders.isEmpty else { return }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let group = DispatchGroup()
        var results: [(String, Int64)] = []

        for folder in folders {
            group.enter()
            FolderSizeService.shared.calculateSize(for: folder.url) { size in
                results.append((folder.name, size))
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            let alert = NSAlert()
            alert.alertStyle = .informational
            if results.count == 1 {
                let (name, size) = results[0]
                alert.messageText = "Folder Size"
                alert.informativeText = "\(name): \(formatter.string(fromByteCount: size))"
            } else {
                alert.messageText = "Folder Sizes"
                let lines = results.map { "\($0.0): \(formatter.string(fromByteCount: $0.1))" }
                alert.informativeText = lines.joined(separator: "\n")
            }
            alert.addButton(withTitle: "OK")
            if let window = self?.view.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }

    // MARK: - Checksum

    @objc private func contextCopyMD5(_ sender: Any?) {
        copyChecksum(algorithm: .md5)
    }

    @objc private func contextCopySHA256(_ sender: Any?) {
        copyChecksum(algorithm: .sha256)
    }

    private func copyChecksum(algorithm: FileOperationService.ChecksumAlgorithm) {
        guard let item = selectedItems.first, !item.isDirectory else { return }
        FileOperationService.shared.computeChecksum(for: item.url, algorithm: algorithm) { [weak self] result in
            switch result {
            case .success(let hash):
                FileOperationClipboard.writeString(hash)
            case .failure(let error):
                self?.showError(error)
            }
        }
    }

    // MARK: - Add to Favorites

    @objc private func contextAddToFavorites(_ sender: Any?) {
        let row = contextMenuRow ?? tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        guard item.isDirectory && !item.isPackage else { return }
        NotificationCenter.default.post(name: .addToSidebarFavorites, object: nil, userInfo: ["url": item.url])
    }

    // MARK: - Open in Terminal

    @objc private func contextOpenInTerminal(_ sender: NSMenuItem) {
        let targetURL: URL
        if let url = sender.representedObject as? URL {
            targetURL = url
        } else {
            targetURL = currentURL
        }

        TerminalLauncher.open(at: targetURL, presentingView: view)
    }

    static func terminalChangeDirectoryScript(for url: URL) -> String {
        TerminalLauncher.changeDirectoryScript(for: url)
    }

    // MARK: - Tags

    private func buildTagsSubmenu() -> NSMenu {
        let menu = NSMenu()
        let selected = selectedItems
        let currentTags: Set<String> = {
            guard let first = selected.first else { return [] }
            let firstTags = Set(FileItem.tags(for: first.url))
            if selected.count == 1 { return firstTags }
            // For multiple selection, show common tags as checked
            return selected.dropFirst().reduce(firstTags) { commonTags, item in
                commonTags.intersection(Set(FileItem.tags(for: item.url)))
            }
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
            var tags = FileItem.tags(for: item.url)
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
            FileOperationService.shared.decompressToUniqueFolder(url, password: password) { [weak self] result in
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
    func batchRenameDidComplete(records: [FileOperationService.FileTransferRecord]) {
        registerUndoTransfer(records: records, actionName: "Rename")
        reloadContents()
    }
}
