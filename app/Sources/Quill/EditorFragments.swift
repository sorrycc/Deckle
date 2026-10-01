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

    /// A rectangle rounded at the top, the bottom, both or neither.
    private func path(_ rect: CGRect, radius: CGFloat, top: Bool, bottom: Bool) -> NSBezierPath {
        let path = NSBezierPath()
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
                let symbol = Styler.calloutSymbols[min(5, d.callout)]
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [color]))
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?.withSymbolConfiguration(config) {
                    let size = image.size
                    image.draw(in: NSRect(
                        x: rect.minX + 10, y: area.minY + (area.height - size.height) / 2, width: size.width, height: size.height))
                }
                if !d.calloutHasTitle {
                    let text = NSAttributedString(string: name, attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold), .foregroundColor: color,
                    ])
                    let size = text.size()
                    text.draw(at: NSPoint(x: rect.minX + 33, y: area.minY + (area.height - size.height) / 2))
                }
            }
        } else if d.quoteDepth > 0 {
            theme.quoteBar.setFill()
            for depth in 0..<d.quoteDepth {
                NSBezierPath(
                    roundedRect: CGRect(x: block.minX + 5 + CGFloat(depth) * Styler.quoteIndent, y: block.minY, width: 3, height: block.height),
                    xRadius: 1.5, yRadius: 1.5
                ).fill()
            }
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
            guard let center = center(of: NSRange(location: bullet.index, length: 1), in: area) else { continue }
            drawBullet(at: center, level: bullet.level, size: d.fontSize)
        }
        for box in d.checkboxes {
            guard let center = center(of: box.range, in: area) else { continue }
            drawCheckbox(at: center, checked: box.checked, size: d.fontSize)
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
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            theme.text.withAlphaComponent(0.32).setStroke()
            box.lineWidth = 1.5
            box.stroke()
        }
    }
}
