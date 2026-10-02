import AppKit

/// A list that pops up at the insertion point while typing: blocks to insert
/// after a `/`, notes to link after `[[`. The text view keeps the keyboard;
/// it hands the list the arrow keys, Return and Escape.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        var symbol: String
        var title: String
        var detail: String = ""
        /// Replaces the typed trigger, the `/` or `[[` and what follows.
        var apply: (_ editor: EditorView, _ trigger: NSRange) -> Void
    }

    static let shared = CompletionPopup()

    /// Made when first shown: a window is dear, and most notes never ask.
    private var panel: PalettePanel?
    private let table = NSTableView()
    private var items: [Item] = []
    private weak var editor: EditorView?
    /// The typed text the list completes, from its `/` or `[[`.
    private(set) var trigger = NSRange(location: NSNotFound, length: 0)

    private static let width: CGFloat = 340
    private static let rowHeight: CGFloat = 30

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.refusesFirstResponder = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 12
        glass.contentView = scroll
        panel.contentView = glass
        self.glass = glass
        return panel
    }

    private weak var glass: NSGlassEffectView?

    var isShown: Bool { panel?.isVisible ?? false }

    /// Shows `items` under the insertion point, or hides the list when there
    /// are none.
    func show(_ items: [Item], trigger: NSRange, in editor: EditorView) {
        guard !items.isEmpty, let window = editor.window else { return close() }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        self.items = items
        self.trigger = trigger
        self.editor = editor
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        let height = CGFloat(min(items.count, 9)) * Self.rowHeight + 10
        glass?.tintColor = Theme.current.background.withAlphaComponent(0.72)
        panel.setFrame(frame(height: height, in: editor), display: true)
        // Over the editor's window, which may not be the one it was over.
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    /// Under the trigger's line, or above it when there is no room below.
    private func frame(height: CGFloat, in editor: EditorView) -> NSRect {
        let caret = editor.textView.firstRect(forCharacterRange: NSRange(location: trigger.location, length: 0), actualRange: nil)
        var frame = NSRect(x: caret.minX - 10, y: caret.minY - height - 6, width: Self.width, height: height)
        if let screen = editor.window?.screen, frame.minY < screen.visibleFrame.minY { frame.origin.y = caret.maxY + 6 }
        return frame
    }

    /// Follows the trigger after its editor scrolled, as when a new line at
    /// the bottom of a note brings the view down. The list goes away once
    /// the trigger is out of view.
    func reposition(for editor: EditorView) {
        guard isShown(for: editor), let panel, let window = editor.window else { return }
        let caret = editor.textView.firstRect(forCharacterRange: NSRange(location: trigger.location, length: 0), actualRange: nil)
        let visible = editor.scrollView.convert(window.convertFromScreen(caret), from: nil)
        guard caret.height > 0, editor.scrollView.bounds.intersects(visible) else { return close() }
        panel.setFrame(frame(height: panel.frame.height, in: editor), display: true)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        trigger = NSRange(location: NSNotFound, length: 0)
    }

    /// Whether the list is up for `editor`.
    func isShown(for editor: EditorView) -> Bool { isShown && self.editor === editor }

    /// Puts the list away if it is `editor`'s.
    func close(for editor: EditorView) {
        if self.editor === editor { close() }
    }

    /// Takes a key `editor`'s text view would act on. Returns whether it did.
    func handle(_ selector: Selector, from editor: EditorView) -> Bool {
        guard isShown(for: editor) else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): accept(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(_ step: Int) {
        let row = (table.selectedRow + step + items.count) % max(1, items.count)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked(_ sender: Any?) { accept(table.clickedRow) }

    private func accept(_ row: Int) {
        guard items.indices.contains(row), let editor else { return close() }
        let item = items[row]
        let trigger = self.trigger
        close()
        item.apply(editor, trigger)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { Self.rowHeight }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("palette"), owner: self) as? PaletteCell ?? PaletteCell()
        let item = items[row]
        cell.show(Palette.Row(
            icon: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil),
            title: NSAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: 13)]),
            detail: item.detail.isEmpty ? nil : NSAttributedString(string: item.detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
            run: { _ in }))
        return cell
    }
}

/// The blocks the `/` menu inserts.
@MainActor
enum SlashCommands {
    /// Inserts `text` in place of the trigger, with the insertion point at
    /// `‸` if the text has one.
    static func insert(_ text: String) -> (EditorView, NSRange) -> Void {
        { editor, trigger in
            let caret = (text as NSString).range(of: "‸")
            let clean = text.replacingOccurrences(of: "‸", with: "")
            let location = trigger.location + (caret.location == NSNotFound ? (clean as NSString).length : caret.location)
            editor.replace(trigger, with: clean, select: NSRange(location: location, length: 0))
        }
    }

    static let all: [CompletionPopup.Item] = [
        .init(symbol: "textformat", title: "Heading 1", detail: "#", apply: insert("# ")),
        .init(symbol: "textformat", title: "Heading 2", detail: "##", apply: insert("## ")),
        .init(symbol: "textformat", title: "Heading 3", detail: "###", apply: insert("### ")),
        .init(symbol: "list.bullet", title: "Bulleted List", detail: "-", apply: insert("- ")),
        .init(symbol: "list.number", title: "Numbered List", detail: "1.", apply: insert("1. ")),
        .init(symbol: "checklist", title: "Task", detail: "- [ ]", apply: insert("- [ ] ")),
        .init(symbol: "text.quote", title: "Quote", detail: ">", apply: insert("> ")),
        .init(symbol: "lightbulb", title: "Callout", detail: "> [!NOTE]", apply: insert("> [!NOTE] ‸\n> ")),
        .init(symbol: "chevron.left.forwardslash.chevron.right", title: "Code Block", detail: "```", apply: insert("```‸\n\n```")),
        .init(symbol: "tablecells", title: "Table", detail: "| |", apply: insert("| ‸Column | Column |\n| --- | --- |\n|  |  |")),
        .init(symbol: "function", title: "Math Block", detail: "$$", apply: insert("$$\n‸\n$$")),
        .init(symbol: "point.3.connected.trianglepath.dotted", title: "Diagram", detail: "mermaid", apply: insert("```mermaid\ngraph LR\n  A[‸Start] --> B[End]\n```")),
        .init(symbol: "minus", title: "Divider", detail: "---", apply: insert("---\n")),
        .init(symbol: "link", title: "Link to Note", detail: "[[", apply: insert("[[‸]]")),
        .init(symbol: "photo", title: "Image…", detail: "![]()", apply: { editor, trigger in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.beginSheetModal(for: editor.window!) { response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { editor.insertImage(from: url, replacing: trigger) }
            }
        }),
        .init(symbol: "number", title: "Footnote", detail: "[^1]", apply: { editor, trigger in
            let text = editor.text as NSString
            var number = 1
            while text.range(of: "[^\(number)]").location != NSNotFound { number += 1 }
            editor.replace(trigger, with: "[^\(number)]", select: NSRange(location: trigger.location + "[^\(number)]".count, length: 0))
            let end = (editor.text as NSString).length
            let definition = (editor.text.hasSuffix("\n") ? "\n" : "\n\n") + "[^\(number)]: "
            editor.replace(NSRange(location: end, length: 0), with: definition, select: NSRange(location: end + (definition as NSString).length, length: 0))
        }),
    ]

    static func matching(_ query: String) -> [CompletionPopup.Item] {
        if query.isEmpty { return all }
        return all.compactMap { item in Palette.score(item.title, query).map { ($0, item) } }
            .sorted { $0.0 > $1.0 }.map(\.1)
    }
}
