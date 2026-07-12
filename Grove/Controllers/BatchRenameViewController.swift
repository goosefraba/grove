import AppKit

protocol BatchRenameViewControllerDelegate: AnyObject {
    func batchRenameDidComplete(records: [FileOperationService.FileTransferRecord])
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
    private let warningLabel = NSTextField(labelWithString: "")

    private var urls: [URL] = []
    private var previewEntries: [FileOperationService.BatchRenameEntry] = []

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
        findField.delegate = self
        view.addSubview(findField)

        let replaceLabel = NSTextField(labelWithString: "Replace:")
        replaceLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(replaceLabel)

        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.placeholderString = "Replacement text"
        replaceField.target = self
        replaceField.action = #selector(fieldChanged(_:))
        replaceField.delegate = self
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

        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        warningLabel.textColor = .systemRed
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.lineBreakMode = .byTruncatingTail
        warningLabel.stringValue = ""
        view.addSubview(warningLabel)

        NSLayoutConstraint.activate([
            warningLabel.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            warningLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            warningLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),

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

        previewEntries = FileOperationService.shared.batchRenamePreview(urls, find: find, replace: replace, useRegex: useRegex)
        previewTable.reloadData()

        let hasChanges = previewEntries.contains(where: \.isChanged)
        let hasCollision = previewEntries.contains(where: \.isCollision)
        warningLabel.stringValue = hasCollision ? "Multiple items would share the same name." : ""
        renameButton.isEnabled = hasChanges && !find.isEmpty && !hasCollision
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
            let records = try FileOperationService.shared.batchRename(urls, find: find, replace: replace, useRegex: useRegex)
            delegate?.batchRenameDidComplete(records: records)
            dismiss(nil)
        } catch FileOperationService.FileOperationError.partialFailure(let records, let underlying) {
            // Some files were renamed before the failure: register undo for those, then report.
            delegate?.batchRenameDidComplete(records: records)
            showError(underlying)
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - NSTableViewDataSource

extension BatchRenameViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        previewEntries.count
    }
}

// MARK: - NSTableViewDelegate

extension BatchRenameViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < previewEntries.count, let columnID = tableColumn?.identifier else { return nil }
        let entry = previewEntries[row]

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
            cell.textField?.stringValue = entry.originalName
            cell.textField?.textColor = .labelColor
        case renamedColumn:
            cell.textField?.stringValue = entry.newName
            if entry.isCollision {
                cell.textField?.textColor = .systemRed
            } else {
                cell.textField?.textColor = entry.isChanged ? .systemBlue : .labelColor
            }
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
