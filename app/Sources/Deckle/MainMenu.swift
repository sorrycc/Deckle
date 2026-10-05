import AppKit

/// The menu bar, built in code so the app needs no xib and no ibtool.
enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Deckle", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenu()
        add(services, titled: "Services", to: appMenu)
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Deckle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Deckle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, titled: "Deckle", to: main)

        // Window commands have no target, so they go to the key window's
        // WindowController through the responder chain.
        let file = NSMenu()
        file.addItem(withTitle: "New Note", action: #selector(WindowController.newNote(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "New Tab", action: #selector(WindowController.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Open…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "o")
        let recent = NSMenu()
        recent.delegate = NSApp.delegate as? NSMenuDelegate
        add(recent, titled: "Open Recent", to: file)
        file.addItem(withTitle: "Quick Open…", action: #selector(WindowController.quickOpen(_:)), keyEquivalent: "p")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(WindowController.closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        file.addItem(withTitle: "Reopen Closed Tab", action: #selector(WindowController.reopenClosedTab(_:)), keyEquivalent: "T")
        file.addItem(withTitle: "Save", action: #selector(WindowController.saveDocument(_:)), keyEquivalent: "s")
        file.addItem(.separator())
        item(file, "Reveal in Finder", #selector(WindowController.revealInFinder(_:)), "r", [.command, .option])
        item(file, "Move to Trash", #selector(WindowController.moveToTrash(_:)), "\u{8}", [.command])
        file.addItem(.separator())
        file.addItem(withTitle: "Export as PDF…", action: #selector(WindowController.exportPDF(_:)), keyEquivalent: "")
        item(file, "Print…", #selector(WindowController.printDocument(_:)), "p", [.command, .option])
        add(file, titled: "File", to: main)

        let edit = NSMenu()
        edit.addItem(withTitle: "Undo", action: #selector(EditorTextView.undo(_:)), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: #selector(EditorTextView.redo(_:)), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        item(edit, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "V", [.command, .option, .shift])
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
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
        find.addItem(withTitle: "Jump to Selection", action: #selector(NSResponder.centerSelectionInVisibleArea(_:)), keyEquivalent: "j")
        add(find, titled: "Find", to: edit)
        // The text system's own menus, which it validates and checkmarks.
        let spelling = NSMenu()
        item(spelling, "Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":", [.command])
        item(spelling, "Check Document Now", #selector(NSText.checkSpelling(_:)), ";", [.command])
        spelling.addItem(.separator())
        spelling.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        spelling.addItem(withTitle: "Check Grammar With Spelling", action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: "")
        spelling.addItem(withTitle: "Correct Spelling Automatically", action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: "")
        add(spelling, titled: "Spelling and Grammar", to: edit)
        let substitutions = NSMenu()
        substitutions.addItem(withTitle: "Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
        substitutions.addItem(withTitle: "Smart Dashes", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: "")
        substitutions.addItem(withTitle: "Text Replacement", action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: "")
        add(substitutions, titled: "Substitutions", to: edit)
        let transformations = NSMenu()
        transformations.addItem(withTitle: "Make Upper Case", action: #selector(NSResponder.uppercaseWord(_:)), keyEquivalent: "")
        transformations.addItem(withTitle: "Make Lower Case", action: #selector(NSResponder.lowercaseWord(_:)), keyEquivalent: "")
        transformations.addItem(withTitle: "Capitalize", action: #selector(NSResponder.capitalizeWord(_:)), keyEquivalent: "")
        add(transformations, titled: "Transformations", to: edit)
        let speech = NSMenu()
        speech.addItem(withTitle: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: "")
        speech.addItem(withTitle: "Stop Speaking", action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: "")
        add(speech, titled: "Speech", to: edit)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Emoji & Symbols", action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: "")
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
        item(format, "Numbered List", #selector(EditorTextView.toggleNumberedList(_:)), "7", [.command, .shift])
        item(format, "Task List", #selector(EditorTextView.toggleTaskList(_:)), "9", [.command, .shift])
        item(format, "Toggle Done", #selector(EditorTextView.toggleTaskDone(_:)), "\r", [.command])
        item(format, "Quote", #selector(EditorTextView.toggleQuote(_:)), "'", [.command])
        item(format, "Code Block", #selector(EditorTextView.toggleCodeBlock(_:)), "c", [.command, .option])
        format.addItem(.separator())
        item(format, "Indent", #selector(EditorTextView.indentItems(_:)), "]", [.command, .option])
        item(format, "Outdent", #selector(EditorTextView.outdentItems(_:)), "[", [.command, .option])
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
        item(go, "Note List", #selector(WindowController.focusList(_:)), "l", [.command, .option])
        item(go, "Editor", #selector(WindowController.focusEditorCommand(_:)), "e", [.command, .option])
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
        window.addItem(.separator())
        item(window, "Welcome to Deckle", #selector(AppDelegate.showWelcomeWindow(_:)), "1", [.command, .shift])
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        let help = NSMenu()
        help.addItem(withTitle: "Deckle Help", action: #selector(AppDelegate.showHelp(_:)), keyEquivalent: "?")
        help.addItem(withTitle: "Markdown Reference", action: #selector(AppDelegate.showMarkdownReference(_:)), keyEquivalent: "")
        add(help, titled: "Help", to: main)
        NSApp.helpMenu = help
        addSymbols(to: main)
        return main
    }

    /// The symbols of Deckle's own commands, by title. The system gives the
    /// standard ones theirs, Copy and Print among them; without these the
    /// app's own would sit bare between them, out of line.
    private static let symbols: [String: String] = [
        "About Deckle": "info.circle",
        "Settings…": "gear",
        "New Note": "square.and.pencil",
        "New Tab": "plus.square.on.square",
        "Open…": "folder",
        "Open Recent": "clock",
        "Quick Open…": "doc.text.magnifyingglass",
        "Close Tab": "xmark.square",
        "Reopen Closed Tab": "arrow.uturn.backward.square",
        "Reveal in Finder": "finder",
        "Move to Trash": "trash",
        "Export as PDF…": "arrow.up.doc",
        "Substitutions": "textformat.abc.dottedunderline",
        "Highlight": "highlighter",
        "Code": "chevron.left.forwardslash.chevron.right",
        "Link": "link",
        "Bulleted List": "list.bullet",
        "Numbered List": "list.number",
        "Task List": "checklist",
        "Toggle Done": "checkmark.circle",
        "Quote": "text.quote",
        "Code Block": "curlybraces",
        "Indent": "increase.indent",
        "Outdent": "decrease.indent",
        "Hide Note List": "list.bullet.rectangle",
        "Search Notes…": "magnifyingglass",
        "Commands…": "command",
        "Go to Heading…": "list.bullet.indent",
        "Show Backlinks": "arrow.turn.up.left",
        "Back": "chevron.left",
        "Forward": "chevron.right",
        "Note List": "list.bullet.rectangle",
        "Editor": "text.cursor",
        "Welcome to Deckle": "books.vertical",
        "Markdown Reference": "book",
    ]

    @MainActor
    private static func addSymbols(to menu: NSMenu) {
        for item in menu.items {
            if item.image == nil, let symbol = symbols[item.title] {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            if let submenu = item.submenu { addSymbols(to: submenu) }
        }
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
