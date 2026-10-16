package editor

import (
	"regexp"
	"strings"

	"deckle/internal/markdown"
	"deckle/internal/theme"

	"github.com/egoist/mygo/ui"
)

// findState is the find bar's: what it finds, what it replaces with, and
// the matches in the note.
type findState struct {
	open        bool
	replacing   bool
	query       string
	replacement string
	matchCase   bool
	regex       bool
	matches     [][2]int
	current     int
	// of is the text the matches are of.
	of      uint64
	focus   bool
	invalid bool
}

func (f *findState) active() bool { return f.open && len(f.matches) > 0 }

func (f *findState) show(e *Editor, replacing bool) {
	f.open = true
	f.replacing = replacing
	f.focus = true
	a, z := e.selection()
	if a != z && z-a < 200 {
		f.query = e.buf.Slice(a, z)
	}
	f.refresh(e)
}

func (f *findState) close(e *Editor) {
	f.open = false
	f.matches = nil
	e.invalidateAll()
}

// refresh finds the matches again in the text as it is.
func (f *findState) refresh(e *Editor) {
	f.matches = f.matches[:0]
	f.invalid = false
	f.of = e.generation
	if f.query == "" {
		return
	}
	text := e.buf.Text()
	var re *regexp.Regexp
	if f.regex {
		expr := f.query
		if !f.matchCase {
			expr = "(?i)" + expr
		}
		var err error
		if re, err = regexp.Compile(expr); err != nil {
			f.invalid = true
			return
		}
	} else {
		q := regexp.QuoteMeta(f.query)
		if !f.matchCase && strings.ToLower(f.query) == f.query {
			q = "(?i)" + q
		}
		re = regexp.MustCompile(q)
	}
	for _, m := range re.FindAllStringIndex(text, 10000) {
		if m[1] == m[0] {
			continue
		}
		f.matches = append(f.matches, [2]int{e.buf.Unit(m[0]), e.buf.Unit(m[1])})
	}
	// The match at or after the caret is the current one.
	a, _ := e.selection()
	f.current = 0
	for i, m := range f.matches {
		if m[0] >= a {
			f.current = i
			break
		}
	}
}

// step selects the next match, or the one before.
func (f *findState) step(e *Editor, dir int) {
	if !f.open || f.of != e.generation {
		f.refresh(e)
	}
	if len(f.matches) == 0 {
		return
	}
	a, z := e.selection()
	i := -1
	if dir > 0 {
		for k, m := range f.matches {
			if m[0] >= z && !(m[0] == a && m[1] == z) {
				i = k
				break
			}
		}
		if i < 0 {
			i = 0
		}
	} else {
		for k := len(f.matches) - 1; k >= 0; k-- {
			if f.matches[k][1] <= a {
				i = k
				break
			}
		}
		if i < 0 {
			i = len(f.matches) - 1
		}
	}
	f.current = i
	m := f.matches[i]
	e.SetSelection(m[0], m[1])
	e.RevealCentered()
}

func (f *findState) replaceOne(e *Editor) {
	if len(f.matches) == 0 {
		return
	}
	a, z := e.selection()
	for _, m := range f.matches {
		if m[0] == a && m[1] == z {
			e.Replace(a, z, f.replacement, [2]int{a, a + markdown.UnitsOf(f.replacement)})
			f.refresh(e)
			break
		}
	}
	f.step(e, 1)
}

func (f *findState) replaceAll(e *Editor) {
	if len(f.matches) == 0 {
		return
	}
	var changes []change
	for _, m := range f.matches {
		changes = append(changes, change{at: m[0], old: e.buf.Slice(m[0], m[1]), new: f.replacement})
	}
	e.hist.breakStep()
	a, _ := e.selection()
	e.apply(changes, [2]int{a, a}, stepEdit)
	e.hist.breakStep()
	f.refresh(e)
}

// paintMatches tints the matches on a line.
func (e *Editor) paintMatches(p *ui.Painter, lv *lineView, start int, ox, top float32, t *theme.Theme) {
	if e.find.of != e.generation {
		e.find.refresh(e)
	}
	end := start + lv.units
	for k, m := range e.find.matches {
		if m[1] < start || m[0] > end {
			continue
		}
		color := t.Highlight
		if k == e.find.current {
			color = t.Accent.Alpha(0.35)
		}
		from, to := max(m[0], start)-start, min(m[1], end)-start
		for _, rw := range lv.rows {
			s, z := max(from, rw.start), min(to, rw.end)
			if z <= s {
				continue
			}
			for _, r := range rw.layout.SelectionRects(ui.TextInputRange{Start: s - rw.start, End: z - rw.start}) {
				p.Fill(ui.Rect{X: ox + lv.bodyX + r.X - 1, Y: top + rw.drawY + r.Y, W: r.W + 2, H: r.H}, color, 3)
			}
		}
	}
}

// findBar builds the find bar at the top right of the editor.
func (e *Editor) findBar(c *ui.Context) {
	t := &e.look.Theme
	f := &e.find
	ui.Column(c.Key("findbar")).Absolute().Top(8).Right(16).Width(360).Padding(8).Gap(6).Radius(10).
		Background(t.Background).Border(1, t.Border).Shadow(0, 6, 18, 0, ui.RGBA(0, 0, 0, 0.16)).Children(func() {
		ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
			in := ui.TextInput(c.Key("find"), &f.query).Placeholder("Find").Grow(1)
			if f.focus {
				in.Focus()
				f.focus = false
			}
			if in.Changed() {
				f.refresh(e)
				if len(f.matches) > 0 {
					m := f.matches[f.current]
					e.SetSelection(m[0], m[1])
					e.RevealCentered()
				}
			}
			if in.Submitted() {
				f.step(e, 1)
			}
			if in.Shortcut(0, ui.KeyEscape) {
				f.close(e)
			}
			status := ""
			switch {
			case f.invalid:
				status = "Invalid"
			case f.query == "":
			case len(f.matches) == 0:
				status = "No results"
			default:
				status = itoa(f.current+1) + " of " + itoa(len(f.matches))
			}
			ui.Text(c, status).FontSize(11).TextColor(t.Secondary).SingleLine()
			if ui.Button(c, "Aa").Tooltip("Match Case").Selected(f.matchCase).Clicked() {
				f.matchCase = !f.matchCase
				f.refresh(e)
			}
			if ui.Button(c, ".*").Tooltip("Regular Expression").Selected(f.regex).Clicked() {
				f.regex = !f.regex
				f.refresh(e)
			}
			if ui.Button(c, "‹").Tooltip("Previous").Clicked() {
				f.step(e, -1)
			}
			if ui.Button(c, "›").Tooltip("Next").Clicked() {
				f.step(e, 1)
			}
			if ui.Button(c, "✕").Tooltip("Done").Clicked() {
				f.close(e)
			}
		})
		if f.replacing && !e.ReadOnly {
			ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
				in := ui.TextInput(c.Key("replace"), &f.replacement).Placeholder("Replace").Grow(1)
				if in.Submitted() {
					f.replaceOne(e)
				}
				if ui.Button(c, "Replace").Clicked() {
					f.replaceOne(e)
				}
				if ui.Button(c, "All").Clicked() {
					f.replaceAll(e)
				}
			})
		}
	})
}
