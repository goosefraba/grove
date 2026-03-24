import AppKit

final class FileProgressViewController: NSViewController {

    private let progressBar = NSProgressIndicator()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private(set) var isCancelled = false

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 360, height: 100))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1.0
        progressBar.doubleValue = 0
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)

        fileNameLabel.font = .systemFont(ofSize: 12)
        fileNameLabel.textColor = .secondaryLabelColor
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fileNameLabel)

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            fileNameLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            fileNameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            fileNameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            progressBar.topAnchor.constraint(equalTo: fileNameLabel.bottomAnchor, constant: 12),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            cancelButton.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
        ])
    }

    func updateProgress(_ value: Double, fileName: String) {
        progressBar.doubleValue = value
        fileNameLabel.stringValue = fileName.isEmpty ? "Completing..." : "Copying \"\(fileName)\"..."
    }

    @objc private func cancelClicked(_ sender: Any?) {
        isCancelled = true
        cancelButton.isEnabled = false
        cancelButton.title = "Cancelling..."
    }
}
