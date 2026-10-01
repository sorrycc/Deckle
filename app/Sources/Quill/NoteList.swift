import AppKit
import ImageIO

@MainActor
protocol NoteListDelegate: AnyObject {
    func noteList(_ list: NoteListController, open url: URL, inNewTab: Bool)
    func noteList(_ list: NoteListController, trash url: URL)
}

/// The middle column: the notes of a folder and the folders under it, each
/// with its title, the start of its text, and its first image.
final class NoteListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var delegate: NoteListDelegate?
    let workspace: Workspace
    private(set) var folder: URL
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let sortButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "No Notes")
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
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

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
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        let container = NSView()
        for view in [header, scrollView, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        updateSortButton()
        reload()
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
        emptyLabel.isHidden = count > 0
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
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
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
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        delegate?.noteList(self, open: URL(fileURLWithPath: note.path), inNewTab: newTab)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let note = note(at: table.clickedRow) else { return }
        delegate?.noteList(self, open: URL(fileURLWithPath: note.path), inNewTab: true)
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
        if let url = clickedURL { delegate?.noteList(self, open: url, inNewTab: true) }
    }

    @objc private func revealInFinder(_ sender: Any?) {
        if let url = clickedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func moveToTrash(_ sender: Any?) {
        if let url = clickedURL { delegate?.noteList(self, trash: url) }
    }
}

/// A row between two hairlines, which the selection covers.
final class NoteRowView: NSTableRowView {
    override func drawSeparator(in dirtyRect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !isSelected, !isNextRowSelected else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: 20, y: bounds.maxY - 1, width: max(0, bounds.width - 36), height: 1).fill()
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
        excerptLabel.lineBreakMode = .byTruncatingTail
        excerptLabel.cell?.truncatesLastVisibleLine = true
        dateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.alignment = .right
        thumbnail.imageScaling = .scaleAxesIndependently
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 6
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        for view in [titleLabel, excerptLabel, dateLabel, thumbnail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(view)
        }
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        textTrailing = [
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            excerptLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ]
        textToThumbnail = [
            dateLabel.trailingAnchor.constraint(equalTo: thumbnail.leadingAnchor, constant: -10),
            excerptLabel.trailingAnchor.constraint(equalTo: thumbnail.leadingAnchor, constant: -10),
        ]
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),
            dateLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            excerptLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            excerptLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            excerptLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            thumbnail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 46),
            thumbnail.heightAnchor.constraint(equalToConstant: 46),
        ] + textTrailing)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ note: NoteSummary) {
        titleLabel.stringValue = note.title
        excerptLabel.stringValue = note.excerpt.isEmpty ? "No additional text" : note.excerpt
        excerptLabel.textColor = note.excerpt.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
        dateLabel.stringValue = NoteCell.format(Date(timeIntervalSince1970: note.modified))
        let hasImage = !note.image.isEmpty
        thumbnail.isHidden = !hasImage
        NSLayoutConstraint.deactivate(hasImage ? textTrailing : textToThumbnail)
        NSLayoutConstraint.activate(hasImage ? textToThumbnail : textTrailing)
        imagePath = note.image
        thumbnail.image = nil
        guard hasImage else { return }
        Thumbnails.load(note.image, side: 104) { [weak self] image in
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

/// Small versions of images, decoded off the main thread and kept in memory.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()
    private static let queue = DispatchQueue(label: "dev.sorrycc.quill.thumbnails", qos: .userInitiated, attributes: .concurrent)

    /// Hands `done` an image at most `side` pixels on its longer side.
    static func load(_ path: String, side: Int, done: @escaping @MainActor (NSImage?) -> Void) {
        let key = "\(path)|\(side)"
        if let cached = cache.object(forKey: key as NSString) { return done(cached) }
        queue.async {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            let thumbnail = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
                .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            DispatchQueue.main.async {
                let image = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width / 2, height: $0.height / 2)) }
                if let image { cache.setObject(image, forKey: key as NSString) }
                done(image)
            }
        }
    }
}
