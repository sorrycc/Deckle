package main

import (
	"fmt"
	"image/png"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"deckle/internal/settings"
	"deckle/internal/workspace"

	"github.com/egoist/mygo/ui"
)

// testWindow is a window of the workspace at dir with no window of the
// system's, for running its view in a tester.
func testWindow(t testing.TB, dir string) *window {
	t.Helper()
	// The system's languages need the app's main loop, which tests lack.
	systemChinese = "zh-Hans"
	a := &deckle{s: settings.Load(filepath.Join(t.TempDir(), "settings.json"))}
	w := &window{a: a, root: dir, name: filepath.Base(dir), saveFailed: map[string]bool{}}
	w.state = a.s.Workspace(dir)
	w.state.SidebarWidth, w.state.ListWidth = 220, 300
	w.ws = workspace.Open(dir, func(e workspace.Event) { w.post(func() { w.workspaceEvent(e) }) })
	t.Cleanup(w.ws.Close)
	w.tree = newTree(w)
	w.list = newNoteList(w)
	w.palette = &palette{w: w}
	w.renderer = newRenderer(w)
	w.tabs = []*tab{{}}
	return w
}

// bigWorkspace writes a workspace of folders of notes.
func bigWorkspace(t testing.TB, folders, notes int) string {
	t.Helper()
	dir := t.TempDir()
	body := strings.Repeat("Some words of a paragraph, with a [[link]] and **bold** text. ", 20)
	for f := range folders {
		sub := filepath.Join(dir, fmt.Sprintf("Folder %d", f))
		os.MkdirAll(sub, 0o755)
		for n := range notes {
			os.WriteFile(filepath.Join(sub, fmt.Sprintf("Note %d.md", n)), []byte(fmt.Sprintf("# Note %d of %d\n\n%s\n", n, f, body)), 0o644)
		}
	}
	return dir
}

func waitIndexed(w *window) {
	for range 200 {
		if len(w.ws.ListNotes(w.root, false)) >= 4000 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestFlatFolderFrameTime prints how long a frame takes with 3,000 notes
// in the workspace's own folder, every one a row of the tree.
func TestFlatFolderFrameTime(t *testing.T) {
	dir := t.TempDir()
	for n := range 3000 {
		os.WriteFile(filepath.Join(dir, fmt.Sprintf("Note %d.md", n)), []byte(fmt.Sprintf("# Note %d\n\nText.\n", n)), 0o644)
	}
	w := testWindow(t, dir)
	tt := ui.NewTester(w.view, 1240, 800)
	for range 5 {
		tt.Frame()
	}
	var times []time.Duration
	for range 30 {
		start := time.Now()
		tt.Frame()
		times = append(times, time.Since(start))
	}
	sort.Slice(times, func(i, j int) bool { return times[i] < times[j] })
	t.Logf("3,000 notes in one folder: median %v per frame", times[len(times)/2])
}

// TestTreeChoosesFolders checks that a folder's row lists its notes, and a
// click on no row lists every note again.
func TestTreeChoosesFolders(t *testing.T) {
	dir := bigWorkspace(t, 3, 2)
	w := testWindow(t, dir)
	tt := ui.NewTester(w.view, 1240, 800)
	tt.Frame()
	if err := tt.Click("Folder 1"); err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, "Folder 1"); w.list.folder != want {
		t.Fatalf("list shows %q, want %q", w.list.folder, want)
	}
	tt.ClickAt(100, 600)
	if w.list.folder != "" {
		t.Fatalf("list shows %q after a click on no row", w.list.folder)
	}
}

// TestWindowFrameTime prints how long a frame of the whole window takes,
// drawn on the CPU, with a workspace of 4,000 notes and a note open.
func TestWindowFrameTime(t *testing.T) {
	dir := bigWorkspace(t, 40, 100)
	w := testWindow(t, dir)
	waitIndexed(w)
	w.open(filepath.Join(dir, "Folder 3", "Note 7.md"), openOptions{})
	tt := ui.NewTester(w.view, 1240, 800)
	for range 5 {
		tt.Frame()
	}
	var times []time.Duration
	for range 60 {
		start := time.Now()
		w.invalidate()
		tt.Frame()
		times = append(times, time.Since(start))
	}
	sort.Slice(times, func(i, j int) bool { return times[i] < times[j] })
	t.Logf("4,000 notes: median %v, p95 %v per frame", times[len(times)/2], times[len(times)*95/100])
	if out := os.Getenv("DECKLE_TEST_SHOT"); out != "" {
		f, _ := os.Create(out)
		png.Encode(f, tt.Image())
		f.Close()
	}
}
