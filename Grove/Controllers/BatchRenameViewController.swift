import AppKit

protocol BatchRenameViewControllerDelegate: AnyObject {
    func batchRenameDidComplete()
}

final class BatchRenameViewController: NSViewController {

    weak var delegate: BatchRenameViewControllerDelegate?

    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let regexCheckbox = NSButton(checkboxWithTitle: "Use Regular Expression", target: nil, action: nil)
    private let previewTable = NSTableView()
    private let scrollView = NSScrollView()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)

    private var urls: [URL] = []
    private var previewNames: [(original: String, renamed: String)] = []

    private let originalColumn = NSUserInterfaceItemIdentifier("OriginalColumn")
    private let renamedColumn = NSUserInterfaceItemIdentifier("RenamedColumn")

    convenience init(urls: [URL]) {
        self.init(nibName: nil, bundle: nil)
        self.urls = urls
    }

    override func loadView() {
        let container = NSView()
        container.setFrameSize(NSSize(width: 500, height: 400))
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updatePreview()
    }

    private func setupUI() {
        let findLabel = NSTextField(labelWithString: "Find:")
        findLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(findLabel)

        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = "Search pattern"
        findField.target = self
        findField.action = #selector(fieldChanged(_:))
        view.addSubview(findField)

        let replaceLabel = NSTextField(labelWithString: "Replace:")
        replaceLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(replaceLabel)

        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.placeholderString = "Replacement text"
        replaceField.target = self
        replaceField.action = #selector(fieldChanged(_:))
        view.addSubview(replaceField)

        regexCheckbox.translatesAutoresizingMaskIntoConstraints = false
        regexCheckbox.target = self
        regexCheckbox.action = #selector(checkboxChanged(_:))
        view.addSubview(regexCheckbox)

        let origCol = NSTableColumn(identifier: originalColumn)
        origCol.title = "Original"
        origCol.width = 220
        previewTable.addTableColumn(origCol)

        let renCol = NSTableColumn(identifier: renamedColumn)
        renCol.title = "Renamed"
        renCol.width = 220
        previewTable.addTableColumn(renCol)

        previewTable.dataSource = self
        previewTable.delegate = self
        previewTable.usesAlternatingRowBackgroundColors = true
        previewTable.allowsEmptySelection = true

        scrollView.documentView = previewTable
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        view.addSubview(cancelButton)

        renameButton.translatesAutoresizingMaskIntoConstraints = false
        renameButton.target = self
        renameButton.action = #selector(renameClicked(_:))
        renameButton.keyEquivalent = "\r"
        renameButton.bezelStyle = .rounded
        renameButton.bezelColor = .controlAccentColor
        view.addSubview(renameButton)

        NSLayoutConstraint.activate([
            findLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            findLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            findLabel.widthAnchor.constraint(equalToConstant: 60),

            findField.centerYAnchor.constraint(equalTo: findLabel.centerYAnchor),
            findField.leadingAnchor.constraint(equalTo: findLabel.trailingAnchor, constant: 8),
            findField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            replaceLabel.topAnchor.constraint(equalTo: findLabel.bottomAnchor, constant: 12),
            replaceLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            replaceLabel.widthAnchor.constraint(equalToConstant: 60),

            replaceField.centerYAnchor.constraint(equalTo: replaceLabel.centerYAnchor),
            replaceField.leadingAnchor.constraint(equalTo: replaceLabel.trailingAnchor, constant: 8),
            replaceField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            regexCheckbox.topAnchor.constraint(equalTo: replaceLabel.bottomAnchor, constant: 12),
            regexCheckbox.leadingAnchor.constraint(equalTo: replaceField.leadingAnchor),

            scrollView.topAnchor.constraint(equalTo: regexCheckbox.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -16),

            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: renameButton.leadingAnchor, constant: -8),

            renameButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            renameButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func updatePreview() {
        let find = findField.stringValue
        let replace = replaceField.stringValue
        let useRegex = regexCheckbox.state == .on

        previewNames = urls.map { url in
            let original = url.lastPathComponent
            let renamed: String
            if find.isEmpty {
                renamed = original
            } else if useRegex {
                guard let regex = try? NSRegularExpression(pattern: find) else {
                    return (original: original, renamed: original)
                }
                let range = NSRange(original.startIndex..., in: original)
                renamed = regex.stringByReplacingMatches(in: original, range: range, withTemplate: replace)
            } else {
                renamed = original.replacingOccurrences(of: find, with: replace)
            }
            return (original: original, renamed: renamed)
        }
        previewTable.reloadData()

        let hasChanges = previewNames.contains { $0.original != $0.renamed }
        renameButton.isEnabled = hasChanges && !find.isEmpty
    }

    @objc private func fieldChanged(_ sender: Any?) {
        updatePreview()
    }

    @objc private func checkboxChanged(_ sender: Any?) {
        updatePreview()
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(nil)
    }

    @objc private func renameClicked(_ sender: Any?) {
        let find = findField.stringValue
        let replace = replaceField.stringValue
        let useRegex = regexCheckbox.state == .on

        do {
            _ = try FileOperationService.shared.batchRename(urls, find: find, replace: replace, useRegex: useRegex)
            delegate?.batchRenameDidComplete()
            dismiss(nil)
        } catch {
            let alert = NSAlert(error: error)
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension BatchRenameViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        previewNames.count
    }
}

// MARK: - NSTableViewDelegate

extension BatchRenameViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < previewNames.count, let columnID = tableColumn?.identifier else { return nil }
        let entry = previewNames[row]

        let cellID = NSUserInterfaceItemIdentifier("BatchCell_\(columnID.rawValue)")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = cellID

        if cell.textField == nil {
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        switch columnID {
        case originalColumn:
            cell.textField?.stringValue = entry.original
            cell.textField?.textColor = .labelColor
        case renamedColumn:
            cell.textField?.stringValue = entry.renamed
            cell.textField?.textColor = entry.original != entry.renamed ? .systemBlue : .labelColor
        default:
            break
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        24
    }
}

// MARK: - NSTextFieldDelegate

extension BatchRenameViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updatePreview()
    }
}
