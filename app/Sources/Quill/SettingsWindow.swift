import AppKit

/// Settings: how the editor looks and behaves.
final class SettingsWindowController: NSWindowController {
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (pane, title, symbol) in [
            (AppearancePane(), "Appearance", "paintpalette"),
            (EditorPane(), "Editor", "text.cursor"),
        ] as [(NSViewController, String, String)] {
            let item = NSTabViewItem(viewController: pane)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.title = "Settings"
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A form of labeled rows, as System Settings lays them out.
@MainActor
private func form(_ rows: [(String, NSView)], width: CGFloat = 520) -> NSView {
    let grid = NSGridView(views: rows.map { label, control in
        let text = NSTextField(labelWithString: label.isEmpty ? "" : label + ":")
        text.alignment = .right
        return [text, control]
    })
    grid.rowSpacing = 14
    grid.columnSpacing = 12
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    // A tall control, such as the grid of themes, has no baseline to share:
    // its label sits level with the top of its first row instead.
    for (index, (_, control)) in rows.enumerated() where control is NSGridView {
        let row = grid.row(at: index)
        row.rowAlignment = .none
        row.cell(at: 1).yPlacement = .top
        let label = row.cell(at: 0)
        label.yPlacement = .none
        label.customPlacementConstraints = [label.contentView!.topAnchor.constraint(equalTo: control.topAnchor, constant: 10)]
    }
    grid.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(grid)
    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: width),
        grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
        grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
    ])
    return container
}

final class AppearancePane: NSViewController {
    private var swatches: [ThemeSwatch] = []
    private let fontPopup = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()

    override func loadView() {
        let grid = NSGridView(numberOfColumns: 4, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        var row: [NSView] = []
        for theme in Theme.all {
            let swatch = ThemeSwatch(theme: theme)
            swatch.target = self
            swatch.action = #selector(chooseTheme(_:))
            swatches.append(swatch)
            row.append(swatch)
            if row.count == 4 {
                grid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty { grid.addRow(with: row + Array(repeating: NSGridCell.emptyContentView, count: 4 - row.count)) }

        fontPopup.addItem(withTitle: "System Font")
        fontPopup.menu?.addItem(.separator())
        for family in NSFontManager.shared.availableFontFamilies where !family.hasPrefix(".") {
            fontPopup.addItem(withTitle: family)
        }
        fontPopup.target = self
        fontPopup.action = #selector(chooseFont(_:))
        sizeField.formatter = { let f = NumberFormatter(); f.minimum = 9; f.maximum = 40; return f }()
        sizeField.alignment = .right
        sizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        sizeField.target = self
        sizeField.action = #selector(sizeEntered(_:))
        sizeStepper.minValue = 9
        sizeStepper.maxValue = 40
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepped(_:))
        let size = NSStackView(views: [sizeField, sizeStepper, NSTextField(labelWithString: "pt")])
        size.spacing = 4

        view = form([("Theme", grid), ("Font", fontPopup), ("Size", size)], width: 720)
        preferredContentSize = view.fittingSize
        refresh()
    }

    private func refresh() {
        for swatch in swatches { swatch.isChosen = swatch.theme.id == Settings.themeID }
        let family = Settings.editorFontFamily
        if family.isEmpty || fontPopup.item(withTitle: family) == nil { fontPopup.selectItem(at: 0) } else { fontPopup.selectItem(withTitle: family) }
        sizeField.integerValue = Int(Settings.editorFontSize)
        sizeStepper.integerValue = Int(Settings.editorFontSize)
    }

    @objc private func chooseTheme(_ sender: ThemeSwatch) {
        Settings.themeID = sender.theme.id
        refresh()
    }

    @objc private func chooseFont(_ sender: NSPopUpButton) {
        Settings.editorFontFamily = sender.indexOfSelectedItem == 0 ? "" : sender.titleOfSelectedItem ?? ""
    }

    @objc private func sizeEntered(_ sender: NSTextField) {
        Settings.editorFontSize = CGFloat(max(9, min(40, sender.integerValue)))
        refresh()
    }

    @objc private func sizeStepped(_ sender: NSStepper) {
        Settings.editorFontSize = CGFloat(sender.integerValue)
        refresh()
    }
}

/// A theme as a card: its background, a few of its colors, and its name.
final class ThemeSwatch: NSControl {
    let theme: Theme
    var isChosen = false { didSet { needsDisplay = true } }

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 140, height: 64))
        toolTip = theme.name
        widthAnchor.constraint(equalToConstant: 140).isActive = true
        heightAnchor.constraint(equalToConstant: 64).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = theme.appearance.flatMap { NSAppearance(named: $0) } ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
            theme.background.setFill()
            card.fill()
            (isChosen ? NSColor.controlAccentColor : theme.text.withAlphaComponent(0.15)).setStroke()
            card.lineWidth = isChosen ? 3 : 1
            card.stroke()
            for (index, color) in [theme.heading, theme.accent, theme.keyword, theme.string].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12 + CGFloat(index) * 16, y: bounds.height - 26, width: 11, height: 11)).fill()
            }
            NSAttributedString(string: theme.name, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: theme.text,
            ]).draw(at: NSPoint(x: 12, y: 10))
        }
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}

final class EditorPane: NSViewController {
    private let widthValue = NSTextField(labelWithString: "")
    private let heightValue = NSTextField(labelWithString: "")

    override func loadView() {
        let hide = NSButton(checkboxWithTitle: "Show Markdown syntax only around the selection", target: self, action: #selector(toggleHide(_:)))
        hide.state = Settings.hidesMarkers ? .on : .off
        let spelling = NSButton(checkboxWithTitle: "Check spelling while typing", target: self, action: #selector(toggleSpelling(_:)))
        spelling.state = Settings.checksSpelling ? .on : .off
        let width = NSSlider(value: Settings.lineWidth, minValue: 480, maxValue: 1400, target: self, action: #selector(widthChanged(_:)))
        width.isContinuous = true
        let height = NSSlider(value: Settings.lineHeight, minValue: 1.2, maxValue: 2.2, target: self, action: #selector(heightChanged(_:)))
        height.isContinuous = true
        for label in [widthValue, heightValue] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }
        view = form([
            ("Syntax", hide), ("", spelling),
            ("Line width", sliderRow(width, widthValue)), ("Line height", sliderRow(height, heightValue)),
        ], width: 720)
        preferredContentSize = view.fittingSize
        refresh()
    }

    private func sliderRow(_ slider: NSSlider, _ value: NSTextField) -> NSView {
        slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let row = NSStackView(views: [slider, value])
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    private func refresh() {
        widthValue.stringValue = "\(Int(Settings.lineWidth)) pt"
        heightValue.stringValue = String(format: "%.2f×", Settings.lineHeight)
    }

    @objc private func toggleHide(_ sender: NSButton) { Settings.hidesMarkers = sender.state == .on }
    @objc private func toggleSpelling(_ sender: NSButton) { Settings.checksSpelling = sender.state == .on }

    @objc private func widthChanged(_ sender: NSSlider) {
        Settings.lineWidth = (sender.doubleValue / 10).rounded() * 10
        refresh()
    }

    @objc private func heightChanged(_ sender: NSSlider) {
        Settings.lineHeight = (sender.doubleValue * 20).rounded() / 20
        refresh()
    }
}
