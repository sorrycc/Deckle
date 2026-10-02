import AppKit
import CDeckleCore
import ImageIO

/// An image drawn above its `![alt](src)` line.
final class ImageWidget: Widget {
    let image: NSImage
    let size: NSSize
    let corner: CGFloat
    /// In the middle of the column, as display math is set.
    let centered: Bool
    var height: CGFloat { size.height }

    init(image: NSImage, size: NSSize, corner: CGFloat = 8, centered: Bool = false) {
        self.image = image
        self.size = size
        self.corner = corner
        self.centered = centered
    }

    func draw(in rect: CGRect, theme: Theme) {
        let x = centered ? rect.minX + ((rect.width - size.width) / 2).rounded() : rect.minX + 4
        let frame = CGRect(x: x, y: rect.minY, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        if corner > 0 { NSBezierPath(roundedRect: frame, xRadius: corner, yRadius: corner).addClip() }
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The room an image will take while it is decoded: a quiet plate of the
/// same size, so the page doesn't jump when the picture arrives.
final class PlaceholderWidget: Widget {
    let size: NSSize
    var height: CGFloat { size.height }

    init(size: NSSize) {
        self.size = size
    }

    func draw(in rect: CGRect, theme: Theme) {
        let frame = CGRect(x: rect.minX + 4, y: rect.minY, width: size.width, height: size.height)
        theme.codeBackground.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
    }
}

/// A Markdown table drawn as a grid.
final class TableWidget: Widget {
    struct Cell {
        let text: NSAttributedString
        let alignment: NSTextAlignment
    }

    private let rows: [[Cell]]
    private let widths: [CGFloat]
    private let heights: [CGFloat]
    private static let padding = NSSize(width: 13, height: 8)
    var height: CGFloat { heights.reduce(0, +) + 1 }

    init(rows: [[Cell]], maxWidth: CGFloat) {
        self.rows = rows
        let columns = rows.map(\.count).max() ?? 0
        var natural = Array(repeating: CGFloat(40), count: columns)
        for row in rows {
            for (i, cell) in row.enumerated() {
                natural[i] = max(natural[i], ceil(cell.text.size().width) + 2 * Self.padding.width)
            }
        }
        // Too wide for the column: every column gives up room in proportion.
        let total = natural.reduce(0, +)
        let scale = total > maxWidth ? maxWidth / total : 1
        widths = natural.map { ($0 * scale).rounded(.down) }
        let widths = widths
        heights = rows.map { row in
            row.enumerated().map { i, cell in
                let width = max(10, widths[i] - 2 * Self.padding.width)
                return ceil(cell.text.boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
                    + 2 * Self.padding.height
            }.max() ?? 24
        }
    }

    func draw(in rect: CGRect, theme: Theme) {
        let width = widths.reduce(0, +)
        let frame = CGRect(x: rect.minX + 0.5, y: rect.minY + 0.5, width: width, height: height - 1)
        let outline = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        if let first = heights.first {
            theme.codeBackground.setFill()
            CGRect(x: frame.minX, y: frame.minY, width: width, height: first).fill()
        }
        // Hairlines between cells, so the grid stays lighter than the text;
        // the rule under the header is a full line.
        let hairline = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
        var y = frame.minY
        for (r, row) in rows.enumerated() {
            var x = frame.minX
            for (i, cell) in row.enumerated() where i < widths.count {
                // A column narrower than its padding still wraps, not overlaps.
                let box = CGRect(x: x + Self.padding.width, y: y + Self.padding.height, width: max(1, widths[i] - 2 * Self.padding.width), height: heights[r] - 2 * Self.padding.height)
                cell.text.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
                x += widths[i]
                if i < widths.count - 1 {
                    theme.rule.withAlphaComponent(theme.rule.alphaComponent * 0.6).setFill()
                    CGRect(x: x - hairline / 2, y: y, width: hairline, height: heights[r]).fill()
                }
            }
            y += heights[r]
            if r < rows.count - 1 {
                theme.rule.setFill()
                CGRect(x: frame.minX, y: r == 0 ? y - 0.5 : y - hairline / 2, width: width, height: r == 0 ? 1 : hairline).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        theme.rule.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}

/// The blocks an editor draws in place of their source: images and tables
/// here, math and diagrams through the renderer.
@MainActor
final class WidgetStore: WidgetSource {
    private weak var editor: EditorView?
    /// Images decoded at the size they are drawn, up to a budget of pixels.
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()
    /// Images being read, so each is asked for once.
    private var loading: Set<String> = []
    private static let decodeQueue = DispatchQueue(label: "dev.sorrycc.deckle.images", qos: .userInitiated, attributes: .concurrent)
    /// The sizes of local images, read from their headers, for the room an
    /// image takes before it is decoded.
    private var imageSizes: [String: NSSize] = [:]
    /// The last image drawn for each piece of math or diagram, shown while a
    /// new one, for another width or theme, renders.
    private var lastRendered: [String: NSImage] = [:]
    private var tables: [String: TableWidget] = [:]
    private var rendered: [String: NSImage] = [:]
    private var rendering: Set<String> = []
    /// A line whose text is hidden all but closes; this is its height.
    static let closedLine: CGFloat = 0.01

    init(editor: EditorView) {
        self.editor = editor
    }

    /// Forgets what was drawn, after a change of theme or width.
    func invalidate() {
        tables.removeAll()
        rendered.removeAll()
    }

    /// Drops the tables only: their cells' text, unlike drawn math and
    /// diagrams, takes the forms of the note's language.
    func invalidateTables() {
        tables.removeAll()
    }

    func applyWidgets(
        to text: NSMutableAttributedString, range: NSRange, spans: [DeckleSpan], style: NSMutableParagraphStyle,
        decoration: inout LineDecoration, styler: Styler, hide: (NSRange) -> Void
    ) {
        guard let editor else { return }
        decoration.widgetWidth = editor.columnWidth
        let whole = NSRange(location: 0, length: text.length)
        func local(_ r: NSRange) -> NSRange { NSIntersectionRange(NSRange(location: r.location - range.location, length: r.length), whole) }
        let lineEnd = (text.string as NSString).rangeOfCharacter(from: .newlines).location
        let content = NSRange(location: 0, length: lineEnd == NSNotFound ? whole.length : lineEnd)

        for span in spans {
            switch span.kindValue {
            case DeckleImage where span.flags & 1 != 0:
                guard let destination = spans.first(where: { $0.kindValue == DeckleImageDest && $0.element == span.element }) else { continue }
                let source = (editor.storage.string as NSString).substring(with: destination.range)
                let widget: Widget
                let available = editor.columnWidth - 2 * style.firstLineHeadIndent
                if let image = image(for: source, line: range) {
                    widget = ImageWidget(image: image, size: fit(image.size, width: available, height: 560))
                } else if let natural = imageSize(for: source) {
                    // Not decoded yet: the room it will take, held for it.
                    widget = PlaceholderWidget(size: fit(natural, width: available, height: 560))
                } else {
                    continue
                }
                decoration.widget = widget
                style.paragraphSpacingBefore += widget.height + 6
                if !styler.isRevealed(span.element) {
                    hide(content)
                    decoration.lineHeight = 6
                }
                return
            case DeckleTable:
                if styler.isRevealed(span.element) { return }
                hide(content)
                decoration.lineHeight = Self.closedLine
                guard span.start == span.elem_start else { return }
                let widget = table(span.element, width: editor.columnWidth, styler: styler)
                decoration.widget = widget
                style.paragraphSpacingBefore += widget.height + 4
                return
            case DeckleMathBlock where span.flags & 1 != 0:
                rendered(.math, source: Self.mathSource(of: span.element, in: editor), span: span, line: range, content: content, style: style, decoration: &decoration, styler: styler, hide: hide)
                return
            case DeckleCodeBlock where span.flags & UInt16(DeckleCodeDiagram | DeckleCodeMath) != 0:
                let kind: Renderer.Kind = span.flags & UInt16(DeckleCodeDiagram) != 0 ? .mermaid : .math
                rendered(kind, source: Self.fenceSource(of: span.element, in: editor), span: span, line: range, content: content, style: style, decoration: &decoration, styler: styler, hide: hide)
                return
            case DeckleInlineMath where !styler.isRevealed(span.element):
                let r = local(span.range)
                guard r.length > 2 else { continue }
                let source = (editor.storage.string as NSString).substring(with: NSRange(location: span.range.location + 1, length: span.range.length - 2))
                guard let image = renderedImage(.inline, source: source, element: span.element, styler: styler) else { continue }
                // Shown no taller than the line, the text's size at most.
                let scale = min(1, styler.fonts.size * 1.7 / max(1, image.size.height))
                let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
                hide(r)
                // The room goes after the first character, where the image is
                // drawn, so a line break can't come between them.
                text.addAttribute(.kern, value: size.width, range: NSRange(location: r.location, length: 1))
                decoration.inlineImages.append((r.location, image, size))
            default:
                break
            }
        }
    }

    // MARK: Math and diagrams

    /// A block of math or a diagram: drawn in place of its source, or above
    /// it while the selection is in it.
    private func rendered(
        _ kind: Renderer.Kind, source: String, span: DeckleSpan, line: NSRange, content: NSRange, style: NSMutableParagraphStyle,
        decoration: inout LineDecoration, styler: Styler, hide: (NSRange) -> Void
    ) {
        let revealed = styler.isRevealed(span.element)
        if !revealed {
            hide(content)
            decoration.lineHeight = Self.closedLine
            decoration.block = .none
        }
        guard span.start == span.elem_start else { return }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !revealed { decoration.lineHeight = nil }
            return
        }
        // While a new rendering is on its way, the last one stands in, so
        // a change of theme or width doesn't blank the block.
        let key = "\(kind.rawValue)|\(source)"
        let image: NSImage?
        if let fresh = renderedImage(kind, source: source, element: span.element, styler: styler) {
            lastRendered[key] = fresh
            image = fresh
        } else {
            image = lastRendered[key]
        }
        guard let image else {
            if !revealed { decoration.lineHeight = nil }
            return
        }
        let width = (editor?.columnWidth ?? 600) - 8
        let scale = min(1, width / max(1, image.size.width))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        // Math is set in the middle of the column; a diagram starts at the
        // text's edge, as the blocks around it do.
        decoration.widget = ImageWidget(image: image, size: size, corner: 0, centered: kind == .math)
        style.paragraphSpacingBefore += size.height + (revealed ? 10 : 6)
    }

    /// The image of math or a diagram in the editor's colors, or nil while it
    /// renders; the element is laid out again when it is ready.
    private func renderedImage(_ kind: Renderer.Kind, source: String, element: NSRange, styler: Styler) -> NSImage? {
        guard let editor else { return nil }
        let appearance = editor.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var color = NSColor.textColor
        var background = NSColor.textBackgroundColor
        var accent = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance {
            color = styler.theme.text.usingColorSpace(.sRGB) ?? .textColor
            background = styler.theme.background.usingColorSpace(.sRGB) ?? .textBackgroundColor
            accent = styler.theme.accent.usingColorSpace(.sRGB) ?? .controlAccentColor
        }
        // A diagram's labels a little under the text, as a code block's are.
        let size = kind == .mermaid ? (styler.fonts.size * 0.9).rounded() : styler.fonts.size * (kind == .math ? 1.15 : 0.95)
        return Renderer.shared.image(
            kind, source: source, dark: dark, color: color, background: background, accent: accent, size: size,
            width: editor.columnWidth - 8, owner: "\(ObjectIdentifier(editor).hashValue)|\(element.location)|\(kind.rawValue)"
        ) { [weak editor] _ in
            editor?.restyle(element)
        }
    }

    /// The math between a block's `$$` marks.
    static func mathSource(of element: NSRange, in editor: EditorView) -> String {
        var text = (editor.storage.string as NSString).substring(with: element).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("$$") { text.removeFirst(2) }
        if text.hasSuffix("$$") { text.removeLast(2) }
        return text
    }

    /// The lines between a code block's fences.
    static func fenceSource(of element: NSRange, in editor: EditorView) -> String {
        var lines = (editor.storage.string as NSString).substring(with: element).components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }
        if let last = lines.last?.trimmingCharacters(in: .whitespaces), last.hasPrefix("```") || last.hasPrefix("~~~") { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Images

    /// The image at a path relative to the note, or a web address. Nil while
    /// it loads; the line is laid out again when it arrives.
    private func image(for source: String, line: NSRange) -> NSImage? {
        guard let editor else { return nil }
        let key: String
        let remote = source.hasPrefix("http://") || source.hasPrefix("https://")
        if remote {
            key = source
        } else {
            let path = source.removingPercentEncoding ?? source
            key = URL(fileURLWithPath: path, relativeTo: editor.url.deletingLastPathComponent()).standardizedFileURL.path
        }
        if let image = Self.images.object(forKey: key as NSString) { return image }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        let done: @MainActor (NSImage?) -> Void = { [weak self] image in
            guard let self else { return }
            self.loading.remove(key)
            guard let image else { return }
            Self.images.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height) * 4)
            self.editor?.restyle(line)
        }
        if remote {
            guard let url = URL(string: key) else { return nil }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let image = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap(Self.decoded)
                DispatchQueue.main.async { done(image) }
            }.resume()
        } else {
            Self.decodeQueue.async {
                let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: key) as CFURL, nil).flatMap(Self.decoded)
                DispatchQueue.main.async { done(image) }
            }
        }
        return nil
    }

    /// Decodes an image no larger than it is ever drawn, off the main
    /// thread, keeping its size in points so the column fits it as before.
    private nonisolated static let maxPixels = 2400

    private nonisolated static func decoded(_ source: CGImageSource) -> NSImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // An oriented image swaps its sides; the thumbnail's own ratio holds.
        let longer = max(width, height)
        let scale = longer > 0 ? min(1, Double(maxPixels) / longer) : 1
        let size = NSSize(width: Double(cgImage.width) / scale, height: Double(cgImage.height) / scale)
        return NSImage(cgImage: cgImage, size: size)
    }

    /// The size of a local image from its header alone, which costs no
    /// decoding; nil for one that can't be read or isn't local.
    private func imageSize(for source: String) -> NSSize? {
        guard let editor, !source.hasPrefix("http://"), !source.hasPrefix("https://") else { return nil }
        let path = source.removingPercentEncoding ?? source
        let key = URL(fileURLWithPath: path, relativeTo: editor.url.deletingLastPathComponent()).standardizedFileURL.path
        if let size = imageSizes[key] { return size.width > 0 ? size : nil }
        var size = NSSize.zero
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: key) as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            size = orientation >= 5 ? NSSize(width: height, height: width) : NSSize(width: width, height: height)
        }
        imageSizes[key] = size
        return size.width > 0 ? size : nil
    }

    private func fit(_ size: NSSize, width: CGFloat, height: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: 1, height: 1) }
        let scale = min(1, width / size.width, height / size.height)
        return NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    // MARK: Tables

    private func table(_ element: NSRange, width: CGFloat, styler: Styler) -> TableWidget {
        guard let editor else { return TableWidget(rows: [], maxWidth: width) }
        let string = editor.storage.string as NSString
        let source = string.substring(with: element)
        let key = "\(source)|\(width)"
        if let cached = tables[key] { return cached }
        var rows: [[TableWidget.Cell]] = []
        var row: [TableWidget.Cell] = []
        var line = -1
        let body = styler.fonts.body
        for span in editor.core.spans(in: string.paragraphRange(for: element)) where span.kindValue == DeckleTableCell {
            let lineStart = string.lineRange(for: NSRange(location: Int(span.start), length: 0)).location
            if lineStart != line {
                if !row.isEmpty { rows.append(row) }
                row = []
                line = lineStart
            }
            let header = span.flags & UInt16(DeckleTableHeader << 4) != 0
            let alignment: NSTextAlignment = switch Int(span.flags & 0xF) {
            case 2: .center
            case 3: .right
            default: .left
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            let source = string.substring(with: span.range)
            let cell = Self.inlineText(source, font: header ? Fonts.with(body, trait: .bold) : body, styler: styler)
            styler.localize(cell, language: styler.cjkLanguage(of: source))
            cell.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length))
            row.append(TableWidget.Cell(text: cell, alignment: alignment))
        }
        if !row.isEmpty { rows.append(row) }
        let widget = TableWidget(rows: rows, maxWidth: width)
        tables[key] = widget
        return widget
    }

    /// The text of a cell with its inline syntax taken out and its style kept:
    /// bold, italic, code and links.
    static func inlineText(_ source: String, font: NSFont, styler: Styler) -> NSMutableAttributedString {
        let theme = styler.theme
        let result = NSMutableAttributedString(string: source, attributes: [.font: font, .foregroundColor: theme.text])
        let rules: [(String, (NSMutableAttributedString, NSRange) -> Void)] = [
            (#"\*\*(.+?)\*\*|__(.+?)__"#, { s, r in s.addAttribute(.font, value: Fonts.with(font, trait: .bold), range: r) }),
            (#"(?<![*\w])\*(?!\*)(.+?)\*|(?<!\w)_(.+?)_"#, { s, r in s.addAttribute(.font, value: Fonts.with(font, trait: .italic), range: r) }),
            (#"`([^`]+)`"#, { s, r in s.addAttributes([.font: styler.fonts.mono(ofSize: font.pointSize * 0.9), .foregroundColor: theme.codeText], range: r) }),
            (#"~~(.+?)~~"#, { s, r in s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r) }),
            (#"\[\[(?:[^\]|]*\|)?([^\]]+)\]\]"#, { s, r in s.addAttribute(.foregroundColor, value: theme.link, range: r) }),
            (#"\[([^\]]+)\]\([^)]*\)"#, { s, r in s.addAttribute(.foregroundColor, value: theme.link, range: r) }),
        ]
        for (pattern, apply) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            // From the end, so earlier ranges hold as the syntax comes out.
            for match in regex.matches(in: result.string, range: NSRange(location: 0, length: result.length)).reversed() {
                let group = (1..<match.numberOfRanges).map { match.range(at: $0) }.first { $0.location != NSNotFound } ?? match.range
                let inner = result.attributedSubstring(from: group).mutableCopy() as! NSMutableAttributedString
                apply(inner, NSRange(location: 0, length: inner.length))
                result.replaceCharacters(in: match.range, with: inner)
            }
        }
        return result
    }
}
