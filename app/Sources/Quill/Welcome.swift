import AppKit

/// The window shown when there is no workspace to open: the app, a button
/// to choose a folder, and the folders opened before.
final class WelcomeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    /// Asked to open a folder as the workspace, or nil to choose one.
    var onOpen: ((URL?) -> Void)?

    private let table = WelcomeTableView()
    private var recents: [URL] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Quill"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
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
        let root = NSView()

        // The app, on the left.
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "Welcome to Quill")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let subtitle = NSTextField(labelWithString: version.isEmpty ? "A fast Markdown editor" : "Version \(version)")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let hint = NSTextField(wrappingLabelWithString: "A workspace is a folder. Its notes stay plain Markdown files, which any app can read.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        let open = NSButton(title: "Open Folder…", target: self, action: #selector(chooseFolder(_:)))
        open.bezelStyle = .glass
        open.controlSize = .large
        open.keyEquivalent = "o"
        open.keyEquivalentModifierMask = [.command]
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }
}

/// Return in the table opens the selected workspace.
final class WelcomeTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let target = target, let doubleAction {
            NSApp.sendAction(doubleAction, to: target, from: self)
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ url: URL) {
        name.stringValue = url.lastPathComponent
        path.stringValue = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        toolTip = url.path
    }
}
