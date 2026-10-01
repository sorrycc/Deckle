import AppKit
import CDeckleCore

/// Something in the text that can be followed.
enum EditorLink {
    /// A web address, or a path relative to the note.
    case destination(String)
    case wiki(String)
    case footnote(String)
}

@MainActor
protocol EditorViewDelegate: AnyObject {
    func editorTextDidChange(_ editor: EditorView)
    func editorSelectionDidChange(_ editor: EditorView)
    func editorDidSave(_ editor: EditorView)
    func editor(_ editor: EditorView, follow link: EditorLink, inNewTab: Bool)
    /// Notes whose name matches what follows a `[[`.
    func editor(_ editor: EditorView, notesMatching query: String) -> [FileMatch]
}

/// A heading of the document, for the outline.
struct Heading {
    let level: Int
    let title: String
    let range: NSRange
}

/// The editor of one text file: a TextKit 2 text view over plain text, styled
/// at display time from the spans the core parses.
final class EditorView: NSView, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate,
    @preconcurrency NSTextContentStorageDelegate, @preconcurrency NSTextLayoutManagerDelegate
{
    private(set) var url: URL
    weak var delegate: EditorViewDelegate?
    let scrollView = NSScrollView()
    let textView: EditorTextView
    let styler: Styler
    let core: CoreDocument

    /// Edited since the last save.
    private(set) var isDirty = false
    private var saveTimer: Timer?
    /// The range whose styling the core reported stale, until it is redrawn.
    private var staleStyle: NSRange?
    /// The elements whose syntax is showing.
    private var revealed: [NSRange] = []
    private var isRestyling = false
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private var widgetStore: WidgetStore?
    /// One list serves every editor; only the focused one types.
    var completion: CompletionPopup { .shared }
    private let rail = OutlineRail()
    private var outlinePending = false

    var storage: NSTextStorage { contentStorage.textStorage! }
    var text: String { storage.string }
    var isMarkdown: Bool { styler.isMarkdown }

    init(url: URL, text: String) {
        self.url = url
        let language = Language.name(for: url)
        styler = Styler(language: language)
        core = CoreDocument(text: text, language: language)

        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        layoutManager.textContainer = container
        textView = EditorTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)

        styler.isJapaneseDocument = CJK.isJapanese(text)
        storage.setAttributedString(NSAttributedString(string: text, attributes: styler.typingAttributes))
        storage.delegate = self
        contentStorage.delegate = self
        layoutManager.delegate = self
        if isMarkdown {
            let store = WidgetStore(editor: self)
            widgetStore = store
            styler.widgets = store
        }

        textView.editor = self
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        if isMarkdown {
            rail.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rail)
            NSLayoutConstraint.activate([
                rail.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
                rail.bottomAnchor.constraint(equalTo: bottomAnchor),
                rail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                rail.widthAnchor.constraint(equalToConstant: 300),
            ])
            rail.onSelect = { [weak self] heading in self?.reveal(NSRange(location: heading.range.location, length: 0)) }
            scheduleOutline()
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        applyAppearance()
        // The elements at the insertion point show their syntax from the
        // start, so moving away from them hides it again.
        revealed = elements(touching: textView.selectedRange())
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceChanged(_:)), name: .appearanceDidChange, object: nil)
    }

    // MARK: Outline

    @objc private func scrolled(_ note: Notification) {
        completion.reposition(for: self)
        scheduleOutline()
        // The block under the pointer changed, though the pointer didn't move.
        if let window, copyButton.superview != nil {
            pointerMoved(to: textView.convert(window.mouseLocationOutsideOfEventStream, from: nil), flags: NSEvent.modifierFlags)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Out of its window, the editor can't take what the list offers.
        if window == nil { completion.close(for: self) }
    }

    /// The outline follows edits and scrolling, once a burst of them settles.
    private func scheduleOutline() {
        guard isMarkdown, !outlinePending else { return }
        outlinePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.outlinePending = false
            self.updateOutline()
        }
    }

    private func updateOutline() {
        let headings = self.headings
        // The heading the top of the view is under.
        var current = -1
        if let top = textView.textLayoutManager?.textViewportLayoutController.viewportRange?.location,
            let storage = textView.textContentStorage
        {
            let offset = storage.offset(from: storage.documentRange.location, to: top)
            let caret = textView.selectedRange().location
            let anchor = window?.firstResponder === textView && caretIsVisible ? caret : offset
            current = (headings.lastIndex { $0.range.location <= anchor }) ?? -1
        }
        rail.show(headings, current: current)
    }

    private var caretIsVisible: Bool {
        let rect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        guard let window else { return false }
        return scrollView.convert(window.convertFromScreen(rect), from: nil).intersects(scrollView.bounds)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Appearance

    @objc private func appearanceChanged(_ note: Notification) {
        applyAppearance()
        restyle(NSRange(location: 0, length: storage.length))
    }

    private func applyAppearance() {
        styler.reload()
        let theme = styler.theme
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.accent
        textView.typingAttributes = styler.typingAttributes
        textView.isContinuousSpellCheckingEnabled = Settings.checksSpelling && isMarkdown
        scrollView.backgroundColor = theme.background
        scrollView.drawsBackground = true
        widgetStore?.invalidate()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Images of math and diagrams are drawn for one appearance.
        widgetStore?.invalidate()
        restyle(NSRange(location: 0, length: storage.length))
    }

    override func layout() {
        super.layout()
        // The column of text stays a readable width, centered in the pane.
        let width = isMarkdown ? Settings.lineWidth : CGFloat.greatestFiniteMagnitude
        let inset = NSSize(width: max(28, ((bounds.width - width) / 2).rounded()), height: 24)
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        // Room after the end of a long file, to scroll its last lines up to
        // eye level.
        textView.pastEnd = max(0, ((bounds.height - safeAreaInsets.top) * 0.45).rounded() - inset.height)
        // Widgets are sized to the column: a new width lays them out again.
        // That includes the first layout: TextKit asks for paragraphs before
        // the view has a frame, and those hold widgets sized for no width.
        // Not during a live resize, though: tables and diagrams are laid out
        // once, for the width the window settles on.
        let column = columnWidth.rounded()
        if bounds.width > 0, column != widgetWidth, !inLiveResize {
            widgetWidth = column
            widgetStore?.invalidate()
            restyleWidgetLines()
        }
    }

    /// Lays out again only the lines whose look depends on the column's
    /// width: images, tables, math and diagrams. The rest of a long note is
    /// left alone, so a resize costs no more than the widgets in it.
    private func restyleWidgetLines() {
        guard widgetStore != nil else { return }
        // The core answers with one span per line; a block is laid out once.
        var done: Set<Int> = []
        for kind in [DeckleImage, DeckleTable, DeckleMathBlock, DeckleCodeBlock, DeckleInlineMath] {
            for span in core.spans(ofKind: kind) {
                if kind == DeckleImage && span.flags & 1 == 0 { continue }
                if kind == DeckleCodeBlock && span.flags & UInt16(DeckleCodeDiagram | DeckleCodeMath) == 0 { continue }
                if done.insert(span.element.location).inserted { restyle(span.element) }
            }
        }
    }

    /// The column width the widgets were last laid out for.
    private var widgetWidth: CGFloat = 0

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Lines laid out during the resize hold widgets of passing widths,
        // whatever width the window ends at.
        widgetWidth = 0
        needsLayout = true
    }

    /// The width of the column of text.
    var columnWidth: CGFloat {
        max(100, bounds.width - 2 * textView.textContainerInset.width - 2 * (textView.textContainer?.lineFragmentPadding ?? 0))
    }

    // MARK: Text changes

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        let inserted = (textStorage.string as NSString).substring(with: editedRange)
        var stale = core.edit(at: editedRange.location, oldLength: editedRange.length - delta, text: inserted)
        // A note that turns Japanese, or stops being, redraws its lines of
        // only Han characters in the other forms.
        let japanese = CJK.isJapanese(textStorage.string)
        if japanese != styler.isJapaneseDocument {
            styler.isJapaneseDocument = japanese
            widgetStore?.invalidateTables()
            stale = NSRange(location: 0, length: textStorage.length)
        }
        staleStyle = staleStyle.map { NSUnionRange($0, stale) } ?? stale
        // Editing ends before the styling is redrawn; textDidChange does it
        // for the user's edits, and this for any other.
        DispatchQueue.main.async { [weak self] in self?.flushStaleStyle() }
    }

    func textDidChange(_ notification: Notification) {
        flushStaleStyle()
        updateCompletion()
        scheduleOutline()
        hideCopyButton()
        isDirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        delegate?.editorTextDidChange(self)
    }

    private func flushStaleStyle() {
        guard let range = staleStyle else { return }
        staleStyle = nil
        restyle(range)
    }

    /// The lines found styled for a stale width, restyled together after
    /// the layout that found them.
    private var healing: NSRange?

    private func healLater(_ range: NSRange) {
        if let healing { self.healing = NSUnionRange(healing, range); return }
        healing = range
        DispatchQueue.main.async { [weak self] in
            guard let self, let range = self.healing else { return }
            self.healing = nil
            self.restyle(range)
        }
    }

    /// Has the lines of `range` laid out again, with their current spans.
    func restyle(_ range: NSRange) {
        let length = storage.length
        guard length > 0, !isRestyling else { return }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        let start = min(range.location, length)
        let lines = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: clamped.length))
        guard lines.length > 0 else { return }
        isRestyling = true
        storage.beginEditing()
        storage.edited(.editedAttributes, range: lines, changeInLength: 0)
        storage.endEditing()
        isRestyling = false
    }

    // MARK: Display

    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        styler.paragraph(from: storage, range: range, spans: core.spans(in: range))
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let paragraph = textElement as? StyledParagraph, !paragraph.decoration.isPlain else {
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        if paragraph.decoration.widget != nil, bounds.width > 0, paragraph.decoration.widgetWidth != columnWidth, !inLiveResize,
            let range = textElement.elementRange
        {
            // Styled for another width, before a layout: laid out again once
            // this layout is done.
            let start = contentStorage.offset(from: contentStorage.documentRange.location, to: range.location)
            let length = contentStorage.offset(from: range.location, to: range.endLocation)
            healLater(NSRange(location: start, length: length))
        }
        let fragment = DecoratedFragment(textElement: textElement, range: textElement.elementRange)
        fragment.decoration = paragraph.decoration
        fragment.theme = styler.theme
        fragment.host = textView
        return fragment
    }

    // MARK: Selection

    func textViewDidChangeSelection(_ notification: Notification) {
        updateRevealed()
        // The list goes away once the insertion point leaves what it completes.
        if completion.isShown(for: self) {
            let caret = textView.selectedRange()
            let trigger = completion.trigger
            if caret.length > 0 || caret.location < trigger.location || caret.location > trigger.upperBound + 1 { completion.close() }
        }
        delegate?.editorSelectionDidChange(self)
    }

    /// The elements with syntax to show for a selection: those it touches.
    private func elements(touching selection: NSRange) -> [NSRange] {
        guard isMarkdown, styler.hidesMarkers, selection.length < 4000, storage.length > 0 else { return [] }
        let lines = (storage.string as NSString).paragraphRange(for: selection)
        var found: [NSRange] = []
        let spans = core.spans(in: lines)
        for span in spans {
            switch span.kindValue {
            case DeckleMarker, DeckleCalloutTag, DeckleThematicBreak, DeckleImage, DeckleTable, DeckleMathBlock, DeckleInlineMath,
                DeckleCodeBlock, DeckleFrontMatter, DeckleListMarker, DeckleTaskMarker:
                var element = span.element
                // A task's syntax shows around its prefix, not its whole line.
                if span.kindValue == DeckleListMarker || span.kindValue == DeckleTaskMarker {
                    let marker = span.kindValue == DeckleListMarker ? span
                        : spans.first { $0.kindValue == DeckleListMarker && $0.element == span.element && $0.end <= span.start }
                    let task = span.kindValue == DeckleTaskMarker ? span
                        : spans.first { $0.kindValue == DeckleTaskMarker && $0.element == span.element && $0.start >= span.end }
                    if let marker, let task { element = Styler.taskPrefix(of: marker, task: task) }
                }
                if selection.location <= element.upperBound && selection.upperBound >= element.location, found.last != element,
                    !found.contains(element)
                {
                    found.append(element)
                }
            default: break
            }
        }
        return found
    }

    private func updateRevealed() {
        let selection = textView.selectedRange()
        styler.selection = selection
        let now = elements(touching: selection)
        guard now != revealed else { return }
        let before = revealed
        revealed = now
        for element in before + now { restyle(element) }
    }

    // MARK: Hover

    /// The pointer is over a link with ⌘ held: a click would follow it.
    private(set) var wantsPointingHand = false
    private var copyTitleTimer: Timer?
    /// The code block the Copy button is over.
    private var hoveredBlock: NSRange?
    private static let copyImage = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
    private static let copiedImage = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))

    /// Copies a code block, from its top right corner while the pointer is
    /// over the block.
    private lazy var copyButton: NSButton = {
        let button = NSButton(title: "Copy", image: Self.copyImage ?? NSImage(), target: self, action: #selector(copyBlock(_:)))
        button.bezelStyle = .glass
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.toolTip = "Copy the code"
        button.sizeToFit()
        return button
    }()

    /// The text view's pointer moved to `point`, or the modifier keys changed.
    func pointerMoved(to point: NSPoint, flags: NSEvent.ModifierFlags) {
        let index = textView.characterIndexForInsertion(at: point)
        let hand = isMarkdown && textView.bounds.contains(point)
            && ((flags.contains(.command) && link(at: index) != nil) || textView.taskBox(at: point) != nil)
        if hand != wantsPointingHand {
            wantsPointingHand = hand
            (hand ? NSCursor.pointingHand : NSCursor.iBeam).set()
        }
        guard isMarkdown, textView.bounds.contains(point), let block = codeBlock(at: index), let band = blockBand(block),
            point.x >= band.minX, point.x <= band.maxX, point.y >= band.minY
        else { return hideCopyButton() }
        if hoveredBlock != block {
            hoveredBlock = block
            resetCopyTitle()
        }
        let size = copyButton.frame.size
        copyButton.frame.origin = NSPoint(x: (band.maxX - size.width - 8).rounded(), y: (band.minY + (band.lineHeight - size.height) / 2).rounded())
        if copyButton.superview == nil { textView.addSubview(copyButton) }
    }

    func pointerLeft() {
        if wantsPointingHand {
            wantsPointingHand = false
            NSCursor.iBeam.set()
        }
        hideCopyButton()
    }

    private func hideCopyButton() {
        hoveredBlock = nil
        if copyButton.superview != nil { copyButton.removeFromSuperview() }
    }

    /// The code block, drawn as code, that the character at `index` is in.
    private func codeBlock(at index: Int) -> NSRange? {
        guard storage.length > 0 else { return nil }
        let string = storage.string as NSString
        let lines = string.paragraphRange(for: NSRange(location: min(index, string.length - 1), length: 0))
        return core.spans(in: lines).first {
            $0.kindValue == DeckleCodeBlock && $0.flags & UInt16(DeckleCodeDiagram | DeckleCodeMath) == 0
        }?.element
    }

    /// Where a block's first line is drawn, in the text view: its band across
    /// the column, and the height of the line.
    private func blockBand(_ element: NSRange) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, lineHeight: CGFloat)? {
        guard let layoutManager = textView.textLayoutManager, let container = layoutManager.textContainer,
            let location = contentStorage.location(contentStorage.documentRange.location, offsetBy: element.location),
            let fragment = layoutManager.textLayoutFragment(for: location)
        else { return nil }
        let origin = textView.textContainerOrigin
        let frame = fragment.layoutFragmentFrame
        let lineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
        return (origin.x, origin.x + container.size.width, origin.y + frame.minY, lineHeight)
    }

    @objc private func copyBlock(_ sender: Any?) {
        guard let block = hoveredBlock, block.upperBound <= storage.length else { return }
        let code = WidgetStore.fenceSource(of: block, in: self)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(code, forType: .string)
        copyButton.title = "Copied"
        copyButton.image = Self.copiedImage
        copyButton.sizeToFit()
        copyTitleTimer?.invalidate()
        copyTitleTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetCopyTitle() }
        }
    }

    private func resetCopyTitle() {
        copyTitleTimer?.invalidate()
        copyButton.title = "Copy"
        copyButton.image = Self.copyImage
        copyButton.sizeToFit()
    }

    // MARK: Completion

    private static let slashPattern = try! NSRegularExpression(pattern: #"^([ \t]*(?:>[ \t]?)*)/([\p{L}\d ]{0,24})$"#)
    private static let linkPattern = try! NSRegularExpression(pattern: #"\[\[([^\[\]|#\n]{0,80})$"#)

    /// Offers blocks after a `/` that starts a line, and notes after `[[`.
    private func updateCompletion() {
        let selection = textView.selectedRange()
        guard isMarkdown, selection.length == 0, !textView.hasMarkedText(), !isCode(at: selection.location) else { return completion.close(for: self) }
        let string = storage.string as NSString
        let line = string.lineRange(for: NSRange(location: selection.location, length: 0))
        let head = string.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let headRange = NSRange(location: 0, length: (head as NSString).length)
        if let match = Self.slashPattern.firstMatch(in: head, range: headRange) {
            let prefix = match.range(at: 1).length
            let query = (head as NSString).substring(with: match.range(at: 2))
            let trigger = NSRange(location: line.location + prefix, length: selection.location - line.location - prefix)
            completion.show(SlashCommands.matching(query), trigger: trigger, in: self)
        } else if let match = Self.linkPattern.firstMatch(in: head, range: headRange) {
            let query = (head as NSString).substring(with: match.range(at: 1))
            let trigger = NSRange(location: line.location + match.range.location, length: match.range.length)
            let notes = delegate?.editor(self, notesMatching: query) ?? []
            completion.show(notes.map { note in
                let url = URL(fileURLWithPath: note.path)
                let name = url.deletingPathExtension().lastPathComponent
                return CompletionPopup.Item(symbol: "doc.text", title: name, detail: note.rel, apply: { editor, trigger in
                    // Takes in the ]] typed after the insertion point too.
                    let text = editor.storage.string as NSString
                    var range = trigger
                    if range.upperBound + 2 <= text.length, text.substring(with: NSRange(location: range.upperBound, length: 2)) == "]]" {
                        range.length += 2
                    }
                    let link = "[[\(name)]]"
                    editor.replace(range, with: link, select: NSRange(location: range.location + (link as NSString).length, length: 0))
                })
            }, trigger: trigger, in: self)
        } else {
            completion.close(for: self)
        }
    }

    // MARK: Files

    /// Copies an image into the note's `assets` folder, unless it is in the
    /// workspace already, and links it in place of `range`.
    func insertImage(from source: URL, replacing range: NSRange) {
        let folder = url.deletingLastPathComponent()
        var target = source
        if !source.path.hasPrefix(folder.path + "/") {
            let assets = folder.appendingPathComponent("assets", isDirectory: true)
            target = FileTreeController.freeName(source.deletingPathExtension().lastPathComponent, extension: source.pathExtension, in: assets)
            do {
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
            } catch {
                presentError(error)
                return
            }
        }
        insertLink(to: target, replacing: range)
    }

    func insertImageOrLink(_ file: URL, replacing range: NSRange) {
        if Files.isImage(file) { insertImage(from: file, replacing: range) } else { insertLink(to: file, replacing: range) }
    }

    /// Saves image data from the clipboard as a PNG in `assets`, and links it.
    func insertImage(data: Data, replacing range: NSRange) {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        let assets = url.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let target = FileTreeController.freeName("Pasted \(stamp)", extension: "png", in: assets)
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try png.write(to: target)
        } catch {
            presentError(error)
            return
        }
        insertLink(to: target, replacing: range)
    }

    /// A link to a file: an image to show, a note, or any other file.
    func insertLink(to file: URL, replacing range: NSRange) {
        let relative = Self.relativePath(from: url.deletingLastPathComponent(), to: file)
        let encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
        let name = file.deletingPathExtension().lastPathComponent
        let link = Files.isImage(file) ? "![\(name)](\(encoded))" : Files.isMarkdown(file) ? "[[\(name)]]" : "[\(file.lastPathComponent)](\(encoded))"
        let string = storage.string as NSString
        // An image goes on a line of its own.
        let needsBreak = Files.isImage(file) && range.location > 0 && string.character(at: range.location - 1) != 10
        let text = (needsBreak ? "\n" : "") + link
        replace(range, with: text, select: NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    static func relativePath(from folder: URL, to file: URL) -> String {
        let base = folder.standardizedFileURL.pathComponents
        let target = file.standardizedFileURL.pathComponents
        var common = 0
        while common < min(base.count, target.count) && base[common] == target[common] { common += 1 }
        let ups = Array(repeating: "..", count: base.count - common)
        return (ups + target[common...]).joined(separator: "/")
    }

    // MARK: Saving

    /// Writes the text to its file if it changed.
    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard isDirty else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            saveFailed = false
            delegate?.editorDidSave(self)
        } catch {
            NSLog("Deckle: could not save \(url.path): \(error.localizedDescription)")
            // Said once: every edit tries again, and the file may stay
            // read-only for a while.
            guard !saveFailed else { return }
            saveFailed = true
            let alert = NSAlert()
            alert.messageText = "The note couldn't be saved"
            alert.informativeText = "\(url.lastPathComponent) couldn't be written. \(error.localizedDescription) Your edits stay in the editor, and Deckle will try again after the next change."
            alert.alertStyle = .warning
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    /// The last save failed, and the user has been told.
    private var saveFailed = false

    /// The file moved.
    func moved(to url: URL) {
        self.url = url
    }

    /// Takes the file's text after something else wrote it. Unsaved edits
    /// win: they are written over it at the next save.
    func reloadFromDisk() {
        guard !isDirty, let disk = Files.readText(url), disk != text else { return }
        replaceText(with: disk)
        isDirty = false
        saveTimer?.invalidate()
    }

    /// Replaces the text by its difference from `new`, which keeps the
    /// selection and the scroll position where they were.
    private func replaceText(with new: String) {
        let old = text as NSString
        let new = new as NSString
        var prefix = 0
        let shortest = min(old.length, new.length)
        while prefix < shortest && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix
            && old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix)
        { suffix += 1 }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        replace(range, with: replacement)
    }

    /// An edit the user can undo.
    func replace(_ range: NSRange, with string: String, select selection: NSRange? = nil) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: styler.typingAttributes))
        textView.didChangeText()
        if let selection { textView.setSelectedRange(selection) }
    }

    // MARK: Navigation

    /// Selects `range` and brings it into view.
    func reveal(_ range: NSRange) {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        let target = NSRange(location: min(range.location, storage.length), length: clamped.length)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        window?.makeFirstResponder(textView)
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    var headings: [Heading] {
        let string = storage.string as NSString
        return core.spans(ofKind: DeckleHeading).compactMap { span in
            guard span.range.upperBound <= string.length else { return nil }
            var title = string.substring(with: span.range)
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "# \t"))
            return title.isEmpty ? nil : Heading(level: Int(span.level), title: title, range: span.range)
        }
    }

    /// The line and column of the insertion point, from 1.
    var position: (line: Int, column: Int) {
        let selection = textView.selectedRange()
        let location = min(selection.location, storage.length)
        let line = (storage.string as NSString).lineRange(for: NSRange(location: location, length: 0))
        return (core.line(of: location), location - line.location + 1)
    }

    /// What can be followed at a character, if anything.
    func link(at index: Int) -> EditorLink? {
        guard isMarkdown, index <= storage.length, storage.length > 0 else { return nil }
        let string = storage.string as NSString
        let lines = string.paragraphRange(for: NSRange(location: min(index, string.length - 1), length: 0))
        let spans = core.spans(in: lines)
        func text(of kind: Int, in element: NSRange) -> String? {
            spans.first { $0.kindValue == kind && $0.element == element }.map { string.substring(with: $0.range) }
        }
        for span in spans where span.element.location <= index && index <= span.element.upperBound {
            switch span.kindValue {
            case DeckleWikiLink, DeckleWikiTarget:
                if let target = text(of: DeckleWikiTarget, in: span.element) { return .wiki(target) }
            case DeckleLink, DeckleLinkDest:
                if let destination = text(of: DeckleLinkDest, in: span.element) { return .destination(destination) }
            case DeckleImage, DeckleImageDest:
                if let destination = text(of: DeckleImageDest, in: span.element) { return .destination(destination) }
            case DeckleFootnoteRef:
                let label = string.substring(with: span.range).trimmingCharacters(in: CharacterSet(charactersIn: "[]^"))
                return .footnote(label)
            default: break
            }
        }
        return nil
    }

    /// The task checkbox at a character, if there is one.
    func taskMarker(at index: Int) -> DeckleSpan? {
        guard isMarkdown, storage.length > 0 else { return nil }
        let string = storage.string as NSString
        let lines = string.paragraphRange(for: NSRange(location: min(index, string.length - 1), length: 0))
        return core.spans(in: lines).first {
            $0.kindValue == DeckleTaskMarker && Int($0.start) <= index && index < Int($0.end)
        }
    }

    /// Jumps between a footnote's reference and its definition.
    func jumpToFootnote(_ label: String) {
        let string = storage.string as NSString
        let definition = string.range(of: "[^\(label)]:")
        let current = textView.selectedRange().location
        if definition.location != NSNotFound && !NSLocationInRange(current, string.lineRange(for: definition)) {
            reveal(NSRange(location: definition.upperBound, length: 0))
        } else {
            let reference = string.range(of: "[^\(label)]")
            if reference.location != NSNotFound { reveal(NSRange(location: reference.upperBound, length: 0)) }
        }
    }

    /// Whether the line at `index` is inside a code block or front matter.
    func isCode(at index: Int) -> Bool {
        guard isMarkdown, storage.length > 0 else { return !isMarkdown }
        let string = storage.string as NSString
        let lines = string.paragraphRange(for: NSRange(location: min(index, string.length), length: 0))
        return core.spans(in: lines).contains { $0.kindValue == DeckleCodeBlock || $0.kindValue == DeckleFrontMatter }
    }
}

/// Reading files as text.
enum Files {
    /// The text of a file, or nil when it isn't text.
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Not UTF-8: a file with a NUL in it is taken for binary.
        if data.prefix(4096).contains(0) { return nil }
        var converted: NSString?
        let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        return encoding == 0 ? nil : converted as String?
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "svg", "avif", "ico"]

    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }
    static func isMarkdown(_ url: URL) -> Bool { Language.name(for: url) == "markdown" }
}
