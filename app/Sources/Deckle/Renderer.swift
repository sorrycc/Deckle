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
    private var loadScheduled = false
    private struct Job {
        let key: String
        /// Who asked: an element of an editor. A newer job from the same
        /// place replaces one still waiting, as when the source is typed in.
        let owner: String
        let kind: Kind
        let source: String
        let dark: Bool
        let color: String
        let background: String
        let accent: String
        let size: CGFloat
        let width: CGFloat
    }

    private var queue: [Job] = []
    private var isBusy = false
    private var images: [String: NSImage] = [:]
    /// Keys in the order they were made, so the oldest go first.
    private var order: [String] = []
    private var waiting: [String: [(NSImage) -> Void]] = [:]
    private var idleTimer: Timer?

    /// The image of `source`, or nil while it renders; `done` gets it then.
    /// A diagram takes the note's `background` and `accent` too, so it is
    /// drawn in the theme's colors.
    func image(
        _ kind: Kind, source: String, dark: Bool, color: NSColor, background: NSColor? = nil, accent: NSColor? = nil,
        size: CGFloat, width: CGFloat, owner: String = "", done: @escaping (NSImage) -> Void
    ) -> NSImage? {
        let hex = Self.hex(color)
        let backgroundHex = background.map(Self.hex) ?? ""
        let accentHex = accent.map(Self.hex) ?? hex
        let key = "\(kind.rawValue)|\(dark)|\(hex)|\(backgroundHex)|\(accentHex)|\(size)|\(Int(width))|\(source)"
        if let image = images[key] { return image }
        if waiting[key] != nil {
            waiting[key]?.append(done)
            return nil
        }
        // What the same place asked for before and hasn't had yet is
        // out of date; whoever waited for it waits for this instead.
        if !owner.isEmpty {
            for stale in queue where stale.owner == owner {
                let callbacks = waiting.removeValue(forKey: stale.key) ?? []
                waiting[key, default: []].append(contentsOf: callbacks)
            }
            queue.removeAll { $0.owner == owner }
        }
        waiting[key, default: []].append(done)
        queue.append(Job(key: key, owner: owner, kind: kind, source: source, dark: dark, color: hex, background: backgroundHex, accent: accentHex, size: size, width: width))
        start()
        return nil
    }

    private static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    private func start() {
        if webView == nil {
            // After the frame that asked, so a note opens before WebKit starts.
            guard !loadScheduled else { return }
            loadScheduled = true
            DispatchQueue.main.async { [self] in
                load()
            }
            return
        }
        guard isLoaded, !isBusy, !queue.isEmpty else {
            if queue.isEmpty, !isBusy { scheduleTeardown() }
            return
        }
        idleTimer?.invalidate()
        isBusy = true
        let job = queue.removeFirst()
        Task { await render(job) }
    }

    /// The web view and its process go away after a while unused; a note
    /// with one formula shouldn't keep them for the whole session. The
    /// images drawn stay.
    private func scheduleTeardown() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tearDown() }
        }
    }

    private func tearDown() {
        guard queue.isEmpty, !isBusy, let window else { return }
        webView?.navigationDelegate = nil
        window.contentView = nil
        window.orderOut(nil)
        self.window = nil
        webView = nil
        isLoaded = false
        loadScheduled = false
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

    private func render(_ job: Job) async {
        defer {
            isBusy = false
            start()
        }
        guard let webView else { return }
        window?.appearance = NSAppearance(named: job.dark ? .darkAqua : .aqua)
        let result = try? await webView.callAsyncJavaScript(
            "return await render(kind, source, dark, color, size, width, background, accent)",
            arguments: [
                "kind": job.kind.rawValue, "source": job.source, "dark": job.dark, "color": job.color, "size": job.size,
                "width": job.width, "background": job.background, "accent": job.accent,
            ],
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
        if images.updateValue(image, forKey: key) == nil { order.append(key) }
        // The oldest make room, a few at a time.
        while order.count > 400 {
            images.removeValue(forKey: order.removeFirst())
        }
        callbacks.forEach { $0(image) }
    }
}
