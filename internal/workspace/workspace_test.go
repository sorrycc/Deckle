package workspace

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func waitFor(t *testing.T, done func() bool) {
	t.Helper()
	for range 300 {
		if done() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out")
}

func TestIndexesListsAndLinks(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "Plan.md"), "---\ntitle: The Plan\n---\n# Ignored\n\nSee [[Notes/Ideas]] and ![p](img.png).\n")
	write(t, filepath.Join(root, "img.png"), "x")
	write(t, filepath.Join(root, "Notes", "Ideas.md"), "# Ideas\n\n- [ ] first **idea** links [[Plan|the plan]]\n| a | b |\n|---|---|\n| c | d |\n")
	write(t, filepath.Join(root, ".hidden", "x.md"), "# Hidden\n")
	write(t, filepath.Join(root, "node_modules", "y.md"), "# Module\n")
	ws := Open(root, nil)
	defer ws.Close()
	waitFor(t, func() bool {
		_, ok := ws.Note(filepath.Join(ws.Root(), "Notes", "Ideas.md"))
		return ok && len(ws.ListNotes(ws.Root(), true)) == 2
	})
	root = ws.Root()

	notes := ws.ListNotes(root, true)
	if len(notes) != 2 || filepath.Base(notes[0]) != "Ideas.md" || filepath.Base(notes[1]) != "Plan.md" {
		t.Fatalf("notes %v", notes)
	}
	plan, _ := ws.Note(filepath.Join(root, "Plan.md"))
	if plan.Title != "The Plan" || plan.Image != filepath.Join(root, "img.png") {
		t.Errorf("plan %+v", plan)
	}
	ideas, _ := ws.Note(filepath.Join(root, "Notes", "Ideas.md"))
	if ideas.Title != "Ideas" || !strings.HasPrefix(ideas.Excerpt, "first idea links the plan a · b c · d") {
		t.Errorf("ideas %+v", ideas)
	}
	if got := ws.ResolveLink("Notes/Ideas", filepath.Join(root, "Plan.md")); got != filepath.Join(root, "Notes", "Ideas.md") {
		t.Errorf("resolve %q", got)
	}
	if got := ws.ResolveLink("Plan", filepath.Join(root, "Notes", "Ideas.md")); got != filepath.Join(root, "Plan.md") {
		t.Errorf("resolve by name %q", got)
	}
	if n := ws.BacklinkCount(filepath.Join(root, "Plan.md")); n != 1 {
		t.Errorf("backlinks %d", n)
	}
	bl := ws.Backlinks(filepath.Join(root, "Plan.md"))
	if len(bl) != 1 || len(bl[0].Lines) != 1 || bl[0].Lines[0].Text != "first idea links the plan" {
		t.Errorf("backlinks %+v", bl)
	}
	found := ws.FindFiles("ide", 10, false)
	if len(found) == 0 || filepath.Base(found[0].Path) != "Ideas.md" {
		t.Errorf("find %+v", found)
	}
	done := make(chan SearchResult, 1)
	ws.Search("IDEA", 1, func(r SearchResult) { done <- r })
	if r := <-done; r.Total != 0 {
		t.Errorf("case-sensitive search %+v", r)
	}
	ws.Search("idea", 2, func(r SearchResult) { done <- r })
	r := <-done
	if r.Total != 2 {
		t.Fatalf("search %+v", r)
	}

	// The watcher takes in a new note.
	write(t, filepath.Join(root, "New.md"), "# Brand new\n")
	waitFor(t, func() bool { return len(ws.ListNotes(root, false)) == 3 })
	os.Remove(filepath.Join(root, "Plan.md"))
	waitFor(t, func() bool { return len(ws.ListNotes(root, false)) == 2 })
}

func TestPreviewsReadPlainlyAroundTheMatch(t *testing.T) {
	line := "- [ ] the section about **friction** needs [[Project Plan|a pass]]."
	at := strings.Index(line, "friction")
	text, col := plainPreview(line, at, len("friction"))
	if text != "the section about friction needs a pass." || text[col:col+8] != "friction" {
		t.Errorf("%q %d", text, col)
	}
	if text, col := plainPreview("## Plan of record", 3, 4); text != "Plan of record" || col != 0 {
		t.Errorf("%q %d", text, col)
	}
	if text, col := plainPreview("## Plan of record", 0, 2); text != "## Plan of record" || col != 0 {
		t.Errorf("%q %d", text, col)
	}
	line = "See [the docs](https://example.com/guide) today"
	text, col = plainPreview(line, strings.Index(line, "example"), 7)
	if text != "See the docs(https://example.com/guide) today" || text[col:col+7] != "example" {
		t.Errorf("%q %d", text, col)
	}
	line = "A [[Project Plan|a pass]] here"
	text, col = plainPreview(line, strings.Index(line, "Plan"), 4)
	if text != "A Project Plan here" || text[col:col+4] != "Plan" {
		t.Errorf("%q %d", text, col)
	}
}

func TestTitlesSortNaturally(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{{"Note 2", "Note 10", -1}, {"note 2", "Note 2", 0}, {"Note 002", "Note 2", 0}, {"a", "ab", -1}, {"3 things", "2026-09-28", -1}}
	for _, c := range cases {
		got := NaturalCompare(c.a, c.b)
		if (got < 0) != (c.want < 0) || (got == 0) != (c.want == 0) {
			t.Errorf("%q vs %q: %d", c.a, c.b, got)
		}
	}
}
