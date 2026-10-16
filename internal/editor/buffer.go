// Package editor is Deckle's Markdown editor: plain text, styled as it is
// typed from the spans of package markdown, with the syntax shown only
// around the selection, and images, tables, math and diagrams drawn in
// place of their source.
package editor

import (
	"slices"
	"sort"
	"strings"
	"unicode/utf8"

	"deckle/internal/markdown"
)

// Buffer is the text of a note and its spans, with where each line starts.
// Offsets are UTF-16 units, as text layout and input methods count them.
type Buffer struct {
	doc *markdown.Doc
	// units and bytes are where each line starts; a line runs to the next
	// one's start, its newline included.
	units []int
	bytes []int
}

// NewBuffer holds text written in language.
func NewBuffer(text, language string) *Buffer {
	b := &Buffer{doc: markdown.NewDoc(text, language)}
	b.units, b.bytes = lineStarts(text, 0, 0)
	return b
}

func lineStarts(s string, unitBase, byteBase int) (units, bytes []int) {
	units, bytes = []int{unitBase}, []int{byteBase}
	u := unitBase
	for i, r := range s {
		u += unitLen(r)
		if r == '\n' {
			units = append(units, u)
			bytes = append(bytes, byteBase+i+1)
		}
	}
	return units, bytes
}

func unitLen(r rune) int {
	if r >= 0x10000 {
		return 2
	}
	return 1
}

// Text is the whole text.
func (b *Buffer) Text() string { return b.doc.Text() }

// Language is what the text is written in.
func (b *Buffer) Language() string { return b.doc.Language() }

// Doc is the text's spans.
func (b *Buffer) Doc() *markdown.Doc { return b.doc }

// Len is the text's length in units.
func (b *Buffer) Len() int { return b.doc.Units() }

// Lines is how many lines the text has: one more than its newlines.
func (b *Buffer) Lines() int { return len(b.units) }

// LineStart is where line i starts.
func (b *Buffer) LineStart(i int) int { return b.units[i] }

// LineEnd is where line i ends, before its newline.
func (b *Buffer) LineEnd(i int) int {
	if i+1 < len(b.units) {
		return b.units[i+1] - 1
	}
	return b.Len()
}

// Line is the text of line i, without its newline.
func (b *Buffer) Line(i int) string {
	end := len(b.Text())
	if i+1 < len(b.bytes) {
		end = b.bytes[i+1] - 1
	}
	return strings.TrimSuffix(b.Text()[b.bytes[i]:end], "\r")
}

// RawLine is line i with a \r before its newline kept.
func (b *Buffer) rawLine(i int) string {
	end := len(b.Text())
	if i+1 < len(b.bytes) {
		end = b.bytes[i+1] - 1
	}
	return b.Text()[b.bytes[i]:end]
}

// LineAt is the line that unit u is on.
func (b *Buffer) LineAt(u int) int {
	i := sort.SearchInts(b.units, u+1) - 1
	return max(0, min(i, len(b.units)-1))
}

// Byte is the byte offset of unit u.
func (b *Buffer) Byte(u int) int {
	u = max(0, min(u, b.Len()))
	i := b.LineAt(u)
	return b.bytes[i] + byteOfUnit(b.Text()[b.bytes[i]:], u-b.units[i])
}

// Unit is the unit offset of byte p.
func (b *Buffer) Unit(p int) int {
	p = max(0, min(p, len(b.Text())))
	i := sort.SearchInts(b.bytes, p+1) - 1
	i = max(0, min(i, len(b.bytes)-1))
	return b.units[i] + markdown.UnitsOf(b.Text()[b.bytes[i]:p])
}

// byteOfUnit is the byte offset of unit u in s.
func byteOfUnit(s string, u int) int {
	n := 0
	for i, r := range s {
		if n >= u {
			return i
		}
		n += unitLen(r)
	}
	return len(s)
}

// Slice is the text between units a and z.
func (b *Buffer) Slice(a, z int) string {
	if a > z {
		a, z = z, a
	}
	return b.Text()[b.Byte(a):b.Byte(z)]
}

// RuneAt is the rune at unit u, and its length in units; 0 past the end.
func (b *Buffer) RuneAt(u int) (rune, int) {
	if u < 0 || u >= b.Len() {
		return 0, 0
	}
	r, _ := utf8.DecodeRuneInString(b.Text()[b.Byte(u):])
	return r, unitLen(r)
}

// RuneBefore is the rune before unit u, and its length in units.
func (b *Buffer) RuneBefore(u int) (rune, int) {
	if u <= 0 {
		return 0, 0
	}
	r, _ := utf8.DecodeLastRuneInString(b.Text()[:b.Byte(u)])
	return r, unitLen(r)
}

// Edit replaces units a..z with s, and returns the range of the new text
// whose styling may have changed.
func (b *Buffer) Edit(a, z int, s string) (int, int) {
	if a > z {
		a, z = z, a
	}
	a, z = max(0, min(a, b.Len())), max(0, min(z, b.Len()))
	la, lz := b.LineAt(a), b.LineAt(z)
	byteA := b.Byte(a)
	byteZ := b.Byte(z)
	ds, de := b.doc.Edit(a, z-a, s)
	du := markdown.UnitsOf(s) - (z - a)
	db := len(s) - (byteZ - byteA)
	// The lines s starts, after the first, replace those the edit took.
	nu, nb := lineStarts(s, a, byteA)
	nu, nb = nu[1:], nb[1:]
	b.units = slices.Replace(b.units, la+1, lz+1, nu...)
	b.bytes = slices.Replace(b.bytes, la+1, lz+1, nb...)
	for i := la + 1 + len(nu); i < len(b.units); i++ {
		b.units[i] += du
		b.bytes[i] += db
	}
	return ds, de
}

// SpansIn returns the spans of line i.
func (b *Buffer) lineSpans(i int) []markdown.Span {
	return b.doc.SpansIn(b.LineStart(i), b.LineEnd(i)+1)
}
