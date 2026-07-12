import AppKit

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarDidSelect(url: URL)
    func sidebarDidSelect(location: StorageLocation)
}

extension SidebarViewControllerDelegate {
    func sidebarDidSelect(location: StorageLocation) {
        guard case .local(let url) = location else { return }
        sidebarDidSelect(url: url)
    }
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    weak var delegate: SidebarViewControllerDelegate?

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()

    private let sections = SidebarSection.allCases
    private var items: [SidebarSection: [SidebarItem]] = [:]

    private var suppressSelectionCallback = false
    private var contextMenuItem: SidebarItem?
    private var contextMenuRow: Int?
    private var volumeRefreshWorkItem: DispatchWorkItem?
    private var cachedDragSequence: Int?
    private var cachedDragOperation: NSDragOperation = []
    private static let sidebarItemPasteboardType = NSPasteboard.PasteboardType("com.grove.sidebaritem")
    private static let sidebarDetailLabelTag = 1_207

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 200, height: 400))
    }

    deinit {
        volumeRefreshWorkItem?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadItems()
        setupOutlineView()
        setupAccessibility()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(volumesChanged(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
        ws.addObserver(self, selector: #selector(volumesChanged(_:)),
                       name: NSWorkspace.willUnmountNotification, object: nil)
        ws.addObserver(self, selector: #selector(volumesChanged(_:)),
                       name: NSWorkspace.didUnmountNotification, object: nil)
        ws.addObserver(self, selector: #selector(volumesChanged(_:)),
                       name: NSWorkspace.didRenameVolumeNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(handleAddToFavorites(_:)),
                                               name: .addToSidebarFavorites, object: nil)
    }

    private func setupAccessibility() {
        outlineView.setAccessibilityRole(.outline)
        outlineView.setAccessibilityLabel("Sidebar")
        outlineView.setAccessibilityIdentifier("sidebarOutlineView")
        scrollView.setAccessibilityIdentifier("sidebarScrollView")
    }

    @objc private func volumesChanged(_ notification: Notification) {
        scheduleVolumeRefresh()
    }

    private func scheduleVolumeRefresh() {
        volumeRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.reloadLocationsPreservingSelection()
        }
        volumeRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func reloadLocationsPreservingSelection() {
        let selectedLocation = selectedSidebarItem()?.location
        items[.locations] = SidebarItem.volumes()
        outlineView.reloadData()
        expandAllSections()

        if let selectedLocation {
            selectItem(for: selectedLocation)
        }
    }

    private func selectedSidebarItem() -> SidebarItem? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? SidebarItem
    }

    private func sidebarItem(from sender: Any?) -> SidebarItem? {
        if let menuItem = sender as? NSMenuItem,
           let sidebarItem = menuItem.representedObject as? SidebarItem {
            return sidebarItem
        }
        return contextMenuItem
    }

    private func expandAllSections() {
        for section in sections {
            outlineView.expandItem(section)
        }
    }

    private func reloadItems() {
        items[.favorites] = SidebarItem.favorites
        items[.locations] = SidebarItem.volumes()
        items[.cloud] = SidebarItem.cloudItems
    }

    private func setupOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.title = ""
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .default
        outlineView.rowHeight = 22
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false

        outlineView.registerForDraggedTypes([.fileURL, Self.sidebarItemPasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        outlineView.reloadData()

        expandAllSections()
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return sections.count
        }
        if let section = item as? SidebarSection {
            return items[section]?.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sections[index]
        }
        if let section = item as? SidebarSection {
            return (items[section] ?? [])[index]
        }
        fatalError("Unexpected outline view item")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarSection
    }

    // MARK: - Drag Source (for reordering)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let sidebarItem = item as? SidebarItem,
              sidebarItem.section == .favorites else { return nil }

        let pbItem = NSPasteboardItem()
        pbItem.setString(sidebarItem.url.path, forType: Self.sidebarItemPasteboardType)
        return pbItem
    }

    // MARK: - Drop Target

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if info.draggingPasteboard.types?.contains(Self.sidebarItemPasteboardType) == true {
            guard let section = item as? SidebarSection, section == .favorites, index != NSOutlineViewDropOnItemIndex else {
                return []
            }
            let builtInCount = SidebarItem.builtInFavorites.count
            if index < builtInCount {
                outlineView.setDropItem(item, dropChildIndex: builtInCount)
            }
            return .move
        }

        guard let section = item as? SidebarSection, section == .favorites else {
            if let sidebarItem = item as? SidebarItem, sidebarItem.section == .favorites {
                let favoritesSection = sections[0]
                let favoritesItems = items[.favorites] ?? []
                outlineView.setDropItem(favoritesSection, dropChildIndex: favoritesItems.count)
                return validateExternalDrop(info)
            }
            return []
        }

        return validateExternalDrop(info)
    }

    private func validateExternalDrop(_ info: any NSDraggingInfo) -> NSDragOperation {
        // Pasteboard reads + file stats are expensive and validateDrop fires on every
        // mouse-move tick; cache the result per dragging session (#43).
        let sequence = info.draggingSequenceNumber
        if cachedDragSequence == sequence {
            return cachedDragOperation
        }
        let operation = computeExternalDropOperation(info)
        cachedDragSequence = sequence
        cachedDragOperation = operation
        return operation
    }

    private func computeExternalDropOperation(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] else {
            return []
        }

        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return []
            }
        }

        return urls.isEmpty ? [] : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if info.draggingPasteboard.types?.contains(Self.sidebarItemPasteboardType) == true {
            return acceptReorderDrop(info: info, targetIndex: index)
        }
        return acceptExternalDrop(info: info, targetIndex: index)
    }

    private func acceptReorderDrop(info: any NSDraggingInfo, targetIndex: Int) -> Bool {
        guard let path = info.draggingPasteboard.string(forType: Self.sidebarItemPasteboardType) else { return false }

        let allFavorites = items[.favorites] ?? []
        let builtInCount = SidebarItem.builtInFavorites.count

        guard let sourceIndex = allFavorites.firstIndex(where: { $0.url.path == path }) else { return false }
        let draggedItem = allFavorites[sourceIndex]

        guard !draggedItem.isBuiltIn else { return false }

        var customFavs = SidebarItem.customFavorites
        let customSourceIndex = sourceIndex - builtInCount
        guard customSourceIndex >= 0, customSourceIndex < customFavs.count else { return false }

        customFavs.remove(at: customSourceIndex)

        var adjustedTarget = targetIndex
        if sourceIndex < targetIndex {
            adjustedTarget -= 1
        }
        var customTargetIndex = adjustedTarget - builtInCount
        if customTargetIndex < 0 { customTargetIndex = 0 }
        if customTargetIndex > customFavs.count { customTargetIndex = customFavs.count }

        customFavs.insert(draggedItem, at: customTargetIndex)

        SidebarItem.saveCustomFavorites(customFavs)
        reloadItems()
        outlineView.reloadData()
        expandAllSections()
        return true
    }

    private func acceptExternalDrop(info: any NSDraggingInfo, targetIndex: Int) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] else {
            return false
        }

        var customFavs = SidebarItem.customFavorites
        let allFavorites = items[.favorites] ?? []
        let builtInCount = SidebarItem.builtInFavorites.count
        var customTargetIndex: Int
        if targetIndex < 0 {
            customTargetIndex = customFavs.count
        } else {
            customTargetIndex = targetIndex - builtInCount
            if customTargetIndex < 0 { customTargetIndex = 0 }
            if customTargetIndex > customFavs.count { customTargetIndex = customFavs.count }
        }

        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            if allFavorites.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                continue
            }
            if customFavs.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                continue
            }

            let title = url.lastPathComponent
            let newItem = SidebarItem(
                title: title,
                url: url,
                systemImage: "folder",
                section: .favorites,
                isBuiltIn: false
            )
            customFavs.insert(newItem, at: customTargetIndex)
            customTargetIndex += 1
        }

        SidebarItem.saveCustomFavorites(customFavs)
        reloadItems()
        outlineView.reloadData()
        expandAllSections()
        return true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarItem
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            let cell = outlineView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("HeaderCell"),
                owner: self
            ) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("HeaderCell")

            if cell.textField == nil {
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(tf)
                cell.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            cell.textField?.stringValue = section.rawValue
            cell.textField?.font = .systemFont(ofSize: GroveUI.sidebarSectionFontSize, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
            cell.setAccessibilityLabel("Section: \(section.rawValue)")
            cell.setAccessibilityRole(.group)
            return cell
        }

        if let sidebarItem = item as? SidebarItem {
            let cell = outlineView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("DataCell"),
                owner: self
            ) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("DataCell")

            if cell.textField == nil {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(iv)
                cell.imageView = iv

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                cell.addSubview(tf)
                cell.textField = tf

                let detail = NSTextField(labelWithString: "")
                detail.translatesAutoresizingMaskIntoConstraints = false
                detail.tag = Self.sidebarDetailLabelTag
                detail.font = .systemFont(ofSize: 10, weight: .medium)
                detail.textColor = .tertiaryLabelColor
                detail.lineBreakMode = .byTruncatingTail
                detail.setContentCompressionResistancePriority(.required, for: .horizontal)
                detail.setContentHuggingPriority(.required, for: .horizontal)
                cell.addSubview(detail)

                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    detail.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                    detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            let detail = cell.viewWithTag(Self.sidebarDetailLabelTag) as? NSTextField
            detail?.stringValue = sidebarItem.sidebarDetail ?? ""
            detail?.isHidden = sidebarItem.sidebarDetail == nil

            cell.textField?.stringValue = sidebarItem.title
            cell.textField?.font = .systemFont(ofSize: GroveUI.sidebarFontSize)
            cell.imageView?.image = NSImage(
                systemSymbolName: sidebarItem.systemImage,
                accessibilityDescription: sidebarItem.title
            ) ?? NSImage(systemSymbolName: "externaldrive", accessibilityDescription: sidebarItem.title)
            cell.imageView?.contentTintColor = sidebarIconTint(for: sidebarItem)
            cell.toolTip = sidebarItem.toolTip
            let accessibilityLabel = [sidebarItem.title, sidebarItem.sidebarDetail, sidebarItem.toolTip]
                .compactMap { $0 }
                .joined(separator: " - ")
            cell.setAccessibilityLabel(accessibilityLabel)
            cell.setAccessibilityIdentifier("sidebar_\(sidebarItem.title)")
            return cell
        }

        return nil
    }

    private func sidebarIconTint(for item: SidebarItem) -> NSColor {
        guard let kind = item.mountedVolume?.kind else {
            return .controlAccentColor
        }

        switch kind {
        case .diskImage:
            return .systemOrange
        case .network:
            return .systemTeal
        case .internalDisk, .localVolume:
            return .secondaryLabelColor
        case .removable, .external:
            return .controlAccentColor
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        delegate?.sidebarDidSelect(location: item.location)
    }

    func selectItem(for url: URL) {
        selectItem(for: .local(url.standardizedFileURL))
    }

    func selectItem(for location: StorageLocation) {
        suppressSelectionCallback = true
        defer { suppressSelectionCallback = false }
        for section in sections {
            guard let sectionItems = items[section] else { continue }
            for sidebarItem in sectionItems {
                if sidebarItem.location == location || sidebarItem.representsProvider(of: location) {
                    let row = outlineView.row(forItem: sidebarItem)
                    if row >= 0 {
                        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
                    suppressSelectionCallback = false
                    return
                }
            }
        }
        outlineView.deselectAll(nil)
    }

    // MARK: - Context Menu Action

    @objc private func handleAddToFavorites(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }

        let allFavorites = items[.favorites] ?? []
        guard !allFavorites.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }

        var customFavs = SidebarItem.customFavorites
        guard !customFavs.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }

        let newItem = SidebarItem(
            title: url.lastPathComponent,
            url: url,
            systemImage: "folder",
            section: .favorites,
            isBuiltIn: false
        )
        customFavs.append(newItem)
        SidebarItem.saveCustomFavorites(customFavs)
        reloadItems()
        outlineView.reloadData()
        expandAllSections()
    }

    @objc private func removeFromSidebar(_ sender: Any) {
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0,
              let sidebarItem = outlineView.item(atRow: clickedRow) as? SidebarItem,
              sidebarItem.section == .favorites,
              !sidebarItem.isBuiltIn else { return }

        var customFavs = SidebarItem.customFavorites
        customFavs.removeAll { $0.url.path == sidebarItem.url.path }
        SidebarItem.saveCustomFavorites(customFavs)
        reloadItems()
        outlineView.reloadData()
        expandAllSections()
    }

    @objc private func browseSidebarItem(_ sender: Any) {
        guard let sidebarItem = sidebarItem(from: sender) else { return }
        suppressSelectionCallback = true
        let row = contextMenuRow ?? outlineView.row(forItem: sidebarItem)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        suppressSelectionCallback = false
        delegate?.sidebarDidSelect(location: sidebarItem.location)
    }

    @objc private func revealSidebarItemInFinder(_ sender: Any) {
        guard let sidebarItem = sidebarItem(from: sender),
              let url = sidebarItem.location.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copySidebarUnixPath(_ sender: Any) {
        copySidebarPath(format: .unix, sender: sender)
    }

    @objc private func copySidebarHFSPath(_ sender: Any) {
        copySidebarPath(format: .hfs, sender: sender)
    }

    @objc private func copySidebarWindowsPath(_ sender: Any) {
        copySidebarPath(format: .windows, sender: sender)
    }

    @objc private func copySidebarTerminalPath(_ sender: Any) {
        copySidebarPath(format: .terminal, sender: sender)
    }

    @objc private func copySidebarURLPath(_ sender: Any) {
        copySidebarPath(format: .url, sender: sender)
    }

    @objc private func copySidebarName(_ sender: Any) {
        copySidebarPath(format: .name, sender: sender)
    }

    private func copySidebarPath(format: PathCopyFormat, sender: Any) {
        guard let sidebarItem = sidebarItem(from: sender),
              let url = sidebarItem.location.localURL else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(PathCopyFormatter.string(for: url, format: format), forType: .string)
    }

    @objc private func ejectMountedVolume(_ sender: Any) {
        guard let sidebarItem = sidebarItem(from: sender),
              let mountedVolume = sidebarItem.mountedVolume,
              mountedVolume.supportsEject else { return }

        // Unmount can block for a long time on busy or network volumes; run it off the
        // main thread so the UI stays responsive and report results back on main (#46).
        let url = mountedVolume.url
        let volumeName = mountedVolume.displayName
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleVolumeRefresh()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.showVolumeEjectError(error, volumeName: volumeName)
                }
            }
        }
    }

    private func showVolumeEjectError(_ error: Error, volumeName: String) {
        let alert = NSAlert()
        alert.messageText = "Could not eject \(volumeName)"
        alert.informativeText = (error as NSError).localizedDescription
        alert.alertStyle = .warning

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - NSMenuDelegate

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        contextMenuItem = nil
        contextMenuRow = nil

        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0,
              let sidebarItem = outlineView.item(atRow: clickedRow) as? SidebarItem else { return }
        contextMenuItem = sidebarItem
        contextMenuRow = clickedRow

        let browseItem = NSMenuItem(
            title: "Browse",
            action: #selector(browseSidebarItem(_:)),
            keyEquivalent: ""
        )
        browseItem.target = self
        browseItem.representedObject = sidebarItem
        menu.addItem(browseItem)

        if sidebarItem.location.localURL != nil {
            let revealItem = NSMenuItem(
                title: "Reveal in Finder",
                action: #selector(revealSidebarItemInFinder(_:)),
                keyEquivalent: ""
            )
            revealItem.target = self
            revealItem.representedObject = sidebarItem
            menu.addItem(revealItem)

            let copyPathItem = NSMenuItem(title: "Copy Path", action: nil, keyEquivalent: "")
            copyPathItem.submenu = buildCopyPathSubmenu(for: sidebarItem)
            menu.addItem(copyPathItem)
        }

        if let mountedVolume = sidebarItem.mountedVolume {
            if mountedVolume.supportsEject {
                menu.addItem(.separator())
                let ejectItem = NSMenuItem(
                    title: "Eject \(mountedVolume.displayName)",
                    action: #selector(ejectMountedVolume(_:)),
                    keyEquivalent: ""
                )
                ejectItem.target = self
                ejectItem.representedObject = sidebarItem
                menu.addItem(ejectItem)
            }
            return
        }

        guard sidebarItem.section == .favorites, !sidebarItem.isBuiltIn else { return }

        menu.addItem(.separator())

        let removeItem = NSMenuItem(
            title: "Remove from Sidebar",
            action: #selector(removeFromSidebar(_:)),
            keyEquivalent: ""
        )
        removeItem.target = self
        menu.addItem(removeItem)
    }

    private func buildCopyPathSubmenu(for sidebarItem: SidebarItem) -> NSMenu {
        let submenu = NSMenu()
        addCopyPathMenuItem(to: submenu, format: .unix, action: #selector(copySidebarUnixPath(_:)), sidebarItem: sidebarItem)
        addCopyPathMenuItem(to: submenu, format: .hfs, action: #selector(copySidebarHFSPath(_:)), sidebarItem: sidebarItem)
        addCopyPathMenuItem(to: submenu, format: .windows, action: #selector(copySidebarWindowsPath(_:)), sidebarItem: sidebarItem)
        addCopyPathMenuItem(to: submenu, format: .terminal, action: #selector(copySidebarTerminalPath(_:)), sidebarItem: sidebarItem)
        addCopyPathMenuItem(to: submenu, format: .url, action: #selector(copySidebarURLPath(_:)), sidebarItem: sidebarItem)
        addCopyPathMenuItem(to: submenu, format: .name, action: #selector(copySidebarName(_:)), sidebarItem: sidebarItem)
        return submenu
    }

    private func addCopyPathMenuItem(
        to menu: NSMenu,
        format: PathCopyFormat,
        action: Selector,
        sidebarItem: SidebarItem
    ) {
        let item = menu.addItem(withTitle: format.menuTitle, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = sidebarItem
    }
}
