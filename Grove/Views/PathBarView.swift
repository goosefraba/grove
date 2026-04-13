import AppKit

final class PathBarView: NSView {

    var onPathComponentClicked: ((URL) -> Void)?

    private var buttons: [NSButton] = []
    private let stackView = NSStackView()
    private var currentComponents: [URL] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        stackView.orientation = .horizontal
        stackView.spacing = 2
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func update(for url: URL) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let components = url.pathComponents_
        currentComponents = components

        for (index, component) in components.enumerated() {
            if index > 0 {
                let separator = NSTextField(labelWithString: "\u{203A}")
                separator.font = .systemFont(ofSize: 12)
                separator.textColor = .tertiaryLabelColor
                stackView.addArrangedSubview(separator)
            }

            let button = NSButton(title: component.displayName, target: self, action: #selector(pathComponentClicked(_:)))
            button.bezelStyle = .recessed
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.tag = index
            button.toolTip = component.path
            button.setAccessibilityLabel("Path component: \(component.path)")
            button.setAccessibilityIdentifier("pathBarComponent_\(index)")

            // Navigate on normal click; reserve alternate click for sibling menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseDown])

            buttons.append(button)
            stackView.addArrangedSubview(button)
        }
    }

    @objc private func pathComponentClicked(_ sender: NSButton) {
        guard sender.tag < currentComponents.count else { return }
        let clickedURL = currentComponents[sender.tag]

        guard let event = NSApp.currentEvent else {
            onPathComponentClicked?(clickedURL)
            return
        }

        let shouldShowSiblingMenu =
            event.type == .rightMouseDown ||
            event.modifierFlags.contains(.control)

        if shouldShowSiblingMenu {
            showSiblingMenu(for: clickedURL, relativeTo: sender)
        } else {
            onPathComponentClicked?(clickedURL)
        }
    }

    private func showSiblingMenu(for url: URL, relativeTo button: NSButton) {
        let parentURL = url.deletingLastPathComponent()

        // Build menu with sibling directories
        let menu = NSMenu()

        // Add current directory item at top, checked
        let currentItem = NSMenuItem(title: url.displayName, action: #selector(siblingMenuItemClicked(_:)), keyEquivalent: "")
        currentItem.target = self
        currentItem.representedObject = url
        currentItem.image = iconForURL(url)
        currentItem.state = .on
        menu.addItem(currentItem)

        // Enumerate sibling directories
        let siblings = siblingDirectories(of: url, in: parentURL)
        if !siblings.isEmpty {
            menu.addItem(.separator())
            for sibling in siblings {
                let item = NSMenuItem(title: sibling.displayName, action: #selector(siblingMenuItemClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = sibling
                item.image = iconForURL(sibling)
                menu.addItem(item)
            }
        }

        // Show the menu below the button
        let point = NSPoint(x: 0, y: button.bounds.maxY + 2)
        menu.popUp(positioning: nil, at: point, in: button)
    }

    private func siblingDirectories(of url: URL, in parentURL: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { childURL in
                guard childURL.standardizedFileURL != url.standardizedFileURL else { return false }
                let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                let isDir = values?.isDirectory ?? false
                let isPackage = values?.isPackage ?? false
                return isDir && !isPackage
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func iconForURL(_ url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @objc private func siblingMenuItemClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onPathComponentClicked?(url)
    }
}
