// Draws the app icon and writes app/Resources/Quill-1024.png.
// Usage: swift scripts/make-icon.swift && scripts/make-icon.sh
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSGradient(colors: [
    NSColor(srgbRed: 0.98, green: 0.96, blue: 0.91, alpha: 1),
    NSColor(srgbRed: 0.91, green: 0.86, blue: 0.76, alpha: 1),
])!.draw(in: shape, angle: -90)

// Ruled lines of a page, under the nib.
NSColor(srgbRed: 0.35, green: 0.28, blue: 0.2, alpha: 0.16).setFill()
for (i, width) in [420.0, 520.0, 360.0].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: 220, y: 300 - CGFloat(i) * 62, width: width, height: 20), xRadius: 10, yRadius: 10).fill()
}

let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
    .applying(.init(paletteColors: [NSColor(srgbRed: 0.16, green: 0.2, blue: 0.42, alpha: 1)]))
if let symbol = NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + 80, width: s.width, height: s.height))
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let out = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("../app/Resources/Quill-1024.png").standardizedFileURL
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print(out.path)
