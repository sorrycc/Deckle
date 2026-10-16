package editor

import (
	"bytes"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"deckle/internal/markdown"
	"deckle/internal/theme"

	"github.com/egoist/mygo/ui"
	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

// A widget is a block drawn above a line, in place of its source or with
// it: an image, a table, math or a diagram.
type widget interface {
	height() float32
	draw(p *ui.Painter, r ui.Rect, t *theme.Theme)
}

// RenderKind is what a Renderer draws.
type RenderKind int

const (
	RenderMath RenderKind = iota
	RenderInlineMath
	RenderDiagram
)

// RenderStyle is how a Renderer draws: in the editor's colors and size, no
// wider than Width.
type RenderStyle struct {
	Dark                      bool
	Color, Background, Accent ui.Color
	Size, Width               float32
}

// A Renderer draws math with KaTeX and diagrams with Mermaid.
type Renderer interface {
	// Render returns the picture of source and its size in DIPs, or nil
	// while it renders; done then runs, on any goroutine, once it can be
	// asked again.
	Render(kind RenderKind, source string, style RenderStyle, done func()) (*ui.Bitmap, float32, float32)
}

type imageWidget struct {
	img      ui.ImageSource
	w, h     float32
	corner   float32
	centered bool
}

func (w *imageWidget) height() float32 { return w.h }

func (w *imageWidget) draw(p *ui.Painter, r ui.Rect, t *theme.Theme) {
	x := r.X + 4
	if w.centered {
		x = r.X + roundf((r.W-w.w)/2)
	}
	frame := ui.Rect{X: x, Y: r.Y, W: w.w, H: w.h}
	if w.img == nil {
		// Not decoded yet: a quiet plate of its size, so the page doesn't
		// jump when the picture arrives.
		p.Fill(frame, t.CodeBackground, 8)
		return
	}
	p.Clip(frame, w.corner, func() { p.Image(w.img, frame, ui.FillBox) })
}

// The images of notes, decoded no larger than they are drawn, up to a
// budget of pixels, shared by every editor.
var images = struct {
	sync.Mutex
	m       map[string]*cachedImage
	loading map[string][]func()
	sizes   map[string][2]float32
	pixels  int
	clock   int
}{m: map[string]*cachedImage{}, loading: map[string][]func(){}, sizes: map[string][2]float32{}}

type cachedImage struct {
	img  ui.ImageSource
	w, h float32
	used int
}

const maxImagePixels = 2400
const imageBudget = 40 * 1024 * 1024 // pixels

func isRemote(src string) bool {
	return strings.HasPrefix(src, "http://") || strings.HasPrefix(src, "https://")
}

// imageKey is the absolute path or address of an image a note names, and
// a stamp of when it was written, so a picture saved again is read again.
func imageKey(src, notePath string) (path, key string) {
	if isRemote(src) {
		return src, src
	}
	if d, err := url.PathUnescape(src); err == nil {
		src = d
	}
	if !filepath.IsAbs(src) {
		src = filepath.Join(filepath.Dir(notePath), src)
	}
	src = filepath.Clean(src)
	stamp := ""
	if st, err := os.Stat(src); err == nil {
		stamp = st.ModTime().Format(time.RFC3339Nano)
	}
	return src, src + "|" + stamp
}

// loadImage returns the image at src, or nil while it loads; done runs on
// another goroutine once it has.
func loadImage(src, notePath string, done func()) (ui.ImageSource, float32, float32) {
	path, key := imageKey(src, notePath)
	images.Lock()
	defer images.Unlock()
	if c := images.m[key]; c != nil {
		images.clock++
		c.used = images.clock
		return c.img, c.w, c.h
	}
	if waiting, ok := images.loading[key]; ok {
		images.loading[key] = append(waiting, done)
		return nil, 0, 0
	}
	images.loading[key] = []func(){done}
	go func() {
		img, w, h := decodeImage(path)
		images.Lock()
		waiting := images.loading[key]
		delete(images.loading, key)
		if img != nil {
			images.clock++
			images.m[key] = &cachedImage{img, w, h, images.clock}
			images.pixels += int(w * h)
			for images.pixels > imageBudget && len(images.m) > 1 {
				oldest, k := 0, ""
				for kk, c := range images.m {
					if k == "" || c.used < oldest {
						oldest, k = c.used, kk
					}
				}
				images.pixels -= int(images.m[k].w * images.m[k].h)
				delete(images.m, k)
			}
		}
		images.Unlock()
		for _, f := range waiting {
			if f != nil {
				f()
			}
		}
	}()
	return nil, 0, 0
}

func readImage(path string) ([]byte, error) {
	if isRemote(path) {
		client := http.Client{Timeout: 20 * time.Second}
		resp, err := client.Get(path)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		return io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	}
	return os.ReadFile(path)
}

// decodeImage decodes an image no larger than it is ever drawn, keeping
// its size.
func decodeImage(path string) (ui.ImageSource, float32, float32) {
	data, err := readImage(path)
	if err != nil {
		return nil, 0, 0
	}
	if strings.EqualFold(filepath.Ext(path), ".svg") || bytes.Contains(data[:min(len(data), 512)], []byte("<svg")) {
		svg, err := ui.ParseSVG(data)
		if err != nil {
			return nil, 0, 0
		}
		w, h := svg.Size()
		return svg, w, h
	}
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0
	}
	b := src.Bounds()
	w, h := float32(b.Dx()), float32(b.Dy())
	if longer := max(w, h); longer > maxImagePixels {
		scale := maxImagePixels / longer
		dst := image.NewRGBA(image.Rect(0, 0, int(w*scale), int(h*scale)))
		xdraw.ApproxBiLinear.Scale(dst, dst.Bounds(), src, b, xdraw.Src, nil)
		src = dst
	}
	return ui.NewBitmap(src), w, h
}

// imageSize reads the size of a local image from its header alone.
func imageSize(src, notePath string) (float32, float32, bool) {
	if isRemote(src) {
		return 0, 0, false
	}
	path, key := imageKey(src, notePath)
	images.Lock()
	s, ok := images.sizes[key]
	images.Unlock()
	if !ok {
		if f, err := os.Open(path); err == nil {
			if c, _, err := image.DecodeConfig(f); err == nil {
				s = [2]float32{float32(c.Width), float32(c.Height)}
			}
			f.Close()
		}
		images.Lock()
		images.sizes[key] = s
		images.Unlock()
	}
	return s[0], s[1], s[0] > 0
}

func fit(w, h, maxW, maxH float32) (float32, float32) {
	if w <= 0 || h <= 0 {
		return 1, 1
	}
	scale := min(1, maxW/w, maxH/h)
	return roundf(w * scale), roundf(h * scale)
}

// widgets supplies an editor's widgets.
type widgets struct {
	ed *Editor
	// tables are kept by their source and width.
	tables map[string]*tableWidget
	// lastRendered is the last picture of each piece of math or diagram,
	// shown while a new one, for another width or theme, renders.
	lastRendered map[string]*imageWidget
	renderOrder  []string
}

func newWidgets(ed *Editor) *widgets {
	return &widgets{ed: ed, tables: map[string]*tableWidget{}, lastRendered: map[string]*imageWidget{}}
}

func (w *widgets) invalidate() { clear(w.tables) }

// arrived asks for the lines of element to be laid out again once what
// they wait for came.
func (w *widgets) arrived(elemStart int) func() {
	ed := w.ed
	return func() {
		ed.post(func() { ed.invalidateAt(elemStart) })
	}
}

// apply puts the widgets of a line in its look: an image on its own line,
// a table, a block of math or a diagram, and inline math.
func (w *widgets) apply(s *styler, look *lineLook, a []attr, text string, start int, spans []markdown.Span, hide func([2]int)) {
	ed := w.ed
	d := &look.deco
	n := len(a)
	content := n
	if strings.HasSuffix(text, "\r") {
		content--
	}
	width := s.width
	for _, sp := range spans {
		elem := [2]int{sp.ElemStart, sp.ElemEnd}
		switch {
		case sp.Kind == markdown.Image && sp.Flags&1 != 0:
			var dest string
			for _, o := range spans {
				if o.Kind == markdown.ImageDest && o.ElemStart == sp.ElemStart {
					dest = ed.buf.Slice(o.Start, o.End)
				}
			}
			if dest == "" {
				continue
			}
			available := width - 2*look.indent
			var wd widget
			if img, iw, ih := loadImage(dest, ed.path, w.arrived(sp.ElemStart)); img != nil {
				fw, fh := fit(iw, ih, available, 560)
				wd = &imageWidget{img: img, w: fw, h: fh, corner: 8}
			} else if iw, ih, ok := imageSize(dest, ed.path); ok {
				fw, fh := fit(iw, ih, available, 560)
				wd = &imageWidget{w: fw, h: fh}
			} else {
				continue
			}
			d.widget = wd
			look.widgetTop = look.spaceBefore
			look.spaceBefore += wd.height() + 6
			if !s.revealed(elem) {
				hide([2]int{0, content})
				look.lineH = 6
			}
			return
		case sp.Kind == markdown.Table:
			if s.revealed(elem) {
				return
			}
			hide([2]int{0, content})
			look.closed = true
			if sp.Start != sp.ElemStart {
				return
			}
			tw := w.table(elem, width, s)
			d.widget = tw
			look.widgetTop = look.spaceBefore
			look.spaceBefore += tw.height() + 4
			return
		case sp.Kind == markdown.MathBlock && sp.Flags&1 != 0:
			w.rendered(RenderMath, func() string { return mathSource(ed.buf.Slice(elem[0], elem[1])) }, sp, look, content, s, hide)
			return
		case sp.Kind == markdown.CodeBlock && sp.Flags&(markdown.CodeDiagram|markdown.CodeMath) != 0:
			kind := RenderMath
			if sp.Flags&markdown.CodeDiagram != 0 {
				kind = RenderDiagram
			}
			w.rendered(kind, func() string { return fenceSource(ed.buf.Slice(elem[0], elem[1])) }, sp, look, content, s, hide)
			return
		case sp.Kind == markdown.InlineMath && !s.revealed(elem):
			r := [2]int{sp.Start - start, sp.End - start}
			if r[1]-r[0] <= 2 || ed.renderer == nil {
				continue
			}
			source := ed.buf.Slice(sp.Start+1, sp.End-1)
			img, iw, ih := ed.renderer.Render(RenderInlineMath, source, w.renderStyle(s, RenderInlineMath), w.arrived(sp.ElemStart))
			if img == nil {
				continue
			}
			// Shown no taller than the line, the text's size at most.
			scale := min(1, s.look.Fonts.Size*1.7/max(1, ih))
			iw, ih = roundf(iw*scale), roundf(ih*scale)
			hide(r)
			// The room goes after the first character, where the image is
			// drawn, so a line break can't come between them.
			a[r[0]].spacing = iw
			d.inlineImages = append(d.inlineImages, inlineImage{r[0], img, iw, ih})
		}
	}
}

func (w *widgets) renderStyle(s *styler, kind RenderKind) RenderStyle {
	t := &s.look.Theme
	size := s.look.Fonts.Size
	switch kind {
	case RenderDiagram:
		size = roundf(size * 0.9)
	case RenderMath:
		size *= 1.15
	default:
		size *= 0.95
	}
	return RenderStyle{Dark: t.Dark, Color: t.Text, Background: t.Background, Accent: t.Accent, Size: size, Width: s.width - 8}
}

// rendered puts a block of math or a diagram above its first line: in
// place of its source, or above it while the selection is in it.
func (w *widgets) rendered(kind RenderKind, source func() string, sp markdown.Span, look *lineLook, content int, s *styler, hide func([2]int)) {
	revealed := s.revealed([2]int{sp.ElemStart, sp.ElemEnd})
	if !revealed {
		hide([2]int{0, content})
		look.closed = true
		look.deco.block = blockNone
	}
	if sp.Start != sp.ElemStart {
		return
	}
	src := source()
	if strings.TrimSpace(src) == "" || w.ed.renderer == nil {
		look.closed = false
		return
	}
	key := string(rune('0'+kind)) + "|" + src
	var wd *imageWidget
	if img, iw, ih := w.ed.renderer.Render(kind, src, w.renderStyle(s, kind), w.arrived(sp.ElemStart)); img != nil {
		scale := min(1, (s.width-8)/max(1, iw))
		wd = &imageWidget{img: img, w: roundf(iw * scale), h: roundf(ih * scale), centered: kind == RenderMath}
		w.lastRendered[key] = wd
	} else {
		wd = w.lastRendered[key]
	}
	// The pictures used longest ago go first, so the blocks still in the
	// note keep theirs.
	for i, k := range w.renderOrder {
		if k == key {
			w.renderOrder = append(w.renderOrder[:i], w.renderOrder[i+1:]...)
			break
		}
	}
	w.renderOrder = append(w.renderOrder, key)
	if len(w.renderOrder) > 200 {
		delete(w.lastRendered, w.renderOrder[0])
		w.renderOrder = w.renderOrder[1:]
	}
	if wd == nil {
		look.closed = false
		return
	}
	look.deco.widget = wd
	look.widgetTop = look.spaceBefore
	if revealed {
		look.spaceBefore += wd.h + 10
	} else {
		look.spaceBefore += wd.h + 6
	}
}

// mathSource is the math between a block's $$ marks.
func mathSource(s string) string {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "$$")
	return strings.TrimSuffix(s, "$$")
}

// fenceSource is the lines between a code block's fences.
func fenceSource(s string) string {
	lines := strings.Split(s, "\n")
	if len(lines) > 0 {
		lines = lines[1:]
	}
	if n := len(lines); n > 0 {
		last := strings.TrimSpace(lines[n-1])
		if strings.HasPrefix(last, "```") || strings.HasPrefix(last, "~~~") {
			lines = lines[:n-1]
		}
	}
	return strings.Join(lines, "\n")
}

// Tables.

type tableCell struct {
	spans  []ui.Span
	align  ui.Align
	layout *ui.TextLayout
}

type tableWidget struct {
	rows    [][]tableCell
	widths  []float32
	heights []float32
	font    ui.Font
}

var tablePad = [2]float32{13, 8}

func (t *tableWidget) height() float32 {
	h := float32(1)
	for _, x := range t.heights {
		h += x
	}
	return h
}

func (w *widgets) table(elem [2]int, width float32, s *styler) *tableWidget {
	ed := w.ed
	source := ed.buf.Slice(elem[0], elem[1])
	key := source + "|" + itoa(int(width))
	if t := w.tables[key]; t != nil {
		return t
	}
	th := &s.look.Theme
	font := ui.Font{Family: s.look.Fonts.BodyFamily(cjkLanguage(source, s.look.Fonts.ChineseScript, s.look.Japanese)), Size: s.look.Fonts.Size}
	var rows [][]tableCell
	var row []tableCell
	line := -1
	for _, sp := range ed.buf.doc.SpansIn(elem[0], elem[1]+1) {
		if sp.Kind != markdown.TableCell {
			continue
		}
		if l := ed.buf.LineAt(sp.Start); l != line {
			if len(row) > 0 {
				rows = append(rows, row)
			}
			row, line = nil, l
		}
		header := sp.Flags&(markdown.TableHeader<<4) != 0
		align := ui.Start
		switch sp.Flags & 0xF {
		case 2:
			align = ui.Center
		case 3:
			align = ui.End
		}
		cf := font
		if header {
			cf.Weight = 700
		}
		row = append(row, tableCell{spans: inlineSpans(ed.buf.Slice(sp.Start, sp.End), cf, th, s.look.Fonts), align: align})
	}
	if len(row) > 0 {
		rows = append(rows, row)
	}
	t := &tableWidget{rows: rows, font: font}
	cols := 0
	for _, r := range rows {
		cols = max(cols, len(r))
	}
	natural := make([]float32, cols)
	for i := range natural {
		natural[i] = 40
	}
	for _, r := range rows {
		for i, c := range r {
			l := ui.ShapeRichTextWith(c.spans, font, ui.TextShape{})
			cw, _ := l.Size()
			natural[i] = max(natural[i], ceil(cw)+2*tablePad[0])
		}
	}
	total := float32(0)
	for _, x := range natural {
		total += x
	}
	scale := float32(1)
	if total > width {
		scale = width / total
	}
	t.widths = make([]float32, cols)
	for i, x := range natural {
		t.widths[i] = float32(int(x * scale))
	}
	for ri, r := range rows {
		h := float32(24)
		for i := range r {
			cw := max(10, t.widths[i]-2*tablePad[0])
			r[i].layout = ui.ShapeRichTextWith(r[i].spans, font, ui.TextShape{Width: cw, Align: r[i].align})
			_, lh := r[i].layout.Size()
			h = max(h, ceil(lh)+2*tablePad[1])
		}
		rows[ri] = r
		t.heights = append(t.heights, h)
	}
	w.tables[key] = t
	return t
}

func (t *tableWidget) draw(p *ui.Painter, r ui.Rect, th *theme.Theme) {
	width := float32(0)
	for _, x := range t.widths {
		width += x
	}
	frame := ui.Rect{X: r.X + 0.5, Y: r.Y + 0.5, W: width, H: t.height() - 1}
	hair := 1 / max(p.Scale(), 1)
	p.Clip(frame, 8, func() {
		if len(t.heights) > 0 {
			p.Fill(ui.Rect{X: frame.X, Y: frame.Y, W: width, H: t.heights[0]}, th.CodeBackground, 0)
		}
		y := frame.Y
		for ri, row := range t.rows {
			x := frame.X
			for i, c := range row {
				if i >= len(t.widths) {
					break
				}
				p.TextLayout(c.layout, x+tablePad[0], y+tablePad[1], th.Text)
				x += t.widths[i]
				if i < len(t.widths)-1 {
					p.Fill(ui.Rect{X: x - hair/2, Y: y, W: hair, H: t.heights[ri]}, th.Rule.Alpha(0.6*float32(th.Rule.A)/255), 0)
				}
			}
			y += t.heights[ri]
			if ri < len(t.rows)-1 {
				if ri == 0 {
					p.Fill(ui.Rect{X: frame.X, Y: y - 0.5, W: width, H: 1}, th.Rule, 0)
				} else {
					p.Fill(ui.Rect{X: frame.X, Y: y - hair/2, W: width, H: hair}, th.Rule, 0)
				}
			}
		}
	})
	p.Stroke(frame, th.Rule, 8, 1)
}

// The inline syntax a cell's text can hold.
var inlineRules = []struct {
	re   *regexp.Regexp
	kind int
}{
	{regexp.MustCompile(`\*\*(.+?)\*\*|__(.+?)__`), 0},
	{regexp.MustCompile(`(?:^|[^*\w])\*([^*]+?)\*|(?:^|\W)_(.+?)_`), 1},
	{regexp.MustCompile("`([^`]+)`"), 2},
	{regexp.MustCompile(`~~(.+?)~~`), 3},
	{regexp.MustCompile(`\[\[(?:[^\]|]*\|)?([^\]]+)\]\]`), 4},
	{regexp.MustCompile(`\[([^\]]+)\]\([^)]*\)`), 4},
}

// inlineSpans is a cell's text with its inline syntax taken out and its
// style kept: bold, italic, code, struck and links.
func inlineSpans(source string, font ui.Font, th *theme.Theme, fonts theme.Fonts) []ui.Span {
	type run struct {
		text string
		a    attr
	}
	runs := []run{{source, attr{}}}
	for _, rule := range inlineRules {
		var out []run
		for _, r := range runs {
			if r.a != (attr{}) {
				out = append(out, r)
				continue
			}
			s := r.text
			for len(s) > 0 {
				m := rule.re.FindStringSubmatchIndex(s)
				if m == nil {
					out = append(out, run{s, r.a})
					break
				}
				g0, g1 := -1, -1
				for k := 2; k+1 < len(m); k += 2 {
					if m[k] >= 0 {
						g0, g1 = m[k], m[k+1]
						break
					}
				}
				if g0 < 0 {
					out = append(out, run{s, r.a})
					break
				}
				// The match's own start may hold a character before the
				// syntax, as the italic rule's lookbehind does.
				start := m[0]
				if rule.kind == 1 && start < len(s) && s[start] != '*' && s[start] != '_' {
					start++
				}
				if start > 0 {
					out = append(out, run{s[:start], r.a})
				}
				a := r.a
				switch rule.kind {
				case 0:
					a.weight = 700
				case 1:
					a.italic = true
				case 2:
					a.family, a.size, a.color = fonts.MonoFamily(), roundf(font.Size*0.9), th.CodeText
				case 3:
					a.strike = true
				case 4:
					a.color = th.Link
				}
				out = append(out, run{s[g0:g1], a})
				s = s[m[1]:]
			}
		}
		runs = out
	}
	var spans []ui.Span
	for _, r := range runs {
		if r.text == "" {
			continue
		}
		sp := ui.Span{Text: r.text, Weight: font.Weight, Italic: r.a.italic, Strikethrough: r.a.strike, Color: r.a.color, Font: r.a.family, Size: r.a.size}
		if r.a.weight > 0 {
			sp.Weight = r.a.weight
		}
		spans = append(spans, sp)
	}
	if len(spans) == 0 {
		spans = []ui.Span{{Text: " "}}
	}
	return spans
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
