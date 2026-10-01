import AppKit

/// The line under the editor: links to the note, then where the insertion
/// point is, how long the note is, and what it is written in.
final class StatusBar: NSView {
    static let height: CGFloat = 26

    let backlinksButton = NSButton()
    private let positionLabel = NSTextField(labelWithString: "")
    private let wordsLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        backlinksButton.isBordered = false
        backlinksButton.font = .systemFont(ofSize: 11)
        backlinksButton.contentTintColor = .secondaryLabelColor
        backlinksButton.imagePosition = .imageLeading
        backlinksButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Backlinks")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        backlinksButton.isHidden = true
        for label in [positionLabel, wordsLabel, languageLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        let trailing = NSStackView(views: [positionLabel, wordsLabel, languageLabel])
        trailing.spacing = 16
        for view in [backlinksButton, trailing] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            backlinksButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            backlinksButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(line: Int, column: Int) {
        positionLabel.stringValue = "Ln \(line), Col \(column)"
    }

    func show(words: Int) {
        wordsLabel.stringValue = words == 1 ? "1 word" : "\(words.formatted()) words"
    }

    func show(language: String) {
        languageLabel.stringValue = language.isEmpty ? "Plain Text" : language.prefix(1).uppercased() + language.dropFirst()
    }

    func show(backlinks count: Int) {
        backlinksButton.isHidden = count == 0
        backlinksButton.title = count == 1 ? "1 backlink" : "\(count) backlinks"
    }

    /// Nothing to report: the tab has no text.
    func clear() {
        positionLabel.stringValue = ""
        wordsLabel.stringValue = ""
        languageLabel.stringValue = ""
        backlinksButton.isHidden = true
    }
}
