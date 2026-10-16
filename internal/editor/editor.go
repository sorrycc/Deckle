package editor

import (
	"slices"
	"strings"
	"time"

	"deckle/internal/markdown"

	"github.com/egoist/mygo/ui"
)

// Hooks are how an editor reaches the app around it.
type Hooks struct {
	// Changed runs after the user changed the text.
	Changed func()
	// Selected runs after the selection moved.
	Selected func()
	// Follow takes a link the user ⌘-clicked or pressed Return on.
	Follow func(l Link, newTab bool)
	// NoteNames lists the notes whose names match query, best first, for
	// completing [[.
	NoteNames func(query string) []string
	// SaveImage stores a pasted or dropped image beside the note and
	// returns the path to link it by.
	SaveImage func(data []byte, ext string) (string, error)
	// LinkFile returns the path to link a dropped file by, relative to the
	// note.
	LinkFile func(path string) string
}

// Link is a link the user followed.
type Link struct {
	// URL is a web address or a path, as written.
	URL string
	// Wiki is the target of a wikilink.
	Wiki string
	// Footnote is the label of a footnote reference.
	Footnote string
}

// Editor edits a note. Its methods run on the main thread.
type Editor struct {
	buf      *Buffer
	path     string
	markdown bool
	hist     history
	// The selection, in units: anchor and caret, and the caret's edge.
	anchor, caret int
	affinity      ui.TextAffinity
	desiredX      float32
	hasDesired    bool
	// marked is an input method's composition, in the text.
	marked    [2]int
	hasMarked bool
	markedSel ui.TextInputRange
	// Layouts of lines, and their heights.
	views    []*lineView
	measured []float32
	hs       heights
	laid     int
	look     Look
	lookKey  lookKey
	styler   *styler
	widgets  *widgets
	renderer Renderer
	// The column of text: its left and width in the element, the room above
	// the text and after its end.
	colX, colW      float32
	padTop, pastEnd float32
	rect            ui.Rect
	viewH           float32
	scroll          float64
	anchorLine      int
	anchorOff       float64
	first, last     int
	reveal          bool
	revealCenter    bool
	revealed        [][2]int
	// The pointer.
	dragging  bool
	dragUnit  int
	dragStart [2]int
	cursor    ui.Cursor
	thumb     bool
	thumbGrab float32
	hover     [2]int
	// hoverBlock is the code block under the pointer, which shows a Copy
	// button; copied says it was just copied.
	hoverBlock [2]int
	copied     bool
	// hoverDest is where the link under the pointer goes.
	hoverDest string
	cmdHeld   bool
	pointer   ui.Point
	// focused and blinkStart run the caret's blink.
	focused    bool
	blinkStart time.Time
	services   ui.Services
	// generation counts the edits.
	generation uint64
	changed    bool
	// Hooks and Post reach the app; Post runs a function on the main
	// thread with a frame after it.
	Hooks Hooks
	Post  func(func())
	// ReadOnly shows the text without letting it change.
	ReadOnly   bool
	completion *completion
	ime        *imeClient
	// pendingScroll is a fraction to scroll to once laid out.
	pendingScroll float64
	// finding is the find bar's state.
	find findState
}

// New opens an editor of text written in language, from the file at path.
func New(text, language, path string) *Editor {
	e := &Editor{buf: NewBuffer(text, language), path: path, markdown: language == "markdown", cursor: ui.CursorText}
	e.styler = &styler{look: &e.look, markdown: e.markdown}
	e.widgets = newWidgets(e)
	e.styler.widgets = e.widgets
	e.ime = &imeClient{e}
	e.look.Japanese = IsJapanese(text)
	e.resetViews()
	e.reveal = true
	e.hist.saved = 0
	// A note opens with the caret on its first line of text, past any
	// front matter, which stays folded.
	if e.markdown {
		for _, sp := range e.buf.doc.SpansIn(0, 1) {
			if sp.Kind == markdown.FrontMatter {
				at := min(sp.ElemEnd, e.buf.Len())
				for at < e.buf.Len() {
					r, n := e.buf.RuneAt(at)
					if r != ' ' && r != '\n' && r != '\t' && r != '\r' {
						break
					}
					at += n
				}
				e.anchor, e.caret = at, at
				break
			}
		}
	}
	e.revealed = e.elementsTouching(e.selection())
	return e
}

// SetRenderer sets what draws math and diagrams.
func (e *Editor) SetRenderer(r Renderer) { e.renderer = r }

// Path is the file the note is from.
func (e *Editor) Path() string { return e.path }

// SetPath records that the note's file moved.
func (e *Editor) SetPath(p string) {
	e.path = p
	e.invalidateAll()
}

// Text is the note's text.
func (e *Editor) Text() string { return e.buf.Text() }

// Buffer is the note's text and spans.
func (e *Editor) Buffer() *Buffer { return e.buf }

// Generation counts the edits, for work that has to know whether the text
// is still the one it was asked about.
func (e *Editor) Generation() uint64 { return e.generation }

// Modified reports whether the text changed since it was last saved.
func (e *Editor) Modified() bool { return !e.hist.isSaved() }

// MarkSaved records that the text as it is was saved.
func (e *Editor) MarkSaved() { e.hist.markSaved() }

// IsMarkdown reports whether the note is Markdown.
func (e *Editor) IsMarkdown() bool { return e.markdown }

func (e *Editor) post(f func()) {
	if e.Post != nil {
		e.Post(f)
	} else {
		f()
	}
}

func (e *Editor) resetViews() {
	n := e.buf.Lines()
	e.views = make([]*lineView, n)
	e.measured = make([]float32, n)
	e.laid = 0
	e.hs.reset(e.measured)
	e.estimate()
}

func (e *Editor) estimate() {
	m, unknown := e.hs.totals()
	if n := len(e.views) - unknown; n > 0 {
		e.hs.est = m / float64(n)
	} else {
		e.hs.est = float64(max(e.look.Fonts.Size, 14) * max(e.look.LineHeight, 1.5) * 1.2)
	}
}

// invalidateLines drops the layouts of lines a..z, keeping their heights
// until they are laid out again.
func (e *Editor) invalidateLines(a, z int) {
	a, z = max(a, 0), min(z, len(e.views)-1)
	for i := a; i <= z; i++ {
		if e.views[i] != nil {
			e.views[i] = nil
			e.laid--
		}
	}
}

func (e *Editor) invalidateAll() { e.invalidateLines(0, len(e.views)-1) }

// invalidateAt lays out again the lines of the elements at unit u, or
// every line with a widget when the text changed since it was asked.
func (e *Editor) invalidateAt(u int) {
	u = min(u, e.buf.Len())
	l := e.buf.LineAt(u)
	last := l
	for _, sp := range e.buf.lineSpans(l) {
		if sp.ElemStart <= u && sp.ElemEnd >= u {
			last = max(last, e.buf.LineAt(sp.ElemEnd))
		}
	}
	e.invalidateLines(l, last)
	e.widgetLines()
}

// widgetLines lays out again the lines whose look depends on the column's
// width or on a picture: images, tables, math and diagrams.
func (e *Editor) widgetLines() {
	if !e.markdown {
		return
	}
	for _, k := range []markdown.Kind{markdown.Image, markdown.Table, markdown.MathBlock, markdown.CodeBlock, markdown.InlineMath} {
		for _, sp := range e.buf.doc.SpansOfKind(k) {
			if k == markdown.Image && sp.Flags&1 == 0 {
				continue
			}
			if k == markdown.CodeBlock && sp.Flags&(markdown.CodeDiagram|markdown.CodeMath) == 0 {
				continue
			}
			e.invalidateLines(e.buf.LineAt(sp.ElemStart), e.buf.LineAt(sp.ElemEnd))
		}
	}
}

// selection is the selection, in order.
func (e *Editor) selection() (int, int) { return min(e.anchor, e.caret), max(e.anchor, e.caret) }

// Selection is the selection, in order, in units.
func (e *Editor) Selection() (int, int) { return e.selection() }

// SetSelection selects units a..z and scrolls to them.
func (e *Editor) SetSelection(a, z int) {
	n := e.buf.Len()
	e.anchor, e.caret = max(0, min(a, n)), max(0, min(z, n))
	e.affinity = ui.TextDownstream
	e.hasDesired = false
	e.hist.breakStep()
	e.reveal = true
	e.selectionChanged()
}

// RevealCentered scrolls so the caret is in the middle of the view.
func (e *Editor) RevealCentered() {
	e.reveal, e.revealCenter = true, true
}

// edit is an edit made as one step: the changes, from the end of the text
// back so that earlier offsets hold, and the selection after.
func (e *Editor) apply(changes []change, sel [2]int, kind stepKind) {
	if e.ReadOnly || len(changes) == 0 {
		return
	}
	before := [2]int{e.anchor, e.caret}
	slices.SortStableFunc(changes, func(a, b change) int { return b.at - a.at })
	done := make([]change, 0, len(changes))
	for _, c := range changes {
		end := c.at + markdown.UnitsOf(c.old)
		old := e.buf.Slice(c.at, end)
		e.replaceText(c.at, end, c.new)
		done = append(done, change{c.at, old, c.new})
	}
	e.anchor, e.caret = sel[0], sel[1]
	e.hist.record(step{changes: done, before: before, after: sel, kind: kind, at: time.Now()})
	e.afterEdit()
}

// replace replaces a..z with s as one step, and puts the caret after it.
func (e *Editor) replace(a, z int, s string, kind stepKind) {
	if a > z {
		a, z = z, a
	}
	end := a + markdown.UnitsOf(s)
	e.apply([]change{{at: a, old: e.buf.Slice(a, z), new: s}}, [2]int{end, end}, kind)
}

// Replace replaces units a..z with s as one step of undo, and selects sel.
func (e *Editor) Replace(a, z int, s string, sel [2]int) {
	if a > z {
		a, z = z, a
	}
	e.hist.breakStep()
	e.apply([]change{{at: a, old: e.buf.Slice(a, z), new: s}}, sel, stepEdit)
	e.hist.breakStep()
}

// replaceText changes the buffer and keeps the layouts of lines in step.
func (e *Editor) replaceText(a, z int, s string) {
	la, lz := e.buf.LineAt(a), e.buf.LineAt(z)
	oldLines := e.buf.Lines()
	ds, de := e.buf.Edit(a, z, s)
	added := e.buf.Lines() - oldLines
	e.generation++
	// The lines from la to lz became la to lz+added.
	if added != 0 {
		nv := make([]*lineView, lz+added-la+1)
		nm := make([]float32, len(nv))
		for i := la; i <= lz; i++ {
			if e.views[i] != nil {
				e.laid--
			}
		}
		e.views = slices.Replace(e.views, la, lz+1, nv...)
		e.measured = slices.Replace(e.measured, la, lz+1, nm...)
		e.hs.reset(e.measured)
		e.estimate()
		if e.anchorLine > lz {
			e.anchorLine += added
		} else if e.anchorLine > la {
			e.anchorLine, e.anchorOff = la, 0
		}
	} else {
		e.invalidateLines(la, lz)
	}
	// What the parser says changed, and the line after it, whose room
	// after a heading may have changed.
	e.invalidateLines(e.buf.LineAt(ds), e.buf.LineAt(de)+1)
	if e.marked[0] >= z && e.hasMarked {
		d := markdown.UnitsOf(s) - (z - a)
		e.marked[0] += d
		e.marked[1] += d
	}
}

// afterEdit takes what an edit changed: the syntax shown, the caret's
// place, and the app's view of the text.
func (e *Editor) afterEdit() {
	n := e.buf.Len()
	e.anchor, e.caret = min(e.anchor, n), min(e.caret, n)
	e.hasDesired = false
	e.reveal = true
	e.changed = true
	e.updateRevealed(true)
	if e.Hooks.Changed != nil {
		e.Hooks.Changed()
	}
	e.updateCompletion()
}

// SetText replaces the whole text, as the file changed on disk: the
// selection stays where it can, and the history is cleared.
func (e *Editor) SetText(s string) {
	a, z := e.selection()
	e.buf = NewBuffer(s, e.buf.Language())
	e.look.Japanese = IsJapanese(s)
	e.hist = history{}
	e.hasMarked = false
	e.resetViews()
	e.generation++
	n := e.buf.Len()
	e.anchor, e.caret = min(a, n), min(z, n)
	e.revealed = e.elementsTouching(e.selection())
	e.hist.markSaved()
}

// Undo takes the last step back.
func (e *Editor) Undo() { e.takeBack(false) }

// Redo makes the last step taken back again.
func (e *Editor) Redo() { e.takeBack(true) }

// CanUndo reports whether there is a step to take back.
func (e *Editor) CanUndo() bool { return e.hist.canUndo() }

// CanRedo reports whether there is a step to make again.
func (e *Editor) CanRedo() bool { return e.hist.canRedo() }

func (e *Editor) takeBack(redo bool) {
	if e.ReadOnly {
		return
	}
	e.hasMarked = false
	from, to := &e.hist.undo, &e.hist.redo
	if redo {
		from, to = to, from
	}
	if len(*from) == 0 {
		return
	}
	s := (*from)[len(*from)-1]
	*from = (*from)[:len(*from)-1]
	if redo {
		// Made again in the order they were made.
		for _, c := range s.changes {
			e.replaceText(c.at, c.at+markdown.UnitsOf(c.old), c.new)
		}
		e.anchor, e.caret = s.after[0], s.after[1]
	} else {
		for _, c := range slices.Backward(s.changes) {
			e.replaceText(c.at, c.at+markdown.UnitsOf(c.new), c.old)
		}
		e.anchor, e.caret = s.before[0], s.before[1]
	}
	*to = append(*to, s)
	e.hist.open = false
	e.afterEdit()
}

// selectionChanged takes a move of the selection: the syntax around it
// shows, and the app hears of it.
func (e *Editor) selectionChanged() {
	e.updateRevealed(false)
	if e.completion != nil && e.completion.open {
		a, z := e.selection()
		if a != z || a < e.completion.trigger[0] || a > e.completion.trigger[1]+1 {
			e.completion.close()
		}
	}
	if e.Hooks.Selected != nil {
		e.Hooks.Selected()
	}
}

// elementsTouching are the elements with syntax to show for a selection:
// those it touches.
func (e *Editor) elementsTouching(a, z int) [][2]int {
	if !e.markdown || !e.look.HidesMarkers || z-a >= 4000 || e.buf.Len() == 0 {
		return nil
	}
	la, lz := e.buf.LineAt(a), e.buf.LineAt(z)
	spans := e.buf.doc.SpansIn(e.buf.LineStart(la), e.buf.LineEnd(lz)+1)
	var found [][2]int
	for _, sp := range spans {
		switch sp.Kind {
		case markdown.Marker, markdown.CalloutTag, markdown.ThematicBreak, markdown.Image, markdown.Table, markdown.MathBlock,
			markdown.InlineMath, markdown.CodeBlock, markdown.FrontMatter, markdown.ListMarker, markdown.TaskMarker:
			elem := [2]int{sp.ElemStart, sp.ElemEnd}
			// A task's syntax shows around its prefix, not its whole line.
			if sp.Kind == markdown.ListMarker || sp.Kind == markdown.TaskMarker {
				var marker, task *markdown.Span
				for k := range spans {
					o := &spans[k]
					if o.ElemStart != sp.ElemStart || o.ElemEnd != sp.ElemEnd {
						continue
					}
					if o.Kind == markdown.ListMarker {
						marker = o
					}
					if o.Kind == markdown.TaskMarker {
						task = o
					}
				}
				if marker != nil && task != nil {
					elem = taskPrefix(*marker, *task)
				}
			}
			if a <= elem[1] && z >= elem[0] && !slices.Contains(found, elem) {
				found = append(found, elem)
			}
		}
	}
	return found
}

// updateRevealed shows the syntax of the elements the selection touches,
// and hides that of the ones it left: only the lines of what changed, and
// of a code block or front matter only its fences.
func (e *Editor) updateRevealed(force bool) {
	a, z := e.selection()
	e.styler.sel = [2]int{a, z}
	now := e.elementsTouching(a, z)
	if !force && slices.Equal(now, e.revealed) {
		return
	}
	for _, el := range e.revealed {
		if !slices.Contains(now, el) {
			e.invalidateElement(el)
		}
	}
	for _, el := range now {
		if !slices.Contains(e.revealed, el) {
			e.invalidateElement(el)
		}
	}
	e.revealed = now
}

func (e *Editor) invalidateElement(el [2]int) {
	n := e.buf.Len()
	if el[0] > n {
		return
	}
	first, last := e.buf.LineAt(el[0]), e.buf.LineAt(min(el[1], n))
	isBlock := false
	for _, sp := range e.buf.lineSpans(first) {
		if sp.ElemStart == el[0] && sp.ElemEnd == el[1] && (sp.Kind == markdown.FrontMatter ||
			(sp.Kind == markdown.CodeBlock && sp.Flags&(markdown.CodeDiagram|markdown.CodeMath) == 0)) {
			isBlock = true
		}
	}
	if isBlock {
		e.invalidateLines(first, first)
		e.invalidateLines(last, last)
		return
	}
	e.invalidateLines(first, last)
}

// setLook takes how the text looks; another look lays every line out
// again.
func (e *Editor) setLook(l Look) {
	l.Japanese = e.look.Japanese
	e.look = l
	if k := e.look.key(); k != e.lookKey {
		e.lookKey = k
		e.widgets.invalidate()
		e.invalidateAll()
		e.updateRevealed(true)
	}
}

// lineTop is where line i starts in the content.
func (e *Editor) lineTop(i int) float64 { return e.hs.top(i) }

// contentHeight is the height of the text.
func (e *Editor) contentHeight() float64 { return e.hs.top(len(e.views)) }

// caretAt is the caret before unit u, in the content: its x from the
// column's left, top and height.
func (e *Editor) caretAt(u int, aff ui.TextAffinity) (x float32, y float64, h float32) {
	l := e.buf.LineAt(u)
	lv := e.layoutLine(l)
	cx, cy, ch := lv.caret(u-e.buf.LineStart(l), aff)
	return cx, e.lineTop(l) + float64(cy), ch
}

// positionAt is the unit nearest (x, y) in the content.
func (e *Editor) positionAt(x float32, y float64) (int, ui.TextAffinity) {
	n := len(e.views)
	y = max(y, 0)
	l := e.hs.at(y)
	for range n {
		lv := e.layoutLine(l)
		top := e.lineTop(l)
		switch {
		case y < top && l > 0:
			l--
		case y >= top+float64(lv.h) && l < n-1:
			l++
		default:
			u, aff := lv.position(x, float32(y-top))
			return e.buf.LineStart(l) + min(u, lv.units), aff
		}
	}
	return e.buf.Len(), ui.TextUpstream
}

func (e *Editor) setScroll(y float64) {
	e.scroll = y
	e.anchorLine = e.hs.at(y)
	e.anchorOff = y - e.lineTop(e.anchorLine)
}

// maxLaid is how many lines keep their layouts out of view.
const maxLaid = 600

// layout lays out the lines in view of a column h high, and those the
// caret is in when it is to be revealed.
func (e *Editor) layout(h float32) {
	e.viewH = h
	e.estimate()
	if f := e.pendingScroll; f > 0 {
		e.pendingScroll = 0
		e.setScroll(f * e.contentHeight())
	}
	e.place(h)
	if e.reveal {
		e.reveal = false
		_, y, ch := e.caretAt(e.caret, e.affinity)
		center := e.revealCenter
		e.revealCenter = false
		top := y - float64(e.padTop)
		switch {
		case center:
			e.setScroll(max(0, y-float64(h)/2))
		case top < e.scroll:
			e.setScroll(max(0, top))
		case y+float64(ch)+float64(e.padTop) > e.scroll+float64(h):
			l := e.buf.LineAt(e.caret)
			for q, room := l-1, y+float64(ch)-e.lineTop(l); q >= 0 && room < float64(h); q-- {
				room += float64(e.layoutLine(q).h)
			}
			_, y, ch = e.caretAt(e.caret, e.affinity)
			e.setScroll(y + float64(ch) + float64(e.padTop) - float64(h))
		}
		e.place(h)
	}
	total := e.contentHeight() + float64(e.padTop+e.pastEnd)
	if s := max(0, min(e.scroll, total-float64(h))); s != e.scroll {
		e.setScroll(s)
		e.place(h)
	}
	if e.laid > maxLaid+e.last-e.first {
		e.forget()
	}
}

// place lays out the lines in view, from the anchor down.
func (e *Editor) place(h float32) {
	n := len(e.views)
	e.anchorLine = max(0, min(e.anchorLine, n-1))
	e.layoutLine(e.anchorLine)
	e.first = e.anchorLine
	for e.first > 0 && e.lineTop(e.anchorLine)+e.anchorOff-e.lineTop(e.first) < 0 {
		e.first--
		e.layoutLine(e.first)
	}
	e.scroll = max(0, e.lineTop(e.anchorLine)+e.anchorOff)
	y := e.lineTop(e.first)
	l := e.first
	for ; l < n; l++ {
		y += float64(e.layoutLine(l).h)
		if y >= e.scroll+float64(h) {
			break
		}
	}
	e.last = min(l, n-1)
}

func (e *Editor) forget() {
	lo, hi := e.first-maxLaid/4, e.last+maxLaid/4
	for i := range e.views {
		if (i < lo || i > hi) && e.views[i] != nil {
			e.views[i] = nil
			e.laid--
		}
	}
}

// Headings lists the note's headings, for the outline.
func (e *Editor) Headings() []Heading {
	var out []Heading
	if !e.markdown {
		return out
	}
	for _, sp := range e.buf.doc.SpansOfKind(markdown.Heading) {
		title := e.buf.Slice(sp.ElemStart, sp.ElemEnd)
		if sp.Level <= 6 {
			title = strings.TrimLeft(title, "# \t")
			title = strings.TrimRight(title, "# \t")
			if l := strings.IndexByte(title, '\n'); l >= 0 {
				title = title[:l]
			}
		}
		out = append(out, Heading{Level: int(sp.Level), Title: plainTitle(title), At: sp.ElemStart})
	}
	return out
}

// Heading is a heading of the note.
type Heading struct {
	Level int
	Title string
	At    int
}

func plainTitle(s string) string {
	r := strings.NewReplacer("**", "", "__", "", "`", "", "==", "", "~~", "")
	return strings.TrimSpace(r.Replace(s))
}

// WordCount counts the words of the note.
func (e *Editor) WordCount() int { return e.buf.doc.CountWords() }

// CaretLine is the 1-based line and column of the caret.
func (e *Editor) CaretLine() (line, col int) {
	l := e.buf.LineAt(e.caret)
	return l + 1, e.caret - e.buf.LineStart(l) + 1
}

// Focused reports whether the editor has the keyboard.
func (e *Editor) Focused() bool { return e.focused }

// DeleteToLineStart deletes from the start of the caret's visual line to
// the caret, as ⌘⌫ does.
func (e *Editor) DeleteToLineStart() {
	a, z := e.selection()
	if a != z {
		e.deleteRange(a, z, false)
		return
	}
	s, _ := e.lineEdges(e.caret)
	if s == e.caret && s > 0 {
		s--
	}
	e.deleteRange(s, e.caret, false)
}

// ScrollFraction is how far down the note is scrolled, from 0 to 1.
func (e *Editor) ScrollFraction() float64 {
	total := e.contentHeight()
	if total <= 0 {
		return 0
	}
	return min(1, e.scroll/total)
}

// SetScrollFraction scrolls the note to f of the way down, once it is
// laid out.
func (e *Editor) SetScrollFraction(f float64) {
	if f <= 0 {
		return
	}
	e.pendingScroll = f
	e.reveal = false
}
