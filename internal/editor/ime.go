package editor

import (
	"deckle/internal/markdown"

	"github.com/egoist/mygo/ui"
)

// The editor is the client of the system's input methods. As in
// NSTextView, an input method's composition is in the text, marked, until
// it is committed; ranges are UTF-16 units, as the editor counts.

var _ ui.TextInputClient = (*imeClient)(nil)

// imeClient is the editor as the input methods see it.
type imeClient struct{ e *Editor }

func (e *Editor) clampRange(r ui.TextInputRange) (int, int) {
	n := e.buf.Len()
	a, z := max(0, min(r.Start, n)), max(0, min(r.End, n))
	if a > z {
		a, z = z, a
	}
	return a, z
}

func (ic *imeClient) TextForRange(r ui.TextInputRange) (string, ui.TextInputRange) {
	e := ic.e
	a, z := e.clampRange(r)
	return e.buf.Slice(a, z), ui.TextInputRange{Start: a, End: z}
}

func (ic *imeClient) Selection() ui.TextInputSelection {
	e := ic.e
	a, z := e.selection()
	return ui.TextInputSelection{Range: ui.TextInputRange{Start: a, End: z}, Reversed: e.caret == a && a != z}
}

func (ic *imeClient) MarkedRange() (ui.TextInputRange, bool) {
	e := ic.e
	if !e.hasMarked {
		return ui.TextInputRange{}, false
	}
	return ui.TextInputRange{Start: e.marked[0], End: e.marked[1]}, true
}

func (ic *imeClient) ReplaceText(r *ui.TextInputRange, s string) {
	e := ic.e
	if e.ReadOnly {
		return
	}
	var a, z int
	switch {
	case r != nil:
		a, z = e.clampRange(*r)
	case e.hasMarked:
		a, z = e.marked[0], e.marked[1]
	default:
		a, z = e.selection()
	}
	wasMarked := e.hasMarked
	e.hasMarked = false
	if wasMarked && r == nil {
		// The composition committed: one step with its start.
		e.replaceKeepingStep(a, z, s)
	} else {
		e.typeText(a, z, s)
	}
	e.blinkStart = timeNow()
	e.services.Invalidate()
}

// replaceKeepingStep replaces a..z as part of the step of undo before it.
func (e *Editor) replaceKeepingStep(a, z int, s string) {
	end := a + markdown.UnitsOf(s)
	e.hist.open = true
	e.apply([]change{{at: a, old: e.buf.Slice(a, z), new: s}}, [2]int{end, end}, stepTyping)
}

func (ic *imeClient) SetMarkedText(r *ui.TextInputRange, s string, selected ui.TextInputRange) {
	e := ic.e
	if e.ReadOnly {
		return
	}
	var a, z int
	switch {
	case r != nil:
		a, z = e.clampRange(*r)
	case e.hasMarked:
		a, z = e.marked[0], e.marked[1]
	default:
		a, z = e.selection()
	}
	if e.hasMarked {
		e.replaceKeepingStep(a, z, s)
	} else {
		e.hist.breakStep()
		e.replace(a, z, s, stepTyping)
	}
	n := markdown.UnitsOf(s)
	e.hasMarked = s != ""
	e.marked = [2]int{a, a + n}
	selected.Start, selected.End = max(0, min(selected.Start, n)), max(0, min(selected.End, n))
	e.markedSel = selected
	e.anchor, e.caret = a+selected.Start, a+selected.End
	e.reveal = true
	e.services.Invalidate()
}

func (ic *imeClient) UnmarkText() {
	e := ic.e
	if e.hasMarked {
		e.hasMarked = false
		e.hist.breakStep()
		e.services.Invalidate()
	}
}

func (ic *imeClient) BoundsForRange(r ui.TextInputRange) (ui.Rect, ui.TextInputRange, bool) {
	e := ic.e
	if len(e.views) == 0 || e.colW <= 0 {
		return ui.Rect{}, ui.TextInputRange{}, false
	}
	a, z := e.clampRange(r)
	x, y, h := e.caretAt(a, e.affinity)
	b := ui.Rect{X: e.colX + x, Y: e.toView(y), W: 1, H: h}
	actual := ui.TextInputRange{Start: a, End: a}
	if z > a {
		x2, y2, _ := e.caretAt(min(z, a+2), ui.TextUpstream)
		if y2 == y && x2 > x {
			b.W = x2 - x
			actual.End = min(z, a+2)
		}
	}
	visible := b.Y+b.H > 0 && b.Y < e.rect.H
	return b, actual, visible
}

func (ic *imeClient) IndexForPoint(p ui.Point) (int, bool) {
	e := ic.e
	if e.colW <= 0 {
		return 0, false
	}
	x, y := e.toContent(p.X, p.Y)
	u, _ := e.positionAt(x, y)
	return u, true
}
