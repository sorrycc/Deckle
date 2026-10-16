package main

import (
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"unicode"
	"unicode/utf8"

	"deckle/internal/editor"
	"deckle/internal/theme"
	"deckle/internal/workspace"

	"github.com/egoist/mygo/ui"
)

type paletteMode int

const (
	modeFiles paletteMode = iota
	modeSearch
	modeCommands
	modeHeadings
	modeBacklinks
)

// palette is the panel over the window that finds things: files by name
// (⌘P), the text of every note (⇧⌘F), commands (⇧⌘P), the headings of the
// note (⇧⌘O) and the notes linking to it (⇧⌘B).
type palette struct {
	w        *window
	open     bool
	mode     paletteMode
	query    string
	selected int
	items    []paletteItem
	focus    bool
	// The search's results, which come back on another goroutine.
	token    atomic.Uint64
	searched string
	results  []paletteItem
	total    int
	list     ui.ListState
	dirty    bool
}

type paletteItem struct {
	title, detail string
	// match is where the query is in detail, for search results.
	match [2]int
	// marks are the bytes of detail a file's query matched.
	marks  []int
	icon   *ui.SVG
	run    func(newTab bool)
	header bool
}

func (p *palette) show(mode paletteMode, query string) {
	if p.open && p.mode == mode && query == "" {
		p.close()
		return
	}
	p.open, p.mode, p.selected, p.focus = true, mode, 0, true
	if query != "" || mode != modeSearch {
		p.query = query
	}
	p.dirty = true
}

func (p *palette) close() {
	p.open = false
	p.w.focusEditor = true
}

// stale asks for the items again, as the index changed.
func (p *palette) stale() {
	p.dirty = true
	if p.open && p.mode == modeSearch {
		p.searched = "\x00"
	}
}

func (p *palette) placeholder() string {
	switch p.mode {
	case modeSearch:
		return "Search Notes"
	case modeCommands:
		return "Run a Command"
	case modeHeadings:
		return "Go to Heading"
	case modeBacklinks:
		return "Notes Linking Here"
	}
	return "Open a Note"
}

func (p *palette) update() {
	w := p.w
	p.dirty = false
	p.items = nil
	switch p.mode {
	case modeFiles:
		for _, m := range w.ws.FindFiles(p.query, 60, false) {
			m := m
			ic := iconNote
			if !m.IsNote {
				ic = iconFile
				if editor.IsImage(m.Path) {
					ic = iconImage
				}
			}
			title := m.Title
			if title == "" {
				title = filepath.Base(m.Path)
			}
			p.items = append(p.items, paletteItem{title: title, detail: m.Rel, marks: m.Indices, icon: ic, run: func(newTab bool) {
				w.open(m.Path, openOptions{newTab: newTab, focus: true})
			}})
		}
	case modeSearch:
		if p.query != p.searched {
			p.searched = p.query
			token := p.token.Add(1)
			q := p.query
			if strings.TrimSpace(q) == "" {
				p.results, p.total = nil, 0
				break
			}
			w.ws.Search(q, token, func(r workspace.SearchResult) {
				w.post(func() {
					if p.token.Load() != token {
						return
					}
					p.results = nil
					for _, f := range r.Files {
						f := f
						p.results = append(p.results, paletteItem{title: f.Title, detail: fmt.Sprintf("%d", f.Count), header: true, icon: iconNote,
							run: func(newTab bool) { w.open(f.Path, openOptions{newTab: newTab, focus: true}) }})
						for _, m := range f.Matches {
							m := m
							p.results = append(p.results, paletteItem{title: m.Text, match: [2]int{m.Column, m.Column + m.Length},
								run: func(newTab bool) {
									sel := [2]int{m.Offset, m.Offset + m.Units}
									w.open(f.Path, openOptions{newTab: newTab, focus: true, sel: &sel})
								}})
						}
					}
					p.total = r.Total
					p.selected = min(p.selected, max(len(p.results)-1, 0))
				})
			})
		}
		p.items = p.results
	case modeCommands:
		for _, cmd := range w.commandList() {
			cmd := cmd
			if p.query != "" && fuzzyScore(cmd.title, p.query) < 0 {
				continue
			}
			p.items = append(p.items, paletteItem{title: cmd.title, detail: cmd.keys, run: func(bool) { w.post(func() { w.run(cmd.id) }) }})
		}
	case modeHeadings:
		ed := w.editor()
		if ed == nil {
			break
		}
		for _, h := range ed.Headings() {
			h := h
			if p.query != "" && fuzzyScore(h.Title, p.query) < 0 {
				continue
			}
			p.items = append(p.items, paletteItem{title: strings.Repeat("   ", h.Level-1) + h.Title, detail: "H" + itoa(h.Level), icon: iconHeading, run: func(bool) {
				ed.SetSelection(h.At, h.At)
				ed.RevealCentered()
				w.focusEditor = true
			}})
		}
	case modeBacklinks:
		t := w.tab()
		if t == nil || t.path == "" {
			break
		}
		for _, b := range w.ws.Backlinks(t.path) {
			b := b
			p.items = append(p.items, paletteItem{title: b.Title, header: true, icon: iconNote, run: func(newTab bool) { w.open(b.Path, openOptions{newTab: newTab, focus: true}) }})
			for _, l := range b.Lines {
				l := l
				p.items = append(p.items, paletteItem{title: l.Text, run: func(newTab bool) {
					sel := [2]int{l.Offset, l.Offset}
					w.open(b.Path, openOptions{newTab: newTab, focus: true, sel: &sel})
				}})
			}
		}
	}
	p.selected = min(p.selected, max(len(p.items)-1, 0))
}

func (p *palette) choose(i int, newTab bool) {
	if i < 0 || i >= len(p.items) {
		return
	}
	it := p.items[i]
	p.open = false
	it.run(newTab)
}

func (p *palette) view(c *ui.Context, th theme.Theme) {
	if !p.open {
		return
	}
	if p.dirty || (p.mode == modeSearch && p.query != p.searched) {
		p.update()
	}
	if p.mode == modeSearch {
		p.items = p.results
	}
	dim := float32(0.08)
	if th.Dark {
		dim = 0.3
	}
	backdrop := ui.Box(c.Key("palette-backdrop")).Absolute().Top(0).Left(0).Right(0).Bottom(0).Background(ui.RGBA(0, 0, 0, dim))
	if backdrop.Clicked() {
		p.close()
	}
	backdrop.Children(func() {
		ui.Column(c.Key("palette")).Absolute().Top(70).Left(0).Right(0).Margin(0, ui.Auto).Width(640).MaxHeight(540).Clip().
			Radius(14).Background(th.Background).Border(1, th.Border).Shadow(0, 24, 60, 0, ui.RGBA(0, 0, 0, 0.22)).Shadow(0, 2, 6, 0, ui.RGBA(0, 0, 0, 0.06)).Children(func() {
			ui.Row(c).Padding(14, 16).Gap(10).AlignItems(ui.Center).Children(func() {
				ic := p.modeIcon()
				ui.Icon(c, ic).FontSize(17).TextColor(th.Secondary)
				in := ui.TextInputBase(c.Key("palette-input"), &p.query).Placeholder(p.placeholder()).Grow(1).FontSize(16)
				if p.focus {
					in.Focus()
					p.focus = false
				}
				if in.Changed() {
					p.selected = 0
					p.dirty = true
				}
				move := func(d int) {
					if len(p.items) == 0 {
						return
					}
					p.selected = (p.selected + d + len(p.items)) % len(p.items)
					p.list.ScrollTo(p.selected, ui.Start)
				}
				if in.Shortcut(0, ui.KeyDown) || in.Shortcut(ui.Ctrl, ui.KeyN) {
					move(1)
				}
				if in.Shortcut(0, ui.KeyUp) || in.Shortcut(ui.Ctrl, ui.KeyP) {
					move(-1)
				}
				if in.Shortcut(0, ui.KeyEnter) {
					p.choose(p.selected, false)
				}
				if in.Shortcut(ui.Cmd, ui.KeyEnter) {
					p.choose(p.selected, true)
				}
				if in.Shortcut(0, ui.KeyEscape) {
					p.close()
				}
				if p.mode == modeSearch && p.total > 0 {
					label := itoa(p.total) + " notes"
					if p.total == 1 {
						label = "1 note"
					}
					ui.Text(c, label).FontSize(12).TextColor(th.Secondary)
				}
			})
			ui.Box(c).Height(1).Background(th.Border)
			ui.List(c.Key("palette-list"), &p.list, len(p.items), func(i int) {
				it := p.items[i]
				r := ui.Row(c.Key(itoa(i))).Padding(7, 12).Gap(10).Radius(8).AlignItems(ui.Center).Cursor(ui.CursorDefault)
				if i == p.selected {
					r.Background(th.Accent.Alpha(0.14))
				} else if r.Hovered() {
					r.Background(th.Text.Alpha(0.04))
				}
				if r.Clicked() {
					p.choose(i, false)
				}
				r.Children(func() {
					if it.icon != nil {
						ic := ui.Icon(c, it.icon).FontSize(15).TextColor(th.Secondary)
						if i == p.selected {
							ic.TextColor(th.Accent)
						}
					} else if p.mode != modeCommands {
						ui.Box(c).Width(15)
					}
					switch {
					case it.match[1] > it.match[0] && it.match[1] <= len(it.title):
						ui.RichText(c, hitSpans(it.title, it.match, p.query, th)...).FontSize(13).SingleLine().Grow(1).TextColor(th.Text)
					case it.header:
						ui.Text(c, it.title).Bold().FontSize(13.5).SingleLine().Grow(1)
					default:
						ui.Text(c, it.title).FontSize(13.5).SingleLine().Grow(1)
					}
					switch {
					case len(it.marks) > 0:
						ui.RichText(c, markedSpans(it.detail, it.marks, th)...).FontSize(11.5).TextColor(th.Secondary).SingleLine().MaxWidth(280)
					case p.mode == modeCommands && it.detail != "":
						keycaps(c, th, it.detail)
					case it.detail != "":
						ui.Text(c, it.detail).FontSize(11.5).TextColor(th.Secondary).SingleLine().MaxWidth(280)
					}
				})
			}).MaxHeight(440).Padding(6)
			if len(p.items) == 0 && p.query != "" {
				ui.Text(c, "No Results").TextColor(th.Secondary).Padding(16).AlignSelf(ui.Center)
			}
			p.footer(c, th)
		})
	})
}

func (p *palette) modeIcon() *ui.SVG {
	switch p.mode {
	case modeCommands:
		return iconCommand
	case modeHeadings:
		return iconHeading
	case modeBacklinks:
		return iconLink
	}
	return iconSearch
}

// footer names the keys the palette takes.
func (p *palette) footer(c *ui.Context, th theme.Theme) {
	hint := func(keys, what string) {
		ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
			keycaps(c, th, keys)
			ui.Text(c, what).FontSize(11.5).TextColor(th.Secondary)
		})
	}
	ui.Row(c.Key("palette-footer")).Padding(8, 14).Gap(16).AlignItems(ui.Center).Background(th.Text.Alpha(0.025)).
		BorderWidth(1, 0, 0, 0).BorderColor(th.Border).Children(func() {
		hint("↑↓", "Move")
		hint("↩", "Open")
		if p.mode == modeFiles || p.mode == modeSearch || p.mode == modeBacklinks {
			hint(keysLabel("CmdOrCtrl+Enter"), "Open in New Tab")
		}
		ui.Box(c).Grow(1)
		hint("esc", "Close")
	})
}

// hitSpans is a line of a search's results with the match found, and the
// query's other matches in the line, highlighted.
func hitSpans(s string, match [2]int, query string, th theme.Theme) []ui.Span {
	hits := [][2]int{match}
	hay, needle := s, query
	if strings.IndexFunc(query, unicode.IsUpper) < 0 {
		// Matched without case, where folding keeps the bytes in place.
		if l := strings.ToLower(s); len(l) == len(s) {
			hay, needle = l, strings.ToLower(query)
		}
	}
	for at := 0; needle != "" && at < len(hay); {
		i := strings.Index(hay[at:], needle)
		if i < 0 {
			break
		}
		h := [2]int{at + i, at + i + len(needle)}
		if h[1] <= match[0] || h[0] >= match[1] {
			hits = append(hits, h)
		}
		at = h[1]
	}
	slices.SortFunc(hits, func(a, b [2]int) int { return a[0] - b[0] })
	var spans []ui.Span
	at := 0
	for _, h := range hits {
		if h[0] < at || h[1] > len(s) {
			continue
		}
		spans = append(spans, ui.Span{Text: s[at:h[0]]}, ui.Span{Text: s[h[0]:h[1]], Background: th.Highlight, Weight: 600})
		at = h[1]
	}
	return append(spans, ui.Span{Text: s[at:]})
}

// markedSpans is s with the bytes at marks in the accent.
func markedSpans(s string, marks []int, th theme.Theme) []ui.Span {
	var spans []ui.Span
	at := map[int]bool{}
	for _, m := range marks {
		at[m] = true
	}
	start := 0
	for i := range s {
		if at[i] {
			if i > start {
				spans = append(spans, ui.Span{Text: s[start:i]})
			}
			_, size := utf8.DecodeRuneInString(s[i:])
			spans = append(spans, ui.Span{Text: s[i : i+size], Color: th.Accent, Weight: 600})
			start = i + size
		}
	}
	if start < len(s) {
		spans = append(spans, ui.Span{Text: s[start:]})
	}
	return spans
}

// fuzzyScore scores how well query matches s, its letters in order, or
// -1.
func fuzzyScore(s, query string) int {
	t, q := []rune(strings.ToLower(s)), []rune(strings.ToLower(query))
	score, j, run := 0, 0, 0
	for i := 0; i < len(t) && j < len(q); i++ {
		if q[j] == ' ' {
			j++
			continue
		}
		if t[i] == q[j] {
			run++
			score += 1 + run
			if i == 0 || t[i-1] == ' ' {
				score += 5
			}
			j++
		} else {
			run = 0
		}
	}
	if j < len(q) {
		return -1
	}
	return score
}
