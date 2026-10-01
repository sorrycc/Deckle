import AppKit

/// The headings of a note as ticks down the right edge of the editor, one
/// per heading and as long as its level is high. Hovering opens them as a
/// list to jump to.
final class OutlineRail: NSView {
    var onSelect: ((Heading) -> Void)?
    private var headings: [Heading] = []
    private var current = -1
    /// The list as a card, made when the rail first opens: a glass view is
    /// dear, and most notes are read without one.
    private var card: NSGlassEffectView?
    private let list = NSStackView()
    /// The headings changed since the list was last built.
    private var listIsStale = true
    private var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            if isOpen {
                let card = self.card ?? makeCard()
                self.card = card
                if listIsStale { rebuildList() } else { updateList() }
                card.isHidden = false
            } else {
                card?.isHidden = true
            }
            needsDisplay = true
        }
    }

    static let width: CGFloat = 28
    private static let tickSpacing: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        list.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeCard() -> NSGlassEffectView {
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let card = NSGlassEffectView()
        card.contentView = scroll
        card.cornerRadius = 14
        card.isHidden = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            list.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 260),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -40),
        ])
        return card
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The rail is narrow until it opens; it takes clicks only where it draws.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if isOpen { return super.hitTest(point) }
        return local.x > bounds.width - Self.width && tickArea.insetBy(dx: 0, dy: -8).contains(local) ? self : nil
    }

    private var tickArea: CGRect {
        let height = CGFloat(headings.count) * Self.tickSpacing
        return CGRect(x: bounds.width - Self.width, y: (bounds.height - height) / 2, width: Self.width, height: height)
    }

    func show(_ headings: [Heading], current: Int) {
        let changed = headings.map(\.title) != self.headings.map(\.title) || headings.map(\.level) != self.headings.map(\.level)
        self.headings = headings
        self.current = current
        isHidden = headings.count < 2
        // The list is built when it is looked at, not on every edit.
        listIsStale = listIsStale || changed
        if isOpen {
            if listIsStale { rebuildList() } else { updateList() }
        }
        needsDisplay = true
    }

    private func rebuildList() {
        listIsStale = false
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, heading) in headings.enumerated() {
            let button = NSButton(title: heading.title, target: self, action: #selector(choose(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            list.addArrangedSubview(button)
            button.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 8 + CGFloat(min(heading.level, 4) - 1) * 12).isActive = true
            button.trailingAnchor.constraint(lessThanOrEqualTo: list.trailingAnchor, constant: -8).isActive = true
        }
        updateList()
    }

    private func updateList() {
        for case let button as NSButton in list.arrangedSubviews {
            let heading = headings[button.tag]
            let isCurrent = button.tag == current
            button.attributedTitle = NSAttributedString(string: heading.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: isCurrent ? .semibold : heading.level <= 2 ? .medium : .regular),
                .foregroundColor: isCurrent ? NSColor.controlAccentColor : heading.level <= 2 ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
        }
    }

    @objc private func choose(_ sender: NSButton) {
        guard headings.indices.contains(sender.tag) else { return }
        onSelect?(headings[sender.tag])
        isOpen = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isOpen else { return }
        let area = tickArea
        for (index, heading) in headings.enumerated() {
            let length: CGFloat = [14, 11, 8, 6, 5, 5][max(1, min(heading.level, 6)) - 1]
            let y = area.minY + CGFloat(index) * Self.tickSpacing + Self.tickSpacing / 2
            (index == current ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: CGRect(x: area.maxX - 8 - length, y: y - 1, width: length, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isOpen && point.x > bounds.width - Self.width && tickArea.insetBy(dx: 0, dy: -8).contains(point) { isOpen = true }
        if isOpen, let card, !card.frame.insetBy(dx: -20, dy: -20).contains(point), point.x < bounds.width - Self.width { isOpen = false }
    }

    override func mouseExited(with event: NSEvent) { isOpen = false }

    override func mouseDown(with event: NSEvent) {
        // A click on a tick jumps to its heading.
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.y - tickArea.minY) / Self.tickSpacing)
        if !isOpen, headings.indices.contains(index) { onSelect?(headings[index]) }
    }
}
