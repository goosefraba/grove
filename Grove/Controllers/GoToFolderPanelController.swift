import AppKit

final class GoToFolderPanelController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private var panel: NSPanel?
    private var textField: NSTextField?
    private var suggestionsTableView: NSTableView?
    private var suggestionsScrollView: NSScrollView?
    private var panelHeightConstraint: NSLayoutConstraint?
    private var suggestions: [String] = []
    private var selectedSuggestionIndex: Int = -1
    var onNavigate: ((URL) -> Void)?

    private static let historyKey = "goToFolderHistory"
    private static let maxHistoryCount = 20
    private static let collapsedPanelHeight: CGFloat = 130
    private static let suggestionsRowHeight: CGFloat = 22
    private static let maxVisibleSuggestions = 8

    // MARK: - History

    private var history: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.historyKey) }
    }

    private func addToHistory(_ path: String) {
        var h = history
        h.removeAll { $0 == path }
        h.insert(path, at: 0)
        if h.count > Self.maxHistoryCount {
            h = Array(h.prefix(Self.maxHistoryCount))
        }
        history = h
    }

    // MARK: - Panel

    func showPanel(relativeTo window: NSWindow) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: Self.collapsedPanelHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Go to Folder"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 420, height: Self.collapsedPanelHeight)
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

        // Suggestions table
        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = Self.suggestionsRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(suggestionDoubleClicked(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Path"))
        column.isEditable = false
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = true
        contentView.addSubview(scrollView)

        self.suggestionsTableView = tableView
        self.suggestionsScrollView = scrollView

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
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

            scrollView.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            goButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            goButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            goButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            goButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),

            cancelButton.trailingAnchor.constraint(equalTo: goButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: goButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])

        // Scroll view height starts at 0 (hidden)
        let heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        self.panelHeightConstraint = heightConstraint

        window.beginSheet(panel) { _ in }
        panel.makeFirstResponder(textField)

        // Show history initially
        updateSuggestions()
    }

    // MARK: - Suggestions

    private func updateSuggestions() {
        guard let textField = textField else { return }
        let text = textField.stringValue.trimmingCharacters(in: .whitespaces)

        if text.isEmpty {
            // Show recent history
            suggestions = history
        } else if text.hasPrefix("/") || text.hasPrefix("~") {
            // Filesystem path completion
            suggestions = filesystemCompletions(for: text)
        } else {
            // Fuzzy match against history
            let lower = text.lowercased()
            suggestions = history.filter { $0.lowercased().contains(lower) }
        }

        selectedSuggestionIndex = -1
        suggestionsTableView?.reloadData()

        let visibleRows = min(suggestions.count, Self.maxVisibleSuggestions)
        let tableHeight = CGFloat(visibleRows) * Self.suggestionsRowHeight + 4
        let showSuggestions = !suggestions.isEmpty

        suggestionsScrollView?.isHidden = !showSuggestions
        panelHeightConstraint?.constant = showSuggestions ? tableHeight : 0

        // Resize panel content to fit suggestions
        if let panel = panel {
            let extraHeight = showSuggestions ? tableHeight + 6 : 0
            let targetHeight = Self.collapsedPanelHeight + extraHeight
            var frame = panel.frame
            let delta = targetHeight - frame.height
            frame.size.height = targetHeight
            frame.origin.y -= delta
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    private func filesystemCompletions(for text: String) -> [String] {
        let expandedPath = (text as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        let parentDir: URL
        let prefix: String

        if expandedPath.hasSuffix("/") {
            parentDir = url
            prefix = ""
        } else {
            parentDir = url.deletingLastPathComponent()
            prefix = url.lastPathComponent.lowercased()
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parentDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let matches = contents.compactMap { childURL -> String? in
            let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return nil }
            let name = childURL.lastPathComponent.lowercased()
            guard prefix.isEmpty || name.hasPrefix(prefix) else { return nil }

            let fullPath = childURL.path + "/"
            if text.hasPrefix("~") {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                if fullPath.hasPrefix(home) {
                    return "~" + fullPath.dropFirst(home.count)
                }
            }
            return fullPath
        }

        return matches.sorted()
    }

    private func acceptSuggestion(at index: Int) {
        guard index >= 0, index < suggestions.count, let textField = textField else { return }
        textField.stringValue = suggestions[index]
        textField.currentEditor()?.moveToEndOfDocument(nil)
        updateSuggestions()
    }

    // MARK: - Actions

    @objc private func cancelClicked(_ sender: Any?) {
        dismissPanel()
    }

    @objc private func goClicked(_ sender: Any?) {
        // If a suggestion is selected, use it
        if selectedSuggestionIndex >= 0, selectedSuggestionIndex < suggestions.count {
            textField?.stringValue = suggestions[selectedSuggestionIndex]
        }

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

        addToHistory(rawPath)
        dismissPanel()
        onNavigate?(url)
    }

    @objc private func suggestionDoubleClicked(_ sender: Any?) {
        guard let tableView = suggestionsTableView else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < suggestions.count else { return }
        textField?.stringValue = suggestions[row]
        goClicked(nil)
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
        self.suggestionsTableView = nil
        self.suggestionsScrollView = nil
        self.panelHeightConstraint = nil
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === textField else { return }
        updateSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            if !suggestions.isEmpty {
                selectedSuggestionIndex = min(selectedSuggestionIndex + 1, suggestions.count - 1)
                suggestionsTableView?.selectRowIndexes(IndexSet(integer: selectedSuggestionIndex), byExtendingSelection: false)
                suggestionsTableView?.scrollRowToVisible(selectedSuggestionIndex)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            if !suggestions.isEmpty {
                selectedSuggestionIndex = max(selectedSuggestionIndex - 1, 0)
                suggestionsTableView?.selectRowIndexes(IndexSet(integer: selectedSuggestionIndex), byExtendingSelection: false)
                suggestionsTableView?.scrollRowToVisible(selectedSuggestionIndex)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            goClicked(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismissPanel()
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            // Tab completes the selected suggestion into the text field
            if selectedSuggestionIndex >= 0, selectedSuggestionIndex < suggestions.count {
                acceptSuggestion(at: selectedSuggestionIndex)
            } else if suggestions.count == 1 {
                acceptSuggestion(at: 0)
            }
            return true
        }
        return false
    }

    // Old completions API — disabled in favor of the suggestions table
    func control(_ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        return []
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        suggestions.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SuggestionCell")
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.font = .systemFont(ofSize: 12)
            cell.lineBreakMode = .byTruncatingMiddle
            cell.cell?.truncatesLastVisibleLine = true
        }
        cell.stringValue = suggestions[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = suggestionsTableView else { return }
        selectedSuggestionIndex = tableView.selectedRow
    }
}
