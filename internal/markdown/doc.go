package markdown

import (
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

// A Doc is an open document: its text, mirrored from the editor, and the
// spans of each of its sections. Offsets it takes and returns are UTF-16
// units, as text layout counts them.
type Doc struct {
	text string
	// "markdown", a language the lexer knows, or "" for plain text.
	language string
	sections []section
	// Where each section starts, in bytes and in UTF-16 units, with the
	// document's length at the end.
	byteStarts []int
	unitStarts []int
}

type section struct {
	bytes, units int
	// Offsets are UTF-16 units from the section's start.
	spans []Span
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

// unitOffsets is the UTF-16 offset of every byte offset of s, its length
// included, or nil when s is ASCII.
func unitOffsets(s string) []int {
	if isASCII(s) {
		return nil
	}
	m := make([]int, 0, len(s)+1)
	units := 0
	for _, r := range s {
		n := utf8.RuneLen(r)
		if n < 0 {
			n = 1
		}
		for range n {
			m = append(m, units)
		}
		units += utf16Len(r)
	}
	// Invalid bytes decode as one rune each; keep the map the text's length.
	for len(m) < len(s) {
		m = append(m, units)
	}
	m = m[:len(s)]
	return append(m, units)
}

func utf16Len(r rune) int {
	if r >= 0x10000 {
		return 2
	}
	return 1
}

// UnitsOf is the length of s in UTF-16 units.
func UnitsOf(s string) int {
	if isASCII(s) {
		return len(s)
	}
	n := 0
	for _, r := range s {
		n += utf16Len(r)
	}
	return n
}

// ByteOf is the byte offset of UTF-16 offset units in s.
func ByteOf(s string, units int) int {
	if isASCII(s) {
		return min(max(units, 0), len(s))
	}
	seen := 0
	for i, r := range s {
		if seen >= units {
			return i
		}
		seen += utf16Len(r)
	}
	return len(s)
}

// NewDoc opens a document of text written in language.
func NewDoc(text, language string) *Doc {
	d := &Doc{text: text, language: language}
	d.parseAll()
	return d
}

func (d *Doc) parseAll() {
	bounds := d.bounds()
	d.sections = make([]section, len(bounds)-1)
	for i := range d.sections {
		d.sections[i] = d.parse(bounds[i], bounds[i+1], i == 0)
	}
	d.index()
}

// Text is the document's text.
func (d *Doc) Text() string { return d.text }

// Language is what the document is written in.
func (d *Doc) Language() string { return d.language }

// bounds are the section boundaries in bytes, the text's length last.
func (d *Doc) bounds() []int {
	var b []int
	if d.language == "markdown" {
		b = SplitSections(d.text)
	} else {
		b = []int{0}
	}
	return append(b, len(d.text))
}

func (d *Doc) parse(start, end int, first bool) (s section) {
	text := d.text[start:end]
	var spans []Span
	func() {
		// A parser that trips over some odd input leaves its section plain
		// rather than taking the editor down with it.
		defer func() {
			if recover() != nil {
				spans = nil
			}
		}()
		if d.language == "markdown" {
			spans = ParseSection(text, first)
		} else if len(text) < 2_000_000 {
			// Past this size the lexer would hold up typing.
			Lex(d.language, text, 0, &spans)
		}
	}()
	units := len(text)
	if m := unitOffsets(text); m != nil {
		at := func(b int) int { return m[min(b, len(m)-1)] }
		for i := range spans {
			sp := &spans[i]
			sp.Start, sp.End, sp.ElemStart, sp.ElemEnd = at(sp.Start), at(sp.End), at(sp.ElemStart), at(sp.ElemEnd)
		}
		units = m[len(m)-1]
	}
	return section{bytes: end - start, units: units, spans: spans}
}

func (d *Doc) index() {
	d.byteStarts = d.byteStarts[:0]
	d.unitStarts = d.unitStarts[:0]
	b, u := 0, 0
	for _, s := range d.sections {
		d.byteStarts = append(d.byteStarts, b)
		d.unitStarts = append(d.unitStarts, u)
		b += s.bytes
		u += s.units
	}
	d.byteStarts = append(d.byteStarts, b)
	d.unitStarts = append(d.unitStarts, u)
}

// Units is the document's length in UTF-16 units.
func (d *Doc) Units() int { return d.unitStarts[len(d.unitStarts)-1] }

// sectionAt is the section holding UTF-16 offset units.
func (d *Doc) sectionAt(units int) int {
	i := sort.Search(len(d.unitStarts), func(i int) bool { return d.unitStarts[i] > units })
	return min(max(i-1, 0), max(len(d.sections)-1, 0))
}

// ByteAt is the byte offset of UTF-16 offset units.
func (d *Doc) ByteAt(units int) int {
	if len(d.sections) == 0 {
		return 0
	}
	i := d.sectionAt(units)
	start, end := d.byteStarts[i], d.byteStarts[i+1]
	return start + ByteOf(d.text[start:end], units-d.unitStarts[i])
}

// UnitAt is the UTF-16 offset of byte offset b.
func (d *Doc) UnitAt(b int) int {
	b = min(max(b, 0), len(d.text))
	i := sort.Search(len(d.byteStarts), func(i int) bool { return d.byteStarts[i] > b })
	i = min(max(i-1, 0), max(len(d.sections)-1, 0))
	if len(d.sections) == 0 {
		return 0
	}
	return d.unitStarts[i] + UnitsOf(d.text[d.byteStarts[i]:b])
}

// Edit replaces oldLen units at start with s, mirroring an edit of the
// editor's text, and returns the range whose styling may have changed, in
// units of the new text.
func (d *Doc) Edit(start, oldLen int, s string) (dirtyStart, dirtyEnd int) {
	start = min(max(start, 0), d.Units())
	oldEnd := min(start+oldLen, d.Units())
	byteStart := d.ByteAt(start)
	byteOldEnd := max(d.ByteAt(oldEnd), byteStart)
	newUnits := UnitsOf(s)
	d.text = d.text[:byteStart] + s + d.text[byteOldEnd:]
	// The sections are reworked from the new text. Should that trip over
	// some odd input, the whole document is parsed afresh instead.
	ok := false
	func() {
		defer func() { recover() }()
		dirtyStart, dirtyEnd = d.reparse(start, oldEnd, newUnits, byteStart, byteOldEnd, len(s))
		ok = true
	}()
	if !ok {
		d.parseAll()
		return 0, d.Units()
	}
	return dirtyStart, dirtyEnd
}

func (d *Doc) reparse(start, oldEnd, newUnits, byteStart, byteOldEnd, newLen int) (int, int) {
	byteNewEnd := byteStart + newLen
	byteDelta := byteNewEnd - byteOldEnd
	unitDelta := newUnits - (oldEnd - start)

	bounds := d.bounds()
	old := d.sections
	taken := make([]bool, len(old))
	oldByteStarts := append([]int(nil), d.byteStarts...)
	oldUnitStarts := append([]int(nil), d.unitStarts...)
	// The old section that covered exactly these bytes of the old text.
	find := func(s, e int) int {
		if s < 0 {
			return -1
		}
		i, ok := sort.Find(len(oldByteStarts), func(i int) int { return s - oldByteStarts[i] })
		if !ok || i+1 >= len(oldByteStarts) || oldByteStarts[i+1] != e {
			return -1
		}
		return i
	}
	sections := make([]section, 0, len(bounds)-1)
	var parsed []int
	for i := 0; i < len(bounds)-1; i++ {
		s, e := bounds[i], bounds[i+1]
		j := -1
		if e <= byteStart && e > s {
			j = find(s, e)
		} else if s >= byteNewEnd && e > s {
			j = find(s-byteDelta, e-byteDelta)
		}
		// The first section alone reads front matter, so a section only
		// keeps its spans while it keeps being first, or not first.
		if j >= 0 && (j == 0) == (i == 0) && !taken[j] {
			taken[j] = true
			sections = append(sections, old[j])
		} else {
			sections = append(sections, d.parse(s, e, i == 0))
			parsed = append(parsed, i)
		}
	}
	d.sections = sections
	d.index()

	// Narrow the changed range to where the spans differ.
	first, last := 0, 0
	if len(parsed) > 0 {
		first, last = parsed[0], parsed[len(parsed)-1]
	}
	contiguous := len(parsed) == last-first+1
	ds, de := start, start+newUnits
	region := [2]int{d.unitStarts[first], d.unitStarts[last+1]}
	var replaced []int
	for i := range old {
		if !taken[i] {
			replaced = append(replaced, i)
		}
	}
	if !contiguous || len(replaced) == 0 {
		return min(ds, region[0]), max(de, region[1])
	}
	abs := func(base int, s Span) Span {
		s.Start += base
		s.End += base
		s.ElemStart += base
		s.ElemEnd += base
		return s
	}
	var before, after []Span
	for _, i := range replaced {
		for _, sp := range old[i].spans {
			before = append(before, abs(oldUnitStarts[i], sp))
		}
	}
	for i := first; i <= last; i++ {
		for _, sp := range d.sections[i].spans {
			after = append(after, abs(d.unitStarts[i], sp))
		}
	}
	shift := func(s Span) Span { return abs(unitDelta, s) }
	// A line of a long block, such as a code block or a quote, looks the
	// same when the block grows or shrinks around an edit elsewhere in it:
	// its span keeps everything but the far edge of its element, which
	// moves with the text. Such lines are not dirty, so typing in a block of
	// thousands of lines restyles the line typed in, not the block. The
	// editor restyles the first line of a block it draws as a whole, a table
	// or a diagram, itself.
	sameBefore := func(b, a Span) bool {
		if b.End >= start {
			return false
		}
		if b == a {
			return true
		}
		if b.ElemEnd >= oldEnd {
			b.ElemEnd += unitDelta
			return b == a
		}
		return false
	}
	sameAfter := func(b, a Span) bool {
		if b.Start <= oldEnd {
			return false
		}
		moved := shift(b)
		if moved == a {
			return true
		}
		if b.ElemStart <= start {
			moved.ElemStart = b.ElemStart
			return moved == a
		}
		return false
	}
	head := 0
	for head < len(before) && head < len(after) && sameBefore(before[head], after[head]) {
		head++
	}
	tail := 0
	for tail < len(before)-head && tail < len(after)-head {
		if !sameAfter(before[len(before)-1-tail], after[len(after)-1-tail]) {
			break
		}
		tail++
	}
	for _, s := range after[head : len(after)-tail] {
		ds = min(ds, s.Start)
		de = max(de, s.End)
	}
	for _, s := range before[head : len(before)-tail] {
		ds = min(ds, min(s.Start, start))
		de = max(de, min(max(s.End+unitDelta, 0), region[1]))
	}
	return max(ds, min(region[0], start)), min(de, d.Units())
}

// LineOf is the 1-based line that UTF-16 offset units is on.
func (d *Doc) LineOf(units int) int {
	end := d.ByteAt(min(units, d.Units()))
	return strings.Count(d.text[:end], "\n") + 1
}

// CountWords counts words as a writer does: runs of letters and digits,
// and each Chinese, Japanese or Korean character on its own.
func (d *Doc) CountWords() int { return CountWords(d.text) }

// CountWords counts the words of s, as Doc.CountWords does.
func CountWords(s string) int {
	count := 0
	inWord := false
	for _, r := range s {
		wide := (r >= 0x2E80 && r <= 0x9FFF || r >= 0xAC00 && r <= 0xD7AF || r >= 0xF900 && r <= 0xFAFF || r >= 0x20000 && r <= 0x2FA1F) &&
			!(r >= 0x3000 && r <= 0x303F)
		switch {
		case wide:
			count++
			inWord = false
		case unicode.IsLetter(r) || unicode.IsDigit(r) || unicode.IsNumber(r):
			if !inWord {
				count++
			}
			inWord = true
		case r != '\'' && r != '’':
			inWord = false
		}
	}
	return count
}

// SpansIn returns the spans that start in start..end, which should be
// whole lines. The result is the caller's.
func (d *Doc) SpansIn(start, end int) []Span {
	var out []Span
	if len(d.sections) == 0 || end <= start {
		return out
	}
	for i := d.sectionAt(start); i < len(d.sections); i++ {
		base := d.unitStarts[i]
		if base >= end {
			break
		}
		spans := d.sections[i].spans
		from := sort.Search(len(spans), func(k int) bool { return spans[k].Start+base >= start })
		for _, s := range spans[from:] {
			if s.Start+base >= end {
				break
			}
			s.Start += base
			s.End += base
			s.ElemStart += base
			s.ElemEnd += base
			out = append(out, s)
		}
	}
	return out
}

// SpansOfKind returns every span of kind, one per element.
func (d *Doc) SpansOfKind(kind Kind) []Span {
	var out []Span
	for i, sec := range d.sections {
		base := d.unitStarts[i]
		for _, s := range sec.spans {
			if s.Kind == kind && s.Start == s.ElemStart {
				s.Start += base
				s.End += base
				s.ElemStart += base
				s.ElemEnd += base
				out = append(out, s)
			}
		}
	}
	return out
}
