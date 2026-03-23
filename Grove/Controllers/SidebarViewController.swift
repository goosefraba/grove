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

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 200, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadItems()
        setupOutlineView()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(volumesChanged(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
        ws.addObserver(self, selector: #selector(volumesChanged(_:)),
                       name: NSWorkspace.didUnmountNotification, object: nil)
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
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false

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
            return cell
        }

        return nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        delegate?.sidebarDidSelect(url: item.url)
    }

    func selectItem(for url: URL) {
        for section in sections {
            guard let sectionItems = items[section] else { continue }
            for sidebarItem in sectionItems {
                if sidebarItem.url == url {
                    let row = outlineView.row(forItem: sidebarItem)
                    if row >= 0 {
                        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
                    return
                }
            }
        }
        outlineView.deselectAll(nil)
    }
}
