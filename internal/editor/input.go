package editor

import (
	"runtime"
	"strings"
	"time"
	"unicode"

	"deckle/internal/markdown"

	"github.com/egoist/mygo/ui"
)

var timeNow = time.Now

const scrollbarWidth = 12

// input takes the editor's input as it comes: keys, text, edit commands,
// the pointer and the wheel.
func (e *Editor) input(ev ui.InputEvent) bool {
	switch ev.Kind {
	case ui.InputKeyDown:
		before := [2]int{e.anchor, e.caret}
		took := e.key(ev.Key, ev.Mods)
		if took {
			e.blinkStart = timeNow()
			if [2]int{e.anchor, e.caret} != before {
				e.selectionChanged()
			}
		}
		if (ev.Mods&ui.Cmd != 0) != e.cmdHeld {
			e.cmdHeld = ev.Mods&ui.Cmd != 0
			e.hoverAt(e.pointer.X, e.pointer.Y)
		}
		return took
	case ui.InputKeyUp:
		if e.cmdHeld && ev.Mods&ui.Cmd == 0 {
			e.cmdHeld = false
			e.hoverAt(e.pointer.X, e.pointer.Y)
			return true
		}
		return false
	case ui.InputText:
		if e.ReadOnly || ev.Text == "" {
			return false
		}
		a, z := e.selection()
		e.typeText(a, z, ev.Text)
		e.blinkStart = timeNow()
		return true
	case ui.InputCommand:
		return e.editCommand(ev.Text)
	case ui.InputPointerDown:
		return e.press(ev)
	case ui.InputPointerMove:
		return e.move(ev)
	case ui.InputPointerUp:
		return e.release(ev)
	case ui.InputScroll:
		before := e.scroll
		total := e.contentHeight() + float64(e.padTop+e.pastEnd)
		e.setScroll(max(0, min(e.scroll+float64(ev.DY), total-float64(e.rect.H))))
		return e.scroll != before
	case ui.InputSelect:
		e.SetSelection(ev.Start, ev.End)
		return true
	}
	return false
}

// typeText types s in place of a..z, joining the typing before it.
func (e *Editor) typeText(a, z int, s string) {
	if e.ReadOnly {
		return
	}
	kind := stepTyping
	if a != z || strings.ContainsAny(s, "\n") || markdown.UnitsOf(s) > 1 {
		e.hist.breakStep()
		kind = stepEdit
	}
	e.replace(a, z, s, kind)
	e.affinity = ui.TextDownstream
	e.selectionChanged()
}

// moveTo puts the caret at u, extending the selection or not.
func (e *Editor) moveTo(u int, aff ui.TextAffinity, extend bool) {
	u = max(0, min(u, e.buf.Len()))
	e.caret, e.affinity = u, aff
	if !extend {
		e.anchor = u
	}
	e.hist.breakStep()
	e.reveal = true
}

func isWord(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' }

func (e *Editor) nextWord(u int) int {
	n, word := e.buf.Len(), false
	for u < n {
		r, w := e.buf.RuneAt(u)
		if isWord(r) {
			word = true
		} else if word {
			break
		}
		u += w
	}
	return u
}

func (e *Editor) prevWord(u int) int {
	word := false
	for u > 0 {
		r, w := e.buf.RuneBefore(u)
		if isWord(r) {
			word = true
		} else if word {
			break
		}
		u -= w
	}
	return u
}

// wordAt is the word, or the run of other characters, around u, within
// its line.
func (e *Editor) wordAt(u int) (int, int) {
	n := e.buf.Len()
	if n == 0 {
		return 0, 0
	}
	u = max(0, min(u, n-1))
	r, _ := e.buf.RuneAt(u)
	if r == '\n' && u > 0 {
		r, _ = e.buf.RuneBefore(u)
		u--
	}
	word := isWord(r)
	a, z := u, u
	for a > 0 {
		r, w := e.buf.RuneBefore(a)
		if r == '\n' || isWord(r) != word {
			break
		}
		a -= w
	}
	for z < n {
		r, w := e.buf.RuneAt(z)
		if r == '\n' || isWord(r) != word {
			break
		}
		z += w
	}
	return a, z
}

// grapheme is the edge of the grapheme before u (dir < 0) or after it.
func (e *Editor) grapheme(u, dir int) int {
	l := e.buf.LineAt(u)
	ls, le := e.buf.LineStart(l), e.buf.LineEnd(l)
	if dir < 0 && u <= ls {
		return max(u-1, 0)
	}
	if dir > 0 && u >= le {
		return min(u+1, e.buf.Len())
	}
	lv := e.layoutLine(l)
	local := u - ls
	var layout *ui.TextLayout
	base := 0
	if lv.prefix != nil && local < lv.bodyStart || lv.prefix != nil && local == lv.bodyStart && dir < 0 {
		layout = lv.prefix
	} else {
		k := lv.rowAt(local, ui.TextDownstream)
		if dir < 0 && k > 0 && local == lv.rows[k].start {
			k--
		}
		layout, base = lv.rows[k].layout, lv.rows[k].start
	}
	var v int
	if dir < 0 {
		v = layout.PreviousBoundary(local - base)
	} else {
		v = layout.NextBoundary(local - base)
	}
	if v == local-base {
		// Past the layout's edge: by a character.
		if dir < 0 {
			_, w := e.buf.RuneBefore(u)
			return u - w
		}
		_, w := e.buf.RuneAt(u)
		return u + w
	}
	return ls + base + v
}

// vertical moves the caret up or down lines, keeping its x.
func (e *Editor) vertical(lines int, extend bool) {
	x, y, h := e.caretAt(e.caret, e.affinity)
	if !e.hasDesired {
		e.desiredX, e.hasDesired = x, true
	}
	l := e.buf.LineAt(e.caret)
	lv := e.layoutLine(l)
	step := float64(max(lv.look.lineH, h))
	target := y + float64(h)/2 + float64(lines)*step
	// A line laid out closer than its neighbors, folded or after a widget,
	// is stepped past rather than landed in again.
	if lines < 0 {
		rowTop := e.lineTop(l) + float64(lv.rows[lv.rowAt(e.caret-e.buf.LineStart(l), e.affinity)].top)
		target = min(target, rowTop-1)
	} else {
		k := lv.rowAt(e.caret-e.buf.LineStart(l), e.affinity)
		rowBottom := e.lineTop(l) + float64(lv.rows[k].top+lv.look.lineH)
		if k == len(lv.rows)-1 {
			rowBottom = e.lineTop(l) + float64(lv.h)
		}
		target = max(target, rowBottom+1)
	}
	switch {
	case target < 0:
		e.moveTo(0, ui.TextDownstream, extend)
	case target > e.contentHeight():
		e.moveTo(e.buf.Len(), ui.TextDownstream, extend)
	default:
		// Past folded lines to one with text.
		tl := e.hs.at(target)
		for lines < 0 && tl > 0 && e.layoutLine(tl).look.closed {
			tl--
			target = e.lineTop(tl) + float64(e.layoutLine(tl).textTop) + 1
		}
		for lines > 0 && tl < len(e.views)-1 && e.layoutLine(tl).look.closed {
			tl++
			target = e.lineTop(tl) + float64(e.layoutLine(tl).textTop) + 1
		}
		u, a := e.positionAt(e.desiredX, target)
		e.moveTo(u, a, extend)
	}
	e.hasDesired = true
}

// lineEdges are the edges of the visual line holding u.
func (e *Editor) lineEdges(u int) (int, int) {
	l := e.buf.LineAt(u)
	lv := e.layoutLine(l)
	ls := e.buf.LineStart(l)
	s, z := lv.rowEdges(u-ls, e.affinity)
	return ls + s, ls + z
}

var emacsKeys = map[ui.Key]ui.Key{ui.KeyB: ui.KeyLeft, ui.KeyF: ui.KeyRight, ui.KeyP: ui.KeyUp, ui.KeyN: ui.KeyDown, ui.KeyH: ui.KeyBackspace, ui.KeyD: ui.KeyDelete}

// key handles a key pressed, and reports whether it took it.
func (e *Editor) key(key ui.Key, mods ui.Modifiers) bool {
	if e.completion != nil && e.completion.open && e.completion.key(e, key, mods) {
		return true
	}
	mac := runtime.GOOS == "darwin"
	shift := mods&ui.Shift != 0
	m := mods &^ ui.Shift
	if mac && m == ui.Ctrl {
		if to, ok := emacsKeys[key]; ok {
			key, m = to, 0
		} else {
			l := e.buf.LineAt(e.caret)
			switch key {
			case ui.KeyA:
				e.moveTo(e.buf.LineStart(l), ui.TextDownstream, shift)
				return true
			case ui.KeyE:
				e.moveTo(e.buf.LineEnd(l), ui.TextDownstream, shift)
				return true
			case ui.KeyK:
				end := e.buf.LineEnd(l)
				if end == e.caret && end < e.buf.Len() {
					end++
				}
				e.deleteRange(e.caret, end, false)
				return true
			}
		}
	}
	word := (!mac && m == ui.Ctrl) || (mac && m == ui.Alt)
	a, z := e.selection()
	n := e.buf.Len()
	switch key {
	case ui.KeyLeft, ui.KeyRight:
		left := key == ui.KeyLeft
		switch {
		case mac && m == ui.Cmd:
			s, end := e.lineEdges(e.caret)
			if left {
				e.moveTo(s, ui.TextDownstream, shift)
			} else {
				e.moveTo(end, ui.TextUpstream, shift)
			}
		case word && left:
			e.moveTo(e.prevWord(e.caret), ui.TextDownstream, shift)
		case word:
			e.moveTo(e.nextWord(e.caret), ui.TextDownstream, shift)
		case m != 0:
			return false
		case a != z && !shift && left:
			e.moveTo(a, ui.TextDownstream, false)
		case a != z && !shift:
			e.moveTo(z, ui.TextDownstream, false)
		case left:
			e.moveTo(e.grapheme(e.caret, -1), ui.TextDownstream, shift)
		default:
			e.moveTo(e.grapheme(e.caret, 1), ui.TextDownstream, shift)
		}
		e.hasDesired = false
		return true
	case ui.KeyUp, ui.KeyDown:
		if mac && m == ui.Cmd {
			if key == ui.KeyUp {
				e.moveTo(0, ui.TextDownstream, shift)
			} else {
				e.moveTo(n, ui.TextDownstream, shift)
			}
			return true
		}
		if mac && m == ui.Alt || !mac && m == ui.Ctrl {
			l := e.buf.LineAt(e.caret)
			ls, le := e.buf.LineStart(l), e.buf.LineEnd(l)
			switch {
			case key == ui.KeyUp && e.caret == ls && l > 0:
				e.moveTo(e.buf.LineStart(l-1), ui.TextDownstream, shift)
			case key == ui.KeyUp:
				e.moveTo(ls, ui.TextDownstream, shift)
			case e.caret == le && l+1 < e.buf.Lines():
				e.moveTo(e.buf.LineEnd(l+1), ui.TextUpstream, shift)
			default:
				e.moveTo(le, ui.TextUpstream, shift)
			}
			e.hasDesired = false
			return true
		}
		if m != 0 {
			return false
		}
		if !shift && a != z {
			if key == ui.KeyUp {
				e.moveTo(a, ui.TextDownstream, false)
			} else {
				e.moveTo(z, ui.TextDownstream, false)
			}
		}
		d := 1
		if key == ui.KeyUp {
			d = -1
		}
		e.vertical(d, shift)
		return true
	case ui.KeyPageUp, ui.KeyPageDown:
		lines := max(int(e.rect.H/(e.look.Fonts.Size*e.look.LineHeight))-1, 1)
		if key == ui.KeyPageUp {
			lines = -lines
		}
		e.vertical(lines, shift)
		return true
	case ui.KeyHome, ui.KeyEnd:
		if m == ui.Ctrl || mac {
			if key == ui.KeyHome {
				e.moveTo(0, ui.TextDownstream, shift)
			} else {
				e.moveTo(n, ui.TextDownstream, shift)
			}
			return true
		}
		s, end := e.lineEdges(e.caret)
		if key == ui.KeyHome {
			e.moveTo(s, ui.TextDownstream, shift)
		} else {
			e.moveTo(end, ui.TextUpstream, shift)
		}
		return true
	case ui.KeyEscape:
		if m != 0 {
			return false
		}
		if e.find.open {
			e.find.close(e)
			return true
		}
		if a != z {
			e.moveTo(z, ui.TextDownstream, false)
			return true
		}
		return false
	case ui.KeyA:
		if m == ui.Cmd {
			e.anchor, e.caret = 0, n
			return true
		}
	case ui.KeyC, ui.KeyX, ui.KeyV, ui.KeyZ:
		if m != ui.Cmd {
			break
		}
		switch key {
		case ui.KeyC:
			return e.editCommand("copy")
		case ui.KeyX:
			return e.editCommand("cut")
		case ui.KeyV:
			if shift {
				return e.editCommand("pasteAndMatchStyle")
			}
			return e.editCommand("paste")
		case ui.KeyZ:
			if shift {
				return e.editCommand("redo")
			}
			return e.editCommand("undo")
		}
	}
	if e.ReadOnly {
		return false
	}
	switch key {
	case ui.KeyBackspace:
		switch {
		case a != z:
			e.deleteRange(a, z, false)
		case mac && m == ui.Cmd:
			s, _ := e.lineEdges(e.caret)
			if s == e.caret && s > 0 {
				s--
			}
			e.deleteRange(s, e.caret, false)
		case word:
			e.deleteRange(e.prevWord(e.caret), e.caret, false)
		case m != 0:
			return false
		case e.caret > 0:
			e.deleteRange(e.grapheme(e.caret, -1), e.caret, true)
		}
		return true
	case ui.KeyDelete:
		switch {
		case a != z:
			e.deleteRange(a, z, false)
		case word:
			e.deleteRange(e.caret, e.nextWord(e.caret), false)
		case m != 0:
			return false
		case e.caret < n:
			e.deleteRange(e.caret, e.grapheme(e.caret, 1), false)
		}
		return true
	case ui.KeyEnter:
		switch m {
		case 0:
			e.newline()
			return true
		case ui.Cmd:
			return e.Run("toggleTaskDone")
		}
		return false
	case ui.KeyTab:
		switch {
		case m != 0:
			return false
		case shift:
			if !e.shiftItems(-1) && !e.isCode(e.caret) {
				return false
			}
			return true
		default:
			if !e.shiftItems(1) {
				e.typeText(a, z, "\t")
			}
			return true
		}
	}
	return false
}

// deleteRange deletes a..z; backspacing typing goes on as one step.
func (e *Editor) deleteRange(a, z int, typing bool) {
	if a == z || e.ReadOnly {
		return
	}
	kind := stepDeleting
	if !typing {
		e.hist.breakStep()
		kind = stepEdit
	}
	if a > z {
		a, z = z, a
	}
	e.apply([]change{{at: a, old: e.buf.Slice(a, z), new: ""}}, [2]int{a, a}, kind)
	e.selectionChanged()
}

// editCommand performs an edit command of a menu or a shortcut.
func (e *Editor) editCommand(name string) bool {
	a, z := e.selection()
	switch name {
	case "copy":
		if a != z {
			e.services.WriteClipboard(e.buf.Slice(a, z))
		}
		return true
	case "cut":
		if a != z && !e.ReadOnly {
			e.services.WriteClipboard(e.buf.Slice(a, z))
			e.deleteRange(a, z, false)
		}
		return true
	case "paste", "pasteAndMatchStyle":
		if !e.ReadOnly {
			e.paste(name == "pasteAndMatchStyle")
		}
		return true
	case "selectAll":
		e.anchor, e.caret = 0, e.buf.Len()
		e.selectionChanged()
		return true
	case "delete":
		if a != z {
			e.deleteRange(a, z, false)
		}
		return true
	case "undo":
		e.Undo()
		return true
	case "redo":
		e.Redo()
		return true
	}
	return e.Run(name)
}

// press handles a press of the pointer.
func (e *Editor) press(ev ui.InputEvent) bool {
	if ev.Button != 0 {
		return false
	}
	if e.overScrollbar(ev.X) {
		e.thumb = true
		top, size := e.thumbBox()
		if ev.Y >= top && ev.Y < top+size {
			e.thumbGrab = ev.Y - top
		} else {
			e.thumbGrab = size / 2
			e.dragThumb(ev.Y)
		}
		return true
	}
	if e.hasMarked {
		e.ime.UnmarkText()
	}
	x, y := e.toContent(ev.X, ev.Y)
	// A click in the room after the text puts the caret at the end.
	if y > e.contentHeight() && ev.Clicks == 1 {
		e.moveTo(e.buf.Len(), ui.TextDownstream, ev.Mods&ui.Shift != 0)
		e.dragging = true
		e.dragUnit = 1
		e.dragStart = [2]int{e.anchor, e.caret}
		e.selectionChanged()
		return true
	}
	u, aff := e.positionAt(x, y)
	if ev.Mods&ui.Cmd != 0 && e.markdown {
		if l, ok := e.LinkAt(u); ok && e.Hooks.Follow != nil {
			e.Hooks.Follow(l, ev.Mods&ui.Shift != 0)
			return true
		}
	}
	if ev.Clicks == 1 && !e.ReadOnly {
		if task, ok := e.taskBoxAt(x, y); ok {
			text := "[x]"
			if task.Flags != 0 {
				text = "[ ]"
			}
			a, z := e.selection()
			e.Replace(task.Start, task.End, text, [2]int{a, z})
			return true
		}
	}
	e.dragging = true
	e.hasDesired = false
	e.dragUnit = min(max(ev.Clicks, 1), 3)
	switch e.dragUnit {
	case 1:
		e.moveTo(u, aff, ev.Mods&ui.Shift != 0)
	case 2:
		e.anchor, e.caret = e.wordAt(u)
	default:
		l := e.buf.LineAt(u)
		e.anchor, e.caret = e.buf.LineStart(l), min(e.buf.LineEnd(l)+1, e.buf.Len())
	}
	e.dragStart = [2]int{e.anchor, e.caret}
	e.hist.breakStep()
	e.selectionChanged()
	return true
}

func (e *Editor) move(ev ui.InputEvent) bool {
	e.pointer = ui.Point{X: ev.X, Y: ev.Y}
	if e.thumb {
		e.dragThumb(ev.Y)
		return true
	}
	if !e.dragging {
		if e.cmdHeld != (ev.Mods&ui.Cmd != 0) {
			e.cmdHeld = ev.Mods&ui.Cmd != 0
		}
		return e.hoverAt(ev.X, ev.Y)
	}
	// Near the edges, a drag scrolls.
	if ev.Y < 0 {
		e.setScroll(max(0, e.scroll+float64(ev.Y)))
	} else if ev.Y > e.rect.H {
		e.setScroll(e.scroll + float64(ev.Y-e.rect.H))
	}
	x, y := e.toContent(ev.X, ev.Y)
	u, aff := e.positionAt(x, y)
	switch e.dragUnit {
	case 2:
		s, end := e.wordAt(u)
		if u < e.dragStart[0] {
			e.anchor, e.caret = e.dragStart[1], s
		} else {
			e.anchor, e.caret = e.dragStart[0], max(end, e.dragStart[1])
		}
	case 3:
		l := e.buf.LineAt(u)
		if u < e.dragStart[0] {
			e.anchor, e.caret = e.dragStart[1], e.buf.LineStart(l)
		} else {
			e.anchor, e.caret = e.dragStart[0], min(e.buf.LineEnd(l)+1, e.buf.Len())
		}
	default:
		e.caret, e.affinity = u, aff
	}
	e.reveal = true
	e.selectionChanged()
	return true
}

func (e *Editor) release(ev ui.InputEvent) bool {
	if e.thumb {
		e.thumb = false
		return true
	}
	if !e.dragging {
		return false
	}
	e.dragging = false
	return true
}

// hoverAt shows what a click at (x, y) of the element would do: a hand
// over a task's box, or over a link with ⌘ held, which then underlines.
func (e *Editor) hoverAt(x, y float32) bool {
	if e.colW <= 0 {
		return false
	}
	cursor := ui.CursorText
	var link [2]int
	if e.overScrollbar(x) {
		cursor = ui.CursorDefault
	} else if e.markdown {
		cx, cy := e.toContent(x, y)
		if _, ok := e.taskBoxAt(cx, cy); ok {
			cursor = ui.CursorPointer
		} else if e.cmdHeld && cy <= e.contentHeight() {
			u, _ := e.positionAt(cx, cy)
			if r, ok := e.linkElement(u); ok {
				link = r
				cursor = ui.CursorPointer
			}
		}
	}
	changed := cursor != e.cursor
	e.cursor = cursor
	dest := ""
	if e.markdown && !e.overScrollbar(x) {
		if cx, cy := e.toContent(x, y); cy >= 0 && cy <= e.contentHeight() {
			if u, _ := e.positionAt(cx, cy); true {
				if r, ok := e.linkElement(u); ok && u >= r[0] && u <= r[1] {
					if l, ok := e.LinkAt(u); ok {
						dest = l.URL + l.Wiki
					}
				}
			}
		}
	}
	if dest != e.hoverDest {
		e.hoverDest = dest
		changed = true
	}
	if b := e.codeBlockAt(x, y); b != e.hoverBlock {
		e.hoverBlock, e.copied = b, false
		changed = true
	}
	if link != e.hover {
		for _, r := range [][2]int{e.hover, link} {
			if r != ([2]int{}) {
				e.invalidateLines(e.buf.LineAt(r[0]), e.buf.LineAt(r[1]))
			}
		}
		e.hover = link
		e.styler.hovered = link
		changed = true
	}
	return changed
}

func (e *Editor) overScrollbar(x float32) bool {
	return e.contentHeight()+float64(e.padTop+e.pastEnd) > float64(e.rect.H) && x >= e.rect.W-scrollbarWidth
}

func (e *Editor) dragThumb(y float32) {
	_, size := e.thumbBox()
	track := e.rect.H - 4 - size
	total := e.contentHeight() + float64(e.padTop+e.pastEnd) - float64(e.rect.H)
	if track <= 0 || total <= 0 {
		return
	}
	f := float64((y - e.thumbGrab - 2) / track)
	e.setScroll(max(0, min(f, 1)) * total)
}

// taskBoxAt is the task whose drawn box is at (x, y) in the content.
func (e *Editor) taskBoxAt(x float32, y float64) (markdown.Span, bool) {
	if !e.markdown || len(e.views) == 0 || y < 0 || y > e.contentHeight() {
		return markdown.Span{}, false
	}
	l := e.hs.at(y)
	lv := e.layoutLine(l)
	if len(lv.look.deco.checkboxes) == 0 {
		return markdown.Span{}, false
	}
	size := lv.look.font.Size
	step := markerStep(size)
	cx := lv.prefixX + step*markerCenter
	rw := lv.rows[0]
	cy := float32(e.lineTop(l)) + rw.drawY + lv.look.ascent - size*0.35
	side := roundf(size * 0.95)
	if x < cx-side/2-4 || x > cx+side/2+4 || float32(y) < cy-side/2-3 || float32(y) > cy+side/2+3 {
		return markdown.Span{}, false
	}
	for _, sp := range e.buf.lineSpans(l) {
		if sp.Kind == markdown.TaskMarker {
			return sp, true
		}
	}
	return markdown.Span{}, false
}

// menu builds the editor's context menu.
func (e *Editor) menu(m *ui.Menu) {
	m.EditItems()
}

// codeBlockAt is the code block, drawn as code, under (x, y) of the
// element.
func (e *Editor) codeBlockAt(x, y float32) [2]int {
	if !e.markdown || e.colW <= 0 || x < e.colX-4 || x > e.colX+e.colW+4 {
		return [2]int{}
	}
	_, cy := e.toContent(x, y)
	if cy < 0 || cy > e.contentHeight() {
		return [2]int{}
	}
	for _, sp := range e.buf.lineSpans(e.hs.at(cy)) {
		if sp.Kind == markdown.CodeBlock && sp.Flags&(markdown.CodeDiagram|markdown.CodeMath) == 0 {
			return [2]int{sp.ElemStart, sp.ElemEnd}
		}
	}
	return [2]int{}
}
