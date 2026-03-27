import AppKit

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarDidSelect(url: URL)
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    weak var delegate: SidebarViewControllerDelegate?

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()

    private let sections = SidebarSection.allCases
    private var items: [SidebarSection: [SidebarItem]] = [:]

    private var suppressSelectionCallback = false
    private static let sidebarItemPasteboardType = NSPasteboard.PasteboardType("com.grove.sidebaritem")

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 200, height: 400))
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
                       name: NSWorkspace.didUnmountNotification, object: nil)

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
        items[.locations] = SidebarItem.volumes()
        outlineView.reloadData()
        for section in sections {
            outlineView.expandItem(section)
        }
    }

    private func reloadItems() {
        items[.favorites] = SidebarItem.favorites
        items[.locations] = SidebarItem.volumes()
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

        for section in sections {
            outlineView.expandItem(section)
        }
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
        for section in sections {
            outlineView.expandItem(section)
        }
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
            customFavs.append(newItem)
        }

        SidebarItem.saveCustomFavorites(customFavs)
        reloadItems()
        outlineView.reloadData()
        for section in sections {
            outlineView.expandItem(section)
        }
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
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
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
                cell.addSubview(tf)
                cell.textField = tf

                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            cell.textField?.stringValue = sidebarItem.title
            cell.imageView?.image = NSImage(systemSymbolName: sidebarItem.systemImage, accessibilityDescription: sidebarItem.title)
            cell.imageView?.contentTintColor = .controlAccentColor
            cell.setAccessibilityLabel("\(sidebarItem.title) - \(sidebarItem.url.path)")
            cell.setAccessibilityIdentifier("sidebar_\(sidebarItem.title)")
            return cell
        }

        return nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        delegate?.sidebarDidSelect(url: item.url)
    }

    func selectItem(for url: URL) {
        suppressSelectionCallback = true
        defer { suppressSelectionCallback = false }
        for section in sections {
            guard let sectionItems = items[section] else { continue }
            for sidebarItem in sectionItems {
                if sidebarItem.url == url {
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
        for section in sections {
            outlineView.expandItem(section)
        }
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
        for section in sections {
            outlineView.expandItem(section)
        }
    }
}

// MARK: - NSMenuDelegate

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0,
              let sidebarItem = outlineView.item(atRow: clickedRow) as? SidebarItem,
              sidebarItem.section == .favorites,
              !sidebarItem.isBuiltIn else { return }

        let removeItem = NSMenuItem(
            title: "Remove from Sidebar",
            action: #selector(removeFromSidebar(_:)),
            keyEquivalent: ""
        )
        removeItem.target = self
        menu.addItem(removeItem)
    }
}
