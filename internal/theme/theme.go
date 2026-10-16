// Package theme holds the colors of Deckle's themes: the System theme,
// which follows light and dark mode and the system's accent, and eight
// palettes that bring an appearance of their own.
package theme

import "github.com/egoist/mygo/ui"

// Theme is the colors of the editor and the window around it.
type Theme struct {
	ID, Name string
	// Dark is the appearance the theme brings; System follows the
	// desktop's.
	Dark       bool
	Background ui.Color
	Text       ui.Color
	// Secondary is quotes, struck text and the text of front matter.
	Secondary ui.Color
	// Syntax is Markdown's syntax, where it shows.
	Syntax         ui.Color
	Accent         ui.Color
	Heading        ui.Color
	Link           ui.Color
	CodeText       ui.Color
	CodeBackground ui.Color
	QuoteBar       ui.Color
	Rule           ui.Color
	Highlight      ui.Color
	Keyword        ui.Color
	String         ui.Color
	Comment        ui.Color
	Number         ui.Color
	Type           ui.Color
	Function       ui.Color
	Constant       ui.Color
	Property       ui.Color
	Inserted       ui.Color
	Deleted        ui.Color
	// Selection is the selected text's background.
	Selection ui.Color
	// Callouts are the colors of note, tip, important, warning and
	// caution.
	Callouts [5]ui.Color
	// Panel is the background of the sidebar and the lists around the
	// editor; Border separates them.
	Panel  ui.Color
	Border ui.Color
}

// OnAccent is what reads on the accent: white on a deep one, the page on
// a pale one.
func (t *Theme) OnAccent() ui.Color {
	c := t.Accent
	l := 0.2126*float64(c.R) + 0.7152*float64(c.G) + 0.0722*float64(c.B)
	if l/255 > 0.62 {
		return t.Background
	}
	return ui.RGB(255, 255, 255)
}

// CalloutColor is the color of a callout by kind, from 1.
func (t *Theme) CalloutColor(kind int) ui.Color {
	return t.Callouts[max(0, min(kind-1, 4))]
}

func hex(v uint32) ui.Color { return ui.RGB(uint8(v>>16), uint8(v>>8), uint8(v)) }

func hexA(v uint32, a float32) ui.Color { return ui.RGBA(uint8(v>>16), uint8(v>>8), uint8(v), a) }

// System is the theme that follows the desktop: light or dark, in the
// system's accent color.
func System(dark bool, accent ui.Color) Theme {
	pick := func(light, darkV uint32) ui.Color {
		if dark {
			return hex(darkV)
		}
		return hex(light)
	}
	t := Theme{ID: "system", Name: "System", Dark: dark, Accent: accent, Link: accent}
	if dark {
		t.Background = hex(0x1E1E1E)
		t.Text = ui.RGBA(255, 255, 255, 0.85)
		t.Secondary = ui.RGBA(255, 255, 255, 0.55)
		t.Syntax = ui.RGBA(255, 255, 255, 0.25)
		t.Heading = ui.RGBA(255, 255, 255, 0.85)
		t.CodeBackground = ui.RGBA(255, 255, 255, 0.06)
		t.QuoteBar = ui.RGBA(255, 255, 255, 0.1)
		t.Rule = ui.RGBA(255, 255, 255, 0.12)
		t.Panel = hex(0x252526)
		t.Border = ui.RGBA(255, 255, 255, 0.08)
		t.Selection = accent.Alpha(0.35)
	} else {
		t.Background = hex(0xFFFFFF)
		t.Text = ui.RGBA(0, 0, 0, 0.85)
		t.Secondary = ui.RGBA(0, 0, 0, 0.5)
		t.Syntax = ui.RGBA(0, 0, 0, 0.26)
		t.Heading = ui.RGBA(0, 0, 0, 0.85)
		t.CodeBackground = ui.RGBA(0, 0, 0, 0.04)
		t.QuoteBar = ui.RGBA(0, 0, 0, 0.1)
		t.Rule = ui.RGBA(0, 0, 0, 0.1)
		t.Panel = hex(0xF5F5F4)
		t.Border = ui.RGBA(0, 0, 0, 0.08)
		t.Selection = accent.Alpha(0.25)
	}
	t.CodeText = pick(0xB4331F, 0xFF9F7E)
	t.Highlight = pick(0xFFEE9A, 0x6B5A12)
	t.Keyword = pick(0xA626A4, 0xD48BE8)
	t.String = pick(0x2E8540, 0x9BD48A)
	t.Comment = pick(0x8A8F98, 0x747B87)
	t.Number = pick(0xB76B01, 0xE8B26B)
	t.Type = pick(0x0B7A8C, 0x6FCBDB)
	t.Function = pick(0x2B5FD9, 0x7FB0FF)
	t.Constant = pick(0xB76B01, 0xE8B26B)
	t.Property = pick(0xC2451E, 0xF0907A)
	t.Inserted = pick(0x28A745, 0x32D74B)
	t.Deleted = pick(0xD73A49, 0xFF453A)
	t.Callouts = [5]ui.Color{pick(0x007AFF, 0x0A84FF), pick(0x28CD41, 0x32D74B), pick(0xAF52DE, 0xBF5AF2), pick(0xFF9500, 0xFF9F0A), pick(0xFF3B30, 0xFF453A)}
	return t
}

type pal struct {
	id, name                                 string
	dark                                     bool
	background, text, secondary, syntax      uint32
	accent, heading, code, keyword, str      uint32
	comment, number, typ, function, property uint32
	highlight                                uint32
	callouts                                 []uint32
}

func palette(p pal) Theme {
	ink := hex(p.text)
	callouts := p.callouts
	if callouts == nil {
		// The palette's own blue, green, purple, orange and red: its code
		// colors where they are those.
		callouts = []uint32{p.function, p.str, p.keyword, p.number, p.property}
	}
	hl := float32(0.6)
	sel := float32(0.25)
	if p.dark {
		hl, sel = 0.35, 0.35
	}
	t := Theme{
		ID: p.id, Name: p.name, Dark: p.dark,
		Background: hex(p.background), Text: ink, Secondary: hex(p.secondary), Syntax: hex(p.syntax),
		Accent: hex(p.accent), Heading: hex(p.heading), Link: hex(p.accent), CodeText: hex(p.code),
		CodeBackground: ink.Alpha(0.06), QuoteBar: ink.Alpha(0.2), Rule: ink.Alpha(0.16),
		Highlight: hexA(p.highlight, hl), Keyword: hex(p.keyword), String: hex(p.str), Comment: hex(p.comment),
		Number: hex(p.number), Type: hex(p.typ), Function: hex(p.function), Constant: hex(p.number),
		Property: hex(p.property), Selection: hexA(p.accent, sel),
		Inserted: hex(p.str), Deleted: hex(p.property),
		Border: ink.Alpha(0.1),
	}
	for i := range t.Callouts {
		t.Callouts[i] = hex(callouts[i])
	}
	// The panels around the editor, a shade off the page.
	t.Panel = mix(t.Background, ink, 0.035)
	return t
}

func mix(a, b ui.Color, f float32) ui.Color {
	m := func(x, y uint8) uint8 { return uint8(float32(x)*(1-f) + float32(y)*f + 0.5) }
	return ui.RGB(m(a.R, b.R), m(a.G, b.G), m(a.B, b.B))
}

// Palettes are the themes with an appearance of their own, in the order
// Settings lists them after System.
var Palettes = []Theme{
	palette(pal{"paper", "Paper", false, 0xFBF7EF, 0x3B3630, 0x7D7468, 0xB5AB9C, 0xB4552D, 0x2A2621, 0x9A4A2B, 0x8B3F8F, 0x4F7A36, 0xA39A8C, 0xA8650F, 0x2F7A86, 0x2F5FA8, 0xB4552D, 0xF6D96B, nil}),
	palette(pal{"github-light", "GitHub Light", false, 0xFFFFFF, 0x1F2328, 0x59636E, 0xA5ADB7, 0x0969DA, 0x1F2328, 0xCF222E, 0xCF222E, 0x0A3069, 0x6E7781, 0x0550AE, 0x953800, 0x8250DF, 0x116329, 0xFFF1A8, []uint32{0x0969DA, 0x1A7F37, 0x8250DF, 0x9A6700, 0xCF222E}}),
	palette(pal{"solarized-light", "Solarized Light", false, 0xFDF6E3, 0x586E75, 0x839496, 0xB8C2C2, 0x268BD2, 0x073642, 0xCB4B16, 0x859900, 0x2AA198, 0x93A1A1, 0xD33682, 0xB58900, 0x268BD2, 0xCB4B16, 0xEEE1A8, []uint32{0x268BD2, 0x859900, 0x6C71C4, 0xB58900, 0xDC322F}}),
	palette(pal{"one-dark", "One Dark", true, 0x282C34, 0xABB2BF, 0x8289A0, 0x5C6370, 0x61AFEF, 0xE06C75, 0xE5C07B, 0xC678DD, 0x98C379, 0x5C6370, 0xD19A66, 0x56B6C2, 0x61AFEF, 0xE06C75, 0xE5C07B, nil}),
	palette(pal{"nord", "Nord", true, 0x2E3440, 0xD8DEE9, 0x9AA5B8, 0x616E88, 0x88C0D0, 0x8FBCBB, 0xEBCB8B, 0x81A1C1, 0xA3BE8C, 0x616E88, 0xB48EAD, 0x8FBCBB, 0x88C0D0, 0xD08770, 0xEBCB8B, []uint32{0x88C0D0, 0xA3BE8C, 0xB48EAD, 0xEBCB8B, 0xBF616A}}),
	palette(pal{"tokyo-night", "Tokyo Night", true, 0x1A1B26, 0xC0CAF5, 0x9AA5CE, 0x565F89, 0x7AA2F7, 0xBB9AF7, 0xFF9E64, 0xBB9AF7, 0x9ECE6A, 0x565F89, 0xFF9E64, 0x2AC3DE, 0x7AA2F7, 0x73DACA, 0xE0AF68, []uint32{0x7AA2F7, 0x9ECE6A, 0xBB9AF7, 0xE0AF68, 0xF7768E}}),
	palette(pal{"rose-pine", "Rosé Pine", true, 0x191724, 0xE0DEF4, 0x908CAA, 0x6E6A86, 0xC4A7E7, 0xEBBCBA, 0xF6C177, 0x31748F, 0xF6C177, 0x6E6A86, 0xEB6F92, 0x9CCFD8, 0xEBBCBA, 0xC4A7E7, 0xF6C177, []uint32{0x9CCFD8, 0x3E8FB0, 0xC4A7E7, 0xF6C177, 0xEB6F92}}),
	palette(pal{"dracula", "Dracula", true, 0x282A36, 0xF8F8F2, 0xB4B7C9, 0x6272A4, 0x8BE9FD, 0xBD93F9, 0xFFB86C, 0xFF79C6, 0xF1FA8C, 0x6272A4, 0xBD93F9, 0x8BE9FD, 0x50FA7B, 0xFFB86C, 0xF1FA8C, []uint32{0x8BE9FD, 0x50FA7B, 0xBD93F9, 0xFFB86C, 0xFF5555}}),
	palette(pal{"gruvbox-dark", "Gruvbox Dark", true, 0x282828, 0xEBDBB2, 0xBDAE93, 0x7C6F64, 0x83A598, 0xFABD2F, 0xFE8019, 0xFB4934, 0xB8BB26, 0x928374, 0xD3869B, 0x8EC07C, 0x83A598, 0xFE8019, 0xFABD2F, []uint32{0x83A598, 0xB8BB26, 0xD3869B, 0xFABD2F, 0xFB4934}}),
}

// IDs lists every theme's ID, System first.
func IDs() []string {
	ids := []string{"system"}
	for _, p := range Palettes {
		ids = append(ids, p.ID)
	}
	return ids
}

// Name is the name of the theme with id.
func Name(id string) string {
	for _, p := range Palettes {
		if p.ID == id {
			return p.Name
		}
	}
	return "System"
}

// Resolve is the theme with id, System when there is none, for a desktop
// that is dark or not, in the system's accent.
func Resolve(id string, dark bool, accent ui.Color) Theme {
	for _, p := range Palettes {
		if p.ID == id {
			return p
		}
	}
	return System(dark, accent)
}

// Fonts are the editor's fonts, from the settings.
type Fonts struct {
	// Body is an installed family for the text, or "" for the system's.
	Body string
	// Size is the text's size in points.
	Size float32
	// Mono is an installed family for code, or "" for the system's.
	Mono string
	// CJK is the face of Chinese and Japanese: "" for the system's,
	// "serif" for Songti and Hiragino Mincho, or an installed family.
	CJK string
	// ChineseScript is the Chinese of Han characters in text without
	// kana: zh-Hans, zh-Hant or zh-HK.
	ChineseScript string
}

// MonoFamily is the family of code.
func (f Fonts) MonoFamily() string {
	if f.Mono != "" {
		return f.Mono + ", monospace"
	}
	return "monospace"
}

// BodyFamily is the family of text, with the chosen face of Chinese and
// Japanese after it for the characters it lacks.
func (f Fonts) BodyFamily(lang string) string {
	fam := f.Body
	if cjk := f.CJKFamily(lang); cjk != "" {
		if fam == "" {
			fam = "system-ui"
		}
		fam += ", " + cjk
	}
	return fam
}

// CJKFamily is the family that draws the Chinese or Japanese of lang, or
// "" to leave it to the system.
func (f Fonts) CJKFamily(lang string) string {
	switch f.CJK {
	case "":
		return ""
	case "serif":
		switch lang {
		case "ja":
			return "Hiragino Mincho ProN"
		case "zh-Hans":
			return "Songti SC"
		}
		return "Songti TC"
	}
	return f.CJK
}

// Heading is the size of a heading of level, from 1.
func (f Fonts) Heading(level int) float32 {
	scale := []float32{1.7, 1.42, 1.22, 1.1, 1.0, 1.0}[max(1, min(level, 6))-1]
	return round(f.Size * scale)
}

// MonoSize is the size of code.
func (f Fonts) MonoSize() float32 { return round(f.Size * 0.9) }

func round(x float32) float32 { return float32(int(x + 0.5)) }
