import AppKit

/// The headings of a note as ticks down the right edge of the editor, one
/// per heading and as long as its level is high. Hovering opens them as a
/// list to jump to.
final class OutlineRail: NSView {
    var onSelect: ((Heading) -> Void)?
    private var headings: [Heading] = []
    private var current = -1
    /// The headings with a tick, as indices into `headings`: all of them
    /// when they fit, else the top levels, else every so many.
    private var ticks: [Int] = []
    private var tickSpacing: CGFloat = 8
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
    private static let maxTickSpacing: CGFloat = 8
    private static let minTickSpacing: CGFloat = 4

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
        let height = CGFloat(ticks.count) * tickSpacing
        return CGRect(x: bounds.width - Self.width, y: (bounds.height - height) / 2, width: Self.width, height: height)
    }

    /// Picks the headings that get a tick, so a note of hundreds of sections
    /// shows its shape instead of a wall of ticks past the edges.
    private func fitTicks() {
        let room = max(Self.minTickSpacing, bounds.height - 56)
        let capacity = max(1, Int(room / Self.minTickSpacing))
        // The deepest level whose headings all fit.
        var picks = Array(headings.indices)
        var level = 6
        while picks.count > capacity, level > 1 {
            level -= 1
            picks = headings.indices.filter { headings[$0].level <= level }
        }
        if picks.count > capacity {
            // Even the top level is too much: every so many of them.
            let step = Int((CGFloat(picks.count) / CGFloat(capacity)).rounded(.up))
            picks = stride(from: 0, to: picks.count, by: max(1, step)).map { picks[$0] }
        } else if level < 6 && picks.count < capacity / 3 {
            // So few that the note's shape is lost: the level that fits keeps
            // every tick, and the next level fills the rest with every so
            // many of its headings.
            let kept = Set(picks)
            let more = headings.indices.filter { !kept.contains($0) && headings[$0].level == level + 1 }
            let step = Int((CGFloat(more.count) / CGFloat(max(1, capacity - picks.count))).rounded(.up))
            picks = (picks + stride(from: 0, to: more.count, by: max(1, step)).map { more[$0] }).sorted()
        }
        ticks = picks
        tickSpacing = picks.isEmpty ? Self.maxTickSpacing : min(Self.maxTickSpacing, room / CGFloat(picks.count))
    }

    override func layout() {
        super.layout()
        fitTicks()
        needsDisplay = true
    }

    func show(_ headings: [Heading], current: Int) {
        let changed = headings.map(\.title) != self.headings.map(\.title) || headings.map(\.level) != self.headings.map(\.level)
        self.headings = headings
        self.current = current
        if changed || ticks.count > headings.count { fitTicks() }
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
        // The tick of the current heading, or of the last one above it when
        // the current heading has no tick of its own.
        let lit = ticks.lastIndex { $0 <= current } ?? -1
        for (slot, index) in ticks.enumerated() {
            let heading = headings[index]
            let length: CGFloat = [14, 11, 8, 6, 5, 5][max(1, min(heading.level, 6)) - 1]
            let y = area.minY + CGFloat(slot) * tickSpacing + tickSpacing / 2
            (slot == lit ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
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
        let slot = Int((point.y - tickArea.minY) / tickSpacing)
        if !isOpen, ticks.indices.contains(slot) { onSelect?(headings[ticks[slot]]) }
    }
}
