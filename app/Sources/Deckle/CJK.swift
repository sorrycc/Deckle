import Foundation

/// Which Chinese or Japanese a line of text is in, so that its Han
/// characters are drawn in that language's forms. Unicode gives 骨, 直 and
/// 返 one code point each, but China, Taiwan, Hong Kong and Japan draw them
/// differently, and only the text's language tells the font which to draw.
enum CJK {
    /// The Chinese scripts a note's Han characters can be set in.
    static let chineseScripts = ["zh-Hans", "zh-Hant", "zh-HK"]

    /// The Chinese the person reads first, from the system's languages, for
    /// Han characters when nothing else says which Chinese they are.
    static var preferredChineseScript: String {
        for language in Locale.preferredLanguages where language.hasPrefix("zh") {
            if language.contains("HK") || language.contains("MO") { return "zh-HK" }
            if language.contains("Hant") || language.contains("TW") { return "zh-Hant" }
            return "zh-Hans"
        }
        return "zh-Hans"
    }

    static func isKana(_ unit: UInt16) -> Bool {
        // Hiragana, katakana and their phonetic extensions, and half-width
        // katakana. The katakana middle dot, also used in Chinese, isn't.
        ((0x3040...0x30FF).contains(unit) && unit != 0x30FB) || (0x31F0...0x31FF).contains(unit) || (0xFF66...0xFF9F).contains(unit)
    }

    static func isHan(_ unit: UInt16) -> Bool {
        // The unified ideographs, extension A and the compatibility block. A
        // surrogate stands for the ideographs past the basic plane.
        (0x4E00...0x9FFF).contains(unit) || (0x3400...0x4DBF).contains(unit) || (0xF900...0xFAFF).contains(unit)
            || (0xD840...0xD8BF).contains(unit)
    }

    /// Whether a Chinese or Japanese face draws `unit`: Han characters, kana,
    /// bopomofo, CJK punctuation and full-width forms. The low half of a
    /// surrogate pair goes with its high half.
    static func isCJK(_ unit: UInt16) -> Bool {
        isHan(unit) || isKana(unit) || (0x3000...0x303F).contains(unit) || (0xFF00...0xFF65).contains(unit)
            || (0x3100...0x312F).contains(unit) || (0x2E80...0x2FDF).contains(unit) || (0x31C0...0x31EF).contains(unit)
            || (0xFE30...0xFE4F).contains(unit)
    }

    /// The runs of `text`, in UTF-16 offsets, that a Chinese or Japanese
    /// face draws.
    static func runs(in text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start = -1
        var index = 0
        while index < text.length {
            let unit = text.character(at: index)
            var length = 1
            if CFStringIsSurrogateHighCharacter(unit) && index + 1 < text.length { length = 2 }
            if isCJK(unit) {
                if start < 0 { start = index }
            } else if start >= 0 {
                result.append(NSRange(location: start, length: index - start))
                start = -1
            }
            index += length
        }
        if start >= 0 { result.append(NSRange(location: start, length: text.length - start)) }
        return result
    }

    /// The language of `text` for drawing it: Japanese where it has kana, or
    /// where it has only Han characters in a Japanese document; `chinese`
    /// for other Han characters; nil for text with neither.
    static func language(of text: String, chinese: String, japaneseDocument: Bool) -> String? {
        var han = false
        for unit in text.utf16 {
            if isKana(unit) { return "ja" }
            if !han && isHan(unit) { han = true }
        }
        return han ? (japaneseDocument ? "ja" : chinese) : nil
    }

    /// Whether `text` is mostly Japanese: kana make up a fifth of its kana
    /// and Han characters. Japanese prose is more kana than kanji, while a
    /// Chinese note that quotes a Japanese title stays well under.
    static func isJapanese(_ text: String) -> Bool {
        var kana = 0
        var han = 0
        for unit in text.utf16 {
            if isKana(unit) { kana += 1 } else if isHan(unit) { han += 1 }
        }
        return kana > 0 && kana * 5 >= kana + han
    }
}
