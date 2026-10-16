package main

import (
	"bytes"
	"context"
	"embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/draw"
	"image/png"
	"regexp"
	"strings"
	"sync"
	"time"

	"deckle/internal/editor"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

//go:embed resources/renderer
var rendererFiles embed.FS

var (
	rendererHTMLOnce sync.Once
	rendererHTML     string
)

// rendererPage is renderer.html with its style sheet, fonts and scripts
// put inline, so the page needs no files.
func rendererPage() string {
	rendererHTMLOnce.Do(func() {
		read := func(name string) string {
			b, _ := rendererFiles.ReadFile("resources/renderer/" + name)
			return string(b)
		}
		css := regexp.MustCompile(`url\(fonts/([^)]+)\)`).ReplaceAllStringFunc(read("katex.min.css"), func(m string) string {
			name := m[len("url(fonts/") : len(m)-1]
			b, _ := rendererFiles.ReadFile("resources/renderer/fonts/" + name)
			return "url(data:font/woff2;base64," + base64.StdEncoding.EncodeToString(b) + ")"
		})
		html := read("renderer.html")
		html = strings.Replace(html, `<link rel="stylesheet" href="katex.min.css">`, "<style>"+css+"</style>", 1)
		// From data: addresses, so that no sequence in the scripts, such as
		// <!-- before a <script in a string, can upset the HTML parser.
		script := func(name string) string {
			return `<script src="data:text/javascript;base64,` + base64.StdEncoding.EncodeToString([]byte(read(name))) + `"></script>`
		}
		html = strings.Replace(html, `<script src="katex.min.js"></script>`, script("katex.min.js"), 1)
		html = strings.Replace(html, `<script src="mermaid.min.js"></script>`, script("mermaid.min.js"), 1)
		rendererHTML = html
	})
	return rendererHTML
}

// renderer draws math with KaTeX and diagrams with Mermaid in a web view
// of the window, kept under the window's native UI, and keeps each result
// as a picture. The web view is made when a note first has math or a
// diagram, and goes after a while unused.
type renderer struct {
	w       *window
	wv      *mygo.WebView
	loaded  bool
	loading bool
	mu      sync.Mutex
	images  map[string]*rendered
	order   []string
	waiting map[string][]func()
	queue   []renderJob
	busy    bool
	idle    *time.Timer
	// printing is the web view of a note being printed.
	printing *mygo.WebView
}

type rendered struct {
	img  *ui.Bitmap
	w, h float32
}

type renderJob struct {
	key, kind, source string
	style             editor.RenderStyle
}

func newRenderer(w *window) *renderer {
	return &renderer{w: w, images: map[string]*rendered{}, waiting: map[string][]func(){}}
}

func hexColor(c ui.Color) string { return fmt.Sprintf("#%02X%02X%02X", c.R, c.G, c.B) }

// Render returns the picture of source, or nil while it renders; done runs
// once it is ready.
func (r *renderer) Render(kind editor.RenderKind, source string, s editor.RenderStyle, done func()) (*ui.Bitmap, float32, float32) {
	k := map[editor.RenderKind]string{editor.RenderMath: "math", editor.RenderInlineMath: "inline", editor.RenderDiagram: "mermaid"}[kind]
	key := fmt.Sprintf("%s|%v|%s|%s|%s|%.1f|%d|%s", k, s.Dark, hexColor(s.Color), hexColor(s.Background), hexColor(s.Accent), s.Size, int(s.Width), source)
	r.mu.Lock()
	defer r.mu.Unlock()
	if img := r.images[key]; img != nil {
		return img.img, img.w, img.h
	}
	if _, ok := r.waiting[key]; ok {
		r.waiting[key] = append(r.waiting[key], done)
		return nil, 0, 0
	}
	r.waiting[key] = []func(){done}
	r.queue = append(r.queue, renderJob{key, k, source, s})
	r.w.post(r.start)
	return nil, 0, 0
}

// host builds the web view under the window's UI, where it draws out of
// sight.
func (r *renderer) host(c *ui.Context) {
	if r.wv != nil {
		ui.WebView(c.Key("renderer"), r.wv).Absolute().Top(0).Left(0).Width(1200).Height(1600)
	}
	if r.printing != nil {
		ui.WebView(c.Key("printing"), r.printing).Absolute().Top(0).Left(0).Width(800).Height(1100)
	}
}

func (r *renderer) start() {
	if r.wv == nil {
		if r.loading {
			return
		}
		r.loading = true
		if r.w.w == nil {
			// A window of tests, with no window of the system's to hold
			// a web view.
			r.fail()
			return
		}
		wv, err := r.w.w.NewWebView(mygo.WebViewOptions{Transparent: true})
		if err != nil {
			r.fail()
			return
		}
		r.wv = wv
		wv.Page().LoadHTML(rendererPage(), "about:blank")
		go func() {
			// Ready once render is defined and KaTeX's fonts are in.
			for range 100 {
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				v, err := wv.Page().EvalContext(ctx, "typeof render === 'function' && typeof katex !== 'undefined'")
				cancel()
				if err == nil && v == true {
					break
				}
				time.Sleep(100 * time.Millisecond)
			}
			r.w.post(func() {
				r.loaded = true
				r.start()
			})
		}()
		return
	}
	r.mu.Lock()
	if !r.loaded || r.busy || len(r.queue) == 0 {
		empty := len(r.queue) == 0 && !r.busy
		r.mu.Unlock()
		if empty {
			r.scheduleTeardown()
		}
		return
	}
	job := r.queue[0]
	r.queue = r.queue[1:]
	r.busy = true
	r.mu.Unlock()
	if r.idle != nil {
		r.idle.Stop()
	}
	wv := r.wv
	go func() {
		img, w, h := r.render(wv, job)
		r.mu.Lock()
		r.busy = false
		waiting := r.waiting[job.key]
		delete(r.waiting, job.key)
		if img != nil {
			r.images[job.key] = &rendered{img, w, h}
			r.order = append(r.order, job.key)
			for len(r.order) > 400 {
				delete(r.images, r.order[0])
				r.order = r.order[1:]
			}
		}
		r.mu.Unlock()
		for _, f := range waiting {
			if f != nil {
				f()
			}
		}
		r.w.post(r.start)
	}()
}

func (r *renderer) fail() {
	r.mu.Lock()
	r.queue = nil
	r.mu.Unlock()
}

// render draws a job in the page and takes a picture of it.
func (r *renderer) render(wv *mygo.WebView, job renderJob) (*ui.Bitmap, float32, float32) {
	args, _ := json.Marshal([]any{job.kind, job.source, job.style.Dark, hexColor(job.style.Color), job.style.Size, job.style.Width, hexColor(job.style.Background), hexColor(job.style.Accent)})
	v, err := wv.Page().Eval("return await render(..." + string(args) + ")")
	if err != nil {
		return nil, 0, 0
	}
	m, _ := v.(map[string]any)
	w, _ := m["width"].(float64)
	h, _ := m["height"].(float64)
	if w <= 0 || h <= 0 {
		return nil, 0, 0
	}
	// A frame for the page to draw what it laid out.
	time.Sleep(50 * time.Millisecond)
	shot, err := wv.CapturePage()
	if err != nil {
		return nil, 0, 0
	}
	img, err := png.Decode(bytes.NewReader(shot))
	if err != nil {
		return nil, 0, 0
	}
	b := img.Bounds()
	scale := float64(b.Dx()) / 1200
	if scale <= 0 {
		scale = 2
	}
	crop := image.Rect(0, 0, min(b.Dx(), int(w*scale+0.5)), min(b.Dy(), int(h*scale+0.5)))
	out := image.NewRGBA(crop)
	draw.Draw(out, crop, img, b.Min, draw.Src)
	return ui.NewBitmap(out), float32(w), float32(h)
}

// scheduleTeardown lets the web view go after a while unused; the
// pictures stay.
func (r *renderer) scheduleTeardown() {
	if r.idle != nil {
		r.idle.Stop()
	}
	r.idle = time.AfterFunc(90*time.Second, func() {
		r.w.post(func() {
			r.mu.Lock()
			idle := len(r.queue) == 0 && !r.busy
			r.mu.Unlock()
			if idle && r.wv != nil {
				r.wv.Destroy()
				r.wv, r.loaded, r.loading = nil, false, false
			}
		})
	})
}
