import AppKit

/// A panel that floats over the window: a field and the rows matching what
/// is typed in it. One panel serves quick open, full-text search, the
/// commands of the menu bar and the headings of the note.
@MainActor
final class Palette: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    enum Mode {
        case files
        case search
        case commands
        case headings
    }

    struct Row {
        var icon: NSImage?
        var title: NSAttributedString
        var detail: NSAttributedString?
        /// A shortcut or count shown at the end of the row.
        var trailing: String?
        var isHeader = false
        /// Runs the row. The flag asks for a new tab.
        var run: (Bool) -> Void
    }

    private weak var controller: WindowController?
    private let panel: PalettePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint!
    private var rows: [Row] = []
    private(set) var mode = Mode.files
    private var searchTimer: Timer?
    /// The first responder before the panel opened, which gets focus back.
    private weak var returnFocus: NSResponder?

    static let width: CGFloat = 640
    private static let rowHeight: CGFloat = 36
    private static let fieldHeight: CGFloat = 52

    init(controller: WindowController) {
        self.controller = controller
        panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400), styleMask: [.borderless], backing: .buffered,
            defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.isReleasedWhenClosed = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.delegate = self
        field.cell?.isScrollable = true

        let column = NSTableColumn(identifier: .init("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 6, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        let separator = NSBox()
        separator.boxType = .separator

        let content = NSView()
        for view in [icon, field, separator, scrollView, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.contentView = content
        panel.contentView = glass
        heightConstraint = content.heightAnchor.constraint(equalToConstant: Self.fieldHeight)
        NSLayoutConstraint.activate([
            heightConstraint,
            content.widthAnchor.constraint(equalToConstant: Self.width),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            separator.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -2),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    var isShown: Bool { panel.isVisible }

    // MARK: Showing

    func show(_ mode: Mode, query: String = "") {
        guard let window = controller?.window else { return }
        if panel.isVisible && self.mode == mode { return close() }
        self.mode = mode
        returnFocus = window.firstResponder
        field.placeholderString = switch mode {
        case .files: "Open a note or file"
        case .search: "Search the text of every note"
        case .commands: "Run a command"
        case .headings: "Go to a heading"
        }
        field.stringValue = query
        // The theme's appearance, so a light theme gets a light panel.
        panel.appearance = window.appearance
        update()
        if !panel.isVisible {
            window.addChildWindow(panel, ordered: .above)
        }
        position()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Centered over the window, a little below its toolbar.
    private func position() {
        guard let window = controller?.window else { return }
        let size = panel.frame.size
        let frame = window.frame
        let top = frame.maxY - 90
        panel.setFrameTopLeftPoint(NSPoint(x: (frame.midX - size.width / 2).rounded(), y: top))
    }

    func close() {
        searchTimer?.invalidate()
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let returnFocus, let window = controller?.window { window.makeFirstResponder(returnFocus) }
        controller?.window?.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click elsewhere puts the panel away.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            self.close()
        }
    }

    // MARK: Rows

    func controlTextDidChange(_ notification: Notification) {
        if mode == .search {
            searchTimer?.invalidate()
            searchTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        } else {
            update()
        }
    }

    private func update() {
        guard let controller else { return }
        let query = field.stringValue
        switch mode {
        case .files:
            show(rows: fileRows(controller.workspace.findFiles(query), query: query), note: nil)
        case .commands:
            show(rows: commandRows(query), note: nil)
        case .headings:
            show(rows: headingRows(query), note: nil)
        case .search:
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return show(rows: [], note: "Type to search every note") }
            controller.workspace.search(query) { [weak self] results in
                guard let self, self.mode == .search, self.field.stringValue == query else { return }
                let rows = self.searchRows(results)
                let count = results.files.reduce(0) { $0 + $1.count }
                let note = results.total == 0 ? "No matches"
                    : "\(count.formatted()) matches in \(results.total.formatted()) notes" + (results.total > results.files.count ? ", first \(results.files.count) shown" : "")
                self.show(rows: rows, note: note)
            }
        }
    }

    private func show(rows: [Row], note: String?) {
        self.rows = rows
        table.reloadData()
        footer.stringValue = note ?? (rows.isEmpty ? "" : hints)
        let visible = min(rows.count, 10)
        let list = rows.isEmpty && note == nil ? 0 : CGFloat(max(visible, rows.isEmpty ? 1 : visible)) * Self.rowHeight + 10
        heightConstraint.constant = Self.fieldHeight + list + (list > 0 ? 24 : 0)
        if let first = rows.firstIndex(where: { !$0.isHeader }) ?? rows.indices.first {
            table.selectRowIndexes([first], byExtendingSelection: false)
            // From the top, so a header above the first match stays in view.
            table.scrollRowToVisible(0)
        }
        panel.layoutIfNeeded()
        if panel.isVisible { position() }
    }

    /// What the keys do in this mode, for the footer.
    private var hints: String {
        switch mode {
        case .files, .search: "↩ Open   ⌘↩ Open in New Tab   esc Close"
        case .commands: "↩ Run   esc Close"
        case .headings: "↩ Go to Heading   esc Close"
        }
    }

    /// `text` with the characters at `indices` bold.
    private func highlighted(_ text: String, _ indices: [Int], size: CGFloat, color: NSColor) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
        let length = (text as NSString).length
        for index in indices where index < length {
            string.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.labelColor], range: NSRange(location: index, length: 1))
        }
        return string
    }

    private func fileRows(_ matches: [FileMatch], query: String) -> [Row] {
        matches.map { match in
            let url = URL(fileURLWithPath: match.path)
            let name = Files.isMarkdown(url) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
            let title = match.title.isEmpty || match.title == name ? name : "\(match.title)"
            return Row(
                icon: NSImage(systemSymbolName: Tab.symbol(for: url), accessibilityDescription: nil),
                title: NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]),
                detail: highlighted(match.rel, match.indices, size: 11, color: .secondaryLabelColor),
                run: { [weak controller] newTab in controller?.open(url, inNewTab: newTab) })
        }
    }

    private func searchRows(_ results: SearchResults) -> [Row] {
        var rows: [Row] = []
        for file in results.files {
            let url = URL(fileURLWithPath: file.path)
            rows.append(Row(
                icon: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil),
                title: NSAttributedString(string: file.title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]),
                detail: nil, trailing: "\(file.count)", isHeader: true,
                run: { [weak controller] newTab in controller?.open(url, inNewTab: newTab) }))
            for match in file.matches {
                let text = NSMutableAttributedString(string: match.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                ])
                let hit = NSIntersectionRange(NSRange(location: match.column, length: match.length), NSRange(location: 0, length: text.length))
                text.addAttributes([.foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.45)], range: hit)
                let selection = NSRange(location: match.offset, length: match.length)
                rows.append(Row(
                    icon: nil, title: text, detail: nil, trailing: "\(match.line)",
                    run: { [weak controller] newTab in controller?.open(url, inNewTab: newTab, selecting: selection) }))
            }
        }
        return rows
    }

    /// Whether `query`'s characters appear in `text` in order, and how well.
    static func score(_ text: String, _ query: String) -> Int? {
        if query.isEmpty { return 0 }
        let haystack = Array(text.lowercased())
        var score = 0
        var position = 0
        var previous = -2
        for ch in query.lowercased() where ch != " " {
            guard let found = haystack[position...].firstIndex(of: ch) else { return nil }
            score += found == previous + 1 ? 3 : (found == 0 || haystack[found - 1] == " " ? 2 : 0)
            previous = found
            position = found + 1
        }
        return score - haystack.count / 8
    }

    /// Every command in the menu bar that can run now.
    private func commandRows(_ query: String) -> [Row] {
        var found: [(Int, Row)] = []
        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let submenu = item.submenu {
                    walk(submenu, path: menu === NSApp.mainMenu ? item.title : "\(path) › \(item.title)")
                    continue
                }
                guard let action = item.action, action != #selector(NSApplication.terminate(_:)) else { continue }
                guard let target = item.target ?? self.target(for: action) else { continue }
                if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) { continue }
                let title = "\(path) › \(item.title)"
                guard let score = Self.score(item.title, query) ?? Self.score(title, query).map({ $0 - 5 }) else { continue }
                // Few menu items have an icon; none keeps the titles aligned.
                found.append((score, Row(
                    icon: nil,
                    title: NSAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]),
                    detail: NSAttributedString(string: path, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
                    trailing: Self.shortcut(item),
                    run: { [weak item] _ in
                        guard let item, let action = item.action else { return }
                        NSApp.sendAction(action, to: target, from: item)
                    })))
            }
        }
        if let menu = NSApp.mainMenu { walk(menu, path: "") }
        return found.enumerated().sorted { a, b in a.element.0 != b.element.0 ? a.element.0 > b.element.0 : a.offset < b.offset }
            .map(\.element.1)
    }

    /// What a menu command would go to in the window under the panel, which
    /// has the key focus while the panel is open.
    private func target(for action: Selector) -> AnyObject? {
        guard let window = controller?.window else { return nil }
        var responder: NSResponder? = returnFocus ?? window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        for candidate in [window, window.delegate as AnyObject?, NSApp, NSApp.delegate as AnyObject?] {
            if let candidate, candidate.responds(to: action) { return candidate }
        }
        return nil
    }

    static func shortcut(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        let key = item.keyEquivalent
        if flags.contains(.shift) || (key.uppercased() == key && key.lowercased() != key) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + (key == "\t" ? "⇥" : key.uppercased())
    }

    private func headingRows(_ query: String) -> [Row] {
        guard let editor = controller?.selectedTab.editor else { return [] }
        return editor.headings.compactMap { heading in
            guard Self.score(heading.title, query) != nil else { return nil }
            let indent = String(repeating: "    ", count: max(0, heading.level - 1))
            return Row(
                icon: nil,
                title: NSAttributedString(string: indent + heading.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: heading.level <= 2 ? .semibold : .regular),
                ]),
                detail: nil, trailing: "H\(heading.level)",
                run: { [weak editor] _ in editor?.reveal(NSRange(location: heading.range.location, length: 0)) })
        }
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): run(table.selectedRow, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        let row = min(max(0, table.selectedRow + step), rows.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked(_ sender: Any?) {
        run(table.clickedRow, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
    }

    private func run(_ index: Int, newTab: Bool) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        returnFocus = nil
        close()
        row.run(newTab)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { Self.rowHeight }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("palette"), owner: self) as? PaletteCell ?? PaletteCell()
        cell.show(rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }
}

/// A panel that takes key focus though it has no title bar.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Selection as a rounded, tinted plate.
final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

final class PaletteCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private var titleLeading: NSLayoutConstraint!
    private var titleLeadingNoIcon: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = .init("palette")
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingMiddle
        detail.maximumNumberOfLines = 1
        trailing.font = .systemFont(ofSize: 11)
        trailing.textColor = .tertiaryLabelColor
        trailing.alignment = .right
        for view in [icon, title, detail, trailing] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLeading = title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10)
        titleLeadingNoIcon = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            titleLeading,
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -10),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ row: Palette.Row) {
        icon.image = row.icon
        icon.isHidden = row.icon == nil
        titleLeading.isActive = row.icon != nil
        titleLeadingNoIcon.isActive = row.icon == nil
        title.attributedStringValue = row.title
        detail.attributedStringValue = row.detail ?? NSAttributedString()
        trailing.stringValue = row.trailing ?? ""
    }
}
