import AppKit

final class FileProgressViewController: NSViewController {

    private let progressBar = NSProgressIndicator()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private let cancellationLock = NSLock()
    private var cancelled = false
    private var operationVerb = "Copying"
    private var archiveStatus: (title: String, detail: String)?
    var onCancel: (() -> Void)?

    var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled
    }

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 380, height: 128))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1.0
        progressBar.doubleValue = 0
        progressBar.setAccessibilityIdentifier("fileOperationProgress")
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)

        fileNameLabel.font = .systemFont(ofSize: 12)
        fileNameLabel.textColor = .secondaryLabelColor
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.setAccessibilityIdentifier("fileOperationTitle")
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fileNameLabel)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setAccessibilityIdentifier("fileOperationDetail")
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.isHidden = archiveStatus == nil
        view.addSubview(detailLabel)

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.setAccessibilityIdentifier("fileOperationCancel")
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            fileNameLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            fileNameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            fileNameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            detailLabel.topAnchor.constraint(equalTo: fileNameLabel.bottomAnchor, constant: 5),
            detailLabel.leadingAnchor.constraint(equalTo: fileNameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: fileNameLabel.trailingAnchor),

            progressBar.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            cancelButton.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
        ])
        if let archiveStatus { applyArchiveStatus(archiveStatus) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if archiveStatus != nil { progressBar.startAnimation(nil) }
    }

    func updateProgress(_ value: Double, fileName: String) {
        progressBar.doubleValue = value
        fileNameLabel.stringValue = fileName.isEmpty ? "Completing..." : "\(operationVerb) \"\(fileName)\"..."
    }

    func configure(operationVerb: String) {
        self.operationVerb = operationVerb
    }

    func configureArchive(title: String, detail: String = "Preparing…") {
        archiveStatus = (title, detail)
        loadViewIfNeeded()
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        applyArchiveStatus((title, detail))
    }

    func updateArchive(title: String, detail: String) {
        guard archiveStatus != nil, !isCancelled else { return }
        archiveStatus = (title, detail)
        applyArchiveStatus((title, detail))
    }

    private func applyArchiveStatus(_ status: (title: String, detail: String)) {
        fileNameLabel.stringValue = status.title
        fileNameLabel.toolTip = status.title
        detailLabel.stringValue = status.detail
        detailLabel.isHidden = false
    }

    @objc private func cancelClicked(_ sender: Any?) {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
        cancelButton.isEnabled = false
        cancelButton.title = "Cancelling…"
        if archiveStatus != nil {
            detailLabel.stringValue = "Cancelling and cleaning up…"
        }
        onCancel?()
    }
}
