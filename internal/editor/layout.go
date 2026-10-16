package editor

import (
	"math/bits"

	"deckle/internal/markdown"

	"github.com/egoist/mygo/ui"
)

// heights sums the heights of the lines of an editor, measured as they are
// laid out and estimated for the others, in two Fenwick trees: the
// heights measured, and how many are not, which the estimate multiplies.
// The top of a line, and the line at a height, take O(log n).
type heights struct {
	measured []float64 // 1-based
	unknown  []int32
	est      float64
}

func (h *heights) reset(hs []float32) {
	n := len(hs)
	h.measured = append(h.measured[:0], make([]float64, n+1)...)
	h.unknown = append(h.unknown[:0], make([]int32, n+1)...)
	for i, x := range hs {
		if x > 0 {
			h.measured[i+1] = float64(x)
		} else {
			h.unknown[i+1] = 1
		}
	}
	for i := 1; i <= n; i++ {
		if j := i + i&-i; j <= n {
			h.measured[j] += h.measured[i]
			h.unknown[j] += h.unknown[i]
		}
	}
}

func (h *heights) add(p int, dm float64, du int32) {
	for i := p + 1; i < len(h.measured); i += i & -i {
		h.measured[i] += dm
		h.unknown[i] += du
	}
}

func (h *heights) top(p int) float64 {
	var m float64
	var u int32
	for i := min(p, len(h.measured)-1); i > 0; i -= i & -i {
		m += h.measured[i]
		u += h.unknown[i]
	}
	return m + float64(u)*h.est
}

func (h *heights) at(y float64) int {
	n := len(h.measured) - 1
	if n <= 0 {
		return 0
	}
	pos := 0
	var sum float64
	for step := 1 << (bits.Len(uint(n)) - 1); step > 0; step >>= 1 {
		if next := pos + step; next <= n {
			if s := sum + h.measured[next] + float64(h.unknown[next])*h.est; s <= y {
				pos, sum = next, s
			}
		}
	}
	return min(pos, n-1)
}

func (h *heights) totals() (float64, int) {
	var m float64
	var u int32
	for i := len(h.measured) - 1; i > 0; i -= i & -i {
		m += h.measured[i]
		u += h.unknown[i]
	}
	return m, int(u)
}

// row is a visual line of a line's text, laid out on its own so that rows
// stand a line height apart.
type row struct {
	layout *ui.TextLayout
	// start and end are the units of the line the row holds.
	start, end int
	// top is the row's box from the line's top; drawY where its text is
	// drawn, centered in the box.
	top, drawY float32
}

// lineView is a line laid out.
type lineView struct {
	look   *lineLook
	prefix *ui.TextLayout
	// prefixX and bodyX are from the column's left.
	prefixX, bodyX float32
	bodyStart      int
	rows           []row
	h              float32
	// textTop is where the first row starts: below the room above, which
	// holds a widget.
	textTop float32
	units   int
}

// rowAt is the row holding unit u of the line, the one before a row's
// start for an upstream caret there.
func (lv *lineView) rowAt(u int, aff ui.TextAffinity) int {
	k := 0
	for k+1 < len(lv.rows) && lv.rows[k+1].start <= u {
		k++
	}
	if k > 0 && u == lv.rows[k].start && aff == ui.TextUpstream {
		k--
	}
	return k
}

// caret is the caret before unit u of the line, from its top-left.
func (lv *lineView) caret(u int, aff ui.TextAffinity) (x, y, h float32) {
	if lv.prefix != nil && u < lv.bodyStart {
		r := lv.prefix.CaretAt(ui.TextCaretPosition{Index: u, Affinity: aff})
		rw := lv.rows[0]
		return lv.prefixX + r.X, rw.drawY + r.Y, r.H
	}
	k := lv.rowAt(u, aff)
	rw := lv.rows[k]
	r := rw.layout.CaretAt(ui.TextCaretPosition{Index: max(0, u-rw.start), Affinity: aff})
	return lv.bodyX + r.X, rw.drawY + r.Y, r.H
}

// position is the unit of the line nearest (x, y), from its top-left.
func (lv *lineView) position(x, y float32) (int, ui.TextAffinity) {
	k := 0
	for k+1 < len(lv.rows) && y >= lv.rows[k+1].top {
		k++
	}
	rw := lv.rows[k]
	if k == 0 && lv.prefix != nil && x < lv.bodyX {
		p := lv.prefix.PositionAt(ui.Point{X: x - lv.prefixX, Y: y - rw.drawY})
		return min(p.Index, lv.bodyStart), p.Affinity
	}
	p := rw.layout.PositionAt(ui.Point{X: x - lv.bodyX, Y: y - rw.drawY})
	u := rw.start + p.Index
	if k+1 < len(lv.rows) && u >= lv.rows[k+1].start {
		return lv.rows[k+1].start, ui.TextUpstream
	}
	return u, p.Affinity
}

// rowEdges are the units where the row holding u starts and ends.
func (lv *lineView) rowEdges(u int, aff ui.TextAffinity) (int, int) {
	if lv.prefix != nil && u < lv.bodyStart {
		return 0, lv.rows[0].end
	}
	k := lv.rowAt(u, aff)
	s := lv.rows[k].start
	if k == 0 {
		s = 0
	}
	return s, lv.rows[k].end
}

// layoutLine lays out line i at the column's width, keeping the layout
// until the line or its look changes.
func (e *Editor) layoutLine(i int) *lineView {
	if lv := e.views[i]; lv != nil {
		return lv
	}
	b := e.buf
	text := b.rawLine(i)
	start := b.LineStart(i)
	spans := b.lineSpans(i)
	after := false
	if i > 0 && e.markdown {
		for _, sp := range b.lineSpans(i - 1) {
			if sp.Kind == markdown.Heading {
				after = true
				break
			}
		}
	}
	e.styler.width = e.colW
	look := e.styler.style(text, start, spans, after)
	lv := &lineView{look: look, units: len(look.attrs)}
	n := lv.units
	x0 := look.indent
	avail := max(e.colW-look.indent-look.rightIndent, 20)
	font := look.font
	lv.bodyX = x0
	if look.prefixEnd > 0 && look.prefixEnd <= n {
		lv.prefix = ui.ShapeRichTextWith(look.spans(0, look.prefixEnd), font, ui.TextShape{})
		pw, _ := lv.prefix.Size()
		lv.prefixX = x0 + look.prefixX
		lv.bodyX = x0 + max(look.bodyX, look.prefixX+pw)
		lv.bodyStart = look.prefixEnd
	}
	bodyW := max(avail-(lv.bodyX-x0), 20)
	bodySpans := look.spans(lv.bodyStart, n)
	full := ui.ShapeRichTextWith(bodySpans, font, ui.TextShape{Width: bodyW})
	_, fullH := full.Size()
	// The rows of the text as it wraps, each laid out again on its own.
	var starts []int
	for y := float32(0); y < fullH; {
		p := full.PositionAt(ui.Point{X: -1e6, Y: y + 0.5})
		r := full.CaretAt(ui.TextCaretPosition{Index: p.Index})
		if len(starts) > 0 && p.Index <= starts[len(starts)-1] {
			break
		}
		starts = append(starts, p.Index)
		if r.Y+r.H <= y {
			break
		}
		y = r.Y + r.H
	}
	if len(starts) == 0 {
		starts = []int{0}
	}
	starts[0] = 0
	lineH := look.lineH
	if look.closed {
		lineH = 0
	}
	lv.textTop = look.spaceBefore
	for k, s := range starts {
		end := n - lv.bodyStart
		if k+1 < len(starts) {
			end = starts[k+1]
		}
		var l *ui.TextLayout
		if len(starts) == 1 {
			l = full
		} else {
			l = ui.ShapeRichTextWith(look.spans(lv.bodyStart+s, lv.bodyStart+end), font, ui.TextShape{})
		}
		_, lh := l.Size()
		top := lv.textTop + float32(k)*lineH
		drawY := top + float32(int((lineH-lh)/2))
		if look.closed {
			drawY = top
		}
		lv.rows = append(lv.rows, row{layout: l, start: lv.bodyStart + s, end: lv.bodyStart + end, top: top, drawY: drawY})
	}
	lv.rows[0].start = lv.bodyStart
	lv.h = lv.textTop + float32(len(lv.rows))*lineH + look.spaceAfter
	if look.closed {
		lv.h = max(lv.textTop+look.spaceAfter, 0.01)
	}
	e.views[i] = lv
	e.laid++
	old := e.measured[i]
	if old > 0 {
		e.hs.add(i, float64(lv.h-old), 0)
	} else {
		e.hs.add(i, float64(lv.h), -1)
	}
	e.measured[i] = lv.h
	return lv
}
