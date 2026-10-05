import AppKit

/// A view that reports light and dark changes, for its layer's colors.
final class AppearanceView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// The page's color behind the toolbar, fading out below it, so text
/// scrolls away under the tabs rather than through them. The title bar
/// itself is clear: the system's own would be white or black over a theme's
/// warm or tinted page.
final class ToolbarShade: NSView {
    /// How far below the toolbar the page's color fades out.
    static let fade: CGFloat = 14

    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError() }

    var color = NSColor.clear {
        didSet { needsLayout = true }
    }

    /// Off while the find bar sits under the toolbar: the fade would wash
    /// over its top edge.
    var fades = true {
        didSet { needsLayout = true }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Without the animation a layer brings to a change of its frame,
        // which would trail a window being resized.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        let solid = bounds.height > 0 ? max(0, bounds.height - Self.fade) / bounds.height : 0
        let end = fades ? 1 : solid
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Without the fade, the shade ends where the toolbar does.
            gradient.colors = [color.cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        }
        gradient.locations = [0, NSNumber(value: Double(solid)), NSNumber(value: Double(end))]
        // A flipped view's layer runs top to bottom.
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        CATransaction.commit()
    }

    /// A shade only: clicks go to the text under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The right column: the selected tab's editor or preview over the status bar.
final class EditorPaneController: NSViewController {
    let statusBar = StatusBar()
    private let container = NSView()
    private let shade = ToolbarShade()
    private weak var shown: NSView?

    override func loadView() {
        let root = AppearanceView()
        root.onAppearanceChange = { [weak self] in self?.applyTheme() }
        root.wantsLayer = true
        for view in [container, statusBar, shade] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            shade.topAnchor.constraint(equalTo: root.topAnchor),
            shade.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            shade.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: ToolbarShade.fade),
        ])
        view = root
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)), name: .appearanceDidChange, object: nil)
    }

    @objc private func themeChanged(_ note: Notification) { applyTheme() }

    /// The pane takes the editor's background, so the status bar and the
    /// margins around the text are one surface.
    private func applyTheme() {
        let theme = Theme.current
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = theme.background.cgColor
        }
        shade.color = theme.background
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyTheme() // layer colors don't follow light and dark changes on their own
    }

    /// Puts a tab's view in the pane, in place of the one there.
    func show(_ content: NSView) {
        guard content !== shown else { return }
        shown?.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        shown = content
        let editor = content as? EditorView
        shade.fades = !(editor?.scrollView.isFindBarVisible ?? false)
        editor?.onFindBarChange = { [weak self, weak editor] visible in
            guard let self, self.shown === editor else { return }
            self.shade.fades = !visible
        }
    }
}
