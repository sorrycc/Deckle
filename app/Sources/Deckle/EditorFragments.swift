import AppKit

/// A line's layout fragment, which draws what the line's text alone can't
/// show: the background of a code block, the bar of a quote, a rule, and
/// blocks such as images in place of their source.
final class DecoratedFragment: NSTextLayoutFragment {
    var decoration = LineDecoration()
    var theme = Theme.system
    /// The view drawn into, for its light or dark appearance.
    weak var host: NSView?

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// The fragment's frame widened to the text container, in its own
    /// coordinates: backgrounds span the column, not the line's text.
    private var band: CGRect {
        let frame = layoutFragmentFrame
        return CGRect(x: -frame.minX, y: 0, width: containerWidth, height: frame.height)
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(band.insetBy(dx: -2, dy: -1))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if !decoration.isPlain {
            // Text is laid out and drawn on the main thread.
            nonisolated(unsafe) let fragment = self
            nonisolated(unsafe) let context = context
            MainActor.assumeIsolated { fragment.drawDecoration(at: point, in: context) }
        }
        super.draw(at: point, in: context)
    }

    @MainActor
    private func drawDecoration(at point: CGPoint, in context: CGContext) {
        let area = band.offsetBy(dx: point.x, dy: point.y)
        let draw = {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            self.drawDecoration(in: area)
            NSGraphicsContext.restoreGraphicsState()
        }
        if let host { host.effectiveAppearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
    }

    /// The icons of callouts, drawn once each as bitmaps: a symbol drawn
    /// straight into a page or a PDF comes out as a block.
    nonisolated(unsafe) private static var icons: [String: NSImage] = [:]

    @MainActor
    private static func calloutIcon(_ symbol: String, color: NSColor, name: String) -> NSImage? {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let key = "\(symbol)|\(rgb.redComponent)|\(rgb.greenComponent)|\(rgb.blueComponent)"
        if let cached = icons[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [rgb]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?.withSymbolConfiguration(config) else { return nil }
        let size = image.size
        let bitmap = NSImage(size: size)
        bitmap.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        bitmap.unlockFocus()
        icons[key] = bitmap
        return bitmap
    }

    /// A rectangle rounded at the top, the bottom, both or neither.
    private func path(_ rect: CGRect, radius: CGFloat, top: Bool, bottom: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        // A folded line, such as a hidden fence, is shorter than a corner.
        let radius = max(0, min(radius, top && bottom ? rect.height / 2 : rect.height))
        let (minX, maxX, minY, maxY) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        let t = top ? radius : 0
        let b = bottom ? radius : 0
        path.move(to: NSPoint(x: minX + t, y: minY))
        path.line(to: NSPoint(x: maxX - t, y: minY))
        if top { path.appendArc(withCenter: NSPoint(x: maxX - t, y: minY + t), radius: t, startAngle: 270, endAngle: 0) }
        path.line(to: NSPoint(x: maxX, y: maxY - b))
        if bottom { path.appendArc(withCenter: NSPoint(x: maxX - b, y: maxY - b), radius: b, startAngle: 0, endAngle: 90) }
        path.line(to: NSPoint(x: minX + b, y: maxY))
        if bottom { path.appendArc(withCenter: NSPoint(x: minX + b, y: maxY - b), radius: b, startAngle: 90, endAngle: 180) }
        path.line(to: NSPoint(x: minX, y: minY + t))
        if top { path.appendArc(withCenter: NSPoint(x: minX + t, y: minY + t), radius: t, startAngle: 180, endAngle: 270) }
        path.close()
        return path
    }

    @MainActor
    private func drawDecoration(in area: CGRect) {
        let d = decoration
        // On whole pixels, so the lines of one block meet without a seam.
        // Both edges round the same way: neighbours share an edge, never a row.
        let top = (area.minY * 2).rounded() / 2
        let block = CGRect(x: area.minX, y: top, width: area.width, height: (area.maxY * 2).rounded() / 2 - top)
        if d.block != .none {
            theme.codeBackground.setFill()
            path(block, radius: 8, top: d.blockFirst, bottom: d.blockLast).fill()
            if let label = d.blockLabel, !label.isEmpty {
                let text = NSAttributedString(string: label, attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: theme.syntax, .kern: 0.6,
                ])
                let size = text.size()
                text.draw(at: NSPoint(x: area.maxX - size.width - 12, y: area.minY + (area.height - size.height) / 2))
            }
        }
        if d.callout != 0 {
            let color = theme.calloutColor(d.callout)
            let inset = CGFloat(d.quoteDepth - 1) * Styler.quoteIndent
            let rect = CGRect(x: block.minX + inset, y: block.minY, width: block.width - inset, height: block.height)
            color.withAlphaComponent(0.1).setFill()
            path(rect, radius: 8, top: d.calloutFirst, bottom: d.calloutLast).fill()
            if let name = d.calloutName {
                // On the first line of text, which the padding above sits over.
                let midY = area.minY + (textLineFragments.first?.typographicBounds.midY ?? area.height / 2)
                if let image = Self.calloutIcon(Styler.calloutSymbols[min(5, d.callout)], color: color, name: name) {
                    let size = image.size
                    image.draw(in: NSRect(x: rect.minX + 10, y: midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                if !d.calloutHasTitle {
                    let text = NSAttributedString(string: name, attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold), .foregroundColor: color,
                    ])
                    let size = text.size()
                    text.draw(at: NSPoint(x: rect.minX + 33, y: midY - size.height / 2))
                }
            }
        } else if d.quoteDepth > 0 {
            theme.quoteBar.setFill()
            for depth in 0..<d.quoteDepth {
                // One bar down the whole quote: rounded only at its ends.
                let level = depth + 1
                let rect = CGRect(x: block.minX + 5 + CGFloat(depth) * Styler.quoteIndent, y: block.minY, width: 3, height: block.height)
                path(rect, radius: 1.5, top: d.quoteFirst.contains(level), bottom: d.quoteLast.contains(level)).fill()
            }
        }
        for box in d.inlineBoxes {
            drawInlineBox(box.range, color: box.color, radius: box.radius, in: area)
        }
        if d.drawsRule {
            theme.rule.setFill()
            CGRect(x: area.minX, y: area.midY.rounded() - 0.5, width: area.width, height: 1).fill()
        }
        if let widget = d.widget {
            widget.draw(in: CGRect(x: area.minX, y: area.minY, width: area.width, height: widget.height), theme: theme)
        }
        for item in d.inlineImages {
            // The character's place in its line, which the kerning after it
            // left room beside.
            guard let line = textLineFragments.first(where: { $0.characterRange.contains(item.index) }) else { continue }
            let origin = line.locationForCharacter(at: item.index)
            let bounds = line.typographicBounds
            let x = area.minX + layoutFragmentFrame.minX + bounds.minX + origin.x
            let y = area.minY + bounds.midY - item.size.height / 2
            item.image.draw(in: CGRect(x: x, y: y, width: item.size.width, height: item.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        for bullet in d.bullets {
            guard var center = markerCenter(at: bullet.index, in: area) else { continue }
            // On the middle of the lowercase letters, where a bullet reads
            // as part of the text, not of the line box.
            center.y = baseline(of: center.y) - d.xHeight / 2
            drawBullet(at: center, level: bullet.level, size: d.fontSize)
        }
        for box in d.checkboxes {
            guard var center = markerCenter(at: box.range.location, in: area) else { continue }
            center.y = baseline(of: center.y) - d.capHeight / 2
            drawCheckbox(at: center, checked: box.checked, size: d.fontSize)
        }
    }

    /// The middle of the room of a list marker starting at `index`, in the
    /// drawing's coordinates: a fixed way into its level's step, so bullets
    /// and boxes line up whatever the marker's own characters.
    private func markerCenter(at index: Int, in area: CGRect) -> CGPoint? {
        guard let line = textLineFragments.first(where: { $0.characterRange.contains(index) }) else { return nil }
        let bounds = line.typographicBounds
        let start = line.locationForCharacter(at: index).x
        let step = decoration.markerStep > 0 ? decoration.markerStep : Styler.markerStep(for: decoration.fontSize)
        return CGPoint(x: area.minX + layoutFragmentFrame.minX + bounds.minX + start + step * Styler.markerCenter, y: area.minY + bounds.midY)
    }

    /// The baseline of a line whose middle is at `midY`: its glyphs are
    /// centered in the line, and the ascent runs from their top.
    private func baseline(of midY: CGFloat) -> CGFloat {
        let d = decoration
        guard d.glyphHeight > 0 else { return midY }
        return (midY - d.glyphHeight / 2 + d.ascender).rounded()
    }

    /// A rounded chip behind the characters at `range`, split where the
    /// text wraps, a little wider than the text on each side.
    private func drawInlineBox(_ range: NSRange, color: NSColor, radius: CGFloat, in area: CGRect) {
        let d = decoration
        color.setFill()
        for line in textLineFragments {
            let sub = NSIntersectionRange(line.characterRange, range)
            guard sub.length > 0 else { continue }
            let bounds = line.typographicBounds
            let start = line.locationForCharacter(at: sub.location).x
            let end = line.locationForCharacter(at: sub.upperBound).x
            guard end > start else { continue }
            let x = area.minX + layoutFragmentFrame.minX + bounds.minX
            let height = max(d.glyphHeight, d.fontSize) + 1
            let rect = CGRect(
                x: (x + start - 2.5).rounded(), y: (area.minY + bounds.midY - height / 2).rounded(), width: (end - start + 5).rounded(),
                height: height.rounded())
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// The middle of the characters at `range`, in the drawing's coordinates.
    private func center(of range: NSRange, in area: CGRect) -> CGPoint? {
        guard let line = textLineFragments.first(where: { $0.characterRange.contains(range.location) }) else { return nil }
        let bounds = line.typographicBounds
        let start = line.locationForCharacter(at: range.location).x
        let end = line.locationForCharacter(at: range.upperBound).x
        return CGPoint(x: area.minX + layoutFragmentFrame.minX + bounds.minX + (start + end) / 2, y: area.minY + bounds.midY)
    }

    /// A disc, a ring or a square, as lists are nested.
    private func drawBullet(at center: CGPoint, level: Int, size: CGFloat) {
        let diameter = max(4, (size * 0.4).rounded())
        let rect = CGRect(x: (center.x - diameter / 2).rounded(), y: (center.y - diameter / 2).rounded(), width: diameter, height: diameter)
        theme.accent.set()
        switch level {
        case 1: NSBezierPath(ovalIn: rect).fill()
        case 2:
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            ring.lineWidth = 1.2
            ring.stroke()
        default: rect.insetBy(dx: 0.5, dy: 0.5).fill()
        }
    }

    /// A box, ticked in the accent color.
    private func drawCheckbox(at center: CGPoint, checked: Bool, size: CGFloat) {
        let side = (size * 0.95).rounded()
        let rect = CGRect(x: (center.x - side / 2).rounded() + 0.5, y: (center.y - side / 2).rounded() + 0.5, width: side - 1, height: side - 1)
        let box = NSBezierPath(roundedRect: rect, xRadius: side * 0.26, yRadius: side * 0.26)
        if checked {
            theme.accent.setFill()
            box.fill()
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.53))
            tick.line(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.70))
            tick.line(to: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.33))
            tick.lineWidth = max(1.5, side * 0.13)
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            // White on a deep accent; the page's color on a pale one.
            theme.onAccent.setStroke()
            tick.stroke()
        } else {
            theme.text.withAlphaComponent(0.32).setStroke()
            box.lineWidth = 1.5
            box.stroke()
        }
    }
}
