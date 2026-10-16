package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"deckle/internal/editor"
	"deckle/internal/markdown"
	"deckle/internal/settings"
	"deckle/internal/theme"
	"deckle/internal/workspace"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

// window is the window of one workspace: the file tree, the note list, and
// the tabs with their editors.
type window struct {
	a        *deckle
	w        *mygo.Window
	root     string
	name     string
	remember bool
	ws       *workspace.Workspace
	tabs     []*tab
	sel      int
	// closedTabs come back with ⇧⌘T, newest last.
	closedTabs []closedTab
	tree       *tree
	list       *noteList
	palette    *palette
	renderer   *renderer
	look       editor.Look
	theme      theme.Theme
	state      settings.Workspace
	// Posts run before the next frame, on the main thread.
	mu    sync.Mutex
	queue []func()
	// The status bar's counts, worked out a moment after typing stops.
	words        int
	backlinks    int
	countPending bool
	// positionPending saves the places of notes a moment after they move.
	positionPending bool
	saveFailed      map[string]bool
	focusEditor     bool
	closing         bool
	outlineHover    bool
}

// tab is a tab of a window: a note, another file, or nothing yet, with the
// files it showed before and after, for Back and Forward.
type tab struct {
	path     string
	ed       *editor.Editor
	image    ui.ImageSource
	imgW     float32
	imgH     float32
	zoom     float32
	back     []place
	forward  []place
	restore  *settings.Position
	readOnly bool
	// latin1 says the file wasn't UTF-8 and is written back as it was read.
	latin1  bool
	modTime time.Time
	saveAt  time.Time
	loadErr string
	scroll  float64
}

type place struct {
	path string
	sel  [2]int
}

type closedTab struct {
	path  string
	sel   [2]int
	index int
}

type openOptions struct {
	newTab bool
	focus  bool
	sel    *[2]int
	// keepHistory leaves Back and Forward as they are, as they themselves
	// do.
	keepHistory bool
}

func newWindow(a *deckle, dir string, remember bool) *window {
	return newWindowAt(a, dir, remember, 0, 0, 1240, 800)
}

func newWindowAt(a *deckle, dir string, remember bool, x, y, width, height int) *window {
	w := &window{a: a, root: dir, name: filepath.Base(dir), remember: remember, saveFailed: map[string]bool{}}
	w.state = a.s.Workspace(dir)
	if w.state.SidebarWidth == 0 {
		w.state.SidebarWidth = 220
	}
	if w.state.ListWidth == 0 {
		w.state.ListWidth = 300
	}
	w.ws = workspace.Open(dir, func(e workspace.Event) { w.post(func() { w.workspaceEvent(e) }) })
	w.tree = newTree(w)
	w.list = newNoteList(w)
	w.palette = &palette{w: w}
	w.renderer = newRenderer(w)
	if len(a.wins) > 0 && x == 0 && y == 0 {
		x, y = a.wins[0].w.Position()
		x, y = x+28, y+28
	}
	opts := mygo.WindowOptions{
		Title: w.name, Width: width, Height: height, MinWidth: 640, MinHeight: 400,
		X: x, Y: y,
		TitleBarStyle:        mygo.TitleBarHidden,
		TrafficLightPosition: &mygo.Point{X: 20, Y: 20},
		BackgroundColor:      "light-dark(#ffffff, #1e1e1e)",
		Content:              ui.View(w.view),
	}
	if len(a.wins) == 0 && x == 0 {
		opts.StateKey = "workspace"
	}
	w.w = mygo.NewWindow(opts)
	w.restoreSession()
	w.w.OnFocus(func() {
		a.focused(w)
		// Back from another app, which may have changed the notes.
		w.post(w.checkDisk)
	})
	w.w.OnBlur(func() { w.post(w.saveAll) })
	w.w.OnFileDrop(func(e *mygo.FileDropEvent) {
		paths := e.Paths
		w.post(func() {
			if t := w.tab(); t != nil && t.ed != nil && t.ed.IsMarkdown() {
				a, z := t.ed.Selection()
				t.ed.InsertFiles(paths, a, z)
				return
			}
			for _, p := range paths {
				w.open(p, openOptions{newTab: true, focus: true})
			}
		})
	})
	w.w.OnClosed(func() {
		w.saveAll()
		w.saveSession()
		w.ws.Close()
		a.closed(w)
	})
	return w
}

// post runs fn on the main thread before the next frame.
func (w *window) post(fn func()) {
	w.mu.Lock()
	w.queue = append(w.queue, fn)
	w.mu.Unlock()
	if w.w != nil {
		w.w.Invalidate()
	}
}

// do runs fn as post does; for code off the window.
func (w *window) do(fn func()) { w.post(fn) }

func (w *window) runQueue() {
	for {
		w.mu.Lock()
		q := w.queue
		w.queue = nil
		w.mu.Unlock()
		if len(q) == 0 {
			return
		}
		for _, f := range q {
			f()
		}
	}
}

func (w *window) invalidate() {
	if w.w != nil {
		w.w.Invalidate()
	}
}

func (w *window) show() {
	w.w.Show()
	w.w.Focus()
}

// closeQuietly closes the window without remembering it as closed by
// hand, as replacing its workspace does.
func (w *window) closeQuietly() {
	w.remember = false
	w.w.Close()
}

func (w *window) tab() *tab {
	if w.sel >= 0 && w.sel < len(w.tabs) {
		return w.tabs[w.sel]
	}
	return nil
}

// editor is the editor of the tab shown, or nil.
func (w *window) editor() *editor.Editor {
	if t := w.tab(); t != nil {
		return t.ed
	}
	return nil
}

// restoreSession opens the tabs the workspace had, each read when first
// shown.
func (w *window) restoreSession() {
	for _, p := range w.state.Tabs {
		if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() {
			t := &tab{path: p}
			if pos, ok := w.state.Positions[p]; ok {
				pos := pos
				t.restore = &pos
			}
			w.tabs = append(w.tabs, t)
		}
	}
	if len(w.tabs) == 0 {
		w.tabs = append(w.tabs, &tab{})
	}
	if w.state.Folder != "" {
		if st, err := os.Stat(w.state.Folder); err == nil && st.IsDir() {
			w.list.folder = w.state.Folder
		}
	}
	w.sel = min(max(0, w.state.Selected), len(w.tabs)-1)
	w.load(w.tab())
	w.focusEditor = true
}

// saveSession remembers the tabs and where each note was left.
func (w *window) saveSession() {
	st := w.state
	st.Tabs = nil
	if st.Positions == nil {
		st.Positions = map[string]settings.Position{}
	}
	for _, t := range w.tabs {
		if t.path == "" || t.readOnly {
			continue
		}
		st.Tabs = append(st.Tabs, t.path)
		if t.ed != nil {
			a, z := t.ed.Selection()
			st.Positions[t.path] = settings.Position{Location: a, Length: z - a, Scroll: t.ed.ScrollFraction()}
		}
	}
	// Places of notes long closed don't pile up.
	if len(st.Positions) > 400 {
		for p := range st.Positions {
			if !slices.Contains(st.Tabs, p) {
				delete(st.Positions, p)
			}
			if len(st.Positions) <= 300 {
				break
			}
		}
	}
	st.Selected = w.sel
	st.Folder = w.list.folder
	st.Expanded = w.tree.expandedPaths()
	w.state = st
	w.a.s.SetWorkspace(w.root, st)
}

func (w *window) savePositionLater() {
	if w.positionPending {
		return
	}
	w.positionPending = true
	time.AfterFunc(2*time.Second, func() {
		w.post(func() {
			w.positionPending = false
			w.saveSession()
		})
	})
}

// readFile reads a file as text: UTF-8, or Latin-1 for one that isn't.
func readFile(path string) (string, bool, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", false, err
	}
	if utf8.Valid(b) {
		return strings.TrimPrefix(string(b), "\xef\xbb\xbf"), false, nil
	}
	r := make([]rune, len(b))
	for i, c := range b {
		r[i] = rune(c)
	}
	return string(r), true, nil
}

func writeFile(path, text string, latin1 bool) error {
	b := []byte(text)
	if latin1 {
		b = b[:0]
		for _, r := range text {
			if r > 255 {
				r = '?'
			}
			b = append(b, byte(r))
		}
	}
	// To a file beside it first, so a failure leaves the note whole.
	tmp := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".deckle")
	mode := os.FileMode(0o644)
	if st, err := os.Stat(path); err == nil {
		mode = st.Mode().Perm()
	}
	if err := os.WriteFile(tmp, b, mode); err != nil {
		os.Remove(tmp)
		// A folder that takes no new files may still take the file itself.
		return os.WriteFile(path, b, mode)
	}
	return os.Rename(tmp, path)
}

// load reads the file of a tab, if it isn't yet.
func (w *window) load(t *tab) {
	if t == nil || t.path == "" || t.ed != nil || t.image != nil {
		return
	}
	if editor.IsImage(t.path) {
		w.loadImage(t)
		return
	}
	text, latin1, err := readFile(t.path)
	if err != nil {
		t.loadErr = err.Error()
		return
	}
	t.loadErr = ""
	t.latin1 = latin1
	if st, err := os.Stat(t.path); err == nil {
		t.modTime = st.ModTime()
	}
	lang := markdown.LanguageForExtension(strings.TrimPrefix(filepath.Ext(t.path), "."))
	ed := editor.New(text, lang, t.path)
	ed.ReadOnly = t.readOnly
	ed.SetRenderer(w.renderer)
	ed.Post = func(f func()) { w.post(f) }
	ed.Hooks = editor.Hooks{
		Changed:   func() { w.edited(t) },
		Selected:  func() { w.savePositionLater() },
		Follow:    func(l editor.Link, newTab bool) { w.follow(t, l, newTab) },
		NoteNames: w.noteNames,
		SaveImage: func(data []byte, ext string) (string, error) { return w.saveImage(t, data, ext) },
		LinkFile:  func(p string) string { return relativePath(filepath.Dir(t.path), p) },
	}
	if r := t.restore; r != nil {
		ed.SetSelection(r.Location, r.Location+r.Length)
		ed.SetScrollFraction(r.Scroll)
		t.restore = nil
	}
	t.ed = ed
}

// edited takes an edit: the file saves a moment after typing stops.
func (w *window) edited(t *tab) {
	t.saveAt = time.Now().Add(600 * time.Millisecond)
	time.AfterFunc(650*time.Millisecond, func() {
		w.post(func() {
			if !t.saveAt.IsZero() && time.Now().After(t.saveAt) {
				w.save(t)
			}
		})
	})
	w.countLater()
}

// save writes a tab's note if it changed. A note that can't be saved says
// so once, and keeps trying.
func (w *window) save(t *tab) bool {
	t.saveAt = time.Time{}
	if t.ed == nil || t.readOnly || !t.ed.Modified() {
		return true
	}
	if err := writeFile(t.path, t.ed.Text(), t.latin1); err != nil {
		if !w.saveFailed[t.path] {
			w.saveFailed[t.path] = true
			path := t.path
			go mygo.Dialog.Message(mygo.MessageOptions{Parent: w.w, Type: mygo.MessageWarning,
				Message: "“" + filepath.Base(path) + "” can't be saved.", Detail: err.Error() + "\n\nDeckle keeps trying while the note is open."})
		}
		return false
	}
	delete(w.saveFailed, t.path)
	t.ed.MarkSaved()
	if st, err := os.Stat(t.path); err == nil {
		t.modTime = st.ModTime()
	}
	w.ws.Touch(t.path)
	return true
}

func (w *window) saveAll() {
	for _, t := range w.tabs {
		w.save(t)
	}
}

// checkDisk takes in what another app changed in the open notes.
func (w *window) checkDisk() {
	for _, t := range w.tabs {
		if t.ed != nil {
			w.reload(t)
		}
	}
}

// reload takes in a change another app made to a tab's file, unless the
// tab has edits of its own, which are written over it at the next save.
func (w *window) reload(t *tab) {
	st, err := os.Stat(t.path)
	if err != nil || st.ModTime().Equal(t.modTime) || t.ed.Modified() {
		return
	}
	text, latin1, err := readFile(t.path)
	if err != nil {
		return
	}
	t.modTime = st.ModTime()
	if text != t.ed.Text() {
		t.latin1 = latin1
		t.ed.SetText(text)
		w.countLater()
	}
}

func (w *window) workspaceEvent(e workspace.Event) {
	switch e.Kind {
	case workspace.EventIndex:
		w.list.stale = true
		w.palette.stale()
		w.countLater()
	case workspace.EventFolder:
		w.tree.folderChanged(e.Path)
	case workspace.EventFile:
		for _, t := range w.tabs {
			if t.ed != nil && realPath(t.path) == realPath(e.Path) {
				w.reload(t)
			}
		}
	}
}

// open shows a file: in the current tab, or a new one, or the tab that
// has it already when that is asked for.
func (w *window) open(path string, o openOptions) {
	path = filepath.Clean(path)
	cur := w.tab()
	switch {
	case o.newTab || cur == nil:
		// A tab showing the file already comes forward.
		for i, t := range w.tabs {
			if t.path == path {
				w.selectTab(i)
				w.applyOpen(t, o)
				return
			}
		}
		t := &tab{path: path}
		if cur != nil && cur.path == "" {
			w.tabs[w.sel] = t
		} else {
			w.tabs = slices.Insert(w.tabs, min(w.sel+1, len(w.tabs)), t)
			w.sel = min(w.sel+1, len(w.tabs)-1)
		}
		w.load(t)
		w.applyOpen(t, o)
	case cur.path == path:
		w.applyOpen(cur, o)
	default:
		w.save(cur)
		if !o.keepHistory && cur.path != "" {
			cur.back = append(cur.back, w.placeOf(cur))
			cur.forward = nil
		}
		cur.path, cur.ed, cur.image, cur.loadErr = path, nil, nil, ""
		if pos, ok := w.state.Positions[path]; ok && o.sel == nil {
			pos := pos
			cur.restore = &pos
		}
		w.load(cur)
		w.applyOpen(cur, o)
	}
	w.tabChanged(o.focus)
}

func (w *window) applyOpen(t *tab, o openOptions) {
	if o.sel != nil && t.ed != nil {
		t.ed.SetSelection(o.sel[0], o.sel[1])
		t.ed.RevealCentered()
	}
	if o.focus {
		w.focusEditor = true
	}
}

func (w *window) placeOf(t *tab) place {
	p := place{path: t.path}
	if t.ed != nil {
		a, z := t.ed.Selection()
		p.sel = [2]int{a, z}
	}
	return p
}

// tabChanged takes another note shown: the list marks it, the session
// remembers it, the status bar counts it.
func (w *window) tabChanged(focus bool) {
	t := w.tab()
	title := w.name
	if t != nil && t.path != "" {
		title = filepath.Base(t.path) + " — " + w.name
	}
	w.w.SetTitle(title)
	if focus {
		w.focusEditor = true
	}
	w.list.reveal = true
	w.countLater()
	w.saveSession()
}

func (w *window) selectTab(i int) {
	if i < 0 || i >= len(w.tabs) || i == w.sel {
		return
	}
	if cur := w.tab(); cur != nil {
		w.save(cur)
	}
	w.sel = i
	w.load(w.tab())
	w.tabChanged(true)
}

func (w *window) newTab() {
	w.tabs = slices.Insert(w.tabs, min(w.sel+1, len(w.tabs)), &tab{})
	w.sel = min(w.sel+1, len(w.tabs)-1)
	w.tabChanged(false)
}

func (w *window) closeTab(i int) {
	if i < 0 || i >= len(w.tabs) {
		return
	}
	t := w.tabs[i]
	w.save(t)
	if t.path != "" {
		w.closedTabs = append(w.closedTabs, closedTab{t.path, w.placeOf(t).sel, i})
		if len(w.closedTabs) > 20 {
			w.closedTabs = w.closedTabs[1:]
		}
	}
	if len(w.tabs) == 1 {
		if t.path == "" {
			w.w.Close()
			return
		}
		w.tabs[0] = &tab{}
		w.tabChanged(false)
		return
	}
	w.tabs = slices.Delete(w.tabs, i, i+1)
	if w.sel >= i && w.sel > 0 {
		w.sel--
	}
	w.load(w.tab())
	w.tabChanged(true)
}

func (w *window) reopenClosedTab() {
	if len(w.closedTabs) == 0 {
		return
	}
	c := w.closedTabs[len(w.closedTabs)-1]
	w.closedTabs = w.closedTabs[:len(w.closedTabs)-1]
	if _, err := os.Stat(c.path); err != nil {
		return
	}
	sel := c.sel
	w.open(c.path, openOptions{newTab: true, focus: true, sel: &sel})
}

func (w *window) goBack(forward bool) {
	t := w.tab()
	if t == nil {
		return
	}
	from, to := &t.back, &t.forward
	if forward {
		from, to = to, from
	}
	if len(*from) == 0 {
		return
	}
	p := (*from)[len(*from)-1]
	*from = (*from)[:len(*from)-1]
	*to = append(*to, w.placeOf(t))
	sel := p.sel
	w.open(p.path, openOptions{focus: true, sel: &sel, keepHistory: true})
}

func (w *window) countLater() {
	if w.countPending {
		return
	}
	w.countPending = true
	time.AfterFunc(300*time.Millisecond, func() {
		w.post(func() {
			w.countPending = false
			if ed := w.editor(); ed != nil {
				w.words = ed.WordCount()
			} else {
				w.words = 0
			}
			if t := w.tab(); t != nil && t.path != "" && workspace.IsMarkdown(t.path) {
				w.backlinks = w.ws.BacklinkCount(t.path)
			} else {
				w.backlinks = 0
			}
		})
	})
}

// noteNames lists the notes matching query, for completing [[.
func (w *window) noteNames(query string) []string {
	var out []string
	for _, m := range w.ws.FindFiles(query, 20, true) {
		out = append(out, m.Path)
	}
	return out
}

// saveImage stores a pasted image in the assets folder beside the note.
func (w *window) saveImage(t *tab, data []byte, ext string) (string, error) {
	dir := filepath.Join(filepath.Dir(t.path), "assets")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	stamp := time.Now().Format("2006-01-02 150405")
	target := freeName(dir, "Pasted "+stamp, ext)
	if err := os.WriteFile(target, data, 0o644); err != nil {
		return "", err
	}
	return relativePath(filepath.Dir(t.path), target), nil
}

// freeName is a path in dir for a file named name.ext that is not taken.
func freeName(dir, name, ext string) string {
	if ext != "" {
		ext = "." + ext
	}
	p := filepath.Join(dir, name+ext)
	for i := 2; ; i++ {
		if _, err := os.Lstat(p); os.IsNotExist(err) {
			return p
		}
		p = filepath.Join(dir, name+" "+itoa(i)+ext)
	}
}

func relativePath(from, to string) string {
	r, err := filepath.Rel(from, to)
	if err != nil {
		return to
	}
	return filepath.ToSlash(r)
}

// follow takes a link the user followed in an editor.
func (w *window) follow(t *tab, l editor.Link, newTab bool) {
	switch {
	case l.Footnote != "":
		t.ed.JumpToFootnote(l.Footnote)
	case l.Wiki != "":
		if p := w.ws.ResolveLink(l.Wiki, t.path); p != "" {
			w.open(p, openOptions{newTab: newTab, focus: true})
			return
		}
		// A link to a note that doesn't exist yet makes it.
		name := strings.TrimSpace(strings.SplitN(l.Wiki, "#", 2)[0])
		if name == "" {
			return
		}
		p := freeName(filepath.Dir(t.path), strings.ReplaceAll(name, "/", "-"), "md")
		if os.WriteFile(p, []byte("# "+name+"\n\n"), 0o644) == nil {
			w.ws.Touch(p)
			w.open(p, openOptions{newTab: newTab, focus: true})
		}
	case strings.HasPrefix(l.URL, "#"):
		slug := strings.ToLower(l.URL[1:])
		for _, h := range t.ed.Headings() {
			if headingSlug(h.Title) == slug {
				t.ed.SetSelection(h.At, h.At)
				t.ed.RevealCentered()
				return
			}
		}
	case strings.Contains(l.URL, "://") || strings.HasPrefix(l.URL, "mailto:"):
		mygo.Shell.OpenExternal(l.URL)
	default:
		p := strings.SplitN(l.URL, "#", 2)[0]
		if d, err := urlUnescape(p); err == nil {
			p = d
		}
		if !filepath.IsAbs(p) {
			p = filepath.Join(filepath.Dir(t.path), p)
		}
		if _, err := os.Stat(p); err == nil {
			w.open(p, openOptions{newTab: newTab, focus: true})
		}
	}
}

// headingSlug is a heading as a link's fragment names it.
func headingSlug(title string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(title) {
		switch {
		case r == ' ':
			b.WriteByte('-')
		case r == '-' || r == '_' || isLetterOrDigit(r):
			b.WriteRune(r)
		}
	}
	return b.String()
}

// themePalettes lists the themes with an appearance of their own.
func themePalettes() []theme.Theme { return theme.Palettes }
