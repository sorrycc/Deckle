// Deckle is a fast, native Markdown editor: notes are plain .md files in a
// folder, styled as they are typed, drawn by MyGo's native UI.
package main

import (
	"log"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"

	"deckle/internal/settings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/updater/native"
)

// deckle is the app: its settings and its windows, one per workspace.
type deckle struct {
	s *settings.Settings
	// wins are the workspace windows, the one focused last first.
	wins    []*window
	welcome *welcomeWindow
	prefs   *prefsWindow
	ready   bool
	pending []string
	// quitting is set once quitting is agreed, so the windows closing as
	// the app goes stay among those to open again.
	quitting bool
}

var app = &deckle{}

func settingsPath() string {
	dir, err := mygo.App.Path(mygo.PathUserData)
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "settings.json")
}

func main() {
	mygo.App.SetName("Deckle")
	// DECKLE_DATA_DIR keeps the settings elsewhere, as scripts/dev.sh's
	// development copy does, so it leaves the everyday app's alone.
	if dir := os.Getenv("DECKLE_DATA_DIR"); dir != "" {
		mygo.App.SetPath(mygo.PathUserData, dir)
	}
	if os.Getenv("DECKLE_SNAPSHOT") == "" && !mygo.App.RequestSingleInstanceLock() {
		return
	}
	mygo.Use(native.Plugin)
	a := app
	mygo.App.OnSecondInstance(func(args []string, wd string) {
		if paths := argPaths(args, wd); len(paths) > 0 {
			a.open(paths)
		} else if len(a.wins) > 0 {
			a.wins[0].show()
		} else {
			a.showWelcome()
		}
	})
	mygo.App.OnOpenFile(func(path string) {
		if !a.ready {
			a.pending = append(a.pending, path)
			return
		}
		a.open([]string{path})
	})
	mygo.App.OnActivate(func(visible bool) {
		// A click on the Dock icon with no window up brings one back.
		if a.ready && !visible {
			if len(a.wins) > 0 {
				a.wins[0].show()
			} else {
				a.showWelcome()
			}
		}
	})
	mygo.App.OnBeforeQuit(func(e *mygo.QuitEvent) {
		if a.quitting {
			return
		}
		a.rememberOpen()
		for _, w := range a.wins {
			w.saveAll()
			w.saveSession()
		}
		a.quitting = true
	})
	mygo.App.OnQuit(func() {
		if a.s != nil {
			a.s.Flush()
		}
	})
	// Closing the last window leaves the app running, as Finder does: the
	// Dock icon or the Welcome window brings a workspace back.
	mygo.App.OnWindowAllClosed(func() {
		if runtime.GOOS != "darwin" && len(a.wins) == 0 && a.welcome == nil {
			mygo.App.Quit()
		}
	})
	mygo.App.WhenReady(func() {
		a.start()
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}

func (a *deckle) start() {
	path := settingsPath()
	fresh := !settings.Exists(path)
	a.s = settings.Load(path)
	// The first launch after Deckle's AppKit versions takes their settings,
	// workspaces and places.
	if fresh {
		if f, ok := settings.Legacy(); ok {
			a.s.Replace(f)
		}
	}
	a.s.OnChange(func() { mygo.RunOnMain(a.prefsChanged) })
	registerFonts(a.s.Prefs().CJKFontFamily)
	a.applyAppearance()
	a.ready = true
	wd, _ := os.Getwd()
	paths := append(a.pending, argPaths(os.Args[1:], wd)...)
	a.pending = nil
	a.launch(paths)
	a.setMenu()
	if out := os.Getenv("DECKLE_SNAPSHOT"); out != "" {
		a.snapshot(out)
	}
}

// snapshot pictures the front window once it settles, after running the
// commands DECKLE_SNAPSHOT_RUN names, and quits: for checking the real
// window from a script.
func (a *deckle) snapshot(out string) {
	go func() {
		time.Sleep(1500 * time.Millisecond)
		for _, id := range strings.Fields(os.Getenv("DECKLE_SNAPSHOT_RUN")) {
			if len(a.wins) > 0 {
				w := a.wins[0]
				w.post(func() { w.run(id) })
			}
			time.Sleep(700 * time.Millisecond)
		}
		if pdf := os.Getenv("DECKLE_EXPORT_PDF"); pdf != "" && len(a.wins) > 0 {
			w := a.wins[0]
			done := make(chan struct{})
			w.post(func() { w.writePDF(pdf, func(error) { close(done) }) })
			select {
			case <-done:
			case <-time.After(30 * time.Second):
			}
		}
		time.Sleep(1500 * time.Millisecond)
		var win *mygo.Window
		switch {
		case a.prefs != nil:
			win = a.prefs.w
		case len(a.wins) > 0:
			win = a.wins[0].w
		case a.welcome != nil:
			win = a.welcome.w
		}
		if win != nil {
			if png, err := win.CapturePage(); err == nil {
				os.WriteFile(out, png, 0o644)
			}
		}
		mygo.App.Quit()
	}()
}

// argPaths are the folders and files of a command line, absolute.
func argPaths(args []string, wd string) []string {
	var paths []string
	for _, arg := range args {
		if arg == "" || strings.HasPrefix(arg, "-") {
			continue
		}
		if !filepath.IsAbs(arg) {
			arg = filepath.Join(wd, arg)
		}
		paths = append(paths, arg)
	}
	return paths
}

// launch opens the windows the app starts with: the folders it was given,
// or else every window open at the last quit, the front one last; with
// none, the Welcome window.
func (a *deckle) launch(paths []string) {
	folders, files := splitPaths(paths)
	if ws := os.Getenv("DECKLE_WORKSPACE"); ws != "" {
		folders = append(folders, ws)
	}
	if len(folders) == 0 {
		var open []string
		a.s.Read(func(st *settings.State) { open = slices.Clone(st.OpenWorkspaces) })
		for _, dir := range open {
			if st, err := os.Stat(dir); err == nil && st.IsDir() {
				a.openWorkspace(dir, true)
			}
		}
	}
	for _, dir := range folders {
		a.openWorkspace(dir, true)
	}
	for _, f := range files {
		a.openFile(f)
	}
	if len(a.wins) == 0 {
		a.showWelcome()
	}
}

// open opens folders and files the app is asked to while it runs.
func (a *deckle) open(paths []string) {
	folders, files := splitPaths(paths)
	for _, dir := range folders {
		a.openWorkspace(dir, true)
	}
	for _, f := range files {
		a.openFile(f)
	}
}

func splitPaths(paths []string) (folders, files []string) {
	for _, p := range paths {
		info, err := os.Stat(p)
		p = filepath.Clean(p)
		switch {
		case err != nil:
		case info.IsDir():
			if !slices.Contains(folders, p) {
				folders = append(folders, p)
			}
		case info.Mode().IsRegular():
			files = append(files, p)
		}
	}
	return
}

func realPath(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

// windowOf is the window of the workspace at dir.
func (a *deckle) windowOf(dir string) *window {
	r := realPath(dir)
	for _, w := range a.wins {
		if w.root == dir || realPath(w.root) == r {
			return w
		}
	}
	return nil
}

// openWorkspace brings the window of the workspace at dir forward, or
// opens one for it.
func (a *deckle) openWorkspace(dir string, remember bool) *window {
	dir = filepath.Clean(dir)
	if w := a.windowOf(dir); w != nil {
		w.show()
		return w
	}
	w := newWindow(a, dir, remember)
	a.wins = slices.Insert(a.wins, 0, w)
	if remember {
		a.s.Opened(dir)
	}
	a.rememberOpen()
	if a.welcome != nil {
		a.welcome.close()
	}
	a.setMenu()
	return w
}

// openFile opens a file in a new tab of the window whose workspace holds
// it, or else of the front one; with no window, the file's folder opens,
// not remembered.
func (a *deckle) openFile(path string) {
	var target *window
	deepest := ""
	for _, w := range a.wins {
		root := realPath(w.root)
		if strings.HasPrefix(realPath(path), root+string(filepath.Separator)) && len(root) > len(deepest) {
			target, deepest = w, root
		}
	}
	if target == nil && len(a.wins) > 0 {
		target = a.wins[0]
	}
	if target == nil {
		var last string
		a.s.Read(func(st *settings.State) { last = st.LastWorkspace })
		if st, err := os.Stat(last); last != "" && err == nil && st.IsDir() {
			target = a.openWorkspace(last, true)
		} else {
			target = a.openWorkspace(filepath.Dir(path), false)
		}
	}
	w := target
	w.do(func() { w.open(path, openOptions{newTab: true, focus: true}) })
	w.show()
}

// closed takes a window that closed.
func (a *deckle) closed(w *window) {
	a.wins = slices.DeleteFunc(a.wins, func(o *window) bool { return o == w })
	if !a.quitting {
		a.rememberOpen()
		if len(a.wins) == 0 {
			a.showWelcome()
		}
	}
	a.setMenu()
}

// rememberOpen records the windows open, the front one last, to open again
// at launch.
func (a *deckle) rememberOpen() {
	var open []string
	for _, w := range slices.Backward(a.wins) {
		if w.remember {
			open = append(open, w.root)
		}
	}
	a.s.Update(func(st *settings.State) { st.OpenWorkspaces = open })
}

// focused is the window in front.
func (a *deckle) focused(w *window) {
	if i := slices.Index(a.wins, w); i > 0 {
		a.wins = slices.Insert(slices.Delete(a.wins, i, i+1), 0, w)
		a.rememberOpen()
		a.setMenu()
	}
}

// chooseWorkspace asks for a folder to open as a workspace; from a
// window's switcher, it replaces that window's.
func (a *deckle) chooseWorkspace(parent *mygo.Window, replace *window) {
	go func() {
		paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{
			Parent: parent, Title: "Open", ButtonLabel: "Open", Directory: true, CreateDirectories: true,
		})
		if err != nil || len(paths) == 0 {
			return
		}
		mygo.RunOnMain(func() {
			if replace != nil {
				a.switchWorkspace(replace, paths[0])
			} else {
				a.open(paths)
			}
		})
	}()
}

// switchWorkspace shows another workspace in w's place; one open in a
// window of its own comes forward instead.
func (a *deckle) switchWorkspace(w *window, dir string) {
	if o := a.windowOf(dir); o != nil {
		o.show()
		return
	}
	x, y := w.w.Position()
	wd, ht := w.w.Size()
	n := newWindowAt(a, dir, true, x, y, wd, ht)
	a.wins = slices.Insert(a.wins, 0, n)
	a.s.Opened(dir)
	w.closeQuietly()
}

func (a *deckle) prefsChanged() {
	systemChinese = ""
	registerFonts(a.s.Prefs().CJKFontFamily)
	a.applyAppearance()
	for _, w := range a.wins {
		w.invalidate()
	}
	if a.welcome != nil {
		a.welcome.w.Invalidate()
	}
	if a.prefs != nil {
		a.prefs.w.Invalidate()
	}
}

// applyAppearance gives a theme's own appearance to the whole app.
func (a *deckle) applyAppearance() {
	id := a.s.Prefs().Theme
	src := mygo.ThemeSystem
	for _, p := range themePalettes() {
		if p.ID == id {
			if p.Dark {
				src = mygo.ThemeDark
			} else {
				src = mygo.ThemeLight
			}
		}
	}
	mygo.Theme.SetSource(src)
}
