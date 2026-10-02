import AppKit
import CDeckleCore

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
    /// The depths whose quote starts or ends on this line, so the bar of a
    /// quote is one rule with rounded ends rather than a pill per line.
    var quoteFirst: Set<Int> = []
    var quoteLast: Set<Int> = []
    /// Rounded chips drawn behind inline code and highlights, with a little
    /// room around the text, in place of a square background attribute.
    var inlineBoxes: [(range: NSRange, color: NSColor, radius: CGFloat)] = []
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
    /// The width of a list level: markers sit in it, and the text after it.
    var markerStep: CGFloat = 0
    /// The size of the line's font, which the bullets and boxes scale with.
    var fontSize: CGFloat = 15
    /// Where the line's text sits in its line box: the height of its glyphs
    /// and the ascent, x-height and cap height of its font, so bullets and
    /// boxes center on the letters rather than on the line.
    var glyphHeight: CGFloat = 0
    var ascender: CGFloat = 0
    var xHeight: CGFloat = 0
    var capHeight: CGFloat = 0

    var isPlain: Bool {
        block == .none && quoteDepth == 0 && callout == 0 && !drawsRule && widget == nil && inlineImages.isEmpty
            && bullets.isEmpty && checkboxes.isEmpty && inlineBoxes.isEmpty
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
    /// The link under the pointer with ⌘ held, which is underlined.
    var hoveredLink: NSRange?
    var hidesMarkers = Settings.hidesMarkers
    /// Where images and other widgets of the document come from.
    weak var widgets: WidgetSource?

    /// Whether the document is mostly Japanese, which makes its lines of
    /// only Han characters Japanese too.
    var isJapaneseDocument = false

    private var base: [NSAttributedString.Key: Any] = [:]
    private var traitCache: [String: NSFont] = [:]
    private var heightCache: [String: CGFloat] = [:]
    /// Too small to see or to take room.
    private let hiddenFont = NSFont.systemFont(ofSize: 0.01)

    static let calloutNames = ["", "Note", "Tip", "Important", "Warning", "Caution"]
    static let calloutSymbols = ["", "info.circle", "lightbulb", "exclamationmark.bubble", "exclamationmark.triangle", "flame"]
    static let quoteIndent: CGFloat = 18
    static let blockPadding: CGFloat = 14

    /// The width of one level of a list at a font size: the marker's room,
    /// and each nested level steps in by it, so bullets, boxes and numbers
    /// line up and their text starts in one column.
    nonisolated static func markerStep(for size: CGFloat) -> CGFloat {
        (size * 1.5).rounded()
    }

    /// Where a bullet or box sits in its marker's room, from its start.
    nonisolated static let markerCenter: CGFloat = 0.42

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
        heightCache.removeAll()
        base = [.font: isMarkdown ? fonts.body : fonts.mono, .foregroundColor: theme.text]
    }

    /// The attributes of text as typed, before its spans are known.
    var typingAttributes: [NSAttributedString.Key: Any] { base }

    static func naturalHeight(of font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    /// The height of a line of `font` with the characters of `language`
    /// in it: the taller of the font and the font that draws them, which
    /// for PingFang and Hiragino is taller than most Latin fonts. Code keeps
    /// its own height, so a block's lines stay even.
    func naturalHeight(of font: NSFont, language: String?) -> CGFloat {
        let own = Styler.naturalHeight(of: font)
        guard let language, font.pointSize >= 1, !fonts.isMono(font) else { return own }
        let key = "\(font.fontName)|\(font.pointSize)|\(language)"
        if let cached = heightCache[key] { return cached }
        let cjk: CTFont = cjkFont(for: font, language: language) ?? CTFontCreateForStringWithLanguage(
            font, (language == "ja" ? "あ" : "永") as CFString, CFRange(location: 0, length: 1), language as CFString)
        let result = max(own, CTFontGetAscent(cjk) + CTFontGetDescent(cjk) + CTFontGetLeading(cjk))
        heightCache[key] = result
        return result
    }

    func lineHeight(for font: NSFont, language: String? = nil, tight: Bool = false, heading: Bool = false) -> CGFloat {
        // A heading that wraps keeps its lines close, as display type does.
        let multiple = heading ? min(Settings.lineHeight, 1.25) : tight ? min(Settings.lineHeight, 1.4) : Settings.lineHeight
        return (naturalHeight(of: font, language: language) * multiple).rounded(.up)
    }

    /// The language `text` is drawn in, by its kana and Han characters.
    func cjkLanguage(of text: String) -> String? {
        CJK.language(of: text, chinese: fonts.chineseScript, japaneseDocument: isJapaneseDocument)
    }

    /// The chosen face for the Chinese or Japanese of `language` in text
    /// set in `font`, or nil for the system's.
    private func cjkFont(for font: NSFont, language: String) -> NSFont? {
        let key = "cjk|\(font.fontName)|\(font.pointSize)|\(language)"
        if let cached = traitCache[key] { return cached }
        let result = fonts.cjkFont(for: font, language: language)
        if let result { traitCache[key] = result }
        return result
    }

    /// Tags `text` with its Chinese or Japanese, so its Han characters take
    /// that language's forms, and sets them in the chosen face. Runs last,
    /// once the fonts of bold, italic and headings are known.
    func localize(_ text: NSMutableAttributedString, language: String?) {
        guard let language else { return }
        let full = NSRange(location: 0, length: text.length)
        text.addAttribute(.languageIdentifier, value: language, range: full)
        guard fonts.cjkFamily(for: language) != nil else { return }
        let string = text.string as NSString
        for run in CJK.runs(in: string) {
            text.enumerateAttribute(.font, in: run) { value, sub, _ in
                guard let font = value as? NSFont, let cjk = self.cjkFont(for: font, language: language) else { return }
                text.addAttribute(.font, value: cjk, range: sub)
            }
        }
    }

    /// Whether the syntax of `element` shows: the selection touches it.
    func isRevealed(_ element: NSRange) -> Bool {
        !hidesMarkers || (selection.location <= element.upperBound && selection.upperBound >= element.location)
    }

    /// The part of a task's line whose syntax shows together: from the start
    /// of the item through its box. The marker's element is the whole line,
    /// but a task reveals only around its prefix, so editing the text never
    /// moves it; the start of the text, one past the box, is outside.
    static func taskPrefix(of marker: DeckleSpan, task: DeckleSpan) -> NSRange {
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
        let result = fonts.mono(ofSize: (font.pointSize * 0.9).rounded())
        traitCache[key] = result
        return result
    }

    /// The paragraph at `range` of `storage`, styled by `spans`, which are the
    /// document's spans for that range. `afterHeading` says the paragraph
    /// follows a heading: blank, it is a shorter line, so a heading sits
    /// closer to its text than to what came before.
    func paragraph(from storage: NSTextStorage, range: NSRange, spans: [DeckleSpan], afterHeading: Bool = false) -> StyledParagraph {
        let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let full = NSRange(location: 0, length: text.length)
        text.addAttributes(base, range: full)
        let style = NSMutableParagraphStyle()
        var decoration = LineDecoration()
        var lineFont = isMarkdown ? fonts.body : fonts.mono
        var tight = !isMarkdown
        var headingLevel = 0
        /// Baseline shifts on top of the line's own, for raised and lowered text.
        var shifts: [(NSRange, CGFloat)] = []
        /// The line without its line break.
        let content = (text.string as NSString).rangeOfCharacter(from: .newlines, options: .backwards).location == NSNotFound
            ? full : NSRange(location: 0, length: max(0, full.length - 1))

        func local(_ span: DeckleSpan) -> NSRange? {
            let start = max(0, Int(span.start) - range.location)
            let end = min(full.length, Int(span.end) - range.location)
            return end >= start ? NSRange(location: start, length: end - start) : nil
        }

        // Block spans first: they set the line's font, which inline ones vary.
        for span in spans {
            guard let r = local(span) else { continue }
            switch span.kindValue {
            case DeckleHeading:
                headingLevel = max(1, min(6, Int(span.level)))
                lineFont = fonts.heading(headingLevel)
                text.addAttributes([.font: lineFont, .foregroundColor: theme.heading], range: full)
                // More room above a bigger heading: it opens a larger part.
                if range.location > 0 {
                    style.paragraphSpacingBefore = (fonts.size * [1.0, 0.75, 0.55, 0.4, 0.3, 0.3][headingLevel - 1]).rounded()
                }
            case DeckleCodeBlock, DeckleFrontMatter:
                let isCode = span.kindValue == DeckleCodeBlock
                lineFont = fonts.mono
                tight = true
                // Front matter's fences carry no flag: they are its first
                // and last lines.
                let isFence = isCode
                    ? span.flags & UInt16(DeckleCodeFenceOpen | DeckleCodeFenceClose) != 0
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
            case DeckleBlockQuote:
                decoration.quoteDepth = max(decoration.quoteDepth, Int(span.level))
                if span.start == span.elem_start { decoration.quoteFirst.insert(Int(span.level)) }
                if span.end == span.elem_end { decoration.quoteLast.insert(Int(span.level)) }
                if span.flags != 0 {
                    decoration.callout = Int(span.flags)
                    decoration.calloutFirst = span.start == span.elem_start
                    decoration.calloutLast = span.end == span.elem_end
                } else if decoration.callout == 0 {
                    text.addAttribute(.foregroundColor, value: theme.secondary, range: full)
                }
            case DeckleTable:
                lineFont = fonts.mono
                text.addAttribute(.font, value: lineFont, range: full)
                if span.flags & UInt16(DeckleTableDelimiter) != 0 {
                    text.addAttribute(.foregroundColor, value: theme.syntax, range: full)
                }
            case DeckleHTML:
                text.addAttributes([.font: mono(for: lineFont), .foregroundColor: theme.secondary], range: r)
            case DeckleMathBlock:
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
            case DeckleEmphasis: addTrait(.italic, to: text, in: r)
            case DeckleStrong: addTrait(.bold, to: text, in: r)
            case DeckleStrike:
                text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: theme.secondary], range: r)
            case DeckleCode:
                text.addAttributes([.font: mono(for: lineFont), .foregroundColor: theme.codeText], range: r)
                decoration.inlineBoxes.append((r, theme.codeBackground, 4))
            case DeckleLink, DeckleWikiLink:
                text.addAttribute(.foregroundColor, value: theme.link, range: r)
                if span.range == hoveredLink {
                    text.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: theme.link], range: r)
                }
                // Hovering tells where the link goes; ⌘-click takes it.
                let target = span.kindValue == DeckleLink ? DeckleLinkDest : DeckleWikiTarget
                if let destination = spans.first(where: { $0.kindValue == target && $0.element == span.element }),
                    destination.range.upperBound <= storage.length, destination.range != span.range
                {
                    text.addAttribute(.toolTip, value: (storage.string as NSString).substring(with: destination.range), range: r)
                }
            case DeckleImage:
                text.addAttribute(.foregroundColor, value: theme.secondary, range: r)
            case DeckleFootnoteRef:
                text.addAttribute(.foregroundColor, value: theme.accent, range: r)
                resize(text, in: r, by: 0.75)
                shifts.append((r, lineFont.pointSize * 0.35))
                if span.range == hoveredLink {
                    text.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: theme.accent], range: r)
                }
            case DeckleFootnoteDef:
                // The label reads as the reference does: small and raised.
                text.addAttribute(.foregroundColor, value: theme.accent, range: r)
                resize(text, in: r, by: 0.75)
                shifts.append((r, lineFont.pointSize * 0.35))
            case DeckleSuperscript:
                resize(text, in: r, by: 0.75)
                shifts.append((r, lineFont.pointSize * 0.35))
            case DeckleSubscript:
                resize(text, in: r, by: 0.75)
                shifts.append((r, -lineFont.pointSize * 0.15))
            case DeckleInlineMath:
                text.addAttributes([.font: mono(for: lineFont), .foregroundColor: theme.type], range: r)
            case DeckleHighlight:
                decoration.inlineBoxes.append((r, theme.highlight, 3))
            case DeckleListMarker:
                let task = spans.first { $0.kindValue == DeckleTaskMarker && $0.start >= span.end }
                let revealed = task.map { isRevealed(Styler.taskPrefix(of: span, task: $0)) } ?? isRevealed(span.element)
                let level = max(1, Int(span.level))
                let step = Styler.markerStep(for: lineFont.pointSize)
                decoration.markerStep = step
                if span.flags == 0 && isMarkdown && !revealed {
                    if task == nil {
                        // A bullet is drawn in the marker's room; the marker
                        // keeps its place in the text, unseen.
                        text.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
                        decoration.bullets.append((r.location, level))
                    } else {
                        // A task's box stands in for its marker and brackets,
                        // which fold away. The line shifts only when the
                        // selection reaches the prefix, which shows it.
                        let gap = NSRange(location: r.location, length: min(content.upperBound, r.upperBound + 1) - r.location)
                        text.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: gap)
                    }
                } else {
                    text.addAttribute(.foregroundColor, value: theme.accent, range: r)
                }
                // Every level steps in by the same width: the indent before
                // the marker is stretched to it.
                if r.location > 0 {
                    let indent = text.attributedSubstring(from: NSRange(location: 0, length: r.location)).size().width
                    let target = CGFloat(level - 1) * step
                    if target > indent { text.addAttribute(.kern, value: target - indent, range: NSRange(location: r.location - 1, length: 1)) }
                }
                var prefixEnd = min(content.upperBound, r.upperBound + 1)
                if let task, let t = local(task) {
                    if isMarkdown && !revealed {
                        text.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: t)
                    } else {
                        text.addAttribute(.font, value: mono(for: lineFont), range: t)
                    }
                    prefixEnd = min(content.upperBound, t.upperBound + 1)
                }
                // The text starts at the end of the marker's room, whatever
                // the marker is: a bullet, a box or a number. Wrapped lines
                // line up with it.
                let prefix = text.attributedSubstring(from: NSRange(location: 0, length: prefixEnd))
                let natural = ceil(prefix.size().width)
                let target = CGFloat(level) * step
                if prefixEnd > 0 && target > natural {
                    text.addAttribute(.kern, value: target - natural, range: NSRange(location: prefixEnd - 1, length: 1))
                }
                style.headIndent = style.firstLineHeadIndent + max(natural, target)
            case DeckleTaskMarker:
                let checked = span.flags != 0
                let marker = spans.first { $0.kindValue == DeckleListMarker && $0.element == span.element && $0.end <= span.start }
                let revealed = marker.map { isRevealed(Styler.taskPrefix(of: $0, task: span)) } ?? isRevealed(span.element)
                if isMarkdown && !revealed {
                    // A box is drawn in the marker's room; the brackets fold.
                    text.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: r)
                    decoration.checkboxes.append((r, checked))
                } else {
                    text.addAttributes([.font: mono(for: lineFont), .foregroundColor: checked ? theme.syntax : theme.accent], range: r)
                }
                // The text after the box and the space that holds its room.
                if checked {
                    let from = min(content.upperBound, r.upperBound + 1)
                    taskChecked = NSRange(location: from, length: max(0, content.upperBound - from))
                }
            case DeckleTableCell:
                if span.flags & UInt16(DeckleTableHeader << 4) != 0 { addTrait(.bold, to: text, in: r) }
            case DeckleTokenKeyword: text.addAttribute(.foregroundColor, value: theme.keyword, range: r)
            case DeckleTokenString: text.addAttribute(.foregroundColor, value: theme.string, range: r)
            case DeckleTokenComment: text.addAttribute(.foregroundColor, value: theme.comment, range: r)
            case DeckleTokenNumber: text.addAttribute(.foregroundColor, value: theme.number, range: r)
            case DeckleTokenType: text.addAttribute(.foregroundColor, value: theme.type, range: r)
            case DeckleTokenFunction: text.addAttribute(.foregroundColor, value: theme.function, range: r)
            case DeckleTokenConstant: text.addAttribute(.foregroundColor, value: theme.constant, range: r)
            case DeckleTokenProperty: text.addAttribute(.foregroundColor, value: theme.property, range: r)
            case DeckleTokenPunctuation: text.addAttribute(.foregroundColor, value: theme.syntax, range: r)
            case DeckleTokenInserted: text.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: r)
            case DeckleTokenDeleted: text.addAttribute(.foregroundColor, value: NSColor.systemRed, range: r)
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
            case DeckleMarker:
                if isRevealed(span.element) {
                    text.addAttribute(.foregroundColor, value: theme.syntax, range: r)
                } else {
                    hide(r)
                }
            case DeckleCalloutTag:
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
            case DeckleThematicBreak:
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
            case DeckleLinkDest, DeckleImageDest:
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

        let language = cjkLanguage(of: text.string)
        localize(text, language: language)
        if afterHeading && (text.string as NSString).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            decoration.lineHeight = (lineHeight(for: lineFont, language: nil) * 0.6).rounded()
        }
        decoration.fontSize = lineFont.pointSize
        decoration.ascender = lineFont.ascender
        decoration.xHeight = lineFont.xHeight
        decoration.capHeight = lineFont.capHeight
        let natural = naturalHeight(of: lineFont, language: language)
        decoration.glyphHeight = natural - lineFont.leading
        let height = decoration.lineHeight ?? lineHeight(for: lineFont, language: language, tight: tight, heading: headingLevel > 0)
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        // A taller line puts its extra room above the text; this centers it.
        let lift = ((height - natural) / 2).rounded(.down)
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
        to text: NSMutableAttributedString, range: NSRange, spans: [DeckleSpan], style: NSMutableParagraphStyle,
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
