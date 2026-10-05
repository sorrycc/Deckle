import AppKit

extension NSColor {
    /// A color from 0xRRGGBB.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// One color in light mode and another in dark.
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

/// The colors of the editor. The System theme follows light and dark mode;
/// the others bring an appearance of their own, which the window takes on.
struct Theme: Sendable {
    let id: String
    let name: String
    /// Nil follows the system.
    let appearance: NSAppearance.Name?
    let background: NSColor
    let text: NSColor
    /// Quotes, struck text, the text of front matter.
    let secondary: NSColor
    /// Markdown's syntax, where it shows.
    let syntax: NSColor
    let accent: NSColor
    let heading: NSColor
    let link: NSColor
    let codeText: NSColor
    let codeBackground: NSColor
    let quoteBar: NSColor
    let rule: NSColor
    let highlight: NSColor
    let keyword: NSColor
    let string: NSColor
    let comment: NSColor
    let number: NSColor
    let type: NSColor
    let function: NSColor
    let constant: NSColor
    let property: NSColor
    /// The selected text's background.
    let selection: NSColor
    /// The colors of callouts: note, tip, important, warning, caution.
    let callouts: [NSColor]

    /// What reads on the accent: white on a deep one, the page on a pale one.
    var onAccent: NSColor {
        let rgb = accent.usingColorSpace(.sRGB) ?? accent
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.62 ? background : .white
    }

    @MainActor static var current: Theme { all.first { $0.id == Settings.themeID } ?? system }

    static let system = Theme(
        id: "system", name: "System", appearance: nil,
        background: .textBackgroundColor,
        text: .labelColor,
        secondary: .secondaryLabelColor,
        syntax: .tertiaryLabelColor,
        accent: .controlAccentColor,
        heading: .labelColor,
        link: .linkColor,
        codeText: .dynamic(light: 0xB4331F, dark: 0xFF9F7E),
        codeBackground: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.04)
        },
        quoteBar: .quaternaryLabelColor,
        rule: .separatorColor,
        highlight: .dynamic(light: 0xFFEE9A, dark: 0x6B5A12),
        keyword: .dynamic(light: 0xA626A4, dark: 0xD48BE8),
        string: .dynamic(light: 0x2E8540, dark: 0x9BD48A),
        comment: .dynamic(light: 0x8A8F98, dark: 0x747B87),
        number: .dynamic(light: 0xB76B01, dark: 0xE8B26B),
        type: .dynamic(light: 0x0B7A8C, dark: 0x6FCBDB),
        function: .dynamic(light: 0x2B5FD9, dark: 0x7FB0FF),
        constant: .dynamic(light: 0xB76B01, dark: 0xE8B26B),
        property: .dynamic(light: 0xC2451E, dark: 0xF0907A),
        selection: .selectedTextBackgroundColor,
        callouts: [.systemBlue, .systemGreen, .systemPurple, .systemOrange, .systemRed]
    )

    /// A theme from a palette of 0xRRGGBB values.
    static func palette(
        _ id: String, _ name: String, dark: Bool, background: UInt32, text: UInt32, secondary: UInt32, syntax: UInt32,
        accent: UInt32, heading: UInt32, code: UInt32, keyword: UInt32, string: UInt32, comment: UInt32, number: UInt32,
        type: UInt32, function: UInt32, property: UInt32, highlight: UInt32, callouts: [UInt32]? = nil
    ) -> Theme {
        let ink = NSColor(hex: text)
        return Theme(
            id: id, name: name, appearance: dark ? .darkAqua : .aqua,
            background: NSColor(hex: background), text: ink, secondary: NSColor(hex: secondary),
            syntax: NSColor(hex: syntax), accent: NSColor(hex: accent), heading: NSColor(hex: heading),
            link: NSColor(hex: accent), codeText: NSColor(hex: code), codeBackground: ink.withAlphaComponent(0.06),
            quoteBar: ink.withAlphaComponent(0.2), rule: ink.withAlphaComponent(0.16),
            highlight: NSColor(hex: highlight, alpha: dark ? 0.35 : 0.6), keyword: NSColor(hex: keyword),
            string: NSColor(hex: string), comment: NSColor(hex: comment), number: NSColor(hex: number),
            type: NSColor(hex: type), function: NSColor(hex: function), constant: NSColor(hex: number),
            property: NSColor(hex: property),
            selection: NSColor(hex: accent, alpha: dark ? 0.35 : 0.25),
            // Callouts in the palette's own blue, green, purple, orange and
            // red: its code colors where they are those, else the ones given.
            callouts: (callouts ?? [function, string, keyword, number, property]).map { NSColor(hex: $0) })
    }

    static let all: [Theme] = [
        system,
        palette(
            "paper", "Paper", dark: false, background: 0xFBF7EF, text: 0x3B3630, secondary: 0x7D7468, syntax: 0xB5AB9C,
            accent: 0xB4552D, heading: 0x2A2621, code: 0x9A4A2B, keyword: 0x8B3F8F, string: 0x4F7A36, comment: 0xA39A8C,
            number: 0xA8650F, type: 0x2F7A86, function: 0x2F5FA8, property: 0xB4552D, highlight: 0xF6D96B),
        palette(
            "github-light", "GitHub Light", dark: false, background: 0xFFFFFF, text: 0x1F2328, secondary: 0x59636E,
            syntax: 0xA5ADB7, accent: 0x0969DA, heading: 0x1F2328, code: 0xCF222E, keyword: 0xCF222E, string: 0x0A3069,
            comment: 0x6E7781, number: 0x0550AE, type: 0x953800, function: 0x8250DF, property: 0x116329,
            highlight: 0xFFF1A8,
            callouts: [0x0969DA, 0x1A7F37, 0x8250DF, 0x9A6700, 0xCF222E]),
        palette(
            "solarized-light", "Solarized Light", dark: false, background: 0xFDF6E3, text: 0x586E75, secondary: 0x839496,
            syntax: 0xB8C2C2, accent: 0x268BD2, heading: 0x073642, code: 0xCB4B16, keyword: 0x859900, string: 0x2AA198,
            comment: 0x93A1A1, number: 0xD33682, type: 0xB58900, function: 0x268BD2, property: 0xCB4B16,
            highlight: 0xEEE1A8,
            callouts: [0x268BD2, 0x859900, 0x6C71C4, 0xB58900, 0xDC322F]),
        palette(
            "one-dark", "One Dark", dark: true, background: 0x282C34, text: 0xABB2BF, secondary: 0x8289A0, syntax: 0x5C6370,
            accent: 0x61AFEF, heading: 0xE06C75, code: 0xE5C07B, keyword: 0xC678DD, string: 0x98C379, comment: 0x5C6370,
            number: 0xD19A66, type: 0x56B6C2, function: 0x61AFEF, property: 0xE06C75, highlight: 0xE5C07B),
        palette(
            "nord", "Nord", dark: true, background: 0x2E3440, text: 0xD8DEE9, secondary: 0x9AA5B8, syntax: 0x616E88,
            accent: 0x88C0D0, heading: 0x8FBCBB, code: 0xEBCB8B, keyword: 0x81A1C1, string: 0xA3BE8C, comment: 0x616E88,
            number: 0xB48EAD, type: 0x8FBCBB, function: 0x88C0D0, property: 0xD08770, highlight: 0xEBCB8B,
            callouts: [0x88C0D0, 0xA3BE8C, 0xB48EAD, 0xEBCB8B, 0xBF616A]),
        palette(
            "tokyo-night", "Tokyo Night", dark: true, background: 0x1A1B26, text: 0xC0CAF5, secondary: 0x9AA5CE,
            syntax: 0x565F89, accent: 0x7AA2F7, heading: 0xBB9AF7, code: 0xFF9E64, keyword: 0xBB9AF7, string: 0x9ECE6A,
            comment: 0x565F89, number: 0xFF9E64, type: 0x2AC3DE, function: 0x7AA2F7, property: 0x73DACA,
            highlight: 0xE0AF68,
            callouts: [0x7AA2F7, 0x9ECE6A, 0xBB9AF7, 0xE0AF68, 0xF7768E]),
        palette(
            "rose-pine", "Rosé Pine", dark: true, background: 0x191724, text: 0xE0DEF4, secondary: 0x908CAA, syntax: 0x6E6A86,
            accent: 0xC4A7E7, heading: 0xEBBCBA, code: 0xF6C177, keyword: 0x31748F, string: 0xF6C177, comment: 0x6E6A86,
            number: 0xEB6F92, type: 0x9CCFD8, function: 0xEBBCBA, property: 0xC4A7E7, highlight: 0xF6C177,
            callouts: [0x9CCFD8, 0x3E8FB0, 0xC4A7E7, 0xF6C177, 0xEB6F92]),
        palette(
            "dracula", "Dracula", dark: true, background: 0x282A36, text: 0xF8F8F2, secondary: 0xB4B7C9, syntax: 0x6272A4,
            accent: 0x8BE9FD, heading: 0xBD93F9, code: 0xFFB86C, keyword: 0xFF79C6, string: 0xF1FA8C, comment: 0x6272A4,
            number: 0xBD93F9, type: 0x8BE9FD, function: 0x50FA7B, property: 0xFFB86C, highlight: 0xF1FA8C,
            callouts: [0x8BE9FD, 0x50FA7B, 0xBD93F9, 0xFFB86C, 0xFF5555]),
        palette(
            "gruvbox-dark", "Gruvbox Dark", dark: true, background: 0x282828, text: 0xEBDBB2, secondary: 0xBDAE93,
            syntax: 0x7C6F64, accent: 0x83A598, heading: 0xFABD2F, code: 0xFE8019, keyword: 0xFB4934, string: 0xB8BB26,
            comment: 0x928374, number: 0xD3869B, type: 0x8EC07C, function: 0x83A598, property: 0xFE8019,
            highlight: 0xFABD2F,
            callouts: [0x83A598, 0xB8BB26, 0xD3869B, 0xFABD2F, 0xFB4934]),
    ]

    /// The color of a callout by kind: note, tip, important, warning, caution.
    func calloutColor(_ kind: Int) -> NSColor {
        callouts[max(0, min(kind - 1, callouts.count - 1))]
    }
}

/// The fonts of the editor, from the settings.
@MainActor
struct Fonts {
    let size: CGFloat
    let body: NSFont
    let mono: NSFont
    /// The face of Chinese and Japanese text, as `Settings.cjkFontFamily`
    /// gives it.
    let cjkFamily: String
    /// The Chinese of Han characters in text without kana.
    let chineseScript: String

    static var current: Fonts {
        Fonts(
            family: Settings.editorFontFamily, size: Settings.editorFontSize, cjkFamily: Settings.cjkFontFamily,
            codeFamily: Settings.codeFontFamily, chineseScript: Settings.chineseScript)
    }

    init(family: String, size: CGFloat, cjkFamily: String = "", codeFamily: String = "", chineseScript: String = "zh-Hans") {
        self.size = size
        self.cjkFamily = cjkFamily
        self.chineseScript = chineseScript
        body = Fonts.font(family: family, size: size) ?? .systemFont(ofSize: size)
        let monoSize = (size * 0.9).rounded()
        mono = Fonts.font(family: codeFamily, size: monoSize) ?? .monospacedSystemFont(ofSize: monoSize, weight: .regular)
    }

    /// The regular face of an installed `family`, or nil for none or empty.
    static func font(family: String, size: CGFloat) -> NSFont? {
        guard !family.isEmpty else { return nil }
        return NSFont(name: family, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }

    /// The code font at `size`.
    func mono(ofSize size: CGFloat) -> NSFont {
        NSFontManager.shared.convert(mono, toSize: size)
    }

    /// Whether `font` sets code, which keeps its own Chinese and Japanese.
    func isMono(_ font: NSFont) -> Bool {
        font.isFixedPitch || font.familyName == mono.familyName
    }

    func heading(_ level: Int) -> NSFont {
        let scale: CGFloat = [1.7, 1.42, 1.22, 1.1, 1.0, 1.0][max(1, min(level, 6)) - 1]
        let base = NSFontManager.shared.convert(body, toSize: (size * scale).rounded())
        return Fonts.with(base, trait: .bold)
    }

    /// The family that draws the Chinese or Japanese of `language`, or nil
    /// to leave it to the system, which chooses by the text's language.
    func cjkFamily(for language: String) -> String? {
        switch cjkFamily {
        case "": nil
        case "serif": language == "ja" ? "Hiragino Mincho ProN" : language == "zh-Hans" ? "Songti SC" : "Songti TC"
        default: cjkFamily
        }
    }

    /// The chosen face for the Chinese or Japanese of `language` in text
    /// set in `font`, at its size and weight, or nil to leave them to the
    /// system. It is set on those characters directly rather than as a
    /// fallback: the system font spaces a fallback's punctuation for its own
    /// PingFang, which leaves gaps after other faces' commas, and a fallback
    /// keeps its own weight, so a bold line would get regular characters.
    func cjkFont(for font: NSFont, language: String) -> NSFont? {
        guard font.pointSize >= 1, !isMono(font), let family = cjkFamily(for: language),
            var cjk = Fonts.font(family: family, size: font.pointSize), cjk.familyName != font.familyName
        else { return nil }
        if font.fontDescriptor.symbolicTraits.contains(.bold) || NSFontManager.shared.weight(of: font) >= 8 {
            cjk = Fonts.with(cjk, trait: .bold)
        }
        if font.fontDescriptor.symbolicTraits.contains(.italic) {
            cjk = Fonts.with(cjk, trait: .italic)
        }
        return cjk
    }

    /// `font` with a bold or italic trait added, where the family has one.
    /// A family without a bold, such as LXGW WenKai, gets its next heavier
    /// weight instead.
    static func with(_ font: NSFont, trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
        if let result = NSFont(descriptor: descriptor, size: font.pointSize),
            result.fontName != font.fontName || font.fontDescriptor.symbolicTraits.contains(trait)
        {
            return result
        }
        if trait == .bold {
            let heavier = NSFontManager.shared.convertWeight(true, of: font)
            if heavier.fontName != font.fontName { return heavier }
        }
        return font
    }
}
