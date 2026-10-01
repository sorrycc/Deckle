import AppKit

/// The menu bar, built in code so the app needs no xib and no ibtool.
enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Quill", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Quill", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Quill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, titled: "Quill", to: main)

        // Window commands have no target, so they go to the key window's
        // WindowController through the responder chain.
        let file = NSMenu()
        file.addItem(withTitle: "New Note", action: #selector(WindowController.newNote(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "New Tab", action: #selector(WindowController.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Open Folder…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "o")
        let recent = NSMenu()
        recent.delegate = NSApp.delegate as? NSMenuDelegate
        add(recent, titled: "Open Recent", to: file)
        file.addItem(withTitle: "Quick Open…", action: #selector(WindowController.quickOpen(_:)), keyEquivalent: "p")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(WindowController.closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        file.addItem(withTitle: "Save", action: #selector(WindowController.saveDocument(_:)), keyEquivalent: "s")
        file.addItem(.separator())
        item(file, "Reveal in Finder", #selector(WindowController.revealInFinder(_:)), "r", [.command, .option])
        add(file, titled: "File", to: main)

        let edit = NSMenu()
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu()
        for (title, key, action) in [
            ("Find…", "f", NSTextFinder.Action.showFindInterface),
            ("Find and Replace…", "f", .showReplaceInterface),
            ("Find Next", "g", .nextMatch),
            ("Find Previous", "G", .previousMatch),
            ("Use Selection for Find", "e", .setSearchString),
        ] {
            let item = find.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.tag = action.rawValue
            if action == .showReplaceInterface { item.keyEquivalentModifierMask = [.command, .option] }
        }
        add(find, titled: "Find", to: edit)
        add(edit, titled: "Edit", to: main)

        let format = NSMenu()
        format.addItem(withTitle: "Bold", action: #selector(EditorTextView.toggleBold(_:)), keyEquivalent: "b")
        format.addItem(withTitle: "Italic", action: #selector(EditorTextView.toggleItalic(_:)), keyEquivalent: "i")
        item(format, "Strikethrough", #selector(EditorTextView.toggleStrikethrough(_:)), "x", [.command, .shift])
        item(format, "Highlight", #selector(EditorTextView.toggleHighlight(_:)), "h", [.command, .shift])
        item(format, "Code", #selector(EditorTextView.toggleInlineCode(_:)), "e", [.command, .shift])
        format.addItem(withTitle: "Link", action: #selector(EditorTextView.insertLink(_:)), keyEquivalent: "k")
        format.addItem(.separator())
        for level in 1...6 {
            let heading = item(format, "Heading \(level)", #selector(EditorTextView.setHeadingLevel(_:)), "\(level)", [.command, .option])
            heading.tag = level
        }
        item(format, "Body", #selector(EditorTextView.setHeadingLevel(_:)), "0", [.command, .option])
        format.addItem(.separator())
        item(format, "Bulleted List", #selector(EditorTextView.toggleBulletList(_:)), "8", [.command, .shift])
        item(format, "Task List", #selector(EditorTextView.toggleTaskList(_:)), "9", [.command, .shift])
        item(format, "Quote", #selector(EditorTextView.toggleQuote(_:)), "'", [.command])
        add(format, titled: "Format", to: main)

        let view = NSMenu()
        item(view, "Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        item(view, "Hide Note List", #selector(WindowController.toggleNoteList(_:)), "l", [.command, .control])
        view.addItem(.separator())
        item(view, "Search Notes…", #selector(WindowController.searchNotes(_:)), "f", [.command, .shift])
        item(view, "Commands…", #selector(WindowController.showCommands(_:)), "p", [.command, .shift])
        item(view, "Go to Heading…", #selector(WindowController.goToHeading(_:)), "o", [.command, .shift])
        item(view, "Show Backlinks", #selector(WindowController.showBacklinks(_:)), "b", [.command, .shift])
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(WindowController.actualSize(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(WindowController.zoomIn(_:)), keyEquivalent: "=")
        // Cmd+Plus (Shift+=) zooms in too.
        let plus = view.addItem(withTitle: "Zoom In", action: #selector(WindowController.zoomIn(_:)), keyEquivalent: "+")
        plus.isHidden = true
        plus.allowsKeyEquivalentWhenHidden = true
        view.addItem(withTitle: "Zoom Out", action: #selector(WindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        add(view, titled: "View", to: main)

        let go = NSMenu()
        go.addItem(withTitle: "Back", action: #selector(WindowController.goBack(_:)), keyEquivalent: "[")
        go.addItem(withTitle: "Forward", action: #selector(WindowController.goForward(_:)), keyEquivalent: "]")
        go.addItem(.separator())
        item(go, "Show Next Tab", #selector(WindowController.selectNextTab(_:)), "\t", [.control])
        item(go, "Show Previous Tab", #selector(WindowController.selectPreviousTab(_:)), "\t", [.control, .shift])
        for number in 1...9 {
            let tab = go.addItem(withTitle: "Tab \(number)", action: #selector(WindowController.selectTabByNumber(_:)), keyEquivalent: "\(number)")
            tab.tag = number
            tab.isHidden = true
            tab.allowsKeyEquivalentWhenHidden = true
        }
        add(go, titled: "Go", to: main)

        let window = NSMenu()
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window
        return main
    }

    @MainActor
    @discardableResult
    static func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @MainActor
    static func add(_ menu: NSMenu, titled title: String, to parent: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        menu.title = title
        parent.addItem(item)
    }
}
