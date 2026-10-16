package markdown

import (
	"fmt"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
)

const sample = `---
title: Sample
tags: [a, b]
---

# Heading one

Some *emphasis*, **strong**, ~~strike~~, ` + "`code`" + `, H~2~O, x^2^, ==marked== and a [link](https://example.com "t").
A [[Wiki Page|label]] and [[Plain]] with a footnote[^1] and https://deckle.md/docs. Math $a^2$.

> quoted **text**
> second line

> [!NOTE]
> A callout.

> [!tip] Titled
> Body.

- item one
- [x] done
  1. nested

` + "```rust" + `
fn main() { let x = "hi"; } // done
` + "```" + `

| Name | Count |
|:-----|------:|
| 中文 | 12 |

![alt](images/pic.png)

$$
E = mc^2
$$

Setext
======

***

[^1]: The note.
`

func all(d *Doc) []Span { return d.SpansIn(0, d.Units()+1) }

func textOf(text string, s Span) string {
	u := utf16.Encode([]rune(text))
	return string(utf16.Decode(u[s.Start:s.End]))
}

func TestSampleSpans(t *testing.T) {
	d := NewDoc(sample, "markdown")
	spans := all(d)
	if os.Getenv("DUMP") != "" {
		for _, s := range spans {
			fmt.Printf("%2d l%d f%d [%d..%d] e[%d..%d] %q\n", s.Kind, s.Level, s.Flags, s.Start, s.End, s.ElemStart, s.ElemEnd, textOf(sample, s))
		}
	}
	has := func(kind Kind, text string) {
		t.Helper()
		for _, s := range spans {
			if s.Kind == kind && textOf(sample, s) == text {
				return
			}
		}
		t.Errorf("no span of kind %d over %q", kind, text)
	}
	has(Heading, "# Heading one")
	has(Marker, "# ")
	has(Emphasis, "*emphasis*")
	has(Strong, "**strong**")
	has(Strike, "~~strike~~")
	has(Code, "`code`")
	has(Subscript, "~2~")
	has(Superscript, "^2^")
	has(Highlight, "==marked==")
	has(Link, "link")
	has(LinkDest, "https://example.com")
	has(Marker, `](https://example.com "t")`)
	has(WikiLink, "label")
	has(WikiTarget, "Wiki Page")
	has(WikiLink, "Plain")
	has(FootnoteRef, "[^1]")
	has(Link, "https://deckle.md/docs")
	has(InlineMath, "$a^2$")
	has(BlockQuote, "> quoted **text**")
	has(Marker, "> ")
	has(CalloutTag, "[!NOTE]")
	has(CalloutTag, "[!tip]")
	has(ListMarker, "-")
	has(ListMarker, "1.")
	has(TaskMarker, "[x]")
	has(CodeBlock, "```rust")
	has(TokenKeyword, "fn")
	has(TokenString, `"hi"`)
	has(TokenComment, "// done")
	has(Table, "| Name | Count |")
	has(TableCell, "中文")
	has(Image, "![alt](images/pic.png)")
	has(ImageDest, "images/pic.png")
	has(MathBlock, "E = mc^2")
	has(Heading, "Setext")
	has(ThematicBreak, "***")
	has(FootnoteDef, "[^1]:")
	has(FrontMatter, "title: Sample")
	has(TokenProperty, "title")
	// Every span stays on one line.
	for _, s := range spans {
		if strings.Contains(textOf(sample, s), "\n") {
			t.Errorf("span crosses lines: %+v", s)
		}
		if !(s.Start <= s.End && s.ElemStart <= s.Start && s.End <= max(s.ElemEnd, s.End)) {
			t.Errorf("bad span %+v", s)
		}
	}
}

func TestFootnoteCaretIsNotASuperscript(t *testing.T) {
	// The definition sits in another section, so the parser sees the
	// reference as text, and its caret must not open a superscript that
	// runs to the next one.
	text := "# A\n\nFootnotes[^1] and H~2~O and x^2^ and ~a b~ end.\n\n" + strings.Repeat("## B\n\nfiller\n\n", 3) + "\n[^1]: The note.\n"
	d := NewDoc(text, "markdown")
	spans := all(d)
	of := func(kind Kind) []string {
		var out []string
		for _, s := range spans {
			if s.Kind == kind {
				out = append(out, textOf(text, s))
			}
		}
		return out
	}
	if got := of(FootnoteRef); !slices.Equal(got, []string{"[^1]"}) {
		t.Errorf("footnote refs %q", got)
	}
	if got := of(Subscript); !slices.Equal(got, []string{"~2~"}) {
		t.Errorf("subscripts %q", got)
	}
	if got := of(Superscript); !slices.Equal(got, []string{"^2^"}) {
		t.Errorf("superscripts %q", got)
	}
	if got := of(Strike); len(got) != 0 {
		t.Errorf("strikes %q", got)
	}
}

// rng is a deterministic generator, so a failure can be replayed.
type rng uint64

func (r *rng) next() uint64 {
	*r ^= *r << 13
	*r ^= *r >> 7
	*r ^= *r << 17
	return uint64(*r)
}

func (r *rng) below(n int) int { return int(r.next() % uint64(max(n, 1))) }

func TestEditsMatchAFreshParse(t *testing.T) {
	pieces := []string{
		"# ", "\n", "\n\n", "```", "```rust\n", "> ", "- ", "**", "*", "`", "[", "](x)", "[[", "]]", "|", "---\n", "$$", "$", "中文",
		"word ", "1. ", "~~", "<!--", "-->", "    ", "[^1]", "[^1]: ", "> [!tip] T\n", "==", "^", "\n# Title\n", "😀", "![a](b.png)", "~",
		"\r\n", "\t", "~~~\n", "<pre>\n", "</pre>", "<div>\n", "Foo\n===\n", "[r]: x\n", "[a][r]", "- a\n", "- [ ] t\n", "-\n", "- - -\n",
	}
	r := rng(0x9E3779B97F4A7C15)
	rounds := 40
	if testing.Short() {
		rounds = 8
	}
	for round := range rounds {
		text := utf16.Encode([]rune(strings.Repeat(sample, 1+round%3)))
		d := NewDoc(string(utf16.Decode(text)), "markdown")
		for step := range 120 {
			start := r.below(len(text) + 1)
			// Not in the middle of a surrogate pair.
			for start < len(text) && text[start] >= 0xDC00 && text[start] < 0xE000 {
				start++
			}
			end := start
			if r.below(3) == 0 {
				end += r.below(40)
			}
			end = min(end, len(text))
			for end < len(text) && text[end] >= 0xDC00 && text[end] < 0xE000 {
				end++
			}
			insert := ""
			if r.below(4) != 0 {
				insert = pieces[r.below(len(pieces))]
			}
			units := utf16.Encode([]rune(insert))
			before := all(d)
			ds, de := d.Edit(start, end-start, insert)
			delta := len(units) - (end - start)
			text = slices.Concat(text[:start], units, text[end:])
			now := string(utf16.Decode(text))
			if d.Text() != now {
				t.Fatalf("round %d step %d: text differs", round, step)
			}
			got := all(d)
			want := all(NewDoc(now, "markdown"))
			if !slices.Equal(got, want) {
				for i := range min(len(got), len(want)) {
					if got[i] != want[i] {
						t.Logf("first difference at %d: got %+v want %+v", i, got[i], want[i])
						break
					}
				}
				t.Fatalf("round %d step %d: insert %q at %d..%d: %d spans, fresh %d", round, step, insert, start, end, len(got), len(want))
			}
			// Outside the reported range nothing changed.
			outside := func(s Span) bool { return s.End < ds || s.Start > de }
			for _, s := range before {
				if !(s.ElemEnd+1 < start || s.ElemStart > end) {
					continue
				}
				moved := func(v int) int {
					if v >= end {
						return v + delta
					}
					return v
				}
				shifted := s
				if s.Start >= end {
					shifted = Span{Start: moved(s.Start), End: moved(s.End), ElemStart: moved(s.ElemStart), ElemEnd: moved(s.ElemEnd), Kind: s.Kind, Level: s.Level, Flags: s.Flags}
				}
				if outside(shifted) && !slices.Contains(got, shifted) {
					t.Fatalf("round %d step %d: %+v changed outside %d..%d, insert %q at %d..%d", round, step, s, ds, de, insert, start, end)
				}
			}
			// A span of an element the edit is in, on a line outside the
			// reported range, kept everything but the element's far edge.
			for _, s := range before {
				if s.ElemEnd+1 < start || s.ElemStart > end {
					continue
				}
				moved := func(v int) int { return v + delta }
				var kept []Span
				if s.End < ds && s.End < start {
					k := s
					k.ElemEnd = moved(s.ElemEnd)
					kept = []Span{s, k}
				} else if s.Start > end && moved(s.Start) > de {
					shifted := Span{Start: moved(s.Start), End: moved(s.End), ElemStart: moved(s.ElemStart), ElemEnd: moved(s.ElemEnd), Kind: s.Kind, Level: s.Level, Flags: s.Flags}
					k := shifted
					k.ElemStart = s.ElemStart
					kept = []Span{shifted, k}
				} else {
					continue
				}
				if !slices.Contains(got, kept[0]) && !slices.Contains(got, kept[1]) {
					t.Fatalf("round %d step %d: %+v changed outside %d..%d, insert %q at %d..%d", round, step, s, ds, de, insert, start, end)
				}
			}
		}
	}
}

func TestTypingInALongBlockDirtiesItsLine(t *testing.T) {
	line := "let value = compute(1) // a line of code\n"
	for _, c := range [][3]string{{"```swift\n", line, "```\n"}, {"", "> a line of a long quote\n", ""}} {
		open, body, close := c[0], c[1], c[2]
		text := "# Title\n\n" + open + strings.Repeat(body, 400) + close + "\nAfter.\n"
		d := NewDoc(text, "markdown")
		at := 9 + len(open) + len(body)*200 + 5
		ds, de := d.Edit(at, 0, "x")
		if !(ds <= at && de > at) {
			t.Errorf("%d..%d misses the edit at %d", ds, de, at)
		}
		if de-ds > 2*len(body) {
			t.Errorf("%d..%d is more than the line at %d", ds, de, at)
		}
		ds, de = d.Edit(at, 1, "")
		if de-ds > 2*len(body) {
			t.Errorf("%d..%d is more than the line at %d", ds, de, at)
		}
	}
}

func TestLargeDocumentTiming(t *testing.T) {
	text := strings.Repeat(strings.Replace(sample, "---\ntitle: Sample\ntags: [a, b]\n---\n", "", 1), 1500)
	units := UnitsOf(text)
	t0 := time.Now()
	d := NewDoc(text, "markdown")
	open := time.Since(t0)
	count := len(all(d))
	var worst, total time.Duration
	for i := range 200 {
		at := units / 200 * i
		t0 := time.Now()
		d.Edit(at, 0, "x")
		e := time.Since(t0)
		worst = max(worst, e)
		total += e
	}
	t.Logf("%d bytes, %d spans: open %v, edit avg %v, worst %v", len(text), count, open, total/200, worst)
}

func TestCodeHighlightsByLanguage(t *testing.T) {
	var spans []Span
	Lex("go", "func main() { return \"x\" } // c", 0, &spans)
	if len(spans) == 0 || spans[0].Kind != TokenKeyword {
		t.Fatalf("spans %+v", spans)
	}
	if LanguageForExtension("MD") != "markdown" || LanguageForExtension("tsx") != "javascript" {
		t.Fatal("extensions")
	}
}
