import AppKit
import CQuillCore

/// An image drawn above its `![alt](src)` line.
final class ImageWidget: Widget {
    let image: NSImage
    let size: NSSize
    let corner: CGFloat
    var height: CGFloat { size.height }

    init(image: NSImage, size: NSSize, corner: CGFloat = 8) {
        self.image = image
        self.size = size
        self.corner = corner
    }

    func draw(in rect: CGRect, theme: Theme) {
        let frame = CGRect(x: rect.minX + 4, y: rect.minY, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        if corner > 0 { NSBezierPath(roundedRect: frame, xRadius: corner, yRadius: corner).addClip() }
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
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
    private static let padding = NSSize(width: 12, height: 7)
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
        theme.rule.setFill()
        var y = frame.minY
        for (r, row) in rows.enumerated() {
            var x = frame.minX
            for (i, cell) in row.enumerated() where i < widths.count {
                let box = CGRect(x: x + Self.padding.width, y: y + Self.padding.height, width: widths[i] - 2 * Self.padding.width, height: heights[r] - 2 * Self.padding.height)
                cell.text.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
                x += widths[i]
                if i < widths.count - 1 { CGRect(x: x, y: y, width: 1, height: heights[r]).fill() }
            }
            y += heights[r]
            if r < rows.count - 1 { CGRect(x: frame.minX, y: y, width: width, height: 1).fill() }
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
    private var images: [String: NSImage] = [:]
    /// Images being read, so each is asked for once.
    private var loading: Set<String> = []
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

    func applyWidgets(
        to text: NSMutableAttributedString, range: NSRange, spans: [QuillSpan], style: NSMutableParagraphStyle,
        decoration: inout LineDecoration, styler: Styler, hide: (NSRange) -> Void
    ) {
        guard let editor else { return }
        let whole = NSRange(location: 0, length: text.length)
        func local(_ r: NSRange) -> NSRange { NSIntersectionRange(NSRange(location: r.location - range.location, length: r.length), whole) }
        let lineEnd = (text.string as NSString).rangeOfCharacter(from: .newlines).location
        let content = NSRange(location: 0, length: lineEnd == NSNotFound ? whole.length : lineEnd)

        for span in spans {
            switch span.kindValue {
            case QuillImage where span.flags & 1 != 0:
                guard let destination = spans.first(where: { $0.kindValue == QuillImageDest && $0.element == span.element }) else { continue }
                let source = (editor.storage.string as NSString).substring(with: destination.range)
                guard let image = image(for: source, line: range) else { continue }
                let size = fit(image.size, width: editor.columnWidth - 2 * style.firstLineHeadIndent, height: 560)
                let widget = ImageWidget(image: image, size: size)
                decoration.widget = widget
                style.paragraphSpacingBefore += size.height + 6
                if !styler.isRevealed(span.element) {
                    hide(content)
                    decoration.lineHeight = 6
                }
                return
            case QuillTable:
                if styler.isRevealed(span.element) { return }
                hide(content)
                decoration.lineHeight = Self.closedLine
                guard span.start == span.elem_start else { return }
                let widget = table(span.element, width: editor.columnWidth, styler: styler)
                decoration.widget = widget
                style.paragraphSpacingBefore += widget.height + 4
                return
            case QuillMathBlock where span.flags & 1 != 0:
                rendered(.math, source: Self.mathSource(of: span.element, in: editor), span: span, line: range, content: content, style: style, decoration: &decoration, styler: styler, hide: hide)
                return
            case QuillCodeBlock where span.flags & UInt16(QuillCodeDiagram | QuillCodeMath) != 0:
                let kind: Renderer.Kind = span.flags & UInt16(QuillCodeDiagram) != 0 ? .mermaid : .math
                rendered(kind, source: Self.fenceSource(of: span.element, in: editor), span: span, line: range, content: content, style: style, decoration: &decoration, styler: styler, hide: hide)
                return
            case QuillInlineMath where !styler.isRevealed(span.element):
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
        _ kind: Renderer.Kind, source: String, span: QuillSpan, line: NSRange, content: NSRange, style: NSMutableParagraphStyle,
        decoration: inout LineDecoration, styler: Styler, hide: (NSRange) -> Void
    ) {
        let revealed = styler.isRevealed(span.element)
        if !revealed {
            hide(content)
            decoration.lineHeight = Self.closedLine
            decoration.block = .none
        }
        guard span.start == span.elem_start else { return }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let image = renderedImage(kind, source: source, element: span.element, styler: styler)
        else {
            if !revealed { decoration.lineHeight = nil }
            return
        }
        let width = (editor?.columnWidth ?? 600) - 8
        let scale = min(1, width / max(1, image.size.width))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        decoration.widget = ImageWidget(image: image, size: size, corner: 0)
        style.paragraphSpacingBefore += size.height + (revealed ? 10 : 6)
    }

    /// The image of math or a diagram in the editor's colors, or nil while it
    /// renders; the element is laid out again when it is ready.
    private func renderedImage(_ kind: Renderer.Kind, source: String, element: NSRange, styler: Styler) -> NSImage? {
        guard let editor else { return nil }
        let appearance = editor.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var color = NSColor.textColor
        appearance.performAsCurrentDrawingAppearance { color = styler.theme.text.usingColorSpace(.sRGB) ?? .textColor }
        let size = kind == .mermaid ? 14 : styler.fonts.size * (kind == .math ? 1.15 : 0.95)
        return Renderer.shared.image(kind, source: source, dark: dark, color: color, size: size, width: editor.columnWidth - 8) { [weak editor] _ in
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
        if let image = images[key] { return image }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        let done: @MainActor (NSImage?) -> Void = { [weak self] image in
            guard let self else { return }
            self.loading.remove(key)
            guard let image else { return }
            self.images[key] = image
            self.editor?.restyle(line)
        }
        if remote {
            guard let url = URL(string: key) else { return nil }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let data = data
                DispatchQueue.main.async { done(data.flatMap { NSImage(data: $0) }) }
            }.resume()
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let data = try? Data(contentsOf: URL(fileURLWithPath: key))
                DispatchQueue.main.async { done(data.flatMap { NSImage(data: $0) }) }
            }
        }
        return nil
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
        for span in editor.core.spans(in: string.paragraphRange(for: element)) where span.kindValue == QuillTableCell {
            let lineStart = string.lineRange(for: NSRange(location: Int(span.start), length: 0)).location
            if lineStart != line {
                if !row.isEmpty { rows.append(row) }
                row = []
                line = lineStart
            }
            let header = span.flags & UInt16(QuillTableHeader << 4) != 0
            let alignment: NSTextAlignment = switch Int(span.flags & 0xF) {
            case 2: .center
            case 3: .right
            default: .left
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            let cell = Self.inlineText(string.substring(with: span.range), font: header ? Fonts.with(body, trait: .bold) : body, styler: styler)
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
            (#"`([^`]+)`"#, { s, r in s.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular), .foregroundColor: theme.codeText], range: r) }),
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
