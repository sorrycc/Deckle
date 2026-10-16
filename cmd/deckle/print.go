package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"html"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"deckle/internal/editor"
	"deckle/internal/markdown"
	"deckle/internal/theme"

	"github.com/egoist/mygo"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	gmhtml "github.com/yuin/goldmark/renderer/html"
)

// printable is the note of the tab shown as an HTML page for printing: its
// Markdown in the editor's look, with math, diagrams, highlights, wikilinks
// and callouts drawn as the editor draws them.
func (w *window) printable(ed *editor.Editor) string {
	text := ed.Text()
	buf := ed.Buffer()
	type sub struct {
		a, z int // bytes
		s    string
	}
	var subs []sub
	add := func(sp markdown.Span, s string) {
		subs = append(subs, sub{buf.Byte(sp.Start), buf.Byte(sp.End), s})
	}
	esc := html.EscapeString
	doc := buf.Doc()
	for _, sp := range doc.SpansOfKind(markdown.MathBlock) {
		src := strings.TrimSuffix(strings.TrimPrefix(strings.TrimSpace(buf.Slice(sp.ElemStart, sp.ElemEnd)), "$$"), "$$")
		sp.Start, sp.End = sp.ElemStart, sp.ElemEnd
		add(sp, `<div class="math" data-src="`+b64(src)+`"></div>`)
	}
	for _, sp := range doc.SpansOfKind(markdown.InlineMath) {
		add(sp, `<span class="imath" data-src="`+b64(buf.Slice(sp.Start+1, sp.End-1))+`"></span>`)
	}
	for _, sp := range doc.SpansOfKind(markdown.Highlight) {
		add(sp, "<mark>"+esc(buf.Slice(sp.Start+2, sp.End-2))+"</mark>")
	}
	for _, o := range doc.SpansIn(0, buf.Len()+1) {
		if o.Kind == markdown.WikiLink {
			label := buf.Slice(o.Start, o.End)
			o.Start, o.End = o.ElemStart, o.ElemEnd
			add(o, `<span class="wiki">`+esc(label)+`</span>`)
		}
	}
	slices.SortFunc(subs, func(x, y sub) int { return y.a - x.a })
	last := len(text) + 1
	for _, s := range subs {
		if s.z > last {
			continue
		}
		text = text[:s.a] + s.s + text[s.z:]
		last = s.a
	}
	// Front matter stays out of print.
	if strings.HasPrefix(text, "---\n") {
		if end := strings.Index(text[4:], "\n---"); end >= 0 {
			text = text[4+end+4:]
		}
	}
	md := goldmark.New(goldmark.WithExtensions(extension.GFM, extension.Footnote), goldmark.WithRendererOptions(gmhtml.WithUnsafe()))
	var body bytes.Buffer
	md.Convert([]byte(text), &body)
	th := theme.Resolve(w.a.s.Prefs().Theme, false, w.theme.Accent)
	if th.Dark {
		// Paper is white: a dark theme prints in the light System colors.
		th = theme.System(false, w.theme.Accent)
	}
	p := w.a.s.Prefs()
	font := "-apple-system, system-ui, sans-serif"
	if p.FontFamily != "" {
		font = "'" + p.FontFamily + "', " + font
	}
	_ = filepath.Dir
	css := `
body { font-family: ` + font + `; font-size: ` + itoa(int(p.FontSize)) + `px; line-height: ` + strings.TrimRight(strings.TrimRight(ftoa(p.LineHeight), "0"), ".") + `; color: ` + hexColor(th.Text) + `; margin: 0; padding: 0 4px; }
h1, h2, h3, h4, h5, h6 { color: ` + hexColor(th.Heading) + `; line-height: 1.25; break-after: avoid; }
a, .wiki { color: ` + hexColor(th.Link) + `; text-decoration: none; }
code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; color: ` + hexColor(th.CodeText) + `; background: rgba(0,0,0,.04); padding: 1px 4px; border-radius: 4px; }
pre { background: rgba(0,0,0,.04); padding: 12px 14px; border-radius: 8px; overflow: hidden; white-space: pre-wrap; break-inside: avoid; }
pre code { background: none; padding: 0; color: inherit; }
blockquote { margin: 0; padding: 0 0 0 16px; border-left: 3px solid rgba(0,0,0,.1); color: ` + hexColor(th.Secondary) + `; }
blockquote.callout { border: none; border-radius: 8px; padding: 8px 14px; color: inherit; }
blockquote.callout .title { font-weight: 600; }
table { border-collapse: collapse; break-inside: avoid; }
th, td { border: 1px solid rgba(0,0,0,.12); padding: 6px 12px; }
th { background: rgba(0,0,0,.04); }
mark { background: ` + hexColor(th.Highlight) + `; border-radius: 3px; padding: 0 2px; }
img { max-width: 100%; break-inside: avoid; }
hr { border: none; border-top: 1px solid rgba(0,0,0,.12); }
.math { text-align: center; margin: 1em 0; }
li input[type=checkbox] { margin: 0 6px 0 -20px; }
li:has(> input[type=checkbox]) { list-style: none; }
`
	callouts := `{"note":"` + hexColor(th.Callouts[0]) + `","tip":"` + hexColor(th.Callouts[1]) + `","important":"` + hexColor(th.Callouts[2]) + `","warning":"` + hexColor(th.Callouts[3]) + `","caution":"` + hexColor(th.Callouts[4]) + `"}`
	page := rendererPage()
	script := `<script>
window.printReady = (async () => {
  window.printStep = "math";
  const src = (el) => new TextDecoder().decode(Uint8Array.from(atob(el.dataset.src), c => c.charCodeAt(0)));
  for (const el of document.querySelectorAll(".math")) katex.render(src(el), el, {displayMode: true, throwOnError: false});
  for (const el of document.querySelectorAll(".imath")) katex.render(src(el), el, {throwOnError: false});
  const colors = ` + callouts + `;
  for (const q of document.querySelectorAll("blockquote")) {
    const p = q.querySelector("p");
    const m = p && p.innerHTML.match(/^\[!(\w+)\]\s*/);
    if (!m) continue;
    const kind = m[1].toLowerCase();
    const color = colors[kind] || colors.note;
    q.classList.add("callout");
    q.style.background = color + "1a";
    p.innerHTML = p.innerHTML.slice(m[0].length);
    const title = document.createElement("div");
    title.className = "title";
    title.style.color = color;
    const first = p.innerHTML.split("\n")[0];
    title.textContent = first.trim() || kind[0].toUpperCase() + kind.slice(1);
    p.innerHTML = p.innerHTML.split("\n").slice(first.trim() ? 1 : 0).join("\n");
    q.insertBefore(title, q.firstChild);
  }
  window.printStep = "mermaid";
  let n = 0;
  mermaid.initialize({ startOnLoad: false, securityLevel: "strict", ...mermaidTheme(false, "` + hexColor(th.Text) + `", "#ffffff", "` + hexColor(th.Accent) + `", 13) });
  for (const code of document.querySelectorAll("pre code.language-mermaid")) {
    try {
      const { svg } = await mermaid.render("print" + (n++), code.textContent);
      const div = document.createElement("div");
      div.innerHTML = svg;
      code.parentElement.replaceWith(div);
    } catch (e) {}
  }
  window.printStep = "fonts";
  await document.fonts.ready;
  window.printStep = "images";
  await Promise.all([...document.images].map(i => i.complete ? 0 : new Promise(r => { i.onload = i.onerror = r; })));
  return true;
})();
</script>`
	page = strings.Replace(page, `<div id="out"></div>`, `<style>`+css+`</style>`+body.String(), 1)
	return strings.Replace(page, "</body>", script+"</body>", 1)
}

func ftoa(f float64) string {
	s := []byte{}
	s = append(s, []byte(itoa(int(f)))...)
	frac := int((f-float64(int(f)))*100 + 0.5)
	s = append(s, '.')
	s = append(s, byte('0'+frac/10), byte('0'+frac%10))
	return string(s)
}

// withPrintable loads the note shown into a web view of the window and
// calls fn with its page once math, diagrams and images are drawn.
func (w *window) withPrintable(fn func(page *mygo.Page)) {
	ed := w.editor()
	if ed == nil || !ed.IsMarkdown() {
		return
	}
	html := w.printable(ed)
	wv, err := w.w.NewWebView(mygo.WebViewOptions{Transparent: true})
	if err != nil {
		return
	}
	w.renderer.printing = wv
	wv.Page().LoadHTML(html, "about:blank")
	go func() {
		for range 200 {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			v, err := wv.Page().EvalContext(ctx, "return window.printReady ? await window.printReady : false")
			cancel()
			if err == nil && v == true {
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
		fn(wv.Page())
		time.Sleep(time.Second)
		w.post(func() {
			wv.Destroy()
			if w.renderer.printing == wv {
				w.renderer.printing = nil
			}
		})
	}()
}

func (w *window) print() {
	w.withPrintable(func(p *mygo.Page) { p.Print() })
}

func (w *window) exportPDF() {
	t := w.tab()
	if t == nil || t.ed == nil {
		return
	}
	name := strings.TrimSuffix(filepath.Base(t.path), filepath.Ext(t.path)) + ".pdf"
	go func() {
		path, err := mygo.Dialog.Save(mygo.SaveDialogOptions{Parent: w.w, Title: "Export as PDF", DefaultPath: filepath.Join(filepath.Dir(t.path), name)})
		if err != nil || path == "" {
			return
		}
		w.post(func() { w.writePDF(path, nil) })
	}()
}

// writePDF writes the note shown as a PDF at path.
func (w *window) writePDF(path string, done func(error)) {
	w.withPrintable(func(p *mygo.Page) {
		pdf, err := p.PrintToPDF(mygo.PDFOptions{PageSize: mygo.PageA4, Background: true})
		if err == nil {
			err = os.WriteFile(path, pdf, 0o644)
		}
		if err != nil {
			go mygo.Dialog.Message(mygo.MessageOptions{Parent: w.w, Type: mygo.MessageWarning, Message: "The PDF can't be written.", Detail: err.Error()})
		}
		if done != nil {
			done(err)
		}
	})
}

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
