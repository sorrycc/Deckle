package editor

import (
	"math"
	"strings"
	"unicode/utf16"

	"deckle/internal/markdown"
	"deckle/internal/theme"

	"github.com/egoist/mygo/ui"
)

// Look is how an editor shows its text, from the settings.
type Look struct {
	Theme theme.Theme
	Fonts theme.Fonts
	// LineHeight is a multiple of the font's height.
	LineHeight float32
	// LineWidth is the widest a line of text gets.
	LineWidth float32
	// HidesMarkers shows Markdown's syntax only around the selection.
	HidesMarkers bool
	// Japanese makes lines of only Han characters Japanese: the note is
	// mostly Japanese.
	Japanese bool
}

func (l *Look) key() lookKey {
	return lookKey{l.Theme.ID, l.Theme.Dark, l.Theme.Accent, l.Fonts, l.LineHeight, l.HidesMarkers, l.Japanese}
}

type lookKey struct {
	theme  string
	dark   bool
	accent ui.Color
	fonts  theme.Fonts
	lh     float32
	hides  bool
	ja     bool
}

const (
	quoteIndent  = 18
	blockPadding = 14
	// markerCenter is where a bullet or box sits in its marker's room,
	// from its start.
	markerCenter = 0.42
	hiddenSize   = 0.01
)

var calloutNames = []string{"", "Note", "Tip", "Important", "Warning", "Caution"}

// markerStep is the width of one level of a list at a font size: the
// marker's room, and each nested level steps in by it, so bullets, boxes
// and numbers line up and their text starts in one column.
func markerStep(size float32) float32 { return float32(math.Round(float64(size * 1.5))) }

// attr is how a unit of a line looks.
type attr struct {
	family    string
	size      float32
	weight    int
	italic    bool
	color     ui.Color
	bg        ui.Color
	radius    float32
	underline bool
	strike    bool
	decoColor ui.Color
	spacing   float32
	lang      string
	hidden    bool
}

type blockDeco uint8

const (
	blockNone blockDeco = iota
	blockCode
	blockFront
)

// deco is what a line draws besides its text.
type deco struct {
	block                 blockDeco
	blockFirst, blockLast bool
	// blockLabel is the language at the top right of a code block.
	blockLabel                string
	quoteDepth                int
	quoteFirst, quoteLast     uint32 // bits by depth
	callout                   int
	calloutFirst, calloutLast bool
	calloutName               string
	calloutHasTitle           bool
	drawsRule                 bool
	widget                    widget
	bullets                   []bulletDeco
	checkboxes                []checkDeco
	inlineImages              []inlineImage
	hasCode                   bool
}

type bulletDeco struct{ index, level int }
type checkDeco struct {
	index   int
	checked bool
}
type inlineImage struct {
	index int
	img   *ui.Bitmap
	w, h  float32
}

// lineLook is a line styled: its runs and how it sits, before it is laid
// out at a width.
type lineLook struct {
	text  string // the line, without its newline
	attrs []attr
	font  ui.Font
	// lineH is the height of each row; closed lines take none.
	lineH       float32
	closed      bool
	spaceBefore float32
	spaceAfter  float32
	// widgetTop is where the widget above the text starts.
	widgetTop   float32
	indent      float32
	rightIndent float32
	// A list item's prefix, its indentation, marker and box, is laid out
	// on its own at prefixX, and the text after it at bodyX, where its
	// wrapped lines line up.
	prefixEnd int
	prefixX   float32
	bodyX     float32
	deco      deco
	glyphH    float32
	ascent    float32
	lang      string
}

// localSpan is a span with offsets within its line.
type localSpan struct {
	markdown.Span
	elem [2]int // absolute
}

func (s localSpan) element() [2]int { return s.elem }

// cjk tells kana and Han characters, to tag a line with its language.
func isKana(r rune) bool {
	return (r >= 0x3040 && r <= 0x30FF && r != 0x30FB) || (r >= 0x31F0 && r <= 0x31FF) || (r >= 0xFF66 && r <= 0xFF9F)
}

func isHan(r rune) bool {
	return r >= 0x4E00 && r <= 0x9FFF || r >= 0x3400 && r <= 0x4DBF || r >= 0xF900 && r <= 0xFAFF || r >= 0x20000 && r <= 0x2FFFF
}

// cjkLanguage is the language text is drawn in: Japanese where it has
// kana, or where it has only Han characters in a Japanese document;
// chinese for other Han characters; "" for text with neither.
func cjkLanguage(text, chinese string, japanese bool) string {
	han := false
	for _, r := range text {
		if isKana(r) {
			return "ja"
		}
		if isHan(r) {
			han = true
		}
	}
	if !han {
		return ""
	}
	if japanese {
		return "ja"
	}
	if chinese == "" {
		return "zh-Hans"
	}
	return chinese
}

// IsJapanese reports whether text is mostly Japanese: kana make up a fifth
// of its kana and Han characters.
func IsJapanese(text string) bool {
	kana, han := 0, 0
	for _, r := range text {
		if isKana(r) {
			kana++
		} else if isHan(r) {
			han++
		}
	}
	return kana > 0 && kana*5 >= kana+han
}

// naturalHeight is the height of a line of font.
func naturalHeight(f ui.Font) (h, ascent float32) {
	m := f.Metrics()
	return m.Ascent + m.Descent + m.LineGap, m.Ascent
}

func ceil(x float32) float32   { return float32(math.Ceil(float64(x))) }
func roundf(x float32) float32 { return float32(math.Round(float64(x))) }

// rowHeight is the height of a row of font: a heading's lines sit close,
// as display type does, and code's a little closer than text's.
func (l *Look) rowHeight(f ui.Font, tight, heading bool) float32 {
	m := l.LineHeight
	if m < 1 {
		m = 1.5
	}
	switch {
	case heading:
		m = min(m, 1.25)
	case tight:
		m = min(m, 1.4)
	}
	h, _ := naturalHeight(f)
	return ceil(h * m)
}

// styler styles the lines of an editor.
type styler struct {
	look     *Look
	markdown bool
	// sel is the selection that decides which syntax shows.
	sel [2]int
	// hovered is the link under the pointer with ⌘ held.
	hovered [2]int
	widgets *widgets
	width   float32
}

func (s *styler) revealed(elem [2]int) bool {
	return !s.look.HidesMarkers || (s.sel[0] <= elem[1] && s.sel[1] >= elem[0])
}

// taskPrefix is the part of a task's line whose syntax shows together:
// from the start of the item through its box.
func taskPrefix(marker, task markdown.Span) [2]int {
	return [2]int{marker.ElemStart, min(task.End, task.ElemEnd)}
}

func (s *styler) baseFont() ui.Font {
	if s.markdown {
		return ui.Font{Family: s.look.Fonts.Body, Size: s.look.Fonts.Size}
	}
	return ui.Font{Family: s.look.Fonts.MonoFamily(), Size: s.look.Fonts.MonoSize()}
}

// style styles line text, starting at unit start, with the spans of its
// line. afterHeading says it follows a heading.
func (s *styler) style(text string, start int, spans []markdown.Span, afterHeading bool) *lineLook {
	t := &s.look.Theme
	fonts := s.look.Fonts
	n := markdown.UnitsOf(text)
	look := &lineLook{text: text}
	a := make([]attr, n)
	base := attr{color: t.Text}
	lineFont := s.baseFont()
	tight := !s.markdown
	headingLevel := 0
	d := &look.deco
	// content is the line without a \r at its end.
	content := n
	if strings.HasSuffix(text, "\r") {
		content--
	}
	all := func(f func(x *attr)) {
		for i := range a {
			f(&a[i])
		}
	}
	over := func(r [2]int, f func(x *attr)) {
		for i := max(r[0], 0); i < min(r[1], n); i++ {
			f(&a[i])
		}
	}
	for i := range a {
		a[i] = base
	}
	local := func(sp markdown.Span) [2]int {
		return [2]int{max(0, sp.Start-start), min(n, sp.End-start)}
	}
	elem := func(sp markdown.Span) [2]int { return [2]int{sp.ElemStart, sp.ElemEnd} }
	mono := func(size float32) (string, float32) {
		return fonts.MonoFamily(), roundf(size * 0.9)
	}
	monoAttr := func(x *attr, size float32) {
		x.family, x.size = mono(size)
		if x.size < 1 {
			x.size = fonts.MonoSize()
		}
	}
	monoFam := fonts.MonoFamily()

	// Block spans first: they set the line's font, which inline ones vary.
	for _, sp := range spans {
		r := local(sp)
		switch sp.Kind {
		case markdown.Heading:
			headingLevel = max(1, min(6, int(sp.Level)))
			lineFont = ui.Font{Family: fonts.Body, Size: fonts.Heading(headingLevel), Weight: 700}
			all(func(x *attr) { x.color = t.Heading })
			// More room above a bigger heading: it opens a larger part.
			if start > 0 {
				look.spaceBefore = roundf(fonts.Size * []float32{1.0, 0.75, 0.55, 0.4, 0.3, 0.3}[headingLevel-1])
			}
		case markdown.CodeBlock, markdown.FrontMatter:
			isCode := sp.Kind == markdown.CodeBlock
			lineFont = ui.Font{Family: monoFam, Size: fonts.MonoSize()}
			tight = true
			var isFence bool
			if isCode {
				isFence = sp.Flags&(markdown.CodeFenceOpen|markdown.CodeFenceClose) != 0
			} else {
				isFence = sp.Start == sp.ElemStart || sp.End == sp.ElemEnd
			}
			rev := s.revealed(elem(sp))
			if !isCode {
				// Front matter is a small block of properties above the
				// note, its fences folded to a sliver of padding until the
				// selection is in it.
				lineFont.Size = roundf(fonts.MonoSize() * 0.9)
			}
			color := t.Text
			if isFence || !isCode {
				color = t.Syntax
				if !isCode {
					color = t.Secondary
				}
				if isCode && !rev {
					color = ui.Transparent
				}
			}
			all(func(x *attr) { x.color = color })
			if !isCode && isFence && !rev {
				look.lineH = 5
				all(func(x *attr) { x.hidden = true })
			}
			if isCode {
				d.block = blockCode
			} else {
				d.block = blockFront
			}
			d.blockFirst = sp.Start == sp.ElemStart
			d.blockLast = sp.End == sp.ElemEnd
			if isCode && d.blockFirst && isFence {
				info := strings.Trim(text[byteOfUnit(text, r[0]):byteOfUnit(text, r[1])], "`~ ")
				if f := strings.Fields(info); len(f) > 0 {
					d.blockLabel = strings.ToUpper(f[0])
				}
			}
			look.indent = blockPadding
			look.rightIndent = blockPadding
		case markdown.BlockQuote:
			d.quoteDepth = max(d.quoteDepth, int(sp.Level))
			if sp.Start == sp.ElemStart {
				d.quoteFirst |= 1 << sp.Level
			}
			if sp.End == sp.ElemEnd {
				d.quoteLast |= 1 << sp.Level
			}
			if sp.Flags != 0 {
				d.callout = int(sp.Flags)
				d.calloutFirst = sp.Start == sp.ElemStart
				d.calloutLast = sp.End == sp.ElemEnd
			} else if d.callout == 0 {
				all(func(x *attr) { x.color = t.Secondary })
			}
		case markdown.Table:
			lineFont = ui.Font{Family: monoFam, Size: fonts.MonoSize()}
			if sp.Flags&markdown.TableDelimiter != 0 {
				all(func(x *attr) { x.color = t.Syntax })
			}
		case markdown.HTML:
			over(r, func(x *attr) { monoAttr(x, lineFont.Size); x.color = t.Secondary })
		case markdown.MathBlock:
			over(r, func(x *attr) { monoAttr(x, lineFont.Size); x.color = t.Type })
		}
	}
	if d.quoteDepth > 0 {
		indent := float32(d.quoteDepth) * quoteIndent
		if d.callout != 0 {
			indent += 10
			look.rightIndent = blockPadding
			// The same room below the last line as above the first.
			if d.calloutFirst {
				look.spaceBefore += 3
			}
			if d.calloutLast {
				look.spaceAfter += 5
			}
		}
		look.indent += indent
	}

	var taskChecked [2]int
	for i := range spans {
		sp := spans[i]
		r := local(sp)
		if r[1] <= r[0] {
			continue
		}
		switch sp.Kind {
		case markdown.Emphasis:
			over(r, func(x *attr) { x.italic = true })
		case markdown.Strong:
			over(r, func(x *attr) { x.weight = 700 })
		case markdown.Strike:
			over(r, func(x *attr) { x.strike = true; x.color = t.Secondary })
		case markdown.Code:
			over(r, func(x *attr) {
				monoAttr(x, lineFont.Size)
				x.color = t.CodeText
				x.bg = t.CodeBackground
				x.radius = 4
			})
			d.hasCode = true
		case markdown.Link, markdown.WikiLink:
			hovered := s.hovered == [2]int{sp.Start, sp.End}
			over(r, func(x *attr) {
				x.color = t.Link
				if hovered {
					x.underline = true
					x.decoColor = t.Link
				}
			})
		case markdown.Image:
			over(r, func(x *attr) { x.color = t.Secondary })
		case markdown.FootnoteRef, markdown.FootnoteDef:
			hovered := s.hovered == [2]int{sp.Start, sp.End}
			over(r, func(x *attr) {
				x.color = t.Accent
				x.size = roundf(lineFont.Size * 0.75)
				if hovered {
					x.underline = true
				}
			})
		case markdown.Superscript, markdown.Subscript:
			over(r, func(x *attr) { x.size = roundf(lineFont.Size * 0.75) })
		case markdown.InlineMath:
			over(r, func(x *attr) { monoAttr(x, lineFont.Size); x.color = t.Type })
		case markdown.Highlight:
			over(r, func(x *attr) { x.bg = t.Highlight; x.radius = 3 })
		case markdown.ListMarker:
			var task *markdown.Span
			for k := range spans {
				if spans[k].Kind == markdown.TaskMarker && spans[k].Start >= sp.End {
					task = &spans[k]
					break
				}
			}
			rev := s.revealed(elem(sp))
			if task != nil {
				rev = s.revealed(taskPrefix(sp, *task))
			}
			level := max(1, int(sp.Level))
			step := markerStep(lineFont.Size)
			if sp.Flags == 0 && s.markdown && !rev {
				if task == nil {
					// A bullet is drawn in the marker's room; the marker
					// keeps its place in the text, unseen.
					over(r, func(x *attr) { x.color = ui.Transparent })
					d.bullets = append(d.bullets, bulletDeco{r[0], level})
				} else {
					// A task's box stands in for its marker and brackets,
					// which fold away.
					over([2]int{r[0], min(content, r[1]+1)}, func(x *attr) { x.hidden = true })
				}
			} else {
				over(r, func(x *attr) { x.color = t.Accent })
			}
			prefixEnd := min(content, r[1]+1)
			if task != nil {
				tr := local(*task)
				if s.markdown && !rev {
					over(tr, func(x *attr) { x.hidden = true })
				} else {
					over(tr, func(x *attr) { monoAttr(x, lineFont.Size) })
				}
				prefixEnd = min(content, tr[1]+1)
			}
			// The indentation before the marker folds: the marker is placed
			// at its level's step.
			over([2]int{0, r[0]}, func(x *attr) { x.hidden = true })
			look.prefixEnd = prefixEnd
			look.prefixX = float32(level-1) * step
			look.bodyX = float32(level) * step
		case markdown.TaskMarker:
			checked := sp.Flags != 0
			var m *markdown.Span
			for k := range spans {
				if spans[k].Kind == markdown.ListMarker && spans[k].ElemStart == sp.ElemStart && spans[k].End <= sp.Start {
					m = &spans[k]
				}
			}
			rev := s.revealed(elem(sp))
			if m != nil {
				rev = s.revealed(taskPrefix(*m, sp))
			}
			if s.markdown && !rev {
				over(r, func(x *attr) { x.hidden = true })
				d.checkboxes = append(d.checkboxes, checkDeco{r[0], checked})
			} else {
				c := t.Accent
				if checked {
					c = t.Syntax
				}
				over(r, func(x *attr) { monoAttr(x, lineFont.Size); x.color = c })
			}
			if checked {
				from := min(content, r[1]+1)
				taskChecked = [2]int{from, content}
			}
		case markdown.TableCell:
			if sp.Flags&(markdown.TableHeader<<4) != 0 {
				over(r, func(x *attr) { x.weight = 700 })
			}
		case markdown.TokenKeyword:
			over(r, func(x *attr) { x.color = t.Keyword })
		case markdown.TokenString:
			over(r, func(x *attr) { x.color = t.String })
		case markdown.TokenComment:
			over(r, func(x *attr) { x.color = t.Comment })
		case markdown.TokenNumber:
			over(r, func(x *attr) { x.color = t.Number })
		case markdown.TokenType:
			over(r, func(x *attr) { x.color = t.Type })
		case markdown.TokenFunction:
			over(r, func(x *attr) { x.color = t.Function })
		case markdown.TokenConstant:
			over(r, func(x *attr) { x.color = t.Constant })
		case markdown.TokenProperty:
			over(r, func(x *attr) { x.color = t.Property })
		case markdown.TokenPunctuation:
			over(r, func(x *attr) { x.color = t.Syntax })
		case markdown.TokenInserted:
			over(r, func(x *attr) { x.color = t.Inserted })
		case markdown.TokenDeleted:
			over(r, func(x *attr) { x.color = t.Deleted })
		}
	}
	if taskChecked[1] > taskChecked[0] {
		over(taskChecked, func(x *attr) { x.strike = true; x.color = t.Secondary })
	}

	// Syntax last, so that hiding it wins over what it sits in.
	var hidden [][2]int
	hide := func(r [2]int) {
		over(r, func(x *attr) { x.hidden = true })
		hidden = append(hidden, r)
	}
	for _, sp := range spans {
		r := local(sp)
		if r[1] <= r[0] {
			continue
		}
		switch sp.Kind {
		case markdown.Marker:
			if s.revealed(elem(sp)) {
				over(r, func(x *attr) { x.color = t.Syntax })
			} else {
				hide(r)
			}
		case markdown.CalloutTag:
			after := [2]int{r[1], content}
			afterText := ""
			if after[1] > after[0] {
				afterText = text[byteOfUnit(text, after[0]):byteOfUnit(text, after[1])]
			}
			title := strings.TrimSpace(afterText)
			color := t.CalloutColor(int(sp.Flags))
			if after[1] > after[0] {
				over(after, func(x *attr) { x.color = color; x.weight = 700 })
			}
			if s.revealed(elem(sp)) {
				over(r, func(x *attr) { x.color = color })
			} else {
				// The space after the tag goes with it.
				spaces := len(afterText) - len(strings.TrimLeft(afterText, " "))
				hide([2]int{r[0], r[1] + spaces})
				d.calloutName = calloutNames[min(5, int(sp.Flags))]
				d.calloutHasTitle = title != ""
			}
		case markdown.ThematicBreak:
			if s.revealed(elem(sp)) {
				over(r, func(x *attr) { x.color = t.Syntax })
			} else {
				hide(r)
				d.drawsRule = true
			}
		}
	}
	for _, sp := range spans {
		r := local(sp)
		if r[1] <= r[0] {
			continue
		}
		if sp.Kind == markdown.LinkDest || sp.Kind == markdown.ImageDest {
			// Shown with its link's syntax, or on its own for a bare link.
			overlaps := false
			for _, h := range hidden {
				if h[0] < r[1] && r[0] < h[1] {
					overlaps = true
				}
			}
			if !overlaps && (sp.Start != sp.ElemStart || sp.End != sp.ElemEnd) {
				over(r, func(x *attr) { x.color = t.Link.Alpha(0.7); x.underline = true; x.decoColor = t.Link.Alpha(0.7) })
			}
		}
	}
	if content < n {
		over([2]int{content, n}, func(x *attr) { x.hidden = true })
	}

	look.font = lineFont
	if s.markdown && s.widgets != nil {
		s.widgets.apply(s, look, a, text, start, spans, hide)
	}
	lang := cjkLanguage(text, fonts.ChineseScript, s.look.Japanese)
	look.lang = lang
	if afterHeading && strings.TrimSpace(text) == "" {
		look.lineH = roundf(s.look.rowHeight(lineFont, false, false) * 0.6)
	}
	natural, ascent := naturalHeight(lineFont)
	look.glyphH, look.ascent = natural, ascent
	if look.lineH == 0 {
		look.lineH = s.look.rowHeight(lineFont, tight, headingLevel > 0)
	}
	for i := range a {
		if a[i].family == "" {
			a[i].family = lineFont.Family
			if !strings.Contains(a[i].family, "monospace") {
				a[i].family = fonts.BodyFamily(lang)
			}
		}
		if a[i].size == 0 {
			a[i].size = lineFont.Size
		}
		if a[i].weight == 0 {
			a[i].weight = lineFont.Weight
		}
		a[i].lang = lang
	}
	look.attrs = a
	return look
}

// spans turns the attributes of units from..to of a line into runs.
func (l *lineLook) spans(from, to int) []ui.Span {
	var out []ui.Span
	text := l.text
	b0 := byteOfUnit(text, from)
	units := from
	// Walk runes, so a surrogate pair stays whole.
	start, startByte := from, b0
	cur := l.attrs
	flush := func(end, endByte int) {
		if end <= start {
			return
		}
		x := cur[start]
		sp := ui.Span{Text: text[startByte:endByte], Font: x.family, Size: x.size, Weight: x.weight, Italic: x.italic, Color: x.color,
			Underline: x.underline, Strikethrough: x.strike, DecorationColor: x.decoColor, Background: x.bg, Radius: x.radius,
			LetterSpacing: x.spacing, Lang: x.lang}
		if x.hidden {
			sp = ui.Span{Text: sp.Text, Size: hiddenSize, Color: ui.RGBA(0, 0, 0, 0.004), Font: x.family, LetterSpacing: x.spacing}
		}
		if sp.Color == ui.Transparent && !x.hidden {
			sp.Color = ui.RGBA(0, 0, 0, 0.004)
		}
		out = append(out, sp)
	}
	for i, r := range text[b0:] {
		if units >= to {
			break
		}
		if units > start && cur[units] != cur[start] {
			flush(units, b0+i)
			start, startByte = units, b0+i
		}
		units += unitLen(r)
	}
	flush(min(units, to), byteOfUnit(text, min(units, to)))
	return out
}

// unitsOf is the UTF-16 length of s.
func unitsOf(s string) int { return len(utf16.Encode([]rune(s))) }
