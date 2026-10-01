import AppKit
import WebKit

/// Draws math with KaTeX and diagrams with Mermaid, in a web view kept out of
/// sight. It loads only when a note first has math or a diagram, and each
/// result is kept as an image.
@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    enum Kind: String {
        /// Math in a line of text.
        case inline
        /// Math as a block.
        case math
        case mermaid
    }

    static let shared = Renderer()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var isLoaded = false
    private var queue: [(key: String, kind: Kind, source: String, dark: Bool, color: String, size: CGFloat, width: CGFloat)] = []
    private var isBusy = false
    private var images: [String: NSImage] = [:]
    private var waiting: [String: [(NSImage) -> Void]] = [:]

    /// The image of `source`, or nil while it renders; `done` gets it then.
    func image(
        _ kind: Kind, source: String, dark: Bool, color: NSColor, size: CGFloat, width: CGFloat,
        done: @escaping (NSImage) -> Void
    ) -> NSImage? {
        let hex = Self.hex(color)
        let key = "\(kind.rawValue)|\(dark)|\(hex)|\(size)|\(Int(width))|\(source)"
        if let image = images[key] { return image }
        if waiting[key] != nil {
            waiting[key]?.append(done)
            return nil
        }
        waiting[key] = [done]
        queue.append((key, kind, source, dark, hex, size, width))
        start()
        return nil
    }

    private static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    private func start() {
        if webView == nil { load() }
        guard isLoaded, !isBusy, !queue.isEmpty else { return }
        isBusy = true
        let job = queue.removeFirst()
        Task { await render(job) }
    }

    private func load() {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        // Out of sight, but in a window, which a web view needs to draw.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1600, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = webView
        window.orderBack(nil)
        self.window = window
        self.webView = webView
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Renderer", isDirectory: true) else { return }
        webView.loadFileURL(folder.appendingPathComponent("renderer.html"), allowingReadAccessTo: folder)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        start()
    }

    private func render(_ job: (key: String, kind: Kind, source: String, dark: Bool, color: String, size: CGFloat, width: CGFloat)) async {
        defer {
            isBusy = false
            start()
        }
        guard let webView else { return }
        window?.appearance = NSAppearance(named: job.dark ? .darkAqua : .aqua)
        let result = try? await webView.callAsyncJavaScript(
            "return await render(kind, source, dark, color, size, width)",
            arguments: ["kind": job.kind.rawValue, "source": job.source, "dark": job.dark, "color": job.color, "size": job.size, "width": job.width],
            contentWorld: .page)
        guard let size = result as? [String: Any], let width = (size["width"] as? NSNumber)?.doubleValue,
            let height = (size["height"] as? NSNumber)?.doubleValue, width > 0, height > 0
        else { return finish(job.key, nil) }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        configuration.afterScreenUpdates = true
        let image = try? await webView.takeSnapshot(configuration: configuration)
        finish(job.key, image)
    }

    private func finish(_ key: String, _ image: NSImage?) {
        let callbacks = waiting.removeValue(forKey: key) ?? []
        guard let image else { return }
        images[key] = image
        if images.count > 400 { images.removeAll() }
        callbacks.forEach { $0(image) }
    }
}
