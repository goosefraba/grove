import AppKit
import ImageIO
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

    /// Bumped on every selection change so stale background loads can discard their results.
    private var loadGeneration = 0

    /// Cap decoded image dimensions to avoid inflating multi-GB rasters into memory.
    private let maxImagePixelSize = 4096

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
        loadGeneration += 1
        guard let item = item else {
            showFallback(nil)
            return
        }

        let ext = item.url.pathExtension.lowercased()
        let isMarkdownType = item.contentType.map { contentType in
            UTType(filenameExtension: "md").map { contentType.conforms(to: $0) } ?? false
        } ?? false
        if ext == "md" || isMarkdownType {
            showMarkdown(item)
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
        }

        // Check extension-based fallbacks
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

    /// Runs `work` on a background queue, then delivers its result on the main queue only if
    /// the selection hasn't changed since this load started. `nil` result falls back.
    private func loadInBackground<T>(_ item: FileItem,
                                     work: @escaping () -> T?,
                                     present: @escaping (T) -> Void) {
        let generation = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = work()
            DispatchQueue.main.async {
                guard let self = self, self.loadGeneration == generation else { return }
                if let result = result {
                    present(result)
                } else {
                    self.showFallback(item)
                }
            }
        }
    }

    private func showText(_ item: FileItem) {
        hideAll()
        scrollView.isHidden = false

        loadInBackground(item, work: {
            // Limit reading to 1 MB
            guard let data = try? Data(contentsOf: item.url, options: [.mappedIfSafe]),
                  data.count < 1_048_576 else {
                return nil
            }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        }, present: { [weak self] content in
            self?.textView.string = content
            self?.textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        })
    }

    private func showMarkdown(_ item: FileItem) {
        hideAll()
        scrollView.isHidden = false

        loadInBackground(item, work: { [weak self] () -> NSAttributedString? in
            guard let self = self,
                  let data = try? Data(contentsOf: item.url, options: [.mappedIfSafe]),
                  data.count < 1_048_576,
                  let content = String(data: data, encoding: .utf8) else {
                return nil
            }
            return self.renderMarkdown(content)
        }, present: { [weak self] attributed in
            self?.textView.textStorage?.setAttributedString(attributed)
        })
    }

    private func renderMarkdown(_ content: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let defaultFont = NSFont.systemFont(ofSize: 13)
        let defaultColor = NSColor.labelColor
        let defaultAttrs: [NSAttributedString.Key: Any] = [.font: defaultFont, .foregroundColor: defaultColor]

        let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var insideFence = false

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var attrs = defaultAttrs

            if trimmed.hasPrefix("```") {
                // Fence marker: monospace it and toggle the code-block state.
                attrs[.font] = codeFont
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
                insideFence.toggle()
            } else if insideFence {
                // Content inside a fenced block: monospace every line, not just the fences.
                attrs[.font] = codeFont
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
            } else if trimmed.hasPrefix("# ") {
                attrs[.font] = NSFont.systemFont(ofSize: 22, weight: .bold)
            } else if trimmed.hasPrefix("## ") {
                attrs[.font] = NSFont.systemFont(ofSize: 18, weight: .bold)
            } else if trimmed.hasPrefix("### ") {
                attrs[.font] = NSFont.systemFont(ofSize: 15, weight: .semibold)
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

        loadInBackground(item, work: { [weak self] () -> NSImage? in
            let maxPixel = self?.maxImagePixelSize ?? 4096
            // Downsample via CGImageSource so a 100 MB TIFF never inflates to a full-res raster.
            if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                ]
                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            // Fallback for formats CGImageSource can't thumbnail (e.g. SVG).
            return NSImage(contentsOf: item.url)
        }, present: { [weak self] image in
            self?.imageView.image = image
        })
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
