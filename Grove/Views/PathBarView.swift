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
            buttons.append(button)
            stackView.addArrangedSubview(button)
        }
    }

    @objc private func pathComponentClicked(_ sender: NSButton) {
        guard sender.tag < currentComponents.count else { return }
        onPathComponentClicked?(currentComponents[sender.tag])
    }
}
