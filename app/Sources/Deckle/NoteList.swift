import AppKit
import ImageIO

@MainActor
protocol NoteListDelegate: AnyObject {
    /// `focus` asks for the keyboard to go to the editor: a click does, a
    /// keyboard move through the list doesn't.
    func noteList(_ list: NoteListController, open url: URL, inNewTab: Bool, focus: Bool)
    func noteList(_ list: NoteListController, trash url: URL)
    func noteListFocusEditor(_ list: NoteListController)
}

/// The middle column: the notes of a folder and the folders under it, each
/// with its title, the start of its text, and its first image.
final class NoteListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var delegate: NoteListDelegate?
    let workspace: Workspace
    private(set) var folder: URL
    private let table = NoteTableView()
    private let scrollView = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let sortButton = NSButton()
    /// A hairline under the header, shown once rows scroll under it.
    private let headerEdge = NSBox()
    private let emptyView = EmptyStateView(title: "No Notes", detail: "⌘N writes the first one.")
    private var count = 0
    /// Rows read from the core so far, by page.
    private var pages: [Int: [NoteSummary]] = [:]
    private static let pageSize = 100
    private var selectedPath: String?
    private var reloadPending = false
    private var isSelectingProgrammatically = false

    init(workspace: Workspace) {
        self.workspace = workspace
        folder = workspace.url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("note"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = NoteCell.height
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.onReturn = { [weak self] in self.map { $0.delegate?.noteListFocusEditor($0) } }
        table.setAccessibilityLabel("Notes")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // Room under the last row, so its plate clears the window's corner.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        // A new theme repaints the rows, whose plates and hairlines take its
        // colors, even when the appearance stays light or dark.
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged(_:)), name: .appearanceDidChange, object: nil)
        headerEdge.boxType = .separator
        headerEdge.wantsLayer = true
        headerEdge.alphaValue = 0

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        sortButton.isBordered = false
        sortButton.imagePosition = .imageOnly
        sortButton.contentTintColor = .secondaryLabelColor
        sortButton.target = self
        sortButton.action = #selector(toggleSort(_:))

        let header = NSStackView(views: [titleLabel, countLabel, NSView(), sortButton])
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)
        emptyView.isHidden = true
        let container = NSView()
        for view in [header, scrollView, emptyView, headerEdge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            headerEdge.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 1),
            headerEdge.heightAnchor.constraint(equalToConstant: 1),
            headerEdge.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerEdge.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
        ])
        view = container
        updateSortButton()
        reload()
    }

    @objc private func themeChanged(_ note: Notification) {
        table.enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
    }

    @objc private func scrolled(_ note: Notification) { updateHeaderEdge() }

    private func updateHeaderEdge() {
        let scrolled = scrollView.contentView.bounds.origin.y > 1
        let alpha: CGFloat = scrolled ? 1 : 0
        guard headerEdge.alphaValue != alpha else { return }
        // Out of a window there is nothing to animate, and the change would
        // be lost.
        if view.window == nil { headerEdge.alphaValue = alpha } else { headerEdge.animator().alphaValue = alpha }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateHeaderEdge()
    }

    /// The note a command in the list acts on.
    var selectedURL: URL? { note(at: table.selectedRow).map { URL(fileURLWithPath: $0.path) } }

    /// Puts the keyboard in the list, on the shown note when it is listed.
    func focus() {
        view.window?.makeFirstResponder(table)
        if table.selectedRow < 0, count > 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func updateSortButton() {
        let byTitle = Settings.sortsNotesByTitle
        sortButton.image = NSImage(
            systemSymbolName: byTitle ? "textformat.abc" : "clock", accessibilityDescription: "Sort")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        sortButton.toolTip = byTitle ? "Sorted by Title" : "Sorted by Date Modified"
    }

    @objc private func toggleSort(_ sender: Any?) {
        Settings.sortsNotesByTitle.toggle()
        updateSortButton()
        reload()
    }

    /// Shows the notes of another folder.
    func show(folder: URL) {
        guard folder.path != self.folder.path else { return }
        self.folder = folder
        reload()
        if count > 0 { table.scrollRowToVisible(0) }
    }

    /// The index changed. A burst of changes reloads the list once.
    func indexChanged() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    func reload() {
        guard isViewLoaded else { return }
        count = workspace.listNotes(in: folder, byTitle: Settings.sortsNotesByTitle)
        pages.removeAll()
        titleLabel.stringValue = folder.path == workspace.url.path ? workspace.name : folder.lastPathComponent
        countLabel.stringValue = count.formatted()
        emptyView.isHidden = count > 0
        isSelectingProgrammatically = true
        table.reloadData()
        restoreSelection()
        isSelectingProgrammatically = false
    }

    private func note(at row: Int) -> NoteSummary? {
        guard row >= 0, row < count else { return nil }
        let page = row / Self.pageSize
        if pages[page] == nil {
            pages[page] = workspace.notes(from: page * Self.pageSize, count: Self.pageSize)
        }
        let rows = pages[page] ?? []
        let index = row % Self.pageSize
        return index < rows.count ? rows[index] : nil
    }

    /// Marks the row of the note the editor shows, if it is loaded, and
    /// brings it into view.
    func select(_ url: URL?) {
        selectedPath = url?.path
        isSelectingProgrammatically = true
        restoreSelection()
        isSelectingProgrammatically = false
        if table.selectedRow >= 0 { table.reveal(row: table.selectedRow) }
    }

    private func restoreSelection() {
        guard let selectedPath else { return table.deselectAll(nil) }
        // Looks through the first pages only: far rows stay unread.
        for row in 0..<min(count, 3 * Self.pageSize) where note(at: row)?.path == selectedPath {
            if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
            return
        }
        table.deselectAll(nil)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let note = note(at: row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("note")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NoteCell ?? NoteCell(identifier: id)
        cell.show(note)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("noteRow")
        if let row = tableView.makeView(withIdentifier: id, owner: self) as? NoteRowView { return row }
        let view = NoteRowView()
        view.identifier = id
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically, let note = note(at: table.selectedRow) else { return }
        selectedPath = note.path
        let event = NSApp.currentEvent
        let newTab = event?.modifierFlags.contains(.command) ?? false
        // Arrowing through the list keeps the keyboard in the list.
        let byKey = event?.type == .keyDown
        delegate?.noteList(self, open: URL(fileURLWithPath: note.path), inNewTab: newTab, focus: !byKey)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let note = note(at: table.clickedRow) else { return }
        delegate?.noteList(self, open: URL(fileURLWithPath: note.path), inNewTab: true, focus: true)
    }

    /// A row can be dragged: onto a folder in the tree to move the note,
    /// into a note for a link, or out to another app.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        note(at: row).map { URL(fileURLWithPath: $0.path) as NSURL }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard note(at: table.clickedRow) != nil else { return }
        for (title, action, symbol) in [
            ("Open in New Tab", #selector(openInNewTab(_:)), "plus.square.on.square"),
            ("Reveal in Finder", #selector(revealInFinder(_:)), "finder"),
            ("Move to Trash", #selector(moveToTrash(_:)), "trash"),
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    private var clickedURL: URL? { note(at: table.clickedRow).map { URL(fileURLWithPath: $0.path) } }

    @objc private func openInNewTab(_ sender: Any?) {
        if let url = clickedURL { delegate?.noteList(self, open: url, inNewTab: true, focus: true) }
    }

    @objc private func revealInFinder(_ sender: Any?) {
        if let url = clickedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func moveToTrash(_ sender: Any?) {
        if let url = clickedURL { delegate?.noteList(self, trash: url) }
    }
}

extension NSTableView {
    /// Brings `row` into view if it isn't: a little above the middle, where
    /// the eye lands, rather than flush against an edge.
    func reveal(row: Int) {
        guard let scrollView = enclosingScrollView else { return scrollRowToVisible(row) }
        let clip = scrollView.contentView
        let rowRect = rect(ofRow: row)
        let visible = clip.documentVisibleRect
        guard rowRect.height > 0, !visible.contains(rowRect) else { return }
        let height = clip.bounds.height
        var y = rowRect.midY - height * 0.4
        y = max(-scrollView.contentInsets.top, min(y, bounds.height + scrollView.contentInsets.bottom - height))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y.rounded()))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// What a column says when it has nothing to list: a title and a hint.
final class EmptyStateView: NSView {
    init(title: String, detail: String) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .center
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A hint only: clicks and drops go through to the list under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The note list's table: Return hands the keyboard to the editor. ⌘⌫ moves
/// the selected note to the Trash through the File menu, which sees the keys
/// before the table would.
final class NoteTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onReturn?()
        default:
            super.keyDown(with: event)
        }
    }
}

/// A row between two hairlines, which the selection covers. Under a theme
/// the selection is a plate of the theme's own colors: the accent while the
/// list has the keyboard, a shade of the text otherwise, rather than the
/// system's grey, which sits oddly on a warm or a dark page.
final class NoteRowView: NSTableRowView {
    override func drawSeparator(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        let theme = Theme.current
        guard theme.appearance != nil else { return super.drawSelection(in: dirtyRect) }
        (isEmphasized ? theme.accent.withAlphaComponent(0.22) : theme.text.withAlphaComponent(0.07)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !isSelected, !isNextRowSelected else { return }
        let theme = Theme.current
        // A hairline: a shade of the text, a tenth as strong.
        (theme.appearance == nil ? NSColor.separatorColor : theme.text.withAlphaComponent(0.1)).setFill()
        // As long as the selection plate, from the text's edge.
        NSRect(x: 20, y: bounds.maxY - 1, width: max(0, bounds.width - 30), height: 1).fill()
    }
}

/// A row of the note list: the title with the date after it, then the start
/// of the text, beside the note's first image.
final class NoteCell: NSTableCellView {
    static let height: CGFloat = 68

    private let titleLabel = NSTextField(labelWithString: "")
    private let excerptLabel = NSTextField(wrappingLabelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let thumbnail = NSImageView()
    private var textTrailing: [NSLayoutConstraint] = []
    private var textToThumbnail: [NSLayoutConstraint] = []
    /// The image this cell waits for, so a late one for a reused cell is dropped.
    private var imagePath = ""

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        excerptLabel.font = .systemFont(ofSize: 12)
        excerptLabel.textColor = .secondaryLabelColor
        excerptLabel.maximumNumberOfLines = 2
        // Wrapping, with the second line cut short: a truncating mode would
        // keep the excerpt to one line.
        excerptLabel.lineBreakMode = .byWordWrapping
        excerptLabel.cell?.truncatesLastVisibleLine = true
        dateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.alignment = .right
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 6
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.borderWidth = 0.5
        thumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        for view in [titleLabel, excerptLabel, dateLabel, thumbnail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(view)
        }
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        // The title and date keep the whole width; a thumbnail sits beside
        // the excerpt only.
        textTrailing = [excerptLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)]
        textToThumbnail = [excerptLabel.trailingAnchor.constraint(equalTo: thumbnail.leadingAnchor, constant: -8)]
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dateLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            excerptLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            excerptLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            excerptLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            thumbnail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            thumbnail.topAnchor.constraint(equalTo: excerptLabel.topAnchor, constant: 1),
            thumbnail.widthAnchor.constraint(equalToConstant: 36),
            thumbnail.heightAnchor.constraint(equalToConstant: 36),
        ] + textTrailing)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A layer's color is fixed when it is set, so the thumbnail's edge is
    /// set again whenever light turns to dark.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            thumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func show(_ note: NoteSummary) {
        titleLabel.stringValue = note.title
        excerptLabel.stringValue = note.excerpt.isEmpty ? "No additional text" : note.excerpt
        excerptLabel.textColor = note.excerpt.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
        dateLabel.stringValue = NoteCell.format(Date(timeIntervalSince1970: note.modified))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(note.title), \(dateLabel.stringValue), \(excerptLabel.stringValue)")
        let hasImage = !note.image.isEmpty
        thumbnail.isHidden = !hasImage
        NSLayoutConstraint.deactivate(hasImage ? textTrailing : textToThumbnail)
        NSLayoutConstraint.activate(hasImage ? textToThumbnail : textTrailing)
        imagePath = note.image
        thumbnail.image = nil
        guard hasImage else { return }
        Thumbnails.load(note.image, side: 80) { [weak self] image in
            guard let self, self.imagePath == note.image else { return }
            self.thumbnail.image = image
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// The time for today, the day for this year, the full date before that.
    static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return timeFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return dayFormatter.string(from: date)
        }
        return yearFormatter.string(from: date)
    }
}

/// Small versions of images, decoded off the main thread a few at a time
/// and kept in memory.
@MainActor
enum Thumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// Who waits for each image being decoded, so a flung list asks once.
    private static var waiting: [String: [@MainActor (NSImage?) -> Void]] = [:]

    /// Hands `done` a square image `side` pixels across, cropped from the
    /// middle of the picture.
    static func load(_ path: String, side: Int, done: @escaping @MainActor (NSImage?) -> Void) {
        let key = "\(path)|\(side)"
        if let cached = cache.object(forKey: key as NSString) { return done(cached) }
        if waiting[key] != nil {
            waiting[key]?.append(done)
            return
        }
        waiting[key] = [done]
        queue.addOperation {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: side * 2,
            ]
            var thumbnail = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
                .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            if let image = thumbnail {
                // The middle square, so a wide picture fills the frame.
                let edge = min(image.width, image.height)
                let square = CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge)
                thumbnail = image.cropping(to: square) ?? image
            }
            DispatchQueue.main.async {
                let image = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width / 2, height: $0.height / 2)) }
                if let image { cache.setObject(image, forKey: key as NSString, cost: image.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 0) }
                let callbacks = waiting.removeValue(forKey: key) ?? []
                for callback in callbacks { callback(image) }
            }
        }
    }
}
