import AppKit

/// A rounded pane of Liquid Glass on macOS 26, and of the popover's blur
/// before it, for the palette, the completion list and the outline card.
final class GlassPane: NSView {
    /// The glass on macOS 26, or the blur and the tint over it before.
    private let backing: NSView
    private let tintView = NSView()

    init(cornerRadius: CGFloat, content: NSView) {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            backing = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            // Panels show while another window is key, and the blur would
            // go flat with it.
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = cornerRadius
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            tintView.wantsLayer = true
            for view in [tintView, content] {
                view.translatesAutoresizingMaskIntoConstraints = false
                blur.addSubview(view)
                Self.pin(view, to: blur)
            }
            backing = blur
        }
        super.init(frame: .zero)
        backing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backing)
        Self.pin(backing, to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A wash of color over the glass, so what's on it reads over whatever
    /// is behind.
    var tintColor: NSColor? {
        didSet {
            if #available(macOS 26, *), let glass = backing as? NSGlassEffectView {
                glass.tintColor = tintColor
            } else {
                tintView.layer?.backgroundColor = tintColor?.cgColor
            }
        }
    }

    /// A pane that is a panel's whole content blurs what is behind the
    /// panel; one inside a window blurs the window's content under it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let blur = backing as? NSVisualEffectView else { return }
        blur.blendingMode = window?.contentView === self ? .behindWindow : .withinWindow
    }

    private static func pin(_ view: NSView, to container: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

extension NSButton.BezelStyle {
    /// Glass on macOS 26, the rounded push button before.
    static var glassOrRounded: NSButton.BezelStyle {
        if #available(macOS 26, *) { .glass } else { .rounded }
    }
}
