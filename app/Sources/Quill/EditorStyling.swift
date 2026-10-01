import AppKit
import CQuillCore

/// What a line's fragment draws besides its text.
struct LineDecoration {
    enum Block {
        case none
        case code
        case frontMatter
    }

    var block = Block.none
    var blockFirst = false
    var blockLast = false
    /// A label at the top right of a code block: its language.
    var blockLabel: String?
    var quoteDepth = 0
    /// The kind of callout the line is in, or 0.
    var callout = 0
    var calloutFirst = false
    var calloutLast = false
    /// Set where the callout's tag is hidden: the fragment draws its icon,
    /// and this name when no title follows.
    var calloutName: String?
    var calloutHasTitle = false
    /// A rule across the line, in place of its hidden `---`.
    var drawsRule = false
    /// A block drawn in place of the line's text, or above it.
    var widget: Widget?
    /// The column width the widget was laid out for.
    var widgetWidth: CGFloat = 0
    /// Images drawn in the line at a character, in the room its kerning
    /// makes: rendered inline math.
    var inlineImages: [(index: Int, image: NSImage, size: NSSize)] = []
    /// The line's height when a widget takes its place: the text is hidden
    /// and the line all but closes.
    var lineHeight: CGFloat?
    /// Bullets drawn over hidden list markers: the marker's character, which
    /// keeps its room, and the depth of its list.
    var bullets: [(index: Int, level: Int)] = []
    /// Boxes drawn over hidden task markers.
    var checkboxes: [(range: NSRange, checked: Bool)] = []
    /// The size of the line's font, which the bullets and boxes scale with.
    var fontSize: CGFloat = 15

    var isPlain: Bool {
        block == .none && quoteDepth == 0 && callout == 0 && !drawsRule && widget == nil && inlineImages.isEmpty
            && bullets.isEmpty && checkboxes.isEmpty
    }
}

/// A paragraph as displayed: the storage's text with the styling of its spans.
final class StyledParagraph: NSTextParagraph {
    var decoration = LineDecoration()
}

/// Styles a line of the document for display. The text storage keeps plain
/// Markdown; what the spans add is applied here, when a paragraph is laid out.
@MainActor
final class Styler {
    let language: String
    private(set) var theme = Theme.current
    private(set) var fonts = Fonts.current
    /// The selection that decides which syntax shows.
    var selection = NSRange(location: 0, length: 0)
    var hidesMarkers = Settings.hidesMarkers
    /// Where images and other widgets of the document come from.
    weak var widgets: WidgetSource?

    private var base: [NSAttributedString.Key: Any] = [:]
    private var traitCache: [String: NSFont] = [:]
    /// Too small to see or to take room.
    private let hiddenFont = NSFont.systemFont(ofSize: 0.01)

    static let calloutNames = ["", "Note", "Tip", "Important", "Warning", "Caution"]
    static let calloutSymbols = ["", "info.circle", "lightbulb", "exclamationmark.bubble", "exclamationmark.triangle", "flame"]
    static let quoteIndent: CGFloat = 18
    static let blockPadding: CGFloat = 14

    var isMarkdown: Bool { language == "markdown" }

    init(language: String) {
        self.language = language
        reload()
    }

    /// Takes the theme and fonts from the settings again.
    func reload() {
        theme = Theme.current
        fonts = Fonts.current
        hidesMarkers = Settings.hidesMarkers
        traitCache.removeAll()
        base = [.font: isMarkdown ? fonts.body : fonts.mono, .foregroundColor: theme.text]
    }

    /// The attributes of text as typed, before its spans are known.
    var typingAttributes: [NSAttributedString.Key: Any] { base }

    static func naturalHeight(of font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    func lineHeight(for font: NSFont, tight: Bool = false) -> CGFloat {
        let multiple = tight ? min(Settings.lineHeight, 1.4) : Settings.lineHeight
        return (Styler.naturalHeight(of: font) * multiple).rounded(.up)
    }

    /// Whether the syntax of `element` shows: the selection touches it.
    func isRevealed(_ element: NSRange) -> Bool {
        !hidesMarkers || (selection.location <= element.upperBound && selection.upperBound >= element.location)
    }

    /// The part of a task's line whose syntax shows together: from the start
    /// of the item through its box. The marker's element is the whole line,
    /// but a task reveals only around its prefix, so editing the text never
    /// moves it; the start of the text, one past the box, is outside.
    static func taskPrefix(of marker: QuillSpan, task: QuillSpan) -> NSRange {
        let start = Int(marker.elem_start)
        return NSRange(location: start, length: min(Int(task.end), Int(task.elem_end)) - start)
    }

    private func trait(_ trait: NSFontDescriptor.SymbolicTraits, of font: NSFont) -> NSFont {
        let key = "\(font.fontName)|\(font.pointSize)|\(trait.rawValue)"
        if let cached = traitCache[key] { return cached }
        let result = Fonts.with(font, trait: trait)
        traitCache[key] = result
        return result
    }

    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, to text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            text.addAttribute(.font, value: self.trait(trait, of: font), range: sub)
        }
    }

    private func resize(_ text: NSMutableAttributedString, in range: NSRange, by scale: CGFloat) {
        text.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            text.addAttribute(
                .font, value: NSFontManager.shared.convert(font, toSize: (font.pointSize * scale).rounded()), range: sub)
        }
    }

    /// The type of front matter: smaller than the note's code.
    private var smallMono: NSFont { mono(for: NSFontManager.shared.convert(fonts.body, toSize: (fonts.size * 0.9).rounded())) }

    private func mono(for font: NSFont) -> NSFont {
        let key = "mono|\(font.pointSize)"
        if let cached = traitCache[key] { return cached }
        let result = NSFont.monospacedSystemFont(ofSize: (font.pointSize * 0.9).rounded(), weight: .regular)
        traitCache[key] = result
        return result
    }

    /// The paragraph at `range` of `storage`, styled by `spans`, which are the
    /// document's spans for that range.
    func paragraph(from storage: NSTextStorage, range: NSRange, spans: [QuillSpan]) -> StyledParagraph {
        let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let full = NSRange(location: 0, length: text.length)
        text.addAttributes(base, range: full)
        let style = NSMutableParagraphStyle()
        var decoration = LineDecoration()
        var lineFont = isMarkdown ? fonts.body : fonts.mono
        var tight = !isMarkdown
        /// Baseline shifts on top of the line's own, for raised and lowered text.
        var shifts: [(NSRange, CGFloat)] = []
        /// The line without its line break.
        let content = (text.string as NSString).rangeOfCharacter(from: .newlines, options: .backwards).location == NSNotFound
            ? full : NSRange(location: 0, length: max(0, full.length - 1))

        func local(_ span: QuillSpan) -> NSRange? {
            let start = max(0, Int(span.start) - range.location)
            let end = min(full.length, Int(span.end) - range.location)
            return end >= start ? NSRange(location: start, length: end - start) : nil
        }

        // Block spans first: they set the line's font, which inline ones vary.
        for span in spans {
            guard let r = local(span) else { continue }
            switch span.kindValue {
            case QuillHeading:
                lineFont = fonts.heading(Int(span.level))
                text.addAttributes([.font: lineFont, .foregroundColor: theme.heading], range: full)
                if range.location > 0 { style.paragraphSpacingBefore = (fonts.size * 0.5).rounded() }
            case QuillCodeBlock, QuillFrontMatter:
                let isCode = span.kindValue == QuillCodeBlock
                lineFont = fonts.mono
                tight = true
                // Front matter's fences carry no flag: they are its first
                // and last lines.
                let isFence = isCode
                    ? span.flags & UInt16(QuillCodeFenceOpen | QuillCodeFenceClose) != 0
                    : span.start == span.elem_start || span.end == span.elem_end
                let revealed = isRevealed(span.element)
                // A fence keeps its line, as the block's padding, but shows
                // its text only while the selection is in the block.
                let fenceColor = isCode && !revealed ? NSColor.clear : theme.syntax
                if !isCode {
                    // Front matter is a small block of properties above the
                    // note, in smaller type, its fences folded to a sliver
                    // of padding until the selection is in it.
                    lineFont = smallMono
                    if isFence && !revealed { decoration.lineHeight = 5 }
                }
                text.addAttributes(
                    [.font: lineFont, .foregroundColor: isFence || !isCode ? fenceColor : theme.text], range: full)
                if !isCode && isFence && !revealed {
                    text.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: full)
                }
                decoration.block = isCode ? .code : .frontMatter
                decoration.blockFirst = span.start == span.elem_start
                decoration.blockLast = span.end == span.elem_end
                if isCode && decoration.blockFirst && isFence {
                    let info = (text.string as NSString).substring(with: r).trimmingCharacters(in: CharacterSet(charactersIn: "`~ "))
                    decoration.blockLabel = info.split(separator: " ").first.map { $0.uppercased() }
                }
                style.firstLineHeadIndent = Styler.blockPadding
                style.headIndent = Styler.blockPadding
                style.tailIndent = -Styler.blockPadding
            case QuillBlockQuote:
                decoration.quoteDepth = max(decoration.quoteDepth, Int(span.level))
                if span.flags != 0 {
                    decoration.callout = Int(span.flags)
                    decoration.calloutFirst = span.start == span.elem_start
                    decoration.calloutLast = span.end == span.elem_end
                } else if decoration.callout == 0 {
                    text.addAttribute(.foregroundColor, value: theme.secondary, range: full)
                }
            case QuillTable:
                lineFont = fonts.mono
                text.addAttribute(.font, value: lineFont, range: full)
                if span.flags & UInt16(QuillTableDelimiter) != 0 {
                    text.addAttribute(.foregroundColor, value: theme.syntax, range: full)
                }
            case QuillHTML:
                text.addAttributes([.font: mono(for: lineFont), .foregroundColor: theme.secondary], range: r)
            case QuillMathBlock:
                text.addAttributes([.font: mono(for: lineFont), .foregroundColor: theme.type], range: r)
            default: break
            }
        }
        if decoration.quoteDepth > 0 {
            let indent = CGFloat(decoration.quoteDepth) * Styler.quoteIndent + (decoration.callout != 0 ? 10 : 0)
            style.firstLineHeadIndent += indent
            style.headIndent += indent
            if decoration.callout != 0 {
                style.tailIndent = -Styler.blockPadding
                // The same room below the last line as above the first.
                if decoration.calloutFirst { style.paragraphSpacingBefore += 3 }
                if decoration.calloutLast { style.paragraphSpacing += 5 }
            }
        }

        var taskChecked: NSRange?
        for span in spans {
            guard let r = local(span), r.length > 0 else { continue }
            switch span.kindValue {
            case QuillEmphasis: addTrait(.italic, to: text, in: r)
            case QuillStrong: addTrait(.bold, to: text, in: r)
            case QuillStrike:
                text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: theme.secondary], range: r)
            case QuillCode:
                text.addAttributes(
                    [.font: mono(for: lineFont), .foregroundColor: theme.codeText, .backgroundColor: theme.codeBackground], range: r)
            case QuillLink, QuillWikiLink:
                text.addAttribute(.foregroundColor, value: theme.link, range: r)
                // Hovering tells where the link goes; ⌘-click takes it.
                let target = span.kindValue == QuillLink ? QuillLinkDest : QuillWikiTarget
                if let destination = spans.first(where: { $0.kindValue == target && $0.element == span.element }),
                    destination.range.upperBound <= storage.length, destination.range != span.range
                {
                    text.addAttribute(.toolTip, value: (storage.string as NSString).substring(with: destination.range), range: r)
                }
            case QuillImage:
                text.addAttribute(.foregroundColor, value: theme.secondary, range: r)
            case QuillFootnoteRef:
                text.addAttribute(.foregroundColor, value: theme.accent, range: r)
                resize(text, in: r, by: 0.75)
                shifts.append((r, lineFont.pointSize * 0.35))
            case QuillFootnoteDef:
                text.addAttribute(.foregroundColor, value: theme.accent, range: r)
            case QuillSuperscript:
                resize(text, in: r, by: 0.75)
                shifts.append((r, lineFont.pointSize * 0.35))
            case QuillSubscript:
                resize(text, in: r, by: 0.75)
                shifts.append((r, -lineFont.pointSize * 0.15))
            case QuillInlineMath:
                text.addAttributes([.font: mono(for: lineFont), .foregroundColor: theme.type], range: r)
            case QuillHighlight:
                text.addAttribute(.backgroundColor, value: theme.highlight, range: r)
            case QuillListMarker:
                let task = spans.first { $0.kindValue == QuillTaskMarker && $0.start >= span.end }
                let revealed = task.map { isRevealed(Styler.taskPrefix(of: span, task: $0)) } ?? isRevealed(span.element)
                if span.flags == 0 && isMarkdown && !revealed {
                    if task == nil {
                        // A bullet is drawn over the marker, which keeps its
                        // room so the line doesn't shift when the syntax shows.
                        text.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
                        decoration.bullets.append((r.location, Int(span.level)))
                    } else {
                        // A task's box stands in for its marker: the marker
                        // and the space after it go, so the box sits where a
                        // bullet would. The line shifts only when the
                        // selection reaches the prefix, which shows it.
                        let gap = NSRange(location: r.location, length: min(content.upperBound, r.upperBound + 1) - r.location)
                        text.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: gap)
                    }
                } else {
                    text.addAttribute(.foregroundColor, value: theme.accent, range: r)
                }
                // Wrapped lines of the item line up with its text.
                var prefixEnd = min(content.upperBound, r.upperBound + 1)
                if let task, let t = local(task) {
                    // The box is measured in the font it is drawn with.
                    text.addAttribute(.font, value: mono(for: lineFont), range: t)
                    prefixEnd = min(content.upperBound, t.upperBound + 1)
                }
                let prefix = text.attributedSubstring(from: NSRange(location: 0, length: prefixEnd))
                style.headIndent = style.firstLineHeadIndent + ceil(prefix.size().width)
            case QuillTaskMarker:
                let checked = span.flags != 0
                let marker = spans.first { $0.kindValue == QuillListMarker && $0.element == span.element && $0.end <= span.start }
                let revealed = marker.map { isRevealed(Styler.taskPrefix(of: $0, task: span)) } ?? isRevealed(span.element)
                if isMarkdown && !revealed {
                    // A box is drawn over the brackets, which keep their room.
                    text.addAttributes([.font: mono(for: lineFont), .foregroundColor: NSColor.clear], range: r)
                    decoration.checkboxes.append((r, checked))
                } else {
                    text.addAttributes([.font: mono(for: lineFont), .foregroundColor: checked ? theme.syntax : theme.accent], range: r)
                }
                if checked { taskChecked = NSRange(location: r.upperBound, length: max(0, content.upperBound - r.upperBound)) }
            case QuillTableCell:
                if span.flags & UInt16(QuillTableHeader << 4) != 0 { addTrait(.bold, to: text, in: r) }
            case QuillTokenKeyword: text.addAttribute(.foregroundColor, value: theme.keyword, range: r)
            case QuillTokenString: text.addAttribute(.foregroundColor, value: theme.string, range: r)
            case QuillTokenComment: text.addAttribute(.foregroundColor, value: theme.comment, range: r)
            case QuillTokenNumber: text.addAttribute(.foregroundColor, value: theme.number, range: r)
            case QuillTokenType: text.addAttribute(.foregroundColor, value: theme.type, range: r)
            case QuillTokenFunction: text.addAttribute(.foregroundColor, value: theme.function, range: r)
            case QuillTokenConstant: text.addAttribute(.foregroundColor, value: theme.constant, range: r)
            case QuillTokenProperty: text.addAttribute(.foregroundColor, value: theme.property, range: r)
            case QuillTokenPunctuation: text.addAttribute(.foregroundColor, value: theme.syntax, range: r)
            case QuillTokenInserted: text.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: r)
            case QuillTokenDeleted: text.addAttribute(.foregroundColor, value: NSColor.systemRed, range: r)
            default: break
            }
        }
        if let taskChecked, taskChecked.length > 0 {
            text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: theme.secondary], range: taskChecked)
        }

        // Syntax last, so that hiding it wins over what it sits in.
        var hidden: [NSRange] = []
        func hide(_ r: NSRange) {
            text.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: r)
            text.removeAttribute(.backgroundColor, range: r)
            text.removeAttribute(.strikethroughStyle, range: r)
            hidden.append(r)
        }
        for span in spans {
            guard let r = local(span), r.length > 0 else { continue }
            switch span.kindValue {
            case QuillMarker:
                if isRevealed(span.element) {
                    text.addAttribute(.foregroundColor, value: theme.syntax, range: r)
                } else {
                    hide(r)
                }
            case QuillCalloutTag:
                let after = NSRange(location: r.upperBound, length: max(0, content.upperBound - r.upperBound))
                let title = (text.string as NSString).substring(with: after).trimmingCharacters(in: .whitespaces)
                let color = theme.calloutColor(Int(span.flags))
                if after.length > 0 {
                    text.addAttribute(.foregroundColor, value: color, range: after)
                    addTrait(.bold, to: text, in: after)
                }
                if isRevealed(span.element) {
                    text.addAttribute(.foregroundColor, value: color, range: r)
                } else {
                    // The space after the tag goes with it.
                    let spaces = (text.string as NSString).substring(with: after).prefix { $0 == " " }.count
                    hide(NSRange(location: r.location, length: r.length + spaces))
                    decoration.calloutName = Styler.calloutNames[min(5, Int(span.flags))]
                    decoration.calloutHasTitle = !title.isEmpty
                }
            case QuillThematicBreak:
                if isRevealed(span.element) {
                    text.addAttribute(.foregroundColor, value: theme.syntax, range: r)
                } else {
                    hide(r)
                    decoration.drawsRule = true
                }
            default: break
            }
        }
        for span in spans {
            guard let r = local(span), r.length > 0 else { continue }
            switch span.kindValue {
            case QuillLinkDest, QuillImageDest:
                // Shown with its link's syntax, or on its own for a bare link.
                if !hidden.contains(where: { NSIntersectionRange($0, r).length > 0 }) && span.range != span.element {
                    text.addAttributes(
                        [.foregroundColor: theme.link.withAlphaComponent(0.7), .underlineStyle: NSUnderlineStyle.single.rawValue],
                        range: r)
                }
            default: break
            }
        }

        if let widgets, isMarkdown {
            widgets.applyWidgets(to: text, range: range, spans: spans, style: style, decoration: &decoration, styler: self, hide: hide)
        }

        decoration.fontSize = lineFont.pointSize
        let height = decoration.lineHeight ?? lineHeight(for: lineFont, tight: tight)
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        // A taller line puts its extra room above the text; this centers it.
        let lift = ((height - Styler.naturalHeight(of: lineFont)) / 2).rounded(.down)
        text.addAttributes([.paragraphStyle: style, .baselineOffset: lift], range: full)
        for (r, shift) in shifts {
            text.addAttribute(.baselineOffset, value: lift + shift, range: r)
        }
        let paragraph = StyledParagraph(attributedString: text)
        paragraph.decoration = decoration
        return paragraph
    }
}

/// Supplies the blocks drawn in place of their source: images, tables, math
/// and diagrams.
@MainActor
protocol WidgetSource: AnyObject {
    func applyWidgets(
        to text: NSMutableAttributedString, range: NSRange, spans: [QuillSpan], style: NSMutableParagraphStyle,
        decoration: inout LineDecoration, styler: Styler, hide: (NSRange) -> Void)
}

/// A block drawn by a line's fragment.
@MainActor
protocol Widget: AnyObject {
    /// Draws into `rect`, in a flipped context.
    func draw(in rect: CGRect, theme: Theme)
    /// The room the widget takes above the line's text.
    var height: CGFloat { get }
}
