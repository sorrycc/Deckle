import AppKit

/// The notes that link to the open note, with the lines that do, in a popover
/// from the status bar.
final class BacklinksController: NSViewController {
    private let links: [Backlink]
    private let open: (URL, NSRange) -> Void

    init(links: [Backlink], open: @escaping (URL, NSRange) -> Void) {
        self.links = links
        self.open = open
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let header = NSTextField(labelWithString: links.count == 1 ? "1 note links here" : "\(links.count) notes link here")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(10, after: header)
        for (index, link) in links.enumerated() {
            let url = URL(fileURLWithPath: link.path)
            let title = button(link.title, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor, symbol: "doc.text") { [weak self] in
                self?.open(url, NSRange(location: 0, length: 0))
            }
            stack.addArrangedSubview(title)
            for line in link.lines {
                let row = button(line.text, font: .systemFont(ofSize: 12), color: .secondaryLabelColor, symbol: nil) { [weak self] in
                    self?.open(url, NSRange(location: line.offset, length: 0))
                }
                stack.addArrangedSubview(row)
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 34).isActive = true
            }
            if index < links.count - 1, let last = stack.arrangedSubviews.last { stack.setCustomSpacing(12, after: last) }
        }
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        let height = min(420, stack.fittingSize.height)
        scroll.frame = NSRect(x: 0, y: 0, width: 380, height: max(80, height))
        view = scroll
    }

    private func button(_ title: String, font: NSFont, color: NSColor, symbol: String?, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton(action: action)
        button.isBordered = false
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.contentTintColor = .secondaryLabelColor
        }
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        return button
    }
}

/// A button that runs a closure.
final class ActionButton: NSButton {
    private let handler: () -> Void

    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(run)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
