// Draws the app icon and writes app/Resources/Deckle-1024.png: a sheet of
// handmade paper with deckled edges on an ink-blue square.
// Usage: swift scripts/make-icon.swift && scripts/make-icon.sh
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!

// The square.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
context.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
shape.fill()
context.restoreGraphicsState()
NSGradient(colors: [
    NSColor(srgbRed: 0.22, green: 0.27, blue: 0.52, alpha: 1),
    NSColor(srgbRed: 0.13, green: 0.16, blue: 0.36, alpha: 1),
])!.draw(in: shape, angle: -90)

// A fixed seed, so every run draws the same edge.
var seed: UInt64 = 0x5EED_DEC1
func random() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(1 << 31)
}

// The sheet's outline: points along each side, pushed in and out by a slow
// wave and a fine fibrous jitter.
let sheet = NSRect(x: -250, y: -300, width: 500, height: 600)
let corners = [
    NSPoint(x: sheet.minX, y: sheet.minY), NSPoint(x: sheet.maxX, y: sheet.minY),
    NSPoint(x: sheet.maxX, y: sheet.maxY), NSPoint(x: sheet.minX, y: sheet.maxY),
]
let edge = NSBezierPath()
for side in 0..<4 {
    let a = corners[side], b = corners[(side + 1) % 4]
    let length = hypot(b.x - a.x, b.y - a.y)
    // The outward normal of a counterclockwise outline.
    let normal = NSPoint(x: (b.y - a.y) / length, y: -(b.x - a.x) / length)
    let steps = Int(length / 5)
    let phase = random() * .pi * 2
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps)
        let wave = sin(t * .pi * 5 + phase) * 4 + sin(t * .pi * 13 + phase * 2) * 2.5
        let fiber = (random() - 0.5) * 6
        // Corners stay put so the sheet keeps its shape.
        let taper = min(1, min(t, 1 - t) * 12)
        let offset = (wave + fiber) * taper
        let point = NSPoint(x: a.x + (b.x - a.x) * t + normal.x * offset,
                            y: a.y + (b.y - a.y) * t + normal.y * offset)
        if side == 0 && i == 0 { edge.move(to: point) } else { edge.line(to: point) }
    }
}
edge.close()

context.saveGraphicsState()
let transform = NSAffineTransform()
transform.translateX(by: size / 2, yBy: size / 2 - 6)
transform.rotate(byDegrees: -5)
transform.concat()

let sheetShadow = NSShadow()
sheetShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
sheetShadow.shadowBlurRadius = 30
sheetShadow.shadowOffset = NSSize(width: 0, height: -14)
context.saveGraphicsState()
sheetShadow.set()
NSColor(srgbRed: 0.97, green: 0.94, blue: 0.87, alpha: 1).setFill()
edge.fill()
context.restoreGraphicsState()
context.saveGraphicsState()
edge.addClip()
NSGradient(colors: [
    NSColor(srgbRed: 0.99, green: 0.97, blue: 0.92, alpha: 1),
    NSColor(srgbRed: 0.93, green: 0.89, blue: 0.80, alpha: 1),
])!.draw(in: sheet.insetBy(dx: -20, dy: -20), angle: -90)
context.restoreGraphicsState()

// Ruled lines of a page.
NSColor(srgbRed: 0.35, green: 0.28, blue: 0.2, alpha: 0.2).setFill()
for (i, width) in [340.0, 400.0, 280.0, 360.0].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: -170, y: 150 - CGFloat(i) * 80, width: width, height: 22), xRadius: 11, yRadius: 11).fill()
}
context.restoreGraphicsState()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let out = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("../app/Resources/Deckle-1024.png").standardizedFileURL
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print(out.path)
