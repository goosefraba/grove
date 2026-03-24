import AppKit

final class GoToFolderPanelController: NSObject, NSTextFieldDelegate {

    private var panel: NSPanel?
    private var textField: NSTextField?
    var onNavigate: ((URL) -> Void)?

    func showPanel(relativeTo window: NSWindow) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Go to Folder"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        self.panel = panel

        let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = contentView

        let label = NSTextField(labelWithString: "Enter a path to go to:")
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)

        let textField = NSTextField()
        textField.placeholderString = "~/Documents or /usr/local"
        textField.font = .systemFont(ofSize: 13)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.delegate = self
        textField.stringValue = "~/"
        textField.setAccessibilityLabel("Folder path")
        textField.setAccessibilityIdentifier("goToFolderPathField")
        self.textField = textField
        contentView.addSubview(textField)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

        let goButton = NSButton(title: "Go", target: self, action: #selector(goClicked(_:)))
        goButton.keyEquivalent = "\r"
        goButton.bezelStyle = .rounded
        goButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(goButton)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            textField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            textField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            textField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            goButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            goButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            goButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),

            cancelButton.trailingAnchor.constraint(equalTo: goButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: goButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])

        window.beginSheet(panel) { _ in }
        panel.makeFirstResponder(textField)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismissPanel()
    }

    @objc private func goClicked(_ sender: Any?) {
        guard let textField = textField else { return }
        let rawPath = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !rawPath.isEmpty else { return }

        let expandedPath = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath).standardizedFileURL

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            showError("The folder \"\(rawPath)\" doesn't exist.")
            return
        }
        guard isDir.boolValue else {
            showError("The path \"\(rawPath)\" is not a folder.")
            return
        }

        dismissPanel()
        onNavigate?(url)
    }

    private func showError(_ message: String) {
        guard let panel = panel else { return }
        let alert = NSAlert()
        alert.messageText = "Cannot Open Folder"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: panel, completionHandler: nil)
    }

    private func dismissPanel() {
        guard let panel = panel,
              let parentWindow = panel.sheetParent else { return }
        parentWindow.endSheet(panel)
        self.panel = nil
        self.textField = nil
    }

    // MARK: - NSTextFieldDelegate (path completion)

    func control(_ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        let currentText = textView.string
        let expandedPath = (currentText as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        let parentDir: URL
        let prefix: String

        if expandedPath.hasSuffix("/") {
            parentDir = url
            prefix = ""
        } else {
            parentDir = url.deletingLastPathComponent()
            prefix = url.lastPathComponent
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parentDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let matches = contents.compactMap { childURL -> String? in
            let name = childURL.lastPathComponent
            guard prefix.isEmpty || name.localizedCaseInsensitiveCompare(prefix) == .orderedSame ||
                  name.lowercased().hasPrefix(prefix.lowercased()) else {
                return nil
            }
            let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return nil }

            if currentText.hasPrefix("~") {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let fullPath = childURL.path + "/"
                if fullPath.hasPrefix(home) {
                    return "~" + fullPath.dropFirst(home.count)
                }
            }
            return childURL.path + "/"
        }

        index.pointee = matches.isEmpty ? -1 : 0
        return matches.sorted()
    }
}
