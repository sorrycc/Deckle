import AppKit
import CDeckleCore

/// The editor's text view: what typing and clicking mean in Markdown.
final class EditorTextView: NSTextView {
    weak var editor: EditorView?

    /// A list item or quote up to the insertion point: indent and quote
    /// marks, then a list marker, a task box and the space before the text.
    private static let itemPattern = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]?)*)(?:([-*+]|\d{1,9}[.)])([ \t]+\[[ xX]\])?([ \t]+))?(.*)$"#)

    private struct Item {
        let prefix: String
        let marker: String
        let task: String
        let gap: String
        let content: String
    }

    private func item(in line: String) -> Item? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = Self.itemPattern.firstMatch(in: line, range: range) else { return nil }
        func group(_ index: Int) -> String {
            let r = match.range(at: index)
            return r.location == NSNotFound ? "" : (line as NSString).substring(with: r)
        }
        let item = Item(prefix: group(1), marker: group(2), task: group(3), gap: group(4), content: group(5))
        // Plain text is neither a list item nor a quote.
        return item.marker.isEmpty && !item.prefix.contains(">") ? nil : item
    }

    // MARK: Size

    /// Room after the text, so the last lines of a long file can scroll up
    /// to eye level. The scroll view's insets can't give it: text under
    /// them is never laid out.
    var pastEnd: CGFloat = 0 {
        didSet {
            if pastEnd != oldValue { setFrameSize(NSSize(width: frame.width, height: contentHeight)) }
        }
    }
    /// The height the text asked for, and the height it was given.
    private var contentHeight: CGFloat = 0
    private var paddedHeight: CGFloat = -1

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        // The text view sizes itself to its text; a width change hands the
        // padded height back, which is not a new content height.
        if size.height != paddedHeight { contentHeight = size.height }
        size.height = contentHeight + pastEnd
        paddedHeight = size.height
        super.setFrameSize(size)
    }

    /// A click in the room after the text puts the insertion point at the end.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if pastEnd > 0, point.y > frame.height - pastEnd + textContainerInset.height, event.clickCount == 1 {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
            return
        }
        clickDown(with: event)
    }

    // MARK: Typing

    /// ⌘⌫ deletes to the start of the line, as it does in every text view.
    /// The File menu gives the same keys to Move to Trash, and a menu sees a
    /// key before the text view would, so the editor claims them first while
    /// it has the keyboard; from a list, the keys still trash the selection.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            window?.firstResponder === self, isEditable
        {
            deleteToBeginningOfLine(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The completion list takes the arrow keys, Return and Escape while open.
    override func doCommand(by selector: Selector) {
        if let editor, editor.completion.handle(selector, from: editor) { return }
        super.doCommand(by: selector)
    }

    /// Escape puts the find bar away, or collapses the selection. The text
    /// system would open its word completions, which a note rarely wants.
    override func cancelOperation(_ sender: Any?) {
        if let scrollView = enclosingScrollView, scrollView.isFindBarVisible {
            let hide = NSMenuItem()
            hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
            performTextFinderAction(hide)
            return
        }
        let selection = selectedRange()
        if selection.length > 0 { setSelectedRange(NSRange(location: selection.upperBound, length: 0)) }
    }

    /// Pasting an image, or image files, saves them beside the note and links
    /// them.
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let editor, editor.isMarkdown {
            let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if !files.isEmpty {
                for file in files { editor.insertImageOrLink(file, replacing: selectedRange()) }
                return
            }
            if board.string(forType: .string) == nil, let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
                editor.insertImage(data: data, replacing: selectedRange())
                return
            }
        }
        pasteAsPlainText(sender)
    }

    /// Dropped files become links where they land.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let editor, editor.isMarkdown, !files.isEmpty else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        for file in files { editor.insertImageOrLink(file, replacing: selectedRange()) }
        return true
    }

    /// Return continues a list or a quote, and ends it on an empty item.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard let editor, editor.isMarkdown, selection.length == 0, !hasMarkedText(), !editor.isCode(at: selection.location) else {
            return super.insertNewline(sender)
        }
        let string = self.string as NSString
        let line = string.lineRange(for: selection)
        let head = string.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        guard let item = item(in: head) else { return super.insertNewline(sender) }
        if item.content.trimmingCharacters(in: .whitespaces).isEmpty {
            // Nothing typed in this item: Return takes its marker away.
            let lineEnd = string.substring(with: NSRange(location: selection.location, length: line.upperBound - selection.location))
            guard lineEnd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return super.insertNewline(sender) }
            insertText("", replacementRange: NSRange(location: line.location, length: selection.location - line.location))
            return
        }
        var marker = item.marker
        if let number = Int(marker.dropLast()), let last = marker.last, marker.count > 1 || last == "." || last == ")" {
            marker = "\(number + 1)\(last)"
        }
        let task = item.task.isEmpty ? "" : " [ ]"
        insertText("\n" + item.prefix + marker + task + item.gap, replacementRange: selection)
    }

    /// Tab and Shift-Tab move a list item in and out.
    override func insertTab(_ sender: Any?) {
        if !shiftItems(by: 1) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !shiftItems(by: -1) { super.insertBacktab(sender) }
    }

    private func shiftItems(by direction: Int) -> Bool {
        guard let editor, editor.isMarkdown, !editor.isCode(at: selectedRange().location) else { return false }
        let string = self.string as NSString
        let selection = selectedRange()
        let lines = string.lineRange(for: selection)
        var pieces: [String] = []
        var any = false
        string.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, range, enclosing, _ in
            let line = string.substring(with: enclosing)
            let isItem = self.item(in: string.substring(with: range)).map { !$0.marker.isEmpty } ?? false
            if !isItem {
                pieces.append(line)
            } else if direction > 0 {
                any = true
                pieces.append("  " + line)
            } else {
                let spaces = min(2, line.prefix { $0 == " " }.count)
                if line.hasPrefix("\t") {
                    any = true
                    pieces.append(String(line.dropFirst()))
                } else {
                    any = any || spaces > 0
                    pieces.append(String(line.dropFirst(spaces)))
                }
            }
        }
        guard any else { return selection.length == 0 ? false : direction < 0 }
        let replacement = pieces.joined()
        let delta = (replacement as NSString).length - lines.length
        insertText(replacement, replacementRange: lines)
        if selection.length == 0 {
            setSelectedRange(NSRange(location: max(lines.location, selection.location + delta), length: 0))
        } else {
            setSelectedRange(NSRange(location: lines.location, length: (replacement as NSString).length))
        }
        return true
    }

    // MARK: Pointing

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        editor?.pointerMoved(to: convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        editor?.pointerLeft()
    }

    /// Holding ⌘ over a link shows that a click would follow it.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        editor?.pointerMoved(to: convert(window.mouseLocationOutsideOfEventStream, from: nil), flags: event.modifierFlags)
    }

    override func cursorUpdate(with event: NSEvent) {
        if editor?.wantsPointingHand == true { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }

    // MARK: Clicking

    private func clickDown(with event: NSEvent) {
        guard let editor else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if event.modifierFlags.contains(.command), let link = editor.link(at: index) {
            editor.delegate?.editor(editor, follow: link, inNewTab: event.modifierFlags.contains(.shift))
            return
        }
        // A click on a task box ticks it.
        if event.clickCount == 1, let marker = taskBox(at: point) {
            let selection = selectedRange()
            editor.replace(marker.range, with: marker.flags != 0 ? "[ ]" : "[x]", select: selection)
            return
        }
        super.mouseDown(with: event)
    }

    /// The task box drawn at `point`, if there is one.
    func taskBox(at point: NSPoint) -> DeckleSpan? {
        guard let editor, let window else { return nil }
        let index = characterIndexForInsertion(at: point)
        guard let marker = editor.taskMarker(at: index) ?? editor.taskMarker(at: max(0, index - 1)) else { return nil }
        // The box sits in the marker's room, from where its brackets start.
        let caret = firstRect(forCharacterRange: NSRange(location: marker.range.location, length: 0), actualRange: nil)
        let at = convert(window.convertFromScreen(caret), from: nil)
        let size = editor.styler.fonts.size
        let side = (size * 0.95).rounded()
        let center = CGPoint(x: at.minX + Styler.markerStep(for: size) * Styler.markerCenter, y: at.midY)
        let box = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        return box.insetBy(dx: -4, dy: -3).contains(point) ? marker : nil
    }

    // MARK: Formatting

    /// Wraps the selection in `mark`, or takes the marks away if it has them.
    private func toggleWrap(_ mark: String) {
        guard let editor, editor.isMarkdown else { return }
        let string = self.string as NSString
        let selection = selectedRange()
        let length = (mark as NSString).length
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: selection.upperBound, length: length)
        if before.location >= 0, after.upperBound <= string.length, string.substring(with: before) == mark,
            string.substring(with: after) == mark
        {
            let whole = NSRange(location: before.location, length: selection.length + 2 * length)
            insertText(string.substring(with: selection), replacementRange: whole)
            setSelectedRange(NSRange(location: before.location, length: selection.length))
            return
        }
        let inner = string.substring(with: selection)
        insertText(mark + inner + mark, replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + length, length: selection.length))
    }

    @objc func toggleBold(_ sender: Any?) { toggleWrap("**") }
    @objc func toggleItalic(_ sender: Any?) { toggleWrap("*") }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleWrap("~~") }
    @objc func toggleInlineCode(_ sender: Any?) { toggleWrap("`") }
    @objc func toggleHighlight(_ sender: Any?) { toggleWrap("==") }

    @objc func insertLink(_ sender: Any?) {
        guard let editor, editor.isMarkdown else { return }
        let selection = selectedRange()
        let inner = (string as NSString).substring(with: selection)
        insertText("[\(inner)](url)", replacementRange: selection)
        // The placeholder is selected, ready to be typed over.
        setSelectedRange(NSRange(location: selection.location + selection.length + 3, length: 3))
    }

    /// Sets the heading level of the selected lines; the menu item's tag is
    /// the level, and 0 makes them plain text.
    @objc func setHeadingLevel(_ sender: NSMenuItem) {
        setLinePrefix(sender.tag > 0 ? String(repeating: "#", count: sender.tag) + " " : "", replacing: #"^#{1,6}[ \t]+"#)
    }

    private static let listPattern = #"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#

    @objc func toggleBulletList(_ sender: Any?) { setLinePrefix("- ", replacing: Self.listPattern, toggles: true) }
    @objc func toggleTaskList(_ sender: Any?) { setLinePrefix("- [ ] ", replacing: Self.listPattern, toggles: true) }
    @objc func toggleQuote(_ sender: Any?) { setLinePrefix("> ", replacing: #"^>[ \t]?"#, toggles: true) }

    /// Numbers the selected lines from 1, or takes the numbers away when
    /// they all have one.
    @objc func toggleNumberedList(_ sender: Any?) {
        guard let editor, editor.isMarkdown, let regex = try? NSRegularExpression(pattern: Self.listPattern) else { return }
        let string = self.string as NSString
        let lines = string.lineRange(for: selectedRange())
        var texts: [(line: String, ending: String)] = []
        string.enumerateSubstrings(in: lines, options: .byLines) { line, range, enclosing, _ in
            texts.append((line ?? "", string.substring(with: NSRange(location: range.upperBound, length: enclosing.upperBound - range.upperBound))))
        }
        if texts.isEmpty { texts = [("", "")] }
        let numbered = try? NSRegularExpression(pattern: #"^[ \t]*\d+[.)][ \t]+"#)
        let allHave = texts.allSatisfy { numbered?.firstMatch(in: $0.line, range: NSRange(location: 0, length: ($0.line as NSString).length)) != nil }
        let replacement = texts.enumerated().map { index, text -> String in
            let range = NSRange(location: 0, length: (text.line as NSString).length)
            let bare = regex.stringByReplacingMatches(in: text.line, range: range, withTemplate: "")
            return (allHave ? bare : "\(index + 1). " + bare) + text.ending
        }.joined()
        insertText(replacement, replacementRange: lines)
        let end = lines.location + (replacement as NSString).length - (texts.last?.ending as NSString? ?? "").length
        setSelectedRange(NSRange(location: end, length: 0))
    }

    /// Fences the selected lines as a code block, or unfences a block the
    /// selection is in.
    @objc func toggleCodeBlock(_ sender: Any?) {
        guard let editor, editor.isMarkdown else { return }
        let string = self.string as NSString
        let selection = selectedRange()
        if editor.isCode(at: selection.location), let block = editor.codeBlockElement(at: selection.location) {
            // Out of the fences: the lines between them stay.
            let lines = string.substring(with: block).components(separatedBy: "\n")
            guard lines.count >= 2 else { return }
            let inner = lines.dropFirst().dropLast().joined(separator: "\n")
            insertText(inner, replacementRange: block)
            setSelectedRange(NSRange(location: block.location, length: (inner as NSString).length))
            return
        }
        let lines = string.lineRange(for: selection)
        var body = string.substring(with: lines)
        let hadBreak = body.hasSuffix("\n")
        if hadBreak { body.removeLast() }
        let fenced = "```\n" + body + "\n```" + (hadBreak ? "\n" : "")
        insertText(fenced, replacementRange: lines)
        // The insertion point after the opening fence, to name the language.
        setSelectedRange(NSRange(location: lines.location + 3, length: 0))
    }

    @objc func indentItems(_ sender: Any?) { _ = shiftItems(by: 1) }
    @objc func outdentItems(_ sender: Any?) { _ = shiftItems(by: -1) }

    /// Gives the selected lines `prefix` in place of what `pattern` matches at
    /// their start. With `toggles`, lines that all have it lose it.
    private func setLinePrefix(_ prefix: String, replacing pattern: String, toggles: Bool = false) {
        guard let editor, editor.isMarkdown, let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let string = self.string as NSString
        let lines = string.lineRange(for: selectedRange())
        var texts: [(line: String, ending: String)] = []
        string.enumerateSubstrings(in: lines, options: .byLines) { line, range, enclosing, _ in
            texts.append((line ?? "", string.substring(with: NSRange(location: range.upperBound, length: enclosing.upperBound - range.upperBound))))
        }
        if texts.isEmpty { texts = [("", "")] }
        let allHave = toggles && texts.allSatisfy { $0.line.hasPrefix(prefix) }
        let replacement = texts.map { text -> String in
            let range = NSRange(location: 0, length: (text.line as NSString).length)
            let bare = regex.stringByReplacingMatches(in: text.line, range: range, withTemplate: "")
            return (allHave ? bare : prefix + bare) + text.ending
        }.joined()
        insertText(replacement, replacementRange: lines)
        let end = lines.location + (replacement as NSString).length - (texts.last?.ending as NSString? ?? "").length
        setSelectedRange(NSRange(location: end, length: 0))
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleStrikethrough(_:)),
            #selector(toggleInlineCode(_:)), #selector(toggleHighlight(_:)), #selector(insertLink(_:)),
            #selector(setHeadingLevel(_:)), #selector(toggleBulletList(_:)), #selector(toggleTaskList(_:)),
            #selector(toggleNumberedList(_:)), #selector(toggleQuote(_:)), #selector(toggleCodeBlock(_:)),
            #selector(indentItems(_:)), #selector(outdentItems(_:)):
            guard let editor, editor.isMarkdown, isEditable else { return false }
            // The menu shows what the insertion point is in: the heading
            // level, the inline style, the kind of list.
            item.state = isCurrent(item.action, level: item.tag, editor: editor) ? .on : .off
            return true
        default:
            return super.validateMenuItem(item)
        }
    }

    /// Whether the style a Format command toggles is on at the selection.
    private func isCurrent(_ action: Selector?, level: Int, editor: EditorView) -> Bool {
        let selection = selectedRange()
        let string = self.string as NSString
        guard string.length > 0 else { return action == #selector(setHeadingLevel(_:)) && level == 0 }
        let lines = string.paragraphRange(for: selection)
        let spans = editor.core.spans(in: lines)
        func inside(_ kind: Int) -> Bool {
            spans.contains { $0.kindValue == kind && Int($0.start) <= selection.location && selection.upperBound <= Int($0.end) }
        }
        switch action {
        case #selector(setHeadingLevel(_:)):
            let heading = spans.first { $0.kindValue == DeckleHeading }
            return level == 0 ? heading == nil : heading.map { Int($0.level) == level } ?? false
        case #selector(toggleBold(_:)): return inside(DeckleStrong)
        case #selector(toggleItalic(_:)): return inside(DeckleEmphasis)
        case #selector(toggleStrikethrough(_:)): return inside(DeckleStrike)
        case #selector(toggleInlineCode(_:)): return inside(DeckleCode)
        case #selector(toggleHighlight(_:)): return inside(DeckleHighlight)
        case #selector(toggleQuote(_:)): return spans.contains { $0.kindValue == DeckleBlockQuote }
        case #selector(toggleCodeBlock(_:)): return spans.contains { $0.kindValue == DeckleCodeBlock }
        case #selector(toggleTaskList(_:)): return spans.contains { $0.kindValue == DeckleTaskMarker }
        case #selector(toggleBulletList(_:)):
            return spans.contains { $0.kindValue == DeckleListMarker && $0.flags == 0 } && !spans.contains { $0.kindValue == DeckleTaskMarker }
        case #selector(toggleNumberedList(_:)): return spans.contains { $0.kindValue == DeckleListMarker && $0.flags != 0 }
        default: return false
        }
    }
}
