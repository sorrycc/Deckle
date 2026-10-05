import AppKit
import CDeckleCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowController: WindowController?
    /// Files and folders handed over before the app finished launching.
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Debug.mark("did finish launching")
        // Deckle has tabs of its own. This keeps the system's Show Tab Bar and
        // Show All Tabs out of the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        // A theme with an appearance of its own gives it to the whole app:
        // every window, panel, sheet, alert and menu.
        applyAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged(_:)), name: .appearanceDidChange, object: nil)
        NSApp.mainMenu = MainMenu.build()
        launched = true

        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "workspace") {
            // A launch argument, which leaves the remembered workspace alone.
            openWorkspace(URL(fileURLWithPath: path, isDirectory: true), remember: false)
        } else if !pendingURLs.isEmpty {
            pendingURLs.forEach(open)
            pendingURLs = []
        } else if let last = Settings.lastWorkspace, FileManager.default.fileExists(atPath: last.path) {
            openWorkspace(last)
        } else {
            showWelcome()
        }
        if defaults.bool(forKey: "welcome") { showWelcome() }
        Debug.mark("workspace window")
        if let path = defaults.string(forKey: "open") { windowController?.open(URL(fileURLWithPath: path)) }
        Debug.mark("opened file")
        NSApp.activate()
        Debug.runLaunchArguments(windowController)
    }

    @objc private func appearanceChanged(_ note: Notification) { applyAppearance() }

    private func applyAppearance() {
        NSApp.appearance = Theme.current.appearance.flatMap { NSAppearance(named: $0) }
    }

    /// Closing the last window leaves the app running, as Xcode and Finder
    /// do: the Dock icon or the Welcome window brings a workspace back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A click on the Dock icon with no window up reopens the workspace, or
    /// offers one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        if let controller = windowController {
            controller.showWindow(nil)
        } else {
            showWelcome()
        }
        return false
    }

    /// A note whose edits can't be saved keeps the app open until the user
    /// has said what to do with them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowController?.canClose() ?? true ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.saveAll()
    }

    /// The Dock's menu lists the workspaces opened before.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for url in Settings.recentWorkspaces.prefix(8) where FileManager.default.fileExists(atPath: url.path) {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
        }
        return menu
    }

    func applicationWillResignActive(_ notification: Notification) {
        windowController?.tabs.forEach { $0.save() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { return pendingURLs.append(contentsOf: urls) }
        urls.forEach(open)
    }

    /// Opens a folder as the workspace. A file opens in a new tab of the
    /// workspace window, wherever it lives, and leaves the workspace as it is.
    private func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue { return openWorkspace(url) }
        let file = url.resolvingSymlinksInPath()
        welcomeController?.close()
        if windowController == nil {
            if let last = Settings.lastWorkspace, FileManager.default.fileExists(atPath: last.path) {
                openWorkspace(last)
            } else {
                // No workspace to open it in: the file's folder, not
                // remembered, so the next launch doesn't come back to it.
                openWorkspace(file.deletingLastPathComponent(), remember: false)
            }
        }
        windowController?.showWindow(nil)
        windowController?.open(file, inNewTab: true)
    }

    func openWorkspace(_ url: URL, remember: Bool = true) {
        welcomeController?.close()
        if let current = windowController {
            if current.workspace.url.path == url.resolvingSymlinksInPath().path { return current.showWindow(nil) }
            guard current.canClose() else { return }
            windowController = nil
            current.close()
        }
        let controller = WindowController(workspace: url)
        controller.onSwitchWorkspace = { [weak self] url in
            if let url { self?.openWorkspace(url) } else { self?.chooseWorkspace() }
        }
        // The window closed by hand: the Welcome window offers another.
        controller.onClose = { [weak self, weak controller] in
            guard let self, self.windowController === controller else { return }
            self.windowController = nil
            self.showWelcome()
        }
        windowController = controller
        controller.showWindow(nil)
        if remember { Settings.noteOpened(workspace: controller.workspace.url) }
    }

    /// Asks for a folder to open as the workspace, or a file to open in a tab.
    @objc func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a folder of notes to open as the workspace, or a file to open in a tab."
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        } else if windowController == nil {
            showWelcome()
        }
    }

    @objc func openFolder(_ sender: Any?) { chooseWorkspace() }

    /// Help > Deckle Help: the usage guide, in a tab of its own, read-only.
    @objc func showHelp(_ sender: Any?) {
        guard let url = Bundle.main.url(forResource: "Deckle Help", withExtension: "md") else { return }
        if let controller = windowController {
            controller.showWindow(nil)
            controller.open(url, inNewTab: true)
        } else if let last = Settings.lastWorkspace, FileManager.default.fileExists(atPath: last.path) {
            openWorkspace(last)
            windowController?.open(url, inNewTab: true)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// The About panel, with what Deckle is and whose work it carries.
    @objc func showAbout(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let credits = NSMutableAttributedString(
            string: "A fast, native Markdown editor.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        credits.append(NSAttributedString(
            string: "Math by KaTeX, diagrams by Mermaid, and Chinese type by LXGW WenKai Lite.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]))
        // The build number says nothing the version doesn't.
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .version: ""])
    }

    @objc func showMarkdownReference(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://commonmark.org/help/")!)
    }

    @objc func showWelcomeWindow(_ sender: Any?) { showWelcome() }

    private var welcomeController: WelcomeWindowController?

    /// The window for when there is no workspace: a button to choose a folder
    /// and the folders opened before.
    func showWelcome() {
        let controller = welcomeController ?? WelcomeWindowController()
        welcomeController = controller
        controller.onOpen = { [weak self] url in
            if let url { self?.open(url) } else { self?.chooseWorkspace() }
        }
        controller.showWindow(nil)
    }

    /// File > Open Recent lists the workspaces opened before.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = windowController?.workspace.url.path
        let recents = Settings.recentWorkspaces.filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in recents {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.state = url.path == current ? .on : .off
        }
        if recents.isEmpty {
            menu.addItem(withTitle: "No Recent Workspaces", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(.separator())
            let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecents(_:)), keyEquivalent: "")
            clear.target = self
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openWorkspace(url) }
    }

    @objc private func clearRecents(_ sender: Any?) {
        Settings.recentWorkspaces = windowController.map { [$0.workspace.url] } ?? []
        welcomeController?.reload()
    }

    private(set) var settingsController: SettingsWindowController?

    @objc func showSettings(_ sender: Any?) {
        let controller = settingsController ?? SettingsWindowController()
        settingsController = controller
        controller.showWindow(sender)
    }
}

extension Debug {
    /// Types into the middle of the open file, timing the edit, the restyle
    /// and the drawing of each keystroke on the main thread.
    static func benchmark(_ controller: WindowController, characters: Int) {
        guard let editor = controller.selectedTab.editor else { return NSApp.terminate(nil) }
        let middle = (editor.text as NSString).length / 2
        let line = (editor.text as NSString).lineRange(for: NSRange(location: middle, length: 0))
        editor.reveal(NSRange(location: line.location, length: 0))
        editor.window?.displayIfNeeded()
        var times: [Double] = []
        let letters = Array("the quick brown fox **jumps** over the `lazy` dog. ")
        for i in 0..<characters {
            let start = CACurrentMediaTime()
            editor.textView.insertText(String(letters[i % letters.count]), replacementRange: editor.textView.selectedRange())
            editor.window?.displayIfNeeded()
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        let sorted = times.sorted()
        let report = String(format: "%d keystrokes in %d units: median %.2f ms, p95 %.2f ms, max %.2f ms\n",
            characters, (editor.text as NSString).length, sorted[sorted.count / 2], sorted[sorted.count * 95 / 100], sorted.last ?? 0)
        FileHandle.standardError.write(report.data(using: .utf8)!)
        // Leaves the file as it was.
        editor.replace(NSRange(location: 0, length: (editor.text as NSString).length), with: Files.readText(editor.url) ?? editor.text)
        NSApp.terminate(nil)
    }

    /// Pages through the open note from the top, laying out and drawing each
    /// page as a reader scrolling would, and prints how long the pages took.
    static func scrollBenchmark(_ controller: WindowController, pages: Int) {
        guard let editor = controller.selectedTab.editor else { return NSApp.terminate(nil) }
        let clip = editor.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -editor.scrollView.contentInsets.top))
        editor.scrollView.reflectScrolledClipView(clip)
        editor.window?.displayIfNeeded()
        var times: [Double] = []
        var y = clip.bounds.origin.y
        let step = clip.bounds.height
        for _ in 0..<pages {
            y += step
            let end = editor.textView.frame.height - clip.bounds.height
            if y > end { break }
            let start = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y))
            editor.scrollView.reflectScrolledClipView(clip)
            editor.window?.displayIfNeeded()
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        let sorted = times.sorted()
        let report = sorted.isEmpty ? "nothing to scroll\n" : String(
            format: "%d pages in %d units: median %.2f ms, p95 %.2f ms, max %.2f ms\n",
            sorted.count, (editor.text as NSString).length, sorted[sorted.count / 2], sorted[sorted.count * 95 / 100], sorted.last ?? 0)
        FileHandle.standardError.write(report.data(using: .utf8)!)
        NSApp.terminate(nil)
    }
}

/// Launch arguments for trying the app from a script:
///   -workspace <folder>   open this folder, without remembering it
///   -open <file>          open this file in a tab
///   -select <loc,len>     select this range of the open file
///   -scroll <fraction>    scroll this far down the open file, from 0 to 1
///   -type <text>          type this text at the selection
///   -run <command>        run the menu command with this title
///   -exportPDF <path>     write the open note as a PDF there
///   -settings YES         open the Settings window, pictured as a panel
///   -welcome YES          open the Welcome window
///   -snapshot <png>       write a picture of the window there, and quit
///   -timing YES           print how long launching and indexing took
///   -benchmark <n>        type n characters in the open file, print the
///                         time each took to lay out and draw, and quit
///   -scrollBenchmark <n>  page n times down the open file, print the time
///                         each page took to lay out and draw, and quit
@MainActor
enum Debug {
    /// Prints how long after launch a step finished, with -timing.
    static func mark(_ step: String) {
        guard UserDefaults.standard.bool(forKey: "timing") else { return }
        let elapsed = Date().timeIntervalSince(processStart)
        FileHandle.standardError.write("\(step): \(Int(elapsed * 1000)) ms\n".data(using: .utf8)!)
    }

    /// When the process started, from the kernel.
    static var processStart: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&name, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// Runs the menu command titled `title`, as choosing it would, from
    /// where the keyboard is in the workspace window.
    private static func run(menuItem title: String, in controller: WindowController) {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title == title, item.action != nil, item.submenu == nil { return item }
                if let found = find(item.submenu) { return found }
            }
            return nil
        }
        guard let item = find(NSApp.mainMenu), let action = item.action else { return }
        if let target = item.target {
            NSApp.sendAction(action, to: target, from: item)
        } else if controller.window?.firstResponder?.tryToPerform(action, with: item) != true {
            NSApp.sendAction(action, to: nil, from: item)
        }
    }

    static func runLaunchArguments(_ controller: WindowController?) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "timing"), let controller {
            DispatchQueue.main.async {
                let shown = Date().timeIntervalSince(processStart)
                FileHandle.standardError.write("window shown \(Int(shown * 1000)) ms after launch\n".data(using: .utf8)!)
            }
            var events = 0
            let previous = controller.workspace.onIndexChange
            controller.workspace.onIndexChange = {
                previous?()
                events += 1
                let elapsed = Date().timeIntervalSince(processStart)
                FileHandle.standardError.write("index event \(events) at \(Int(elapsed * 1000)) ms\n".data(using: .utf8)!)
            }
        }
        if let count = defaults.object(forKey: "benchmark") as? String, let n = Int(count), let controller {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { benchmark(controller, characters: n) }
            return
        }
        if let count = defaults.object(forKey: "scrollBenchmark") as? String, let n = Int(count), let controller {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { scrollBenchmark(controller, pages: n) }
            return
        }
        // A snapshot or a PDF: the window is shown, acted on, pictured, and
        // the app quits.
        let snapshot = defaults.string(forKey: "snapshot")
        guard let controller, snapshot != nil || defaults.string(forKey: "exportPDF") != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let editor = controller.selectedTab.editor {
                if let select = defaults.string(forKey: "select") {
                    let parts = select.split(separator: ",").compactMap { Int($0) }
                    if parts.count == 2 { editor.reveal(NSRange(location: parts[0], length: parts[1])) }
                }
                if defaults.object(forKey: "scroll") != nil {
                    let fraction = defaults.double(forKey: "scroll")
                    if fraction >= 1 {
                        editor.textView.scrollToEndOfDocument(nil)
                    } else {
                        let height = editor.textView.frame.height - editor.scrollView.contentView.bounds.height
                        editor.textView.scroll(NSPoint(x: 0, y: max(0, height * fraction)))
                    }
                }
                if let text = defaults.string(forKey: "type") {
                    editor.textView.insertText(text.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: editor.textView.selectedRange())
                }
                if let title = defaults.string(forKey: "run") { run(menuItem: title, in: controller) }
                if let hover = defaults.string(forKey: "hover"), let index = Int(hover) {
                    // The pointer over a character, with ⌘ held if asked.
                    let rect = editor.textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
                    let point = editor.textView.convert(editor.textView.window!.convertFromScreen(rect), from: nil)
                    editor.pointerMoved(to: NSPoint(x: point.midX, y: point.midY), flags: defaults.bool(forKey: "command") ? .command : [])
                }
            }
            if let path = defaults.string(forKey: "exportPDF") {
                controller.writePDF(to: URL(fileURLWithPath: path))
            }
            // Asked for the PDF alone, the app is done once it is written.
            guard let snapshot else { return NSApp.terminate(nil) }
            if defaults.bool(forKey: "settings") {
                (NSApp.delegate as? AppDelegate)?.showSettings(nil)
                if let tab = defaults.object(forKey: "settingsTab") as? String, let index = Int(tab) {
                    (NSApp.delegate as? AppDelegate)?.settingsController?.selectTab(index)
                }
            }
            if let palette = defaults.string(forKey: "palette") {
                let query = defaults.string(forKey: "query") ?? ""
                switch palette {
                case "files": controller.debugPalette(.files, query: query)
                case "search": controller.debugPalette(.search, query: query)
                case "headings": controller.debugPalette(.headings, query: query)
                case "backlinks": controller.showBacklinks(nil)
                default: controller.debugPalette(.commands, query: query)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                // The window server's pictures of Deckle's own windows only:
                // the main window, and any panel over it beside it.
                let others = NSApp.windows.filter { $0 !== controller.window && $0.isVisible && $0.frame.minX > -10_000 }
                for window in [controller.window].compactMap({ $0 }) + others {
                    let path = window === controller.window ? snapshot : snapshot.replacingOccurrences(of: ".png", with: "-panel.png")
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
                    try? capture.run()
                    capture.waitUntilExit()
                }
                NSApp.terminate(nil)
            }
        }
    }
}
