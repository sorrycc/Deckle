import AppKit
import CDeckleCore

/// The window of one workspace: the file tree, the note list, and the tabs
/// with their editors.
final class WindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
    TabStripDelegate, EditorViewDelegate, FileTreeDelegate, NoteListDelegate
{
    let workspace: Workspace
    /// Asks the app for another workspace; nil lets the user choose a folder.
    var onSwitchWorkspace: ((URL?) -> Void)?
    /// The window was closed.
    var onClose: (() -> Void)?
    /// Tabs closed in this window, newest last, to bring back with ⇧⌘T.
    private var closedTabs: [(url: URL, selection: NSRange, scroll: CGFloat?, index: Int)] = []
    private var positionSavePending = false

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
        // The first window fits the screen it opens on. Laid out wider and
        // then squeezed to fit, the split view would fold the sidebar away
        // before the window is ever seen, and the autosave would keep that.
        let room = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1240, height: 800)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: min(1240, room.width - 24), height: min(800, room.height - 60)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = workspace.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
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
        split.splitView.autosaveName = "DeckleSplit"
        // Where the window was last: known before its columns are laid out,
        // so they are laid out once, at their final size.
        window.setFrameAutosaveName("DeckleWindow")
        if !window.setFrameUsingName("DeckleWindow") { window.center() }
        // The split view is laid out at the window's own size before it
        // becomes the content view: from a zero frame, the first layout
        // would find no room for three columns.
        let content = window.contentRect(forFrameRect: window.frame)
        split.view.frame = NSRect(origin: .zero, size: content.size)
        let firstLayout = Settings.defaults.object(forKey: "NSSplitView Subview Frames DeckleSplit") == nil
        window.contentViewController = split
        window.setContentSize(content.size)
        // The first window: columns of a comfortable width, until the user's
        // own are saved. The dividers are placed once the split view has
        // laid its columns out; a frame set before that is overruled.
        if firstLayout {
            split.view.layoutSubtreeIfNeeded()
            let divider = split.splitView.dividerThickness
            split.splitView.setPosition(220, ofDividerAt: 0)
            split.splitView.setPosition(220 + divider + 300, ofDividerAt: 1)
        }
        Debug.mark("split view set")

        configureControls()
        let toolbar = NSToolbar(identifier: "DeckleToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        Debug.mark("toolbar set")

        workspace.onFolderChange = { [weak self] url in self?.tree.folderChanged(url) }
        workspace.onIndexChange = { [weak self] in
            self?.list.indexChanged()
            self?.updateBacklinks()
        }
        workspace.onFileChange = { [weak self] url in
            // Every tab that shows it: one note can be open in two.
            self?.tabs.filter { $0.url?.path == url.path }.forEach { $0.loadedEditor?.reloadFromDisk() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(splitResized(_:)), name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        // The editor's column itself says when it takes a new width. A
        // window that opens with its saved layout is never resized, and
        // the tabs would keep the narrow strip they were made with.
        pane.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(splitResized(_:)), name: NSView.frameDidChangeNotification, object: pane.view)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)), name: .appearanceDidChange, object: nil)
        applyTheme()
        Debug.mark("window built")
        restoreSession()
        Debug.mark("session restored")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Session

    private func restoreSession() {
        let state = Settings.state(for: workspace.url)
        let paths = (state["tabs"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        // Where each note was left: its insertion point and scroll position.
        let positions = state["positions"] as? [String: [String: Double]] ?? [:]
        for path in paths {
            let tab = makeTab()
            // A note with no saved place opens as a fresh one does, past its
            // front matter, rather than at the very start.
            let position = positions[path]
            let selection = position.map { NSRange(location: Int($0["location"] ?? 0), length: Int($0["length"] ?? 0)) }
            // Read when first shown: only the selected tab costs at launch.
            tab.restore(URL(fileURLWithPath: path), selecting: selection, scrolledTo: position?["scroll"].map { CGFloat($0) })
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
        var positions: [String: [String: Double]] = [:]
        for tab in tabs {
            guard let url = tab.url else { continue }
            let position = tab.position
            var entry: [String: Double] = ["location": Double(position.selection.location), "length": Double(position.selection.length)]
            if let scroll = position.scroll { entry["scroll"] = Double(scroll) }
            positions[url.path] = entry
        }
        state["positions"] = positions
        Settings.setState(state, for: workspace.url)
    }

    /// Remembers where the insertion point is once a burst of moves settles,
    /// so a crash or a force quit loses no place.
    private func savePositionLater() {
        guard !positionSavePending else { return }
        positionSavePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.positionSavePending = false
            self?.saveSession()
        }
    }

    /// Whether to animate, which Reduce Motion turns off.
    static var animates: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func setListCollapsed(_ collapsed: Bool) {
        (Self.animates ? listItem.animator() : listItem).isCollapsed = collapsed
    }

    /// Saves every open file and the session. Called before the window goes.
    func saveAll() {
        tabs.forEach { $0.save() }
        saveSession()
    }

    /// Whether every note is saved, or the user agreed to what isn't: asked
    /// before the window closes, the workspace changes or the app quits.
    func canClose() -> Bool { tabs.allSatisfy { $0.canClose() } }

    func windowShouldClose(_ sender: NSWindow) -> Bool { canClose() }

    func windowWillClose(_ notification: Notification) {
        saveAll()
        workspace.close()
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        tabs.forEach { $0.save() }
    }

    func windowDidResize(_ notification: Notification) { fitTabStrip() }
    @objc private func splitResized(_ note: Notification) { fitTabStrip() }
    @objc private func themeChanged(_ note: Notification) { applyTheme() }

    /// The window's chrome takes the theme's colors too: the note list and
    /// the title bar over it sit on the page's color, a shade apart, so a
    /// warm or a dark page isn't framed in the system's grey.
    private func applyTheme() {
        let theme = Theme.current
        guard theme.appearance != nil else {
            window?.backgroundColor = .windowBackgroundColor
            return
        }
        window?.backgroundColor = theme.background.blended(withFraction: 0.035, of: theme.text) ?? theme.background
    }

    // MARK: Tabs

    private func makeTab() -> Tab {
        let tab = Tab()
        tab.editorDelegate = self
        return tab
    }

    /// Shows a file: in the tab that has it, in a new tab, or in this one.
    /// The editor takes the keyboard unless `focusEditor` is false, as when
    /// a list is being arrowed through.
    func open(_ url: URL, inNewTab: Bool = false, selecting selection: NSRange? = nil, focusEditor: Bool = true) {
        if let existing = tabs.first(where: { $0.url?.path == url.path }) {
            select(existing, focusEditor: focusEditor)
            if let selection { existing.editor?.reveal(selection) }
            return
        }
        if inNewTab && selectedTab.url != nil {
            let tab = makeTab()
            tabs.insert(tab, at: (tabs.firstIndex { $0 === selectedTab } ?? tabs.count - 1) + 1)
            tab.open(url, selecting: selection)
            select(tab, focusEditor: focusEditor)
        } else {
            selectedTab.open(url, selecting: selection)
            tabChanged(focusEditor: focusEditor)
        }
    }

    private func select(_ tab: Tab, focusEditor: Bool = true) {
        if selectedTab !== tab { selectedTab?.save() }
        selectedTab = tab
        tabChanged(focusEditor: focusEditor)
    }

    /// Puts the keyboard in the editor, from a list.
    func focusEditor() {
        selectedTab.editor?.focus()
    }

    @objc func focusEditorCommand(_ sender: Any?) { focusEditor() }

    /// Puts the keyboard in the note list, or the tree when the list is away.
    @objc func focusList(_ sender: Any?) {
        if !listItem.isCollapsed, list.isViewLoaded {
            list.focus()
        } else if !treeItem.isCollapsed, tree.isViewLoaded {
            tree.focus()
        }
    }

    /// The selected tab, or what it shows, changed.
    private func tabChanged(focusEditor: Bool = true) {
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
            // No note to point at: the tree marks the folder the list shows.
            if tree.isViewLoaded { tree.select(list.folder) }
        }
        if focusEditor { selectedTab.editor?.focus() }
        updateStatus()
        updateBacklinks()
        saveSession()
    }

    private func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }), tab.canClose() else { return }
        if let url = tab.url {
            let position = tab.position
            closedTabs.append((url, position.selection, position.scroll, index))
            if closedTabs.count > 20 { closedTabs.removeFirst() }
        }
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

    func tabStrip(_ strip: TabStripView, closeOthers tab: Tab) {
        for other in tabs where other !== tab { close(other) }
    }

    func tabStrip(_ strip: TabStripView, closeAfter tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        for other in tabs[(index + 1)...].reversed() { close(other) }
    }

    func tabStrip(_ strip: TabStripView, move tab: Tab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let moved = tabs.remove(at: from)
        tabs.insert(moved, at: min(index, tabs.count))
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

    /// Brings back the tab closed last, where it was.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let closed = closedTabs.popLast() else { return }
        if let existing = tabs.first(where: { $0.url?.path == closed.url.path }) { return select(existing) }
        let tab = makeTab()
        tab.open(closed.url, selecting: closed.selection, scrolledTo: closed.scroll)
        tabs.insert(tab, at: min(closed.index, tabs.count))
        select(tab)
    }

    /// File > Move to Trash: the note shown, or what a list has selected.
    @objc func moveToTrash(_ sender: Any?) {
        if let responder = window?.firstResponder as? NSView {
            if tree.isViewLoaded, responder.isDescendant(of: tree.view), let url = tree.selectedURL { return tree.trash(url) }
            if list.isViewLoaded, responder.isDescendant(of: list.view), let url = list.selectedURL { return tree.trash(url) }
        }
        guard let url = selectedTab.url else { return }
        tree.trash(url)
    }

    @objc func newNote(_ sender: Any?) {
        let folder = tree.isViewLoaded ? tree.targetFolder : workspace.url
        guard let url = tree.createNote(in: folder, text: "# ", opens: false) else { return }
        open(url)
        // Unless the tab stayed with a note it couldn't save.
        if selectedTab.url?.path == url.path { selectedTab.editor?.reveal(NSRange(location: 2, length: 0)) }
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
        setListCollapsed(!listItem.isCollapsed)
    }

    @objc func openFolder(_ sender: Any?) { onSwitchWorkspace?(nil) }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([selectedTab.url ?? workspace.url])
    }

    // MARK: Printing

    /// Paper settings for a note: the column scaled to the page's width,
    /// with an inch of margin.
    private func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        return info
    }

    /// Runs a print operation over the editor as it is drawn, without the
    /// room it keeps after its last line.
    private func withPrintableEditor(_ work: (EditorView) -> Void) {
        guard let editor = selectedTab.editor else { return }
        let pastEnd = editor.textView.pastEnd
        editor.textView.pastEnd = 0
        editor.textView.layoutSubtreeIfNeeded()
        work(editor)
        editor.textView.pastEnd = pastEnd
    }

    @objc func printDocument(_ sender: Any?) {
        withPrintableEditor { editor in
            let operation = NSPrintOperation(view: editor.textView, printInfo: printInfo())
            operation.jobTitle = selectedTab.displayTitle
            operation.run()
        }
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let window, selectedTab.editor != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = selectedTab.displayTitle + ".pdf"
        panel.directoryURL = selectedTab.url?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.writePDF(to: url) }
        }
    }

    /// Writes the note as it is drawn to a PDF at `url`, paged as a print
    /// would be.
    func writePDF(to url: URL) {
        withPrintableEditor { editor in
            let info = printInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let operation = NSPrintOperation(view: editor.textView, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.jobTitle = selectedTab.displayTitle
            operation.run()
        }
    }

    @objc func zoomIn(_ sender: Any?) { Settings.editorFontSize = min(40, Settings.editorFontSize + 1) }
    @objc func zoomOut(_ sender: Any?) { Settings.editorFontSize = max(9, Settings.editorFontSize - 1) }
    @objc func actualSize(_ sender: Any?) { Settings.editorFontSize = 15 }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return selectedTab.canGoBack
        case #selector(goForward(_:)): return selectedTab.canGoForward
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): return tabs.count > 1
        case #selector(saveDocument(_:)), #selector(printDocument(_:)), #selector(exportPDF(_:)): return selectedTab.editor != nil
        case #selector(reopenClosedTab(_:)): return !closedTabs.isEmpty
        case #selector(moveToTrash(_:)):
            if let responder = window?.firstResponder as? NSView {
                if tree.isViewLoaded, responder.isDescendant(of: tree.view) { return tree.selectedURL != nil }
                if list.isViewLoaded, responder.isDescendant(of: list.view) { return list.selectedURL != nil }
            }
            return selectedTab.url.map { !$0.path.hasPrefix(Bundle.main.bundlePath) } ?? false
        case #selector(goToHeading(_:)): return selectedTab.editor?.isMarkdown == true
        case #selector(toggleNoteList(_:)):
            item.title = listItem.isCollapsed ? "Show Note List" : "Hide Note List"
            return true
        default: return true
        }
    }

    // MARK: Status

    private func updateStatus() {
        guard let editor = selectedTab.editor else {
            pane.statusBar.clear()
            if let preview = selectedTab.view as? ImagePreview, preview.pixelSize.width > 0 {
                pane.statusBar.show(note: "\(Int(preview.pixelSize.width)) × \(Int(preview.pixelSize.height)) px")
            }
            return
        }
        let position = editor.position
        pane.statusBar.show(line: position.line, column: position.column)
        pane.statusBar.show(language: editor.isMarkdown ? nil : editor.styler.language)
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
        popover.appearance = window?.appearance
        popover.contentViewController = BacklinksController(links: links) { [weak self, weak popover] url, selection in
            popover?.close()
            self?.open(url, selecting: selection)
        }
        popover.show(relativeTo: pane.statusBar.backlinksButton.bounds, of: pane.statusBar.backlinksButton, preferredEdge: .maxY)
    }

    private func updateBacklinks() {
        guard let url = selectedTab?.url, Files.isMarkdown(url) else { return pane.statusBar.show(backlinks: 0) }
        pane.statusBar.show(backlinks: workspace.backlinkCount(to: url))
    }

    // MARK: Editor

    func editorTextDidChange(_ editor: EditorView) {
        guard editor === selectedTab?.editor else { return }
        scheduleWordCount()
    }

    func editorSelectionDidChange(_ editor: EditorView) {
        // Tabs restored at launch set their selection before one is selected.
        guard editor === selectedTab?.editor else { return }
        let position = editor.position
        pane.statusBar.show(line: position.line, column: position.column)
        savePositionLater()
    }

    func editorDidSave(_ editor: EditorView) {}

    func editor(_ editor: EditorView, notesMatching query: String, done: @escaping @MainActor ([FileMatch]) -> Void) {
        let path = editor.url.path
        workspace.findFiles(query, limit: 30, notesOnly: true) { matches in done(matches.filter { $0.path != path }) }
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
                if let url = tree.createNote(in: folder, named: name.replacingOccurrences(of: "/", with: "-"), text: "# \(name)\n\n", opens: false) {
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

    func fileTree(_ tree: FileTreeController, open url: URL, inNewTab: Bool, focus: Bool) {
        open(url, inNewTab: inNewTab, focusEditor: focus)
    }

    func fileTree(_ tree: FileTreeController, showFolder url: URL) {
        list.show(folder: url)
        if listItem.isCollapsed { setListCollapsed(false) }
        saveSession()
    }

    func fileTree(_ tree: FileTreeController, moved old: URL, to new: URL) {
        tabs.forEach { $0.fileMoved(from: old, to: new) }
        // The tabs closed before and the folder the list shows follow too.
        for index in closedTabs.indices {
            if let url = Self.moved(closedTabs[index].url, from: old, to: new) { closedTabs[index].url = url }
        }
        if let folder = Self.moved(list.folder, from: old, to: new) { list.show(folder: folder) }
        tabChanged(focusEditor: editorHasKeyboard)
    }

    func fileTree(_ tree: FileTreeController, shouldRemove url: URL) -> Bool {
        // What was typed in the last moment goes to the file before it
        // goes to the Trash, so Undo brings all of it back. Edits that
        // can't be written are asked about first.
        tabs.filter { $0.url.map { Self.isAt($0, orUnder: url) } ?? false }.allSatisfy { $0.canClose() }
    }

    func fileTree(_ tree: FileTreeController, removed url: URL) {
        // The keyboard stays where it was: in a list, the next ⌘⌫ trashes
        // the next note rather than deleting text in the one now shown.
        let focus = editorHasKeyboard
        for tab in tabs { _ = tab.fileRemoved(url) }
        closedTabs.removeAll { Self.isAt($0.url, orUnder: url) }
        if Self.isAt(list.folder, orUnder: url) { list.show(folder: workspace.url) }
        tabChanged(focusEditor: focus)
    }

    /// Whether the keyboard is in the editor's pane, or nowhere in particular.
    private var editorHasKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return true }
        if tree.isViewLoaded, responder.isDescendant(of: tree.view) { return false }
        if list.isViewLoaded, responder.isDescendant(of: list.view) { return false }
        return true
    }

    private static func isAt(_ url: URL, orUnder folder: URL) -> Bool {
        url.path == folder.path || url.path.hasPrefix(folder.path + "/")
    }

    /// Where `url` is after `old` moved to `new`, if it was at or under it.
    private static func moved(_ url: URL, from old: URL, to new: URL) -> URL? {
        if url.path == old.path { return new }
        guard url.path.hasPrefix(old.path + "/") else { return nil }
        return new.appendingPathComponent(String(url.path.dropFirst(old.path.count + 1)))
    }

    func fileTreeSwitchWorkspace(_ tree: FileTreeController, to url: URL?) { onSwitchWorkspace?(url) }

    func noteList(_ list: NoteListController, open url: URL, inNewTab: Bool, focus: Bool) {
        open(url, inNewTab: inNewTab, focusEditor: focus)
    }
    func noteList(_ list: NoteListController, trash url: URL) { tree.trash(url) }
    func noteListFocusEditor(_ list: NoteListController) { focusEditor() }
    func fileTreeFocusEditor(_ tree: FileTreeController) { focusEditor() }

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
        tabStripWidth.constant = max(140, pane.view.frame.width - 160)
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
