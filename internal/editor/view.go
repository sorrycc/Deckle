package editor

import (
	"fmt"
	"time"

	"deckle/internal/theme"

	"github.com/egoist/mygo/ui"
)

// View builds the editor, in look, as an element the app sizes.
func (e *Editor) View(c *ui.Context, look Look) ui.Element {
	el := ui.Box(c).Focusable().Clip()
	e.services = c.Services()
	e.setLook(look)
	focused := el.Focused()
	if focused != e.focused {
		e.focused = focused
		e.blinkStart = c.Now()
		if !focused {
			e.dragging, e.thumb = false, false
			if e.completion != nil {
				e.completion.close()
			}
		}
	}
	if e.changed {
		e.changed = false
		el.SetChanged()
	}
	el.Role(ui.RoleTextField).Label("Note")
	if !e.ReadOnly {
		el.HandleTextInput(e.ime)
	}
	el.HandleInput(e.input)
	el.Cursor(e.cursor)
	el.Draw(e.paint)
	el.ContextMenu(e.menu)
	el.FocusRing(false)
	el.Background(look.Theme.Background)
	el.Children(func() { e.overlays(c) })
	if focused && !e.ReadOnly {
		// The caret blinks for half a minute after the last change.
		const blink = 530 * time.Millisecond
		if phase := c.Now().Sub(e.blinkStart); phase < 30*time.Second {
			c.After(blink - phase%blink)
		}
	}
	return el
}

// geometry places the column of text in an element of r: a readable width
// for Markdown, centered.
func (e *Editor) geometry(r ui.Rect) {
	width := float32(1e9)
	if e.markdown {
		width = e.look.LineWidth
		if width < 360 {
			width = 760
		}
	}
	inset := max(28, roundf((r.W-width)/2))
	colW := max(100, r.W-2*inset-8)
	if colW != e.colW {
		e.colW = colW
		e.widgets.invalidate()
		e.invalidateAll()
	}
	e.colX = inset + 4
	e.padTop = 24
	// Room after the end of a long note, to scroll its last lines up to
	// eye level.
	e.pastEnd = max(0, roundf(r.H*0.45)-e.padTop)
}

// contentY is where content y shows in the element.
func (e *Editor) toView(y float64) float32 { return float32(y-e.scroll) + e.padTop }

func (e *Editor) toContent(x, y float32) (float32, float64) {
	return x - e.colX, float64(y-e.padTop) + e.scroll
}

func (e *Editor) paint(p *ui.Painter, r ui.Rect) {
	e.rect = r
	e.geometry(r)
	e.layout(r.H)
	t := &e.look.Theme
	ox, oy := r.X+e.colX, r.Y
	a, z := e.selection()
	for i := e.first; i <= e.last && i < len(e.views); i++ {
		lv := e.layoutLine(i)
		top := oy + e.toView(e.lineTop(i))
		start := e.buf.LineStart(i)
		e.paintDecoration(p, lv, ox, top, t)
		if a != z && a <= start+lv.units && z >= start {
			e.paintSelection(p, lv, i, max(a, start)-start, min(z, start+lv.units)-start, z > start+lv.units, ox, top, t)
		}
		if e.find.active() {
			e.paintMatches(p, lv, start, ox, top, t)
		}
		if lv.prefix != nil {
			p.TextLayout(lv.prefix, ox+lv.prefixX, top+lv.rows[0].drawY, t.Text)
		}
		for _, rw := range lv.rows {
			p.TextLayout(rw.layout, ox+lv.bodyX, top+rw.drawY, t.Text)
		}
		e.paintMarkers(p, lv, ox, top, t)
		if e.hasMarked && e.marked[0] >= start && e.marked[0] <= start+lv.units {
			e.paintMarked(p, lv, start, ox, top, t)
		}
	}
	if e.focused && !e.ReadOnly && a == z {
		const blink = 530 * time.Millisecond
		if phase := p.Now().Sub(e.blinkStart); (phase/blink)%2 == 0 || phase < 0 {
			cx, cy, ch := e.caretAt(e.caret, e.affinity)
			p.Fill(ui.Rect{X: ox + cx, Y: oy + e.toView(cy), W: 2, H: ch}, t.Accent, 1)
		}
	}
	if total := e.contentHeight() + float64(e.padTop+e.pastEnd); total > float64(r.H) {
		top, size := e.thumbBox()
		alpha := float32(0.25)
		if e.thumb {
			alpha = 0.45
		}
		p.Fill(ui.Rect{X: r.X + r.W - 9, Y: r.Y + top, W: 6, H: size}, t.Text.Alpha(alpha), 3)
	}
	if e.completion != nil && e.completion.open {
		e.completion.anchorAt(e)
	}
}

// paintDecoration paints what a line shows behind its text: the
// background of a code block or front matter, a callout's box, the bars of
// a quote, a rule, and its widget.
func (e *Editor) paintDecoration(p *ui.Painter, lv *lineView, ox, top float32, t *theme.Theme) {
	d := &lv.look.deco
	bandTop := top + lv.textTop
	bandH := lv.h - lv.textTop - lv.look.spaceAfter
	if d.calloutLast {
		bandH += lv.look.spaceAfter
	}
	if d.calloutFirst {
		bandTop -= 3
		bandH += 3
	}
	band := ui.Rect{X: ox - 4, Y: bandTop, W: e.colW + 8, H: bandH}
	if d.block != blockNone && bandH > 0 {
		roundedBand(p, band, 8, d.blockFirst, d.blockLast, t.CodeBackground)
		if d.blockLabel != "" {
			lbl := ui.ShapeRichTextWith([]ui.Span{{Text: d.blockLabel, Size: 10, Weight: 600, Color: t.Syntax, LetterSpacing: 0.6}}, ui.Font{Size: 10}, ui.TextShape{})
			w, h := lbl.Size()
			p.TextLayout(lbl, band.X+band.W-w-12, top+lv.rows[0].top+(lv.look.lineH-h)/2, t.Syntax)
		}
	}
	if d.callout != 0 {
		color := t.CalloutColor(d.callout)
		inset := float32(d.quoteDepth-1) * quoteIndent
		rect := ui.Rect{X: band.X + inset, Y: band.Y, W: band.W - inset, H: band.H}
		roundedBand(p, rect, 8, d.calloutFirst, d.calloutLast, color.Alpha(0.1))
		if d.calloutName != "" {
			rw := lv.rows[0]
			mid := top + rw.top + lv.look.lineH/2
			icon := calloutIcon(d.callout, color)
			p.Image(icon, ui.Rect{X: rect.X + 10, Y: mid - 8, W: 16, H: 16}, ui.Contain)
			if !d.calloutHasTitle {
				name := ui.ShapeRichTextWith([]ui.Span{{Text: d.calloutName, Weight: 600, Color: color}}, ui.Font{Size: e.look.Fonts.Size}, ui.TextShape{})
				_, h := name.Size()
				p.TextLayout(name, rect.X+33, mid-h/2, color)
			}
		}
	} else if d.quoteDepth > 0 {
		for depth := 0; depth < d.quoteDepth; depth++ {
			level := uint(depth + 1)
			rect := ui.Rect{X: band.X + 5 + float32(depth)*quoteIndent, Y: band.Y, W: 3, H: band.H}
			roundedBand(p, rect, 1.5, d.quoteFirst&(1<<level) != 0, d.quoteLast&(1<<level) != 0, t.QuoteBar)
		}
	}
	if d.drawsRule {
		mid := top + lv.textTop + lv.look.lineH/2
		p.Fill(ui.Rect{X: band.X, Y: float32(int(mid)) - 0.5, W: band.W, H: 1}, t.Rule, 0)
	}
	if d.widget != nil {
		h := d.widget.height()
		wy := top + lv.look.widgetTop
		d.widget.draw(p, ui.Rect{X: ox, Y: wy, W: e.colW, H: h}, t)
	}
	for _, im := range d.inlineImages {
		x, y, ch := lv.caret(im.index, ui.TextDownstream)
		p.Image(im.img, ui.Rect{X: ox + x + 0.5, Y: top + y + ch/2 - im.h/2, W: im.w, H: im.h}, ui.Contain)
	}
}

// roundedBand fills r rounded only at the ends that are an element's:
// the lines of one block meet without a seam.
func roundedBand(p *ui.Painter, r ui.Rect, radius float32, first, last bool, c ui.Color) {
	fill := r
	if !first {
		fill.Y -= 2 * radius
		fill.H += 2 * radius
	}
	if !last {
		fill.H += 2 * radius
	}
	p.Clip(r, 0, func() { p.Fill(fill, c, radius) })
}

// paintMarkers paints the bullets and boxes that stand in for hidden list
// markers.
func (e *Editor) paintMarkers(p *ui.Painter, lv *lineView, ox, top float32, t *theme.Theme) {
	d := &lv.look.deco
	if len(d.bullets) == 0 && len(d.checkboxes) == 0 {
		return
	}
	size := lv.look.font.Size
	step := markerStep(size)
	rw := lv.rows[0]
	baseline := top + rw.drawY + lv.look.ascent
	cx := ox + lv.prefixX + step*markerCenter
	for _, b := range d.bullets {
		cy := baseline - size*0.26
		dia := max(4, roundf(size*0.4))
		rect := ui.Rect{X: roundf(cx - dia/2), Y: roundf(cy - dia/2), W: dia, H: dia}
		switch b.level {
		case 1:
			p.Fill(rect, t.Accent, dia/2)
		case 2:
			p.Stroke(ui.Rect{X: rect.X + 0.6, Y: rect.Y + 0.6, W: rect.W - 1.2, H: rect.H - 1.2}, t.Accent, dia/2, 1.2)
		default:
			p.Fill(ui.Rect{X: rect.X + 0.5, Y: rect.Y + 0.5, W: rect.W - 1, H: rect.H - 1}, t.Accent, 0)
		}
	}
	for _, b := range d.checkboxes {
		cy := baseline - size*0.35
		side := roundf(size * 0.95)
		rect := ui.Rect{X: roundf(cx-side/2) + 0.5, Y: roundf(cy-side/2) + 0.5, W: side - 1, H: side - 1}
		if b.checked {
			p.Fill(rect, t.Accent, side*0.26)
			var path ui.Path
			path.MoveTo(rect.X+rect.W*0.27, rect.Y+rect.H*0.53).LineTo(rect.X+rect.W*0.44, rect.Y+rect.H*0.70).LineTo(rect.X+rect.W*0.75, rect.Y+rect.H*0.33)
			p.StrokePath(&path, max(1.5, side*0.13), t.OnAccent())
		} else {
			p.Stroke(rect, t.Text.Alpha(0.32*float32(t.Text.A)/255), side*0.26, 1.5)
		}
	}
}

// paintSelection fills the selection's rectangles within line i, units
// from..to of it, and a space after the line when the newline is selected.
func (e *Editor) paintSelection(p *ui.Painter, lv *lineView, i, from, to int, newline bool, ox, top float32, t *theme.Theme) {
	color := t.Selection
	if !e.focused {
		color = t.Text.Alpha(0.12)
	}
	if lv.look.closed {
		return
	}
	if lv.prefix != nil && from < lv.bodyStart {
		for _, s := range lv.prefix.SelectionRects(ui.TextInputRange{Start: from, End: min(to, lv.bodyStart)}) {
			p.Fill(ui.Rect{X: ox + lv.prefixX + s.X, Y: top + lv.rows[0].top, W: s.W, H: lv.look.lineH}, color, 0)
		}
	}
	for _, rw := range lv.rows {
		s, z := max(from, rw.start), min(to, rw.end)
		if z <= s {
			continue
		}
		for _, sr := range rw.layout.SelectionRects(ui.TextInputRange{Start: s - rw.start, End: z - rw.start}) {
			p.Fill(ui.Rect{X: ox + lv.bodyX + sr.X, Y: top + rw.top, W: sr.W, H: lv.look.lineH}, color, 0)
		}
	}
	if newline && i < len(e.views)-1 {
		x, _, _ := lv.caret(lv.units, ui.TextUpstream)
		rw := lv.rows[len(lv.rows)-1]
		p.Fill(ui.Rect{X: ox + x, Y: top + rw.top, W: lv.look.font.Size * 0.35, H: lv.look.lineH}, color, 0)
	}
}

// paintMarked underlines an input method's composition.
func (e *Editor) paintMarked(p *ui.Painter, lv *lineView, start int, ox, top float32, t *theme.Theme) {
	from, to := e.marked[0]-start, min(e.marked[1]-start, lv.units)
	for _, rw := range lv.rows {
		s, z := max(from, rw.start), min(to, rw.end)
		if z <= s {
			continue
		}
		for _, sr := range rw.layout.SelectionRects(ui.TextInputRange{Start: s - rw.start, End: z - rw.start}) {
			p.Fill(ui.Rect{X: ox + lv.bodyX + sr.X, Y: top + rw.drawY + sr.Y + sr.H - 2, W: sr.W, H: 2}, t.Accent, 0)
		}
	}
}

// thumbBox is the top and height of the scroll bar's thumb.
func (e *Editor) thumbBox() (top, size float32) {
	total := e.contentHeight() + float64(e.padTop+e.pastEnd)
	track := e.rect.H - 4
	size = max(24, track*float32(float64(e.rect.H)/max(total, 1)))
	room := float64(track - size)
	at := 0.0
	if m := total - float64(e.rect.H); m > 0 {
		at = e.scroll / m
	}
	return 2 + float32(room*at), size
}

var calloutIcons = map[string]*ui.SVG{}

// calloutIcon is the icon of a kind of callout, in color: info, a bulb, a
// speech bubble, a warning sign and a flame.
func calloutIcon(kind int, c ui.Color) *ui.SVG {
	key := fmt.Sprintf("%d|%02x%02x%02x", kind, c.R, c.G, c.B)
	if s := calloutIcons[key]; s != nil {
		return s
	}
	paths := []string{
		`<circle cx="12" cy="12" r="9"/><path d="M12 16v-4M12 8h.01"/>`,
		`<path d="M15 14c.2-1 .7-1.7 1.5-2.5A5 5 0 0 0 12 3a5 5 0 0 0-5 5c0 1.3.5 2.4 1.5 3.5.8.8 1.3 1.5 1.5 2.5M9 18h6M10 22h4"/>`,
		`<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/><path d="M12 7v4M12 14h.01"/>`,
		`<path d="m21.7 18-8-14a2 2 0 0 0-3.4 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.7-3M12 9v4M12 17h.01"/>`,
		`<path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.4-.5-2-1-3-1.1-2.1-.2-4 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.2.5-2.3 1.5-3 0 1.5 1 2.5 2 2.5"/>`,
	}
	src := fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#%02x%02x%02x" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">%s</svg>`,
		c.R, c.G, c.B, paths[max(0, min(kind-1, 4))])
	s := ui.MustParseSVG([]byte(src))
	calloutIcons[key] = s
	return s
}
