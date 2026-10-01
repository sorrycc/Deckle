import AppKit

extension Notification.Name {
    /// The look of the editor changed: theme, font or layout.
    static let appearanceDidChange = Notification.Name("DeckleAppearanceDidChange")
}

/// Every setting the Settings window shows, stored in user defaults. Launch
/// arguments (`-editorFontSize 18`) override them, as with any defaults.
@MainActor
enum Settings {
    static let defaults = UserDefaults.standard

    private static func changed() {
        NotificationCenter.default.post(name: .appearanceDidChange, object: nil)
    }

    static var themeID: String {
        get { defaults.string(forKey: "theme") ?? "system" }
        set { defaults.set(newValue, forKey: "theme"); changed() }
    }

    /// An installed font family, or empty for the system font.
    static var editorFontFamily: String {
        get { defaults.string(forKey: "editorFontFamily") ?? "" }
        set { defaults.set(newValue, forKey: "editorFontFamily"); changed() }
    }

    static var editorFontSize: CGFloat {
        get { let size = defaults.double(forKey: "editorFontSize"); return size >= 9 ? min(size, 40) : 15 }
        set { defaults.set(Double(newValue), forKey: "editorFontSize"); changed() }
    }

    /// Line height as a multiple of the font's.
    static var lineHeight: CGFloat {
        get { let value = defaults.double(forKey: "lineHeight"); return value >= 1 ? min(value, 2.4) : 1.5 }
        set { defaults.set(Double(newValue), forKey: "lineHeight"); changed() }
    }

    /// The widest a line of text gets, in points.
    static var lineWidth: CGFloat {
        get { let value = defaults.double(forKey: "lineWidth"); return value >= 360 ? value : 760 }
        set { defaults.set(Double(newValue), forKey: "lineWidth"); changed() }
    }

    /// Shows Markdown's syntax only around the selection.
    static var hidesMarkers: Bool {
        get { defaults.object(forKey: "hidesMarkers") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hidesMarkers"); changed() }
    }

    static var checksSpelling: Bool {
        get { defaults.bool(forKey: "checksSpelling") }
        set { defaults.set(newValue, forKey: "checksSpelling"); changed() }
    }

    static var sortsNotesByTitle: Bool {
        get { defaults.bool(forKey: "sortsNotesByTitle") }
        set { defaults.set(newValue, forKey: "sortsNotesByTitle") }
    }

    // MARK: Migration

    /// Copies settings, workspaces and window layout from the app's old name,
    /// Quill, once. The old domain is left as it was.
    static func migrateFromQuill() {
        let marker = "migratedFromQuill"
        guard !defaults.bool(forKey: marker),
              let old = defaults.persistentDomain(forName: "dev.sorrycc.quill") else { return }
        let renamed = [
            "NSWindow Frame QuillWindow": "NSWindow Frame DeckleWindow",
            "NSSplitView Subview Frames QuillSplit": "NSSplitView Subview Frames DeckleSplit",
        ]
        for (key, value) in old where defaults.object(forKey: renamed[key] ?? key) == nil {
            defaults.set(value, forKey: renamed[key] ?? key)
        }
        defaults.set(true, forKey: marker)
    }

    // MARK: Workspaces

    static var lastWorkspace: URL? {
        get { defaults.string(forKey: "lastWorkspace").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: "lastWorkspace") }
    }

    /// Workspaces opened before, newest first.
    static var recentWorkspaces: [URL] {
        get { (defaults.stringArray(forKey: "recentWorkspaces") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(Array(newValue.map(\.path).prefix(12)), forKey: "recentWorkspaces") }
    }

    static func noteOpened(workspace url: URL) {
        lastWorkspace = url
        recentWorkspaces = [url] + recentWorkspaces.filter { $0.path != url.path }
    }

    /// What is remembered about one workspace: its tabs and starred files.
    static func state(for workspace: URL) -> [String: Any] {
        (defaults.dictionary(forKey: "workspaces") ?? [:])[workspace.path] as? [String: Any] ?? [:]
    }

    static func setState(_ state: [String: Any], for workspace: URL) {
        var all = defaults.dictionary(forKey: "workspaces") ?? [:]
        all[workspace.path] = state
        defaults.set(all, forKey: "workspaces")
    }
}
