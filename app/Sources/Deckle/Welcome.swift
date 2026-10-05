import AppKit

/// The window shown when there is no workspace to open: the app, a button
/// to choose a folder, and the folders opened before.
final class WelcomeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSMenuDelegate {
    /// Asked to open a folder as the workspace or a file in a tab, or nil to
    /// choose one.
    var onOpen: ((URL?) -> Void)?

    private let table = WelcomeTableView()
    private var recents: [URL] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Deckle"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        applyAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged(_:)), name: .appearanceDidChange, object: nil)
    }

    @objc private func appearanceChanged(_ note: Notification) { applyAppearance() }

    /// The theme's appearance, as the workspace window takes it.
    private func applyAppearance() {
        window?.appearance = Theme.current.appearance.flatMap { NSAppearance(named: $0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    /// Reads the recent workspaces again, leaving out folders that are gone.
    func reload() {
        recents = Settings.recentWorkspaces.filter { FileManager.default.fileExists(atPath: $0.path) }
        table.reloadData()
        if !recents.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func makeContent() -> NSView {
        let root = DropView()
        root.onDrop = { [weak self] url in self?.onOpen?(url) }

        // The app, on the left.
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "Welcome to Deckle")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let subtitle = NSTextField(labelWithString: version.isEmpty ? "A fast Markdown editor" : "Version \(version)")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let hint = NSTextField(wrappingLabelWithString: "A workspace is a folder. Its notes stay plain Markdown files, which any app can read.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        let open = NSButton(title: "Open…", target: self, action: #selector(chooseFolder(_:)))
        open.bezelStyle = .push
        open.controlSize = .large
        // The one thing to do here: the default button, in the accent color.
        open.keyEquivalent = "\r"
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        open.imagePosition = .imageLeading

        let left = NSStackView(views: [icon, title, subtitle, hint, open])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 6
        left.setCustomSpacing(16, after: icon)
        left.setCustomSpacing(22, after: subtitle)
        left.setCustomSpacing(26, after: hint)

        // The recent workspaces, on the right.
        let column = NSTableColumn(identifier: .init("workspace"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 52
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.onDelete = { [weak self] in self?.removeSelected(nil) }
        table.setAccessibilityLabel("Recent Workspaces")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 44, left: 0, bottom: 8, right: 0)

        let recentsTitle = NSTextField(labelWithString: "Recent Workspaces")
        recentsTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        recentsTitle.textColor = .secondaryLabelColor
        let empty = NSTextField(labelWithString: "No Recent Workspaces")
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center
        emptyLabel = empty

        let right = NSVisualEffectView()
        right.material = .sidebar
        right.blendingMode = .behindWindow
        right.state = .active
        // A folder dropped anywhere on the window opens as the workspace, a
        // file in a tab.
        root.registerForDraggedTypes([.fileURL])
        for view in [scroll, recentsTitle, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            right.addSubview(view)
        }
        for view in [left, right] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 128),
            icon.heightAnchor.constraint(equalToConstant: 128),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            left.centerXAnchor.constraint(equalTo: root.leadingAnchor, constant: 230),
            left.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 6),
            left.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            right.topAnchor.constraint(equalTo: root.topAnchor),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            right.widthAnchor.constraint(equalToConstant: 300),
            scroll.topAnchor.constraint(equalTo: right.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            recentsTitle.topAnchor.constraint(equalTo: right.topAnchor, constant: 22),
            recentsTitle.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 20),
            empty.centerXAnchor.constraint(equalTo: right.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: right.centerYAnchor),
        ])
        return root
    }

    private weak var emptyLabel: NSTextField?

    // MARK: Actions

    @objc private func chooseFolder(_ sender: Any?) { onOpen?(nil) }

    private var menuRow: Int { table.clickedRow >= 0 ? table.clickedRow : table.selectedRow }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard recents.indices.contains(menuRow) else { return }
        for (title, action) in [
            ("Open", #selector(openSelected(_:))), ("Show in Finder", #selector(showInFinder(_:))),
            ("Remove from Recents", #selector(removeSelected(_:))),
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
    }

    @objc private func showInFinder(_ sender: Any?) {
        guard recents.indices.contains(menuRow) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recents[menuRow]])
    }

    @objc private func removeSelected(_ sender: Any?) {
        guard recents.indices.contains(menuRow) else { return }
        let url = recents[menuRow]
        Settings.recentWorkspaces = Settings.recentWorkspaces.filter { $0.path != url.path }
        reload()
    }

    @objc private func openSelected(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard recents.indices.contains(row) else { return }
        onOpen?(recents[row])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        emptyLabel?.isHidden = !recents.isEmpty
        return recents.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("recent")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? RecentCell ?? RecentCell(identifier: id)
        cell.show(recents[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { WelcomeRowView() }
}

/// The window's content, which takes a dropped folder or file.
private final class DropView: NSView {
    var onDrop: ((URL) -> Void)?

    /// A folder among the dropped items, or else the first file.
    private func item(in info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first { $0.hasDirectoryPath } ?? urls.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { item(in: sender) == nil ? [] : .generic }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = item(in: sender) else { return false }
        onDrop?(url)
        return true
    }
}

/// Selection as a plate inset from the pane's edges, as the lists' are.
final class WelcomeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // The theme's accent, as the lists in the workspace window use.
        (Theme.current.appearance == nil ? NSColor.controlAccentColor : Theme.current.accent).withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// Return in the table opens the selected workspace; Delete takes it off
/// the list.
final class WelcomeTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let target = target, let doubleAction {
            NSApp.sendAction(doubleAction, to: target, from: self)
        } else if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A recent workspace: its name over its path, beside a folder.
final class RecentCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        for view in [icon, name, path] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            // The two lines together, in the middle of the row.
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            path.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ url: URL) {
        name.stringValue = url.lastPathComponent
        path.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        toolTip = url.path
    }
}
