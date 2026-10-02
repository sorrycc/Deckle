import AppKit

/// A view that reports light and dark changes, for its layer's colors.
final class AppearanceView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// The right column: the selected tab's editor or preview over the status bar.
final class EditorPaneController: NSViewController {
    let statusBar = StatusBar()
    private let container = NSView()
    private weak var shown: NSView?

    override func loadView() {
        let root = AppearanceView()
        root.onAppearanceChange = { [weak self] in self?.applyTheme() }
        root.wantsLayer = true
        for view in [container, statusBar] as [NSView] {
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
    }
}
