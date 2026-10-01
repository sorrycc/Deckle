import AppKit

@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, select tab: Tab)
    func tabStrip(_ strip: TabStripView, close tab: Tab)
    /// The user dragged `tab` to `index`.
    func tabStrip(_ strip: TabStripView, move tab: Tab, to index: Int)
    func tabStripNewTab(_ strip: TabStripView)
}

/// The tabs, as a row in the toolbar or a column. In a row, tabs share the
/// width equally up to a maximum, like Safari's compact tabs.
/// Crowded tabs drop their titles and show only the icon; past that the row
/// scrolls to keep the selected tab in view. In a column, each tab is a row
/// as wide as the sidebar, a New Tab row follows the last one, and the column
/// scrolls. Tabs can be dragged to reorder them.
final class TabStripView: NSView {
    enum Orientation {
        case horizontal
        case vertical
    }

    weak var delegate: TabStripDelegate?
    var orientation = Orientation.horizontal {
        didSet {
            guard orientation != oldValue else { return }
            drag = nil
            scrollOffset = 0
            newTabRow.isHidden = !isVertical
            layoutItems(animated: false)
        }
    }

    private static let maxTabWidth: CGFloat = 240
    /// Below this, tabs show only their icon.
    private static let titleMinWidth: CGFloat = 64
    private static let minTabWidth: CGFloat = 34
    private static let rowHeight: CGFloat = 34
    private static let animationDuration = 0.18

    private var items: [TabItemView] = []
    private var selectedItem: TabItemView?
    /// How far the row is scrolled when the tabs don't fit.
    private var scrollOffset: CGFloat = 0
    /// Positions are along the row or column.
    private var drag: (item: TabItemView, start: CGFloat, origin: CGFloat, moved: Bool)?
    /// Follows the last tab of a column.
    private let newTabRow = NewTabRowView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        newTabRow.isHidden = true
        newTabRow.onClick = { [weak self] in self.map { $0.delegate?.tabStripNewTab($0) } }
        addSubview(newTabRow)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the row for `tabs`, reusing item views for tabs already shown.
    /// Tabs that move slide to their new place, and new ones fade in.
    func update(tabs: [Tab], selected: Tab?) {
        // The row changed under a drag; the drag's order no longer holds.
        drag = nil
        var existing = Dictionary(uniqueKeysWithValues: items.map { (ObjectIdentifier($0.tab), $0) })
        var added: [TabItemView] = []
        items = tabs.map { tab in
            if let item = existing.removeValue(forKey: ObjectIdentifier(tab)) { return item }
            let item = TabItemView(tab: tab)
            item.strip = self
            item.onSelect = { [weak self] in self.map { $0.delegate?.tabStrip($0, select: tab) } }
            item.onClose = { [weak self] in self.map { $0.delegate?.tabStrip($0, close: tab) } }
            addSubview(item)
            added.append(item)
            return item
        }
        existing.values.forEach { $0.removeFromSuperview() }
        selectedItem = items.first { $0.tab === selected }
        for item in items {
            item.isSelected = item === selectedItem
            item.refresh()
        }
        let animate = window != nil && !items.isEmpty && (added.count < items.count || !existing.isEmpty)
        layoutItems(animated: animate, fadeIn: animate ? added : [])
    }

    func refresh(_ tab: Tab) {
        items.first { $0.tab === tab }?.refresh()
    }

    override func layout() {
        super.layout()
        // A column stays where the user scrolled it.
        layoutItems(animated: false, reveal: !isVertical)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isVertical else { return super.scrollWheel(with: event) }
        scrollOffset -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
        layoutItems(animated: false, reveal: false)
    }

    // MARK: Layout

    private var isVertical: Bool { orientation == .vertical }
    private var spacing: CGFloat { isVertical ? 2 : 4 }
    /// The room along the row or column.
    private var extent: CGFloat { isVertical ? bounds.height : bounds.width }

    /// A tab's size along the row or column.
    private var tabLength: CGFloat {
        if isVertical { return Self.rowHeight }
        let count = CGFloat(max(1, items.count))
        let fit = (bounds.width - spacing * (count - 1)) / count
        return min(Self.maxTabWidth, max(Self.minTabWidth, fit)).rounded(.down)
    }

    private func slot(_ index: Int, length: CGFloat) -> NSRect {
        let position = CGFloat(index) * (length + spacing) - scrollOffset
        return isVertical
            ? NSRect(x: 0, y: position, width: bounds.width, height: length)
            : NSRect(x: position, y: 0, width: length, height: bounds.height)
    }

    /// `reveal` scrolls the selected tab into view.
    private func layoutItems(animated: Bool, fadeIn: [TabItemView] = [], reveal: Bool = true) {
        guard !items.isEmpty else { return }
        let length = tabLength
        let extent = extent
        let compact = (isVertical ? bounds.width : length) < Self.titleMinWidth
        let slots = items.count + (isVertical ? 1 : 0)
        let total = CGFloat(slots) * (length + spacing) - spacing
        if total <= extent {
            scrollOffset = 0
        } else {
            if reveal, let selectedItem, let index = items.firstIndex(of: selectedItem) {
                let start = CGFloat(index) * (length + spacing)
                scrollOffset = min(max(scrollOffset, start + length - extent), start)
            }
            scrollOffset = min(max(0, scrollOffset), total - extent)
        }
        for item in fadeIn {
            item.frame = slot(items.firstIndex(of: item) ?? 0, length: length)
            item.alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Self.animationDuration : 0
            context.allowsImplicitAnimation = animated
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (index, item) in items.enumerated() where item !== drag?.item {
                item.isCompact = compact
                item.closesOnTrailing = isVertical && !compact
                let frame = slot(index, length: length)
                if animated {
                    item.animator().frame = frame
                    item.animator().alphaValue = 1
                } else {
                    item.frame = frame
                    item.alphaValue = 1
                }
            }
            newTabRow.isCompact = compact
            let frame = slot(items.count, length: length)
            if animated {
                newTabRow.animator().frame = frame
            } else {
                newTabRow.frame = frame
            }
        }
    }

    // MARK: Dragging

    private func position(of event: NSEvent) -> CGFloat {
        let point = convert(event.locationInWindow, from: nil)
        return isVertical ? point.y : point.x
    }

    fileprivate func beginDrag(_ item: TabItemView, with event: NSEvent) {
        drag = (item, position(of: event), isVertical ? item.frame.minY : item.frame.minX, false)
    }

    fileprivate func continueDrag(with event: NSEvent) {
        guard var drag, let from = items.firstIndex(of: drag.item) else { return }
        let delta = position(of: event) - drag.start
        if !drag.moved {
            guard abs(delta) > 4, items.count > 1 else { return }
            drag.moved = true
            // Keep the dragged tab above its neighbours.
            addSubview(drag.item, positioned: .above, relativeTo: nil)
        }
        self.drag = drag
        let length = tabLength
        let last = CGFloat(items.count - 1) * (length + spacing) - scrollOffset
        let position = min(max(-scrollOffset, drag.origin + delta), last)
        if isVertical {
            drag.item.frame.origin.y = position
        } else {
            drag.item.frame.origin.x = position
        }
        let center = position + length / 2 + scrollOffset
        let to = min(items.count - 1, max(0, Int(center / (length + spacing))))
        if to != from {
            items.insert(items.remove(at: from), at: to)
            layoutItems(animated: true, reveal: false)
        }
    }

    fileprivate func endDrag() {
        guard let drag else { return }
        self.drag = nil
        guard drag.moved, let index = items.firstIndex(of: drag.item) else { return }
        layoutItems(animated: true, reveal: false)
        delegate?.tabStrip(self, move: drag.item.tab, to: index)
    }
}

/// One tab: icon, title, and a close button that replaces the icon on hover,
/// or sits at the end of a tab in a column.
final class TabItemView: NSView {
    let tab: Tab
    fileprivate weak var strip: TabStripView?
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            titleLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
            updateAppearance()
        }
    }
    /// Too narrow for a title: the icon sits in the middle.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            titleLabel.isHidden = isCompact
            // Off before on, so the two never hold at once.
            (isCompact ? iconLeading : iconCentered).isActive = false
            (isCompact ? iconCentered : iconLeading).isActive = true
            updateAppearance()
        }
    }

    /// The close button sits at the end, on the selected tab too, and the
    /// icon stays.
    var closesOnTrailing = false {
        didSet {
            guard closesOnTrailing != oldValue else { return }
            // Off before on, so the two never hold at once.
            (closesOnTrailing ? closeOverIcon : closeTrailing).isActive = false
            (closesOnTrailing ? closeTrailing : closeOverIcon).isActive = true
            updateAppearance()
        }
    }

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isHovered = false { didSet { updateAppearance() } }
    private var iconLeading: NSLayoutConstraint!
    private var iconCentered: NSLayoutConstraint!
    private var closeOverIcon: NSLayoutConstraint!
    private var closeTrailing: NSLayoutConstraint!
    private var titleToClose: NSLayoutConstraint!

    private static let closeImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))

    init(tab: Tab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        icon.imageScaling = .scaleProportionallyDown

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = Self.closeImage
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"

        for view in [icon, titleLabel, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        iconCentered = icon.centerXAnchor.constraint(equalTo: centerXAnchor)
        // On hover the close button takes the icon's place, as in Safari.
        closeOverIcon = closeButton.centerXAnchor.constraint(equalTo: icon.centerXAnchor)
        closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        titleToClose = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -2)
        // Gives way in a compact tab, which has no room after a centered icon.
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7)
        titleLeading.priority = .defaultHigh
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            closeOverIcon,
            closeButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            titleLeading,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let title = tab.displayTitle
        if titleLabel.stringValue != title {
            titleLabel.stringValue = title
            toolTip = title
        }
        icon.image = tab.icon
        icon.contentTintColor = .secondaryLabelColor
        updateAppearance()
    }

    private func updateAppearance() {
        let fill: NSColor = isSelected ? .labelColor.withAlphaComponent(0.11)
            : isHovered ? .labelColor.withAlphaComponent(0.05) : .clear
        layer?.backgroundColor = fill.cgColor
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        // A compact tab only offers to close when it is the selected one, so a
        // pass of the mouse along a crowded row can't hit a close button.
        let showsClose = closesOnTrailing ? isHovered || isSelected : isHovered && (!isCompact || isSelected)
        closeButton.isHidden = !showsClose
        titleToClose.isActive = closesOnTrailing && showsClose
        let coversIcon = showsClose && !closesOnTrailing
        icon.isHidden = coversIcon
    }

    override func updateLayer() {
        super.updateLayer()
        updateAppearance() // layer colors don't follow light/dark changes on their own
    }

    override var wantsUpdateLayer: Bool { true }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        strip?.beginDrag(self, with: event)
    }

    override func mouseDragged(with event: NSEvent) { strip?.continueDrag(with: event) }
    override func mouseUp(with event: NSEvent) { strip?.endDrag() }

    // Middle click closes, as in a browser.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    // Clicks in the tab select it instead of dragging the window.
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func closeClicked() { onClose?() }
}

/// The row after the last tab of a sidebar, which opens a new tab.
final class NewTabRowView: NSView {
    var onClick: (() -> Void)?
    /// Too narrow for a title: the plus sits in the middle.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            titleLabel.isHidden = isCompact
            // Off before on, so the two never hold at once.
            (isCompact ? iconLeading : iconCentered).isActive = false
            (isCompact ? iconCentered : iconLeading).isActive = true
        }
    }

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "New Tab")
    private var isHovered = false { didSet { needsDisplay = true } }
    private var iconLeading: NSLayoutConstraint!
    private var iconCentered: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        toolTip = "New Tab"

        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [icon, titleLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        iconCentered = icon.centerXAnchor.constraint(equalTo: centerXAnchor)
        // Gives way in a compact tab, which has no room after a centered icon.
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7)
        titleLeading.priority = .defaultHigh
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            titleLeading,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = (isHovered ? NSColor.labelColor.withAlphaComponent(0.05) : .clear).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
