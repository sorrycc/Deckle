import AppKit
import CQuillCore

/// The window of one workspace: the file tree, the note list, and the tabs
/// with their editors.
final class WindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
    TabStripDelegate, EditorViewDelegate, FileTreeDelegate, NoteListDelegate
{
    let workspace: Workspace
    /// Asks the app for another workspace; nil lets the user choose a folder.
    var onSwitchWorkspace: ((URL?) -> Void)?

    private let split = NSSplitViewController()
    private let tree: FileTreeController
    private let list: NoteListController
    private let pane = EditorPaneController()
    private var treeItem: NSSplitViewItem!
    private var listItem: NSSplitViewItem!

    private(set) var tabs: [Tab] = []
    private(set) var selectedTab: Tab!
    private let tabStrip = TabStripView()
    private lazy var tabStripWidth = tabStrip.widthAnchor.constraint(equalToConstant: 400)
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let newTabButton = NSButton()
    private let newNoteButton = NSButton()
    private let searchButton = NSButton()
    private var wordCountPending = false

    init(workspace url: URL) {
        workspace = Workspace(url: url)
        Debug.mark("workspace opened")
        tree = FileTreeController(workspace: workspace)
        list = NoteListController(workspace: workspace)
        Debug.mark("columns made")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = workspace.name
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 400)
        super.init(window: window)
        window.delegate = self

        tree.delegate = self
        list.delegate = self
        treeItem = NSSplitViewItem(sidebarWithViewController: tree)
        treeItem.minimumThickness = 170
        treeItem.maximumThickness = 380
        listItem = NSSplitViewItem(contentListWithViewController: list)
        listItem.minimumThickness = 220
        listItem.maximumThickness = 440
        let paneItem = NSSplitViewItem(viewController: pane)
        paneItem.minimumThickness = 380
        split.addSplitViewItem(treeItem)
        split.addSplitViewItem(listItem)
        split.addSplitViewItem(paneItem)
        split.splitView.autosaveName = "QuillSplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1240, height: 800))
        Debug.mark("split view set")

        configureControls()
        let toolbar = NSToolbar(identifier: "QuillToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("QuillWindow")
        if !window.setFrameUsingName("QuillWindow") { window.center() }
        Debug.mark("toolbar set")

        workspace.onFolderChange = { [weak self] url in self?.tree.folderChanged(url) }
        workspace.onIndexChange = { [weak self] in
            self?.list.indexChanged()
            self?.updateBacklinks()
        }
        workspace.onFileChange = { [weak self] url in
            self?.tabs.first { $0.url?.path == url.path }?.editor?.reloadFromDisk()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged(_:)), name: .appearanceDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(splitResized(_:)), name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        applyWindowAppearance()
        Debug.mark("window built")
        restoreSession()
        Debug.mark("session restored")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Session

    private func restoreSession() {
        let state = Settings.state(for: workspace.url)
        let paths = (state["tabs"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        for path in paths {
            let tab = makeTab()
            tab.open(URL(fileURLWithPath: path))
            tabs.append(tab)
        }
        if tabs.isEmpty { tabs.append(makeTab()) }
        if let folder = state["folder"] as? String, FileManager.default.fileExists(atPath: folder) {
            list.show(folder: URL(fileURLWithPath: folder, isDirectory: true))
        }
        let selected = state["selected"] as? Int ?? 0
        select(tabs[min(max(0, selected), tabs.count - 1)])
    }

    private func saveSession() {
        var state = Settings.state(for: workspace.url)
        state["tabs"] = tabs.compactMap { $0.url?.path }
        state["selected"] = tabs.firstIndex { $0 === selectedTab } ?? 0
        state["folder"] = list.folder.path
        if tree.isViewLoaded { state["expanded"] = tree.expandedPaths }
        Settings.setState(state, for: workspace.url)
    }

    /// Saves every open file and the session. Called before the window goes.
    func saveAll() {
        tabs.forEach { $0.save() }
        saveSession()
    }

    func windowWillClose(_ notification: Notification) {
        saveAll()
        workspace.close()
    }

    func windowDidResignKey(_ notification: Notification) {
        tabs.forEach { $0.save() }
    }

    func windowDidResize(_ notification: Notification) { fitTabStrip() }
    @objc private func splitResized(_ note: Notification) { fitTabStrip() }

    @objc private func appearanceChanged(_ note: Notification) { applyWindowAppearance() }

    /// A theme with an appearance of its own gives it to the whole window.
    private func applyWindowAppearance() {
        window?.appearance = Theme.current.appearance.flatMap { NSAppearance(named: $0) }
    }

    // MARK: Tabs

    private func makeTab() -> Tab {
        let tab = Tab()
        tab.editorDelegate = self
        return tab
    }

    /// Shows a file: in the tab that has it, in a new tab, or in this one.
    func open(_ url: URL, inNewTab: Bool = false, selecting selection: NSRange? = nil) {
        if let existing = tabs.first(where: { $0.url?.path == url.path }) {
            select(existing)
            if let selection { existing.editor?.reveal(selection) }
            return
        }
        if inNewTab && selectedTab.url != nil {
            let tab = makeTab()
            tabs.insert(tab, at: (tabs.firstIndex { $0 === selectedTab } ?? tabs.count - 1) + 1)
            tab.open(url, selecting: selection)
            select(tab)
        } else {
            selectedTab.open(url, selecting: selection)
            tabChanged()
        }
    }

    private func select(_ tab: Tab) {
        if selectedTab !== tab { selectedTab?.save() }
        selectedTab = tab
        tabChanged()
    }

    /// The selected tab, or what it shows, changed.
    private func tabChanged() {
        CompletionPopup.shared.close()
        tabStrip.update(tabs: tabs, selected: selectedTab)
        pane.show(selectedTab.view)
        backButton.isEnabled = selectedTab.canGoBack
        forwardButton.isEnabled = selectedTab.canGoForward
        window?.title = selectedTab.url.map { _ in "\(selectedTab.displayTitle) — \(workspace.name)" } ?? workspace.name
        if let url = selectedTab.url {
            list.select(url)
            if tree.isViewLoaded { tree.select(url) }
        } else {
            list.select(nil)
        }
        selectedTab.editor?.focus()
        updateStatus()
        updateBacklinks()
        saveSession()
    }

    private func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.save()
        tabs.remove(at: index)
        if tabs.isEmpty { tabs.append(makeTab()) }
        if tab === selectedTab {
            selectedTab = nil
            select(tabs[min(index, tabs.count - 1)])
        } else {
            tabChanged()
        }
    }

    func tabStrip(_ strip: TabStripView, select tab: Tab) { select(tab) }
    func tabStrip(_ strip: TabStripView, close tab: Tab) { close(tab) }
    func tabStripNewTab(_ strip: TabStripView) { newTab(nil) }

    func tabStrip(_ strip: TabStripView, move tab: Tab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.insert(tabs.remove(at: from), at: min(index, tabs.count - 1))
        tabChanged()
    }

    // MARK: Commands

    @objc func newTab(_ sender: Any?) {
        let tab = makeTab()
        tabs.append(tab)
        select(tab)
    }

    @objc func closeTab(_ sender: Any?) {
        // The last empty tab closes the window, as in a browser.
        if tabs.count == 1 && selectedTab.url == nil { return window?.performClose(sender) ?? () }
        close(selectedTab)
    }

    @objc func newNote(_ sender: Any?) {
        let folder = tree.isViewLoaded ? tree.targetFolder : workspace.url
        guard let url = tree.createNote(in: folder, text: "# ") else { return }
        open(url)
        selectedTab.editor?.reveal(NSRange(location: 2, length: 0))
    }

    @objc func saveDocument(_ sender: Any?) { selectedTab.save() }

    @objc func goBack(_ sender: Any?) {
        selectedTab.goBack()
        tabChanged()
    }

    @objc func goForward(_ sender: Any?) {
        selectedTab.goForward()
        tabChanged()
    }

    @objc func selectNextTab(_ sender: Any?) { cycleTab(by: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { cycleTab(by: -1) }

    private func cycleTab(by step: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === selectedTab }) else { return }
        select(tabs[(index + step + tabs.count) % tabs.count])
    }

    /// Cmd+1 to Cmd+8 select a tab by position, and Cmd+9 the last one.
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        if tabs.indices.contains(index) { select(tabs[index]) }
    }

    @objc func toggleNoteList(_ sender: Any?) {
        listItem.animator().isCollapsed.toggle()
    }

    @objc func openFolder(_ sender: Any?) { onSwitchWorkspace?(nil) }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([selectedTab.url ?? workspace.url])
    }

    @objc func zoomIn(_ sender: Any?) { Settings.editorFontSize = min(40, Settings.editorFontSize + 1) }
    @objc func zoomOut(_ sender: Any?) { Settings.editorFontSize = max(9, Settings.editorFontSize - 1) }
    @objc func actualSize(_ sender: Any?) { Settings.editorFontSize = 15 }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return selectedTab.canGoBack
        case #selector(goForward(_:)): return selectedTab.canGoForward
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): return tabs.count > 1
        case #selector(saveDocument(_:)): return selectedTab.editor != nil
        case #selector(goToHeading(_:)): return selectedTab.editor?.isMarkdown == true
        case #selector(toggleNoteList(_:)):
            item.title = listItem.isCollapsed ? "Show Note List" : "Hide Note List"
            return true
        default: return true
        }
    }

    // MARK: Status

    private func updateStatus() {
        guard let editor = selectedTab.editor else { return pane.statusBar.clear() }
        let position = editor.position
        pane.statusBar.show(line: position.line, column: position.column)
        pane.statusBar.show(language: editor.styler.language)
        scheduleWordCount()
    }

    /// Counting words reads the whole text, so typing only asks for it, and
    /// one count follows a burst of edits.
    private func scheduleWordCount() {
        guard !wordCountPending else { return }
        wordCountPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.wordCountPending = false
            if let editor = self.selectedTab.editor { self.pane.statusBar.show(words: editor.core.wordCount) }
        }
    }

    @objc func showBacklinks(_ sender: Any?) {
        guard let url = selectedTab.url else { return }
        let links = workspace.backlinks(to: url)
        guard !links.isEmpty else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = BacklinksController(links: links) { [weak self, weak popover] url, selection in
            popover?.close()
            self?.open(url, selecting: selection)
        }
        popover.show(relativeTo: pane.statusBar.backlinksButton.bounds, of: pane.statusBar.backlinksButton, preferredEdge: .maxY)
    }

    private func updateBacklinks() {
        guard let url = selectedTab?.url, Files.isMarkdown(url) else { return pane.statusBar.show(backlinks: 0) }
        pane.statusBar.show(backlinks: workspace.backlinks(to: url).count)
    }

    // MARK: Editor

    func editorTextDidChange(_ editor: EditorView) {
        guard editor === selectedTab.editor else { return }
        scheduleWordCount()
    }

    func editorSelectionDidChange(_ editor: EditorView) {
        guard editor === selectedTab.editor else { return }
        let position = editor.position
        pane.statusBar.show(line: position.line, column: position.column)
    }

    func editorDidSave(_ editor: EditorView) {}

    func editor(_ editor: EditorView, notesMatching query: String) -> [FileMatch] {
        workspace.findFiles(query, limit: 30, notesOnly: true).filter { $0.path != editor.url.path }
    }

    func editor(_ editor: EditorView, follow link: EditorLink, inNewTab: Bool) {
        switch link {
        case .footnote(let label):
            editor.jumpToFootnote(label)
        case .wiki(let target):
            if let url = workspace.resolveLink(target, from: editor.url) {
                open(url, inNewTab: inNewTab)
            } else {
                // A link to a note that doesn't exist yet makes it.
                let name = target.split(separator: "#").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? target
                guard !name.isEmpty else { return }
                let folder = editor.url.deletingLastPathComponent()
                if let url = tree.createNote(in: folder, named: name.replacingOccurrences(of: "/", with: "-"), text: "# \(name)\n\n") {
                    open(url, inNewTab: inNewTab)
                }
            }
        case .destination(let destination):
            if destination.hasPrefix("#") {
                let slug = String(destination.dropFirst()).lowercased()
                if let heading = editor.headings.first(where: { WindowController.slug($0.title) == slug }) {
                    editor.reveal(NSRange(location: heading.range.location, length: 0))
                }
                return
            }
            if let url = URL(string: destination), let scheme = url.scheme, scheme.count > 1 {
                NSWorkspace.shared.open(url)
                return
            }
            let path = destination.split(separator: "#").first.map(String.init) ?? destination
            let decoded = path.removingPercentEncoding ?? path
            let url = URL(fileURLWithPath: decoded, relativeTo: editor.url.deletingLastPathComponent()).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { open(url, inNewTab: inNewTab) }
        }
    }

    /// A heading as a link's fragment names it.
    static func slug(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }.replacingOccurrences(of: " ", with: "-")
    }

    // MARK: Tree and list

    func fileTree(_ tree: FileTreeController, open url: URL, inNewTab: Bool) { open(url, inNewTab: inNewTab) }

    func fileTree(_ tree: FileTreeController, showFolder url: URL) {
        list.show(folder: url)
        if listItem.isCollapsed { listItem.animator().isCollapsed = false }
        saveSession()
    }

    func fileTree(_ tree: FileTreeController, moved old: URL, to new: URL) {
        tabs.forEach { $0.fileMoved(from: old, to: new) }
        tabChanged()
    }

    func fileTree(_ tree: FileTreeController, removed url: URL) {
        for tab in tabs { _ = tab.fileRemoved(url) }
        tabChanged()
    }

    func fileTreeSwitchWorkspace(_ tree: FileTreeController, to url: URL?) { onSwitchWorkspace?(url) }

    func noteList(_ list: NoteListController, open url: URL, inNewTab: Bool) { open(url, inNewTab: inNewTab) }
    func noteList(_ list: NoteListController, trash url: URL) { tree.trash(url) }

    // MARK: Toolbar

    private enum Item {
        static let newNote = NSToolbarItem.Identifier("newNote")
        static let listSeparator = NSToolbarItem.Identifier("listSeparator")
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let tabs = NSToolbarItem.Identifier("tabs")
        static let newTab = NSToolbarItem.Identifier("newTab")
        static let search = NSToolbarItem.Identifier("search")
    }

    private func configureControls() {
        for (button, name, tip, action) in [
            (backButton, "chevron.left", "Back", #selector(goBack(_:))),
            (forwardButton, "chevron.right", "Forward", #selector(goForward(_:))),
            (newTabButton, "plus", "New Tab", #selector(newTab(_:))),
            (newNoteButton, "square.and.pencil", "New Note", #selector(newNote(_:))),
            (searchButton, "magnifyingglass", "Search Notes", #selector(searchNotes(_:))),
        ] {
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: tip)
            button.toolTip = tip
            button.bezelStyle = .toolbar
            button.target = self
            button.action = action
        }
        pane.loadViewIfNeeded()
        pane.statusBar.backlinksButton.target = self
        pane.statusBar.backlinksButton.action = #selector(showBacklinks(_:))
        tabStrip.delegate = self
        tabStripWidth.isActive = true
        tabStrip.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    /// Gives the tabs the room the editor's column leaves them.
    private func fitTabStrip() {
        guard pane.isViewLoaded else { return }
        tabStripWidth.constant = max(140, pane.view.frame.width - 250)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Item.newNote, Item.listSeparator, Item.back,
            Item.forward, Item.tabs, Item.newTab, .flexibleSpace, Item.search,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if id == Item.listSeparator {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 1)
        }
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Item.newNote: item.view = newNoteButton; item.label = "New Note"
        case Item.back: item.view = backButton; item.label = "Back"
        case Item.forward: item.view = forwardButton; item.label = "Forward"
        case Item.newTab: item.view = newTabButton; item.label = "New Tab"
        case Item.search: item.view = searchButton; item.label = "Search"
        case Item.tabs:
            item.view = tabStrip
            item.label = "Tabs"
            fitTabStrip()
        default: return nil
        }
        return item
    }

    // MARK: Panels

    private lazy var palette = Palette(controller: self)

    @objc func quickOpen(_ sender: Any?) { palette.show(.files) }
    @objc func searchNotes(_ sender: Any?) {
        // The selected text is what to look for, when there is some.
        let selected = selectedTab.editor.map { ($0.text as NSString).substring(with: $0.textView.selectedRange()) } ?? ""
        palette.show(.search, query: selected.contains("\n") ? "" : selected)
    }
    @objc func showCommands(_ sender: Any?) { palette.show(.commands) }
    @objc func goToHeading(_ sender: Any?) { palette.show(.headings) }

    func debugPalette(_ mode: Palette.Mode, query: String) { palette.show(mode, query: query) }
}
