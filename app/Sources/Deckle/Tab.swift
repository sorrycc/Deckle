import AppKit

/// One tab: a file shown in an editor or a preview, and the files it showed
/// before, to go back to.
@MainActor
final class Tab {
    /// A place in the tab's history.
    struct Entry {
        var url: URL
        var selection = NSRange(location: 0, length: 0)
        /// Where the view was scrolled to, once it has been left.
        var scroll: CGFloat?
    }

    private(set) var entries: [Entry] = []
    private(set) var index = -1
    /// A restored tab reads its file when it is first shown, so a launch
    /// costs one note, not one per tab.
    private var needsLoad = false
    /// Whether a restored tab goes back to a saved place. Without one the
    /// editor picks its own, past any front matter.
    private var restoresPlace = true
    private var loadedView: NSView = PlaceholderView(symbol: "square.and.pencil", title: "No Note Open", detail: "Choose a note, or press ⌘N for a new one.")
    weak var editorDelegate: EditorViewDelegate?

    /// The editor, a preview, or a placeholder when the tab is empty.
    var view: NSView {
        if needsLoad {
            needsLoad = false
            load(select: restoresPlace)
        }
        return loadedView
    }

    var editor: EditorView? { view as? EditorView }
    /// The editor if the tab has read its file, which asking doesn't make it do.
    var loadedEditor: EditorView? { needsLoad ? nil : loadedView as? EditorView }
    var isLoaded: Bool { !needsLoad }

    /// Where the tab's file is being read: the editor's own place, or the
    /// one it was restored with.
    var position: (selection: NSRange, scroll: CGFloat?) {
        if let editor = loadedEditor { return (editor.textView.selectedRange(), editor.scrollView.contentView.bounds.origin.y) }
        guard entries.indices.contains(index) else { return (NSRange(location: 0, length: 0), nil) }
        return (entries[index].selection, entries[index].scroll)
    }

    /// Remembers `url` as the tab's file without reading it yet.
    func restore(_ url: URL, selecting selection: NSRange?, scrolledTo scroll: CGFloat?) {
        entries = [Entry(url: url, selection: selection ?? NSRange(location: 0, length: 0), scroll: scroll)]
        index = 0
        needsLoad = true
        restoresPlace = selection != nil
    }
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

    /// Shows the file at `url`, after what the tab showed so far. A scroll
    /// position puts the view back where it was, as after a relaunch.
    func open(_ url: URL, selecting selection: NSRange? = nil, scrolledTo scroll: CGFloat? = nil) {
        if url == self.url {
            if let selection { editor?.reveal(selection) }
            return
        }
        guard leave() else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(Entry(url: url, selection: selection ?? NSRange(location: 0, length: 0), scroll: scroll))
        index = entries.count - 1
        load(select: selection != nil)
    }

    func goBack() {
        guard canGoBack, leave() else { return }
        index -= 1
        load(select: true)
    }

    func goForward() {
        guard canGoForward, leave() else { return }
        index += 1
        load(select: true)
    }

    /// Saves the file shown and remembers where its editor was. Returns
    /// false when the note has edits that couldn't be saved and the user
    /// would rather stay with it.
    private func leave() -> Bool {
        guard let editor = loadedEditor, entries.indices.contains(index) else { return true }
        guard editor.saveBeforeLeaving() else { return false }
        entries[index].selection = editor.textView.selectedRange()
        entries[index].scroll = editor.scrollView.contentView.bounds.origin.y
        return true
    }

    /// Saves the file shown.
    func save() { loadedEditor?.save() }

    /// Saves the file shown before the tab closes or the app quits. Returns
    /// false to keep the tab, when its edits couldn't be saved and the user
    /// chose not to lose them.
    func canClose() -> Bool { loadedEditor?.saveBeforeLeaving() ?? true }

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
        if let editor = loadedEditor, let url { editor.moved(to: url) }
    }

    /// Forgets a file that was deleted. Returns whether the tab showed it.
    func fileRemoved(_ removed: URL) -> Bool {
        let showed = url.map { $0.path == removed.path || $0.path.hasPrefix(removed.path + "/") } ?? false
        let current = url
        entries.removeAll { $0.url.path == removed.path || $0.url.path.hasPrefix(removed.path + "/") }
        if showed {
            index = entries.count - 1
            needsLoad = false
            load(select: true)
        } else if let current {
            index = entries.firstIndex { $0.url == current } ?? entries.count - 1
        }
        return showed
    }

    private func load(select: Bool) {
        guard let url else {
            loadedView = PlaceholderView(symbol: "square.and.pencil", title: "No Note Open", detail: "Choose a note, or press ⌘N for a new one.")
            return
        }
        let entry = entries[index]
        if Files.isImage(url) {
            loadedView = ImagePreview(url: url)
        } else if let (text, encoding) = Files.read(url) {
            let editor = EditorView(url: url, text: text, encoding: encoding)
            editor.delegate = editorDelegate
            // A note that ships with the app, such as the help, is read-only.
            if url.path.hasPrefix(Bundle.main.bundlePath) { editor.textView.isEditable = false }
            loadedView = editor
            if select {
                let length = (text as NSString).length
                let location = min(entry.selection.location, length)
                editor.textView.setSelectedRange(NSRange(location: location, length: min(entry.selection.length, length - location)))
                // The scroll position holds once the text is laid out.
                DispatchQueue.main.async {
                    if let scroll = entry.scroll {
                        editor.textView.scroll(NSPoint(x: 0, y: scroll))
                    } else {
                        editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
                    }
                }
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            loadedView = PlaceholderView(symbol: "doc", title: url.lastPathComponent, detail: "Deckle can't show this file.", url: url)
        } else {
            loadedView = PlaceholderView(symbol: "questionmark.folder", title: url.lastPathComponent, detail: "This file is gone.")
        }
    }
}

/// What a tab shows when it has no file, or one Deckle can't show.
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

/// An image file, centered in the pane, fitted to it and zoomable.
final class ImagePreview: NSView {
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    /// The image's size in pixels, for the status bar.
    let pixelSize: NSSize

    init(url: URL) {
        let image = NSImage(contentsOf: url)
        pixelSize = image?.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? .zero
        super.init(frame: .zero)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // One image pixel to one screen pixel, so the picture stays sharp.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = pixelSize.width > 0 ? NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale) : image?.size ?? .zero
        imageView.frame = NSRect(origin: .zero, size: size)
        scrollView.contentView = CenteringClipView()
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
        let size = imageView.frame.size
        guard !fitted, imageView.image != nil, size.width > 0, size.height > 0, bounds.width > 0 else { return }
        fitted = true
        let visible = scrollView.frame.size
        let scale = min(1, min((visible.width - 40) / size.width, (visible.height - 40) / size.height))
        if scale < 1 { scrollView.magnification = max(scrollView.minMagnification, scale) }
    }
}

/// A clip view that keeps a document smaller than itself in the middle.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if frame.width < rect.width { rect.origin.x = frame.minX - (rect.width - frame.width) / 2 }
        if frame.height < rect.height { rect.origin.y = frame.minY - (rect.height - frame.height) / 2 }
        return rect
    }
}
