import AppKit

/// One tab: a file shown in an editor or a preview, and the files it showed
/// before, to go back to.
@MainActor
final class Tab {
    /// A place in the tab's history.
    struct Entry {
        var url: URL
        var selection = NSRange(location: 0, length: 0)
        var scroll: CGFloat = 0
    }

    private(set) var entries: [Entry] = []
    private(set) var index = -1
    /// The editor, a preview, or a placeholder when the tab is empty.
    private(set) var view: NSView = PlaceholderView(symbol: "square.and.pencil", title: "No Note Open", detail: "Choose a note, or press ⌘N for a new one.")
    weak var editorDelegate: EditorViewDelegate?

    var editor: EditorView? { view as? EditorView }
    var url: URL? { entries.indices.contains(index) ? entries[index].url : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < entries.count - 1 }

    var displayTitle: String {
        guard let url else { return "New Tab" }
        return Files.isMarkdown(url) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    var icon: NSImage? {
        guard let url else { return NSImage(systemSymbolName: "plus.square.dashed", accessibilityDescription: nil) }
        return NSImage(systemSymbolName: Tab.symbol(for: url), accessibilityDescription: nil)
    }

    static func symbol(for url: URL) -> String {
        if Files.isMarkdown(url) { return "doc.text" }
        if Files.isImage(url) { return "photo" }
        return Language.name(for: url).isEmpty ? "doc" : "chevron.left.forwardslash.chevron.right"
    }

    /// Shows the file at `url`, after what the tab showed so far.
    func open(_ url: URL, selecting selection: NSRange? = nil) {
        if url == self.url {
            if let selection { editor?.reveal(selection) }
            return
        }
        leave()
        entries.removeSubrange((index + 1)...)
        entries.append(Entry(url: url, selection: selection ?? NSRange(location: 0, length: 0)))
        index = entries.count - 1
        load(select: selection != nil)
    }

    func goBack() {
        guard canGoBack else { return }
        leave()
        index -= 1
        load(select: true)
    }

    func goForward() {
        guard canGoForward else { return }
        leave()
        index += 1
        load(select: true)
    }

    /// Saves the file shown and remembers where its editor was.
    private func leave() {
        guard let editor, entries.indices.contains(index) else { return }
        editor.save()
        entries[index].selection = editor.textView.selectedRange()
        entries[index].scroll = editor.scrollView.contentView.bounds.origin.y
    }

    /// Saves the file shown, before the tab closes or the app quits.
    func save() { editor?.save() }

    /// The file moved or was renamed.
    func fileMoved(from old: URL, to new: URL) {
        for i in entries.indices {
            let path = entries[i].url.path
            if path == old.path {
                entries[i].url = new
            } else if path.hasPrefix(old.path + "/") {
                entries[i].url = new.appendingPathComponent(String(path.dropFirst(old.path.count + 1)))
            }
        }
        if let editor, let url { editor.moved(to: url) }
    }

    /// Forgets a file that was deleted. Returns whether the tab showed it.
    func fileRemoved(_ removed: URL) -> Bool {
        let showed = url.map { $0.path == removed.path || $0.path.hasPrefix(removed.path + "/") } ?? false
        let current = url
        entries.removeAll { $0.url.path == removed.path || $0.url.path.hasPrefix(removed.path + "/") }
        if showed {
            index = entries.count - 1
            load(select: true)
        } else if let current {
            index = entries.firstIndex { $0.url == current } ?? entries.count - 1
        }
        return showed
    }

    private func load(select: Bool) {
        guard let url else {
            view = PlaceholderView(symbol: "square.and.pencil", title: "No Note Open", detail: "Choose a note, or press ⌘N for a new one.")
            return
        }
        let entry = entries[index]
        if Files.isImage(url) {
            view = ImagePreview(url: url)
        } else if let text = Files.readText(url) {
            let editor = EditorView(url: url, text: text)
            editor.delegate = editorDelegate
            view = editor
            if select {
                let length = (text as NSString).length
                let location = min(entry.selection.location, length)
                editor.textView.setSelectedRange(NSRange(location: location, length: min(entry.selection.length, length - location)))
                // The scroll position holds once the text is laid out.
                DispatchQueue.main.async {
                    if entry.scroll > 0 {
                        editor.textView.scroll(NSPoint(x: 0, y: entry.scroll))
                    } else {
                        editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
                    }
                }
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            view = PlaceholderView(symbol: "doc", title: url.lastPathComponent, detail: "Quill can't show this file.", url: url)
        } else {
            view = PlaceholderView(symbol: "questionmark.folder", title: url.lastPathComponent, detail: "This file is gone.")
        }
    }
}

/// What a tab shows when it has no file, or one Quill can't show.
final class PlaceholderView: NSView {
    private let url: URL?

    init(symbol: String, title: String, detail: String, url: URL? = nil) {
        self.url = url
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(14, after: icon)
        if url != nil {
            let button = NSButton(title: "Open in Default App", target: self, action: #selector(openExternally))
            button.bezelStyle = .glass
            stack.addArrangedSubview(button)
            stack.setCustomSpacing(16, after: detailLabel)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func openExternally() {
        if let url { NSWorkspace.shared.open(url) }
    }
}

/// An image file, fitted to the pane and zoomable.
final class ImagePreview: NSView {
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()

    init(url: URL) {
        super.init(frame: .zero)
        let image = NSImage(contentsOf: url)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
        scrollView.documentView = imageView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var fitted = false

    override func layout() {
        super.layout()
        // Fits a large image to the pane once, and leaves the zoom alone after.
        guard !fitted, let size = imageView.image?.size, size.width > 0, bounds.width > 0 else { return }
        fitted = true
        let visible = scrollView.contentView.bounds.size
        let scale = min(1, min((visible.width - 40) / size.width, (visible.height - 40) / size.height))
        if scale < 1 { scrollView.magnification = max(scrollView.minMagnification, scale) }
    }
}
