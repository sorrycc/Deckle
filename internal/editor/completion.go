package editor

import (
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"deckle/internal/markdown"

	"github.com/egoist/mygo/ui"
)

// completion is the list a `/` at the start of a line opens, of blocks to
// insert, and the one `[[` opens, of notes to link.
type completion struct {
	open     bool
	items    []completionItem
	trigger  [2]int
	selected int
	at       ui.Point
	list     ui.ListState
}

type completionItem struct {
	title, detail string
	apply         func(e *Editor, trigger [2]int)
}

func (c *completion) close() {
	c.open = false
	c.items = nil
}

var (
	slashPattern = regexp.MustCompile(`^([ \t]*(?:>[ \t]?)*)/([\p{L}\d ]{0,24})$`)
	wikiPattern  = regexp.MustCompile(`\[\[([^\[\]|#\n]{0,80})$`)
)

// insertBlock inserts text in place of the trigger, with the caret at ‸
// when the text has one.
func insertBlock(text string) func(e *Editor, trigger [2]int) {
	return func(e *Editor, trigger [2]int) {
		at := strings.Index(text, "‸")
		clean := strings.Replace(text, "‸", "", 1)
		caret := trigger[0] + markdown.UnitsOf(clean)
		if at >= 0 {
			caret = trigger[0] + markdown.UnitsOf(text[:at])
		}
		e.Replace(trigger[0], trigger[1], clean, [2]int{caret, caret})
	}
}

var slashCommands []completionItem

func init() {
	slashCommands = []completionItem{
		{"Heading 1", "#", insertBlock("# ")},
		{"Heading 2", "##", insertBlock("## ")},
		{"Heading 3", "###", insertBlock("### ")},
		{"Bulleted List", "-", insertBlock("- ")},
		{"Numbered List", "1.", insertBlock("1. ")},
		{"Task", "- [ ]", insertBlock("- [ ] ")},
		{"Quote", ">", insertBlock("> ")},
		{"Callout", "> [!NOTE]", insertBlock("> [!NOTE] ‸\n> ")},
		{"Code Block", "```", insertBlock("```‸\n\n```")},
		{"Table", "| |", insertBlock("| ‸Column | Column |\n| --- | --- |\n|  |  |")},
		{"Math Block", "$$", insertBlock("$$\n‸\n$$")},
		{"Diagram", "mermaid", insertBlock("```mermaid\ngraph LR\n  A[‸Start] --> B[End]\n```")},
		{"Divider", "---", insertBlock("---\n")},
		{"Link to Note", "[[", insertBlock("[[‸]]")},
		{"Footnote", "[^1]", func(e *Editor, trigger [2]int) {
			text := e.buf.Text()
			n := 1
			for strings.Contains(text, "[^"+itoa(n)+"]") {
				n++
			}
			ref := "[^" + itoa(n) + "]"
			at := trigger[0] + markdown.UnitsOf(ref)
			e.Replace(trigger[0], trigger[1], ref, [2]int{at, at})
			end := e.buf.Len()
			def := "\n\n" + ref + ": "
			if strings.HasSuffix(e.buf.Text(), "\n") {
				def = "\n" + ref + ": "
			}
			e.Replace(end, end, def, [2]int{end + markdown.UnitsOf(def), end + markdown.UnitsOf(def)})
		}},
	}
}

// fuzzy scores how well query matches title, its letters in order, or -1.
func fuzzy(title, query string) int {
	t, q := []rune(strings.ToLower(title)), []rune(strings.ToLower(query))
	score, j, run := 0, 0, 0
	for i := 0; i < len(t) && j < len(q); i++ {
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

func slashMatching(query string) []completionItem {
	if query == "" {
		return slashCommands
	}
	type scored struct {
		s  int
		it completionItem
	}
	var out []scored
	for _, it := range slashCommands {
		if s := fuzzy(it.title, query); s >= 0 {
			out = append(out, scored{s, it})
		}
	}
	slices.SortStableFunc(out, func(a, b scored) int { return b.s - a.s })
	var items []completionItem
	for _, s := range out {
		items = append(items, s.it)
	}
	return items
}

// updateCompletion offers blocks after a `/` that starts a line, and notes
// after `[[`.
func (e *Editor) updateCompletion() {
	if e.completion == nil {
		e.completion = &completion{}
	}
	c := e.completion
	a, z := e.selection()
	if !e.markdown || a != z || e.hasMarked || e.isCode(a) {
		c.close()
		return
	}
	l := e.buf.LineAt(a)
	ls := e.buf.LineStart(l)
	head := e.buf.Slice(ls, a)
	if m := slashPattern.FindStringSubmatchIndex(head); m != nil {
		prefix := markdown.UnitsOf(head[:m[3]])
		c.show(slashMatching(head[m[4]:m[5]]), [2]int{ls + prefix, a})
		return
	}
	if m := wikiPattern.FindStringSubmatchIndex(head); m != nil && e.Hooks.NoteNames != nil {
		query := head[m[2]:m[3]]
		trigger := [2]int{ls + markdown.UnitsOf(head[:m[0]]), a}
		var items []completionItem
		for _, path := range e.Hooks.NoteNames(query) {
			name := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
			items = append(items, completionItem{title: name, detail: path, apply: func(e *Editor, trigger [2]int) {
				// Takes in the ]] typed after the caret too.
				end := trigger[1]
				if end+2 <= e.buf.Len() && e.buf.Slice(end, end+2) == "]]" {
					end += 2
				}
				link := "[[" + name + "]]"
				at := trigger[0] + markdown.UnitsOf(link)
				e.Replace(trigger[0], end, link, [2]int{at, at})
			}})
		}
		c.show(items, trigger)
		return
	}
	c.close()
}

func (c *completion) show(items []completionItem, trigger [2]int) {
	if len(items) == 0 {
		c.close()
		return
	}
	if !c.open || c.trigger[0] != trigger[0] {
		c.selected = 0
	}
	c.open, c.items, c.trigger = true, items, trigger
	c.selected = min(c.selected, len(items)-1)
}

func (c *completion) anchorAt(e *Editor) { c.at = e.FocusPoint() }

func (c *completion) accept(e *Editor, i int) {
	if i < 0 || i >= len(c.items) {
		return
	}
	it, trigger := c.items[i], c.trigger
	c.close()
	it.apply(e, trigger)
	e.selectionChanged()
}

// key takes the arrows, Return, Tab and Escape while the list is open.
func (c *completion) key(e *Editor, key ui.Key, mods ui.Modifiers) bool {
	if mods&^ui.Shift != 0 {
		return false
	}
	switch key {
	case ui.KeyDown:
		c.selected = (c.selected + 1) % len(c.items)
	case ui.KeyUp:
		c.selected = (c.selected + len(c.items) - 1) % len(c.items)
	case ui.KeyEnter, ui.KeyTab:
		c.accept(e, c.selected)
	case ui.KeyEscape:
		c.close()
	default:
		return false
	}
	return true
}

// Overlays builds what floats over the editor: the completion list and the
// find bar. Build it in the editor's element.
func (e *Editor) overlays(c *ui.Context) {
	t := &e.look.Theme
	if cp := e.completion; cp != nil && cp.open && len(cp.items) > 0 {
		x, y := cp.at.X, cp.at.Y+4
		rows := min(len(cp.items), 9)
		h := float32(rows)*30 + 8
		if y+h > e.rect.H && cp.at.Y-h-24 > 0 {
			y = cp.at.Y - h - 28
		}
		ui.Column(c.Key("completion")).Absolute().Left(min(x, max(e.rect.W-300, 0))).Top(y).Width(280).Height(h).
			Padding(4).Radius(10).Background(t.Background).Border(1, t.Border).
			Shadow(0, 8, 24, 0, ui.RGBA(0, 0, 0, 0.18)).Children(func() {
			ui.Scroll(c).Grow(1).Children(func() {
				for i, it := range cp.items {
					row := ui.Row(c.Key(it.title+it.detail)).Padding(6, 10).Radius(6).Gap(8).AlignItems(ui.Center).Height(30)
					if i == cp.selected {
						row.Background(t.Accent.Alpha(0.14))
					}
					if row.Clicked() {
						cp.accept(e, i)
					}
					row.Children(func() {
						ui.Text(c, it.title).SingleLine().Grow(1).TextColor(t.Text)
						ui.Text(c, it.detail).SingleLine().FontSize(11).TextColor(t.Secondary).MaxWidth(120)
					})
				}
			})
		})
	}
	if e.find.open {
		e.findBar(c)
	}
	if e.hoverDest != "" && !e.dragging {
		ui.Text(c.Key("link-tip"), e.hoverDest).Absolute().Left(min(e.pointer.X+12, max(e.rect.W-320, 0))).Top(e.pointer.Y+18).
			MaxWidth(300).SingleLine().FontSize(11.5).Padding(3, 8).Radius(6).Background(t.Text.Alpha(0.85)).TextColor(t.Background)
	}
	if b := e.hoverBlock; b != ([2]int{}) && b[1] <= e.buf.Len() {
		l := e.buf.LineAt(b[0])
		if l < len(e.views) {
			lv := e.layoutLine(l)
			y := e.toView(e.lineTop(l) + float64(lv.textTop))
			if y > -20 && y < e.rect.H {
				label := "Copy"
				if e.copied {
					label = "Copied"
				}
				btn := ui.Row(c.Key("copy-code")).Absolute().Top(y+4).Left(e.colX+e.colW-80).Width(72).Height(22).Radius(6).
					Center().Background(t.Background).Border(1, t.Border).Cursor(ui.CursorDefault)
				if btn.Clicked() {
					e.services.WriteClipboard(fenceSource(e.buf.Slice(b[0], b[1])))
					e.copied = true
				}
				btn.Children(func() { ui.Text(c, label).FontSize(11).TextColor(t.Secondary) })
			}
		}
	}
}
