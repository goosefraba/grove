import AppKit
import UniformTypeIdentifiers

final class PreviewPaneController: NSViewController {

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private let fallbackContainer = NSView()
    private let fallbackIconView = NSImageView()
    private let fallbackNameLabel = NSTextField(labelWithString: "")
    private let fallbackKindLabel = NSTextField(labelWithString: "")
    private let fallbackSizeLabel = NSTextField(labelWithString: "")

    private var currentItem: FileItem?

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 300, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTextView()
        setupImageView()
        setupFallbackView()
        showFallback(nil)
    }

    private func setupTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = true
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupImageView() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true
        view.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])
    }

    private func setupFallbackView() {
        fallbackContainer.translatesAutoresizingMaskIntoConstraints = false
        fallbackContainer.isHidden = true
        view.addSubview(fallbackContainer)

        fallbackIconView.imageScaling = .scaleProportionallyUpOrDown
        fallbackIconView.translatesAutoresizingMaskIntoConstraints = false
        fallbackContainer.addSubview(fallbackIconView)

        fallbackNameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        fallbackNameLabel.alignment = .center
        fallbackNameLabel.lineBreakMode = .byTruncatingMiddle
        fallbackNameLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackContainer.addSubview(fallbackNameLabel)

        fallbackKindLabel.font = .systemFont(ofSize: 12)
        fallbackKindLabel.textColor = .secondaryLabelColor
        fallbackKindLabel.alignment = .center
        fallbackKindLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackContainer.addSubview(fallbackKindLabel)

        fallbackSizeLabel.font = .systemFont(ofSize: 12)
        fallbackSizeLabel.textColor = .secondaryLabelColor
        fallbackSizeLabel.alignment = .center
        fallbackSizeLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackContainer.addSubview(fallbackSizeLabel)

        NSLayoutConstraint.activate([
            fallbackContainer.topAnchor.constraint(equalTo: view.topAnchor),
            fallbackContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            fallbackContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fallbackContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            fallbackIconView.centerXAnchor.constraint(equalTo: fallbackContainer.centerXAnchor),
            fallbackIconView.centerYAnchor.constraint(equalTo: fallbackContainer.centerYAnchor, constant: -40),
            fallbackIconView.widthAnchor.constraint(equalToConstant: 64),
            fallbackIconView.heightAnchor.constraint(equalToConstant: 64),

            fallbackNameLabel.topAnchor.constraint(equalTo: fallbackIconView.bottomAnchor, constant: 12),
            fallbackNameLabel.leadingAnchor.constraint(equalTo: fallbackContainer.leadingAnchor, constant: 16),
            fallbackNameLabel.trailingAnchor.constraint(equalTo: fallbackContainer.trailingAnchor, constant: -16),

            fallbackKindLabel.topAnchor.constraint(equalTo: fallbackNameLabel.bottomAnchor, constant: 4),
            fallbackKindLabel.leadingAnchor.constraint(equalTo: fallbackContainer.leadingAnchor, constant: 16),
            fallbackKindLabel.trailingAnchor.constraint(equalTo: fallbackContainer.trailingAnchor, constant: -16),

            fallbackSizeLabel.topAnchor.constraint(equalTo: fallbackKindLabel.bottomAnchor, constant: 2),
            fallbackSizeLabel.leadingAnchor.constraint(equalTo: fallbackContainer.leadingAnchor, constant: 16),
            fallbackSizeLabel.trailingAnchor.constraint(equalTo: fallbackContainer.trailingAnchor, constant: -16),
        ])
    }

    func updateSelection(_ item: FileItem?) {
        currentItem = item
        guard let item = item else {
            showFallback(nil)
            return
        }

        if let contentType = item.contentType {
            if contentType.conforms(to: .image) {
                showImage(item)
                return
            }
            if contentType.conforms(to: .text) || contentType.conforms(to: .sourceCode) {
                showText(item)
                return
            }
            // Markdown
            if item.url.pathExtension.lowercased() == "md" || contentType.conforms(to: .text) {
                showMarkdown(item)
                return
            }
        }

        // Check extension-based fallbacks
        let ext = item.url.pathExtension.lowercased()
        let textExtensions: Set<String> = [
            "txt", "md", "swift", "py", "js", "ts", "json", "xml", "html", "css",
            "yml", "yaml", "toml", "sh", "bash", "zsh", "fish", "rb", "rs", "go",
            "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "scala", "php",
            "sql", "r", "lua", "vim", "conf", "ini", "cfg", "env", "gitignore",
            "dockerfile", "makefile", "cmake", "gradle",
        ]
        if textExtensions.contains(ext) {
            if ext == "md" {
                showMarkdown(item)
            } else {
                showText(item)
            }
            return
        }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico", "svg"]
        if imageExtensions.contains(ext) {
            showImage(item)
            return
        }

        showFallback(item)
    }

    private func showText(_ item: FileItem) {
        hideAll()
        scrollView.isHidden = false

        // Limit reading to 1 MB
        guard let data = try? Data(contentsOf: item.url, options: [.mappedIfSafe]),
              data.count < 1_048_576,
              let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            showFallback(item)
            return
        }

        textView.string = content
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    private func showMarkdown(_ item: FileItem) {
        hideAll()
        scrollView.isHidden = false

        guard let data = try? Data(contentsOf: item.url, options: [.mappedIfSafe]),
              data.count < 1_048_576,
              let content = String(data: data, encoding: .utf8) else {
            showFallback(item)
            return
        }

        // Render markdown as attributed string with basic formatting
        let attributed = renderMarkdown(content)
        textView.textStorage?.setAttributedString(attributed)
    }

    private func renderMarkdown(_ content: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let defaultFont = NSFont.systemFont(ofSize: 13)
        let defaultColor = NSColor.labelColor
        let defaultAttrs: [NSAttributedString.Key: Any] = [.font: defaultFont, .foregroundColor: defaultColor]

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var attrs = defaultAttrs

            if trimmed.hasPrefix("# ") {
                attrs[.font] = NSFont.systemFont(ofSize: 22, weight: .bold)
            } else if trimmed.hasPrefix("## ") {
                attrs[.font] = NSFont.systemFont(ofSize: 18, weight: .bold)
            } else if trimmed.hasPrefix("### ") {
                attrs[.font] = NSFont.systemFont(ofSize: 15, weight: .semibold)
            } else if trimmed.hasPrefix("```") {
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                // Keep default
            }

            result.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }

        return result
    }

    private func showImage(_ item: FileItem) {
        hideAll()
        imageView.isHidden = false

        if let image = NSImage(contentsOf: item.url) {
            imageView.image = image
        } else {
            showFallback(item)
        }
    }

    private func showFallback(_ item: FileItem?) {
        hideAll()
        fallbackContainer.isHidden = false

        guard let item = item else {
            fallbackIconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: "No selection")
            fallbackNameLabel.stringValue = "No Selection"
            fallbackKindLabel.stringValue = ""
            fallbackSizeLabel.stringValue = ""
            return
        }

        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.size = NSSize(width: 64, height: 64)
        fallbackIconView.image = icon
        fallbackNameLabel.stringValue = item.name
        fallbackKindLabel.stringValue = item.kind
        fallbackSizeLabel.stringValue = item.formattedSize
    }

    private func hideAll() {
        scrollView.isHidden = true
        imageView.isHidden = true
        fallbackContainer.isHidden = true
        textView.string = ""
        imageView.image = nil
    }
}
