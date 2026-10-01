import AppKit

@MainActor
protocol FileTreeDelegate: AnyObject {
    func fileTree(_ tree: FileTreeController, open url: URL, inNewTab: Bool)
    func fileTree(_ tree: FileTreeController, showFolder url: URL)
    func fileTree(_ tree: FileTreeController, moved old: URL, to new: URL)
    func fileTree(_ tree: FileTreeController, removed url: URL)
    func fileTreeSwitchWorkspace(_ tree: FileTreeController, to url: URL?)
}

/// A file or folder in the tree. Folders read their children when first
/// expanded, so a large workspace costs nothing until it is looked at.
final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    /// The Starred group, which is not a folder on disk.
    let isGroup: Bool
    weak var parent: FileNode?
    var children: [FileNode]?

    init(url: URL, isDirectory: Bool, isGroup: Bool = false, parent: FileNode? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.isGroup = isGroup
        self.parent = parent
    }

    /// Reads the folder again, keeping the nodes of entries still there so
    /// that what is expanded under them stays expanded.
    func reload() {
        guard isDirectory, !isGroup else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let existing = Dictionary(uniqueKeysWithValues: (children ?? []).map { ($0.url.lastPathComponent, $0) })
        var nodes: [FileNode] = []
        for child in urls where child.lastPathComponent != "node_modules" {
            let isDirectory = (try? child.resourceValues(forKeys: Set(keys)))?.isDirectory ?? false
            if let node = existing[child.lastPathComponent], node.isDirectory == isDirectory {
                nodes.append(node)
            } else {
                nodes.append(FileNode(url: url.appendingPathComponent(child.lastPathComponent, isDirectory: isDirectory), isDirectory: isDirectory, parent: self))
            }
        }
        // Folders first, then names as Finder orders them.
        nodes.sort {
            $0.isDirectory != $1.isDirectory
                ? $0.isDirectory : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        children = nodes
    }
}

/// The sidebar: the workspace's folders and files, starred files above them,
/// and the workspace switcher below.
final class FileTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    weak var delegate: FileTreeDelegate?
    let workspace: Workspace
    private let root: FileNode
    private let starredGroup: FileNode
    private let outline = NSOutlineView()
    private let scrollView = NSScrollView()
    private let switcher = NSPopUpButton(frame: .zero, pullsDown: true)
    private let emptyView = EmptyStateView(title: "No Files", detail: "Drop files here, or press ⌘N.")
    /// Loaded folders by path, to find the node a change belongs to.
    private var folders: [String: FileNode] = [:]
    private var isSelectingProgrammatically = false

    private(set) var starred: [URL] = []

    init(workspace: Workspace) {
        self.workspace = workspace
        root = FileNode(url: workspace.url, isDirectory: true)
        starredGroup = FileNode(url: workspace.url.appendingPathComponent(".starred"), isDirectory: true, isGroup: true)
        super.init(nibName: nil, bundle: nil)
        let state = Settings.state(for: workspace.url)
        starred = (state["starred"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        root.reload()
        folders[root.url.path] = root
        rebuildStarred()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.autosaveExpandedItems = false
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        switcher.isBordered = false
        switcher.font = .systemFont(ofSize: 12, weight: .medium)
        switcher.menu?.delegate = self
        (switcher.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom

        emptyView.isHidden = true
        let container = NSView()
        for view in [scrollView, switcher, emptyView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            emptyView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: switcher.topAnchor, constant: -4),
            switcher.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            switcher.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            switcher.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        view = container
        rebuildSwitcher()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The one column is as wide as the sidebar, so names get its room.
        outline.sizeLastColumnToFit()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outline.reloadData()
        updateEmptyState()
        if !starred.isEmpty { outline.expandItem(starredGroup) }
        let expanded = Settings.state(for: workspace.url)["expanded"] as? [String] ?? []
        // Parents before children, so each path finds its node loaded.
        for path in expanded.sorted() {
            if let node = node(for: URL(fileURLWithPath: path)) { outline.expandItem(node) }
        }
    }

    // MARK: State

    private func updateEmptyState() {
        emptyView.isHidden = !(root.children?.isEmpty ?? true) || !starred.isEmpty
    }

    /// The folders expanded in the tree, to open them again next time.
    var expandedPaths: [String] {
        (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FileNode }
            .filter { $0.isDirectory && !$0.isGroup && outline.isItemExpanded($0) }.map(\.url.path)
    }

    /// The folder a new note goes in: the selected folder, or the selected
    /// file's.
    var targetFolder: URL {
        guard let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.isGroup else { return workspace.url }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func rebuildStarred() {
        starredGroup.children = starred.map { FileNode(url: $0, isDirectory: false, parent: starredGroup) }
    }

    private func saveStarred() {
        var state = Settings.state(for: workspace.url)
        state["starred"] = starred.map(\.path)
        Settings.setState(state, for: workspace.url)
        rebuildStarred()
        outline.reloadData()
        if !starred.isEmpty { outline.expandItem(starredGroup) }
        updateEmptyState()
    }

    private func rebuildSwitcher() {
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: workspace.name, action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "books.vertical", accessibilityDescription: nil)
        menu.addItem(title)
        for url in Settings.recentWorkspaces where url.path != workspace.url.path && FileManager.default.fileExists(atPath: url.path) {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(switchWorkspace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Folder…", action: #selector(switchWorkspace(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        switcher.menu = menu
    }

    @objc private func switchWorkspace(_ sender: NSMenuItem) {
        delegate?.fileTreeSwitchWorkspace(self, to: sender.representedObject as? URL)
    }

    // MARK: Changes on disk

    /// The node of a file or folder whose parents are loaded.
    private func node(for url: URL) -> FileNode? {
        if url.path == root.url.path { return root }
        guard let parent = folders[url.deletingLastPathComponent().path] else { return nil }
        if parent.children == nil { parent.reload() }
        return parent.children?.first { $0.url.lastPathComponent == url.lastPathComponent }
    }

    /// A folder's contents changed on disk.
    func folderChanged(_ url: URL) {
        guard let node = folders[url.path], node.children != nil else { return }
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.url
        node.reload()
        // Folders that went away are no longer loaded.
        folders = folders.filter { FileManager.default.fileExists(atPath: $0.key) }
        isSelectingProgrammatically = true
        outline.reloadItem(node === root ? nil : node, reloadChildren: true)
        if let selected { select(selected, expanding: false) }
        isSelectingProgrammatically = false
        updateEmptyState()
        let kept = starred.filter { FileManager.default.fileExists(atPath: $0.path) }
        if kept.count != starred.count {
            starred = kept
            saveStarred()
        }
    }

    /// Selects the row of `url`, expanding the folders above it if asked.
    func select(_ url: URL, expanding: Bool = true) {
        guard url.path.hasPrefix(root.url.path + "/") else { return }
        if expanding {
            var parents: [URL] = []
            var parent = url.deletingLastPathComponent()
            while parent.path.count > root.url.path.count {
                parents.append(parent)
                parent = parent.deletingLastPathComponent()
            }
            for folder in parents.reversed() {
                if let node = node(for: folder) { outline.expandItem(node) }
            }
        }
        guard let node = node(for: url) else { return }
        // The file's own row, not its copy under Starred.
        let row = outline.row(forItem: node)
        guard row >= 0, row != outline.selectedRow else { return }
        isSelectingProgrammatically = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        isSelectingProgrammatically = false
    }

    // MARK: Outline

    private func children(of item: Any?) -> [FileNode] {
        guard let node = item as? FileNode else {
            return (starred.isEmpty ? [] : [starredGroup]) + (root.children ?? [])
        }
        if node.children == nil {
            node.reload()
            folders[node.url.path] = node
        }
        return node.children ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isDirectory ?? false }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? FileNode)?.isGroup ?? false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !((item as? FileNode)?.isGroup ?? false) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier(node.isGroup ? "group" : "file")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id, group: node.isGroup)
        if node.isGroup {
            cell.textField?.stringValue = "Starred"
            return cell
        }
        let name = node.url.lastPathComponent
        cell.textField?.stringValue = !node.isDirectory && Files.isMarkdown(node.url) ? node.url.deletingPathExtension().lastPathComponent : name
        cell.textField?.isEditable = node.parent !== starredGroup
        cell.textField?.delegate = self
        let symbol = node.isDirectory ? "folder" : node.parent === starredGroup ? "star" : Tab.symbol(for: node.url)
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, group: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        if group {
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        cell.addSubview(image)
        cell.imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically, let node = outline.item(atRow: outline.selectedRow) as? FileNode else { return }
        if node.isDirectory {
            delegate?.fileTree(self, showFolder: node.url)
        } else {
            let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            delegate?.fileTree(self, open: node.url, inNewTab: newTab)
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            delegate?.fileTree(self, open: node.url, inNewTab: true)
        }
    }

    // MARK: Renaming

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = outline.row(for: field)
        guard let node = outline.item(atRow: row) as? FileNode else { return }
        var name = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let shown = !node.isDirectory && Files.isMarkdown(node.url)
            ? node.url.deletingPathExtension().lastPathComponent : node.url.lastPathComponent
        guard !name.isEmpty, name != shown else {
            field.stringValue = shown
            return
        }
        // A note keeps its extension, which the tree doesn't show.
        if !node.isDirectory && Files.isMarkdown(node.url) { name += "." + node.url.pathExtension }
        let target = node.url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: node.isDirectory)
        move(node.url, to: target)
    }

    /// Moves a file or folder, and tells the window so open tabs follow.
    @discardableResult
    private func move(_ source: URL, to target: URL) -> Bool {
        guard source.path != target.path else { return false }
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            presentError(error)
            folderChanged(source.deletingLastPathComponent())
            return false
        }
        if let index = starred.firstIndex(where: { $0.path == source.path }) {
            starred[index] = target
            saveStarred()
        }
        delegate?.fileTree(self, moved: source, to: target)
        folderChanged(source.deletingLastPathComponent())
        folderChanged(target.deletingLastPathComponent())
        return true
    }

    // MARK: Menu

    private var clickedNode: FileNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? FileNode
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === outline.menu else { return }
        menu.removeAllItems()
        let node = clickedNode.flatMap { $0.isGroup ? nil : $0 }
        func add(_ title: String, _ action: Selector, _ symbol: String) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        add("New Note", #selector(newNote(_:)), "square.and.pencil")
        add("New Folder", #selector(newFolder(_:)), "folder.badge.plus")
        guard let node else { return }
        menu.addItem(.separator())
        if !node.isDirectory {
            add("Open in New Tab", #selector(openInNewTab(_:)), "plus.square.on.square")
            let isStarred = starred.contains { $0.path == node.url.path }
            add(isStarred ? "Remove Star" : "Star", #selector(toggleStar(_:)), isStarred ? "star.slash" : "star")
        }
        if node.parent !== starredGroup { add("Rename…", #selector(rename(_:)), "pencil") }
        add("Reveal in Finder", #selector(revealInFinder(_:)), "finder")
        menu.addItem(.separator())
        add("Move to Trash", #selector(moveToTrash(_:)), "trash")
    }

    /// The folder a menu command acts in: the clicked folder, or the clicked
    /// file's.
    private var clickedFolder: URL {
        guard let node = clickedNode, !node.isGroup, node.parent !== starredGroup else { return workspace.url }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    /// A name in `folder` no file has yet: "Untitled", "Untitled 2", and so on.
    static func freeName(_ base: String, extension ext: String, in folder: URL) -> URL {
        var index = 1
        while true {
            let name = (index == 1 ? base : "\(base) \(index)") + (ext.isEmpty ? "" : "." + ext)
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    /// Creates an empty note in `folder` and opens it.
    @discardableResult
    func createNote(in folder: URL, named name: String = "Untitled", text: String = "") -> URL? {
        let url = Self.freeName(name, extension: "md", in: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentError(error)
            return nil
        }
        folderChanged(folder)
        delegate?.fileTree(self, open: url, inNewTab: false)
        select(url)
        return url
    }

    @objc private func newNote(_ sender: Any?) {
        guard let url = createNote(in: clickedFolder) else { return }
        beginRenaming(url)
    }

    @objc private func newFolder(_ sender: Any?) {
        let url = Self.freeName("New Folder", extension: "", in: clickedFolder)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            presentError(error)
            return
        }
        folderChanged(clickedFolder)
        select(url)
        beginRenaming(url)
    }

    private func beginRenaming(_ url: URL) {
        guard let node = node(for: url) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.scrollRowToVisible(row)
        outline.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func rename(_ sender: Any?) {
        if let node = clickedNode { beginRenaming(node.url) }
    }

    @objc private func openInNewTab(_ sender: Any?) {
        if let node = clickedNode { delegate?.fileTree(self, open: node.url, inNewTab: true) }
    }

    @objc private func toggleStar(_ sender: Any?) {
        guard let node = clickedNode else { return }
        if let index = starred.firstIndex(where: { $0.path == node.url.path }) {
            starred.remove(at: index)
        } else {
            starred.append(node.url)
        }
        saveStarred()
    }

    @objc private func revealInFinder(_ sender: Any?) {
        if let node = clickedNode { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
    }

    @objc private func moveToTrash(_ sender: Any?) {
        guard let node = clickedNode, !node.isGroup else { return }
        trash(node.url)
    }

    /// Moves a file or folder to the Trash, where it can be put back from.
    func trash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            presentError(error)
            return
        }
        delegate?.fileTree(self, removed: url)
        folderChanged(url.deletingLastPathComponent())
    }

    // MARK: Dragging

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, !node.isGroup, node.parent !== starredGroup else { return nil }
        return node.url as NSURL
    }

    /// The folder a drop on `item` lands in.
    private func dropFolder(for item: Any?) -> URL? {
        guard let node = item as? FileNode else { return workspace.url }
        if node.isGroup || node.parent === starredGroup { return nil }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let folder = dropFolder(for: item) else { return [] }
        // The whole folder takes the drop, not a place between its rows.
        let target = (item as? FileNode).flatMap { $0.isDirectory ? $0 : $0.parent }
        outlineView.setDropItem(target === root ? nil : target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let moves = urls.filter { $0.deletingLastPathComponent().path != folder.path && !folder.path.hasPrefix($0.path) }
        guard !moves.isEmpty else { return [] }
        return info.draggingSource as? NSOutlineView === outlineView ? .move : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = dropFolder(for: item) else { return false }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let local = info.draggingSource as? NSOutlineView === outlineView
        var done = false
        for url in urls where url.deletingLastPathComponent().path != folder.path {
            let base = url.deletingPathExtension().lastPathComponent
            let target = Self.freeName(base, extension: url.pathExtension, in: folder)
            if local {
                done = move(url, to: target) || done
            } else if (try? FileManager.default.copyItem(at: url, to: target)) != nil {
                done = true
            }
        }
        folderChanged(folder)
        return done
    }
}
