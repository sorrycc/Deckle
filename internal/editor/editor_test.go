package editor

import (
	"image/png"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"deckle/internal/theme"

	"github.com/egoist/mygo/ui"
)

const note = `---
title: Sample
---

# Heading one

Some *emphasis*, **strong**, ~~strike~~, ` + "`code`" + `, H~2~O, ==marked== and a [link](https://example.com).
A [[Wiki Page|label]] with a footnote[^1] and a long line that wraps around because it goes on and on and on past the width of the column, so we can see rows spaced as lines are.

> quoted **text**
> second line

> [!TIP] Titled
> A callout body.

- item one
- [x] done task
- [ ] open task
  1. nested

` + "```go" + `
func main() { fmt.Println("hi") } // done
` + "```" + `

| Name | Count |
|:-----|------:|
| 中文 | 12 |

---

[^1]: The note.
`

func testLook() Look {
	return Look{Theme: theme.System(false, ui.RGB(0, 122, 255)), Fonts: theme.Fonts{Size: 15}, LineHeight: 1.5, LineWidth: 760, HidesMarkers: true}
}

func shot(t *testing.T, tt *ui.Tester, name string) {
	dir := os.Getenv("SHOTS")
	if dir == "" {
		return
	}
	f, err := os.Create(filepath.Join(dir, name+".png"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	png.Encode(f, tt.Image())
}

func newTester(t *testing.T, text string) (*Editor, *ui.Tester) {
	e := New(text, "markdown", "/tmp/note.md")
	look := testLook()
	tt := ui.NewTester(func(c *ui.Context) {
		e.View(c, look).Fill().AutoFocus()
	}, 900, 1100)
	return e, tt
}

func TestRendersANote(t *testing.T) {
	e, tt := newTester(t, note)
	tt.Frame()
	shot(t, tt, "note")
	if e.views[0] == nil {
		t.Fatal("first line not laid out")
	}
}

func TestTypingAndUndo(t *testing.T) {
	e, tt := newTester(t, "hello")
	e.SetSelection(5, 5)
	tt.Frame()
	tt.Type(" world")
	if got := e.Text(); got != "hello world" {
		t.Fatalf("text %q", got)
	}
	tt.Key(ui.Cmd, ui.KeyZ)
	if got := e.Text(); got != "hello" {
		t.Fatalf("after undo %q", got)
	}
	tt.Key(ui.Cmd|ui.Shift, ui.KeyZ)
	if got := e.Text(); got != "hello world" {
		t.Fatalf("after redo %q", got)
	}
}

func TestReturnContinuesALists(t *testing.T) {
	e, tt := newTester(t, "- one")
	e.SetSelection(5, 5)
	tt.Frame()
	tt.Key(0, ui.KeyEnter)
	tt.Type("two")
	tt.Key(0, ui.KeyEnter)
	tt.Key(0, ui.KeyEnter)
	if got := e.Text(); got != "- one\n- two\n" {
		t.Fatalf("text %q", got)
	}
	e2, tt2 := newTester(t, "1. a\n- [x] b")
	e2.SetSelection(4, 4)
	tt2.Frame()
	tt2.Key(0, ui.KeyEnter)
	if got := e2.Text(); !strings.HasPrefix(got, "1. a\n2. ") {
		t.Fatalf("numbered %q", got)
	}
	e2.SetSelection(e2.buf.Len(), e2.buf.Len())
	tt2.Key(0, ui.KeyEnter)
	if got := e2.Text(); !strings.HasSuffix(got, "- [x] b\n- [ ] ") {
		t.Fatalf("task %q", got)
	}
}

func TestArrowsMoveThroughLines(t *testing.T) {
	e, tt := newTester(t, note)
	tt.Frame()
	e.SetSelection(0, 0)
	for range 40 {
		tt.Key(0, ui.KeyDown)
	}
	if e.caret == 0 {
		t.Fatal("caret did not move down")
	}
	for range 80 {
		tt.Key(0, ui.KeyUp)
	}
	if e.caret != 0 {
		t.Fatalf("caret %d after going up", e.caret)
	}
	for range 30 {
		tt.Key(0, ui.KeyRight)
	}
	if e.caret != 30 {
		t.Fatalf("caret %d after 30 rights", e.caret)
	}
}

func TestFormatting(t *testing.T) {
	e, _ := newTester(t, "word")
	e.SetSelection(0, 4)
	e.Run("toggleBold")
	if e.Text() != "**word**" {
		t.Fatalf("%q", e.Text())
	}
	e.Run("toggleBold")
	if e.Text() != "word" {
		t.Fatalf("%q", e.Text())
	}
	e.Run("heading2")
	if e.Text() != "## word" {
		t.Fatalf("%q", e.Text())
	}
	e.Run("toggleTaskList")
	e.Run("toggleTaskDone")
	if e.Text() != "- [x] ## word" {
		t.Fatalf("%q", e.Text())
	}
}

func TestTypingSpeed(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	text := strings.Repeat(note, 300*1024/len(note))
	e, tt := newTester(t, text)
	mid := e.buf.Len() / 2
	e.SetSelection(mid, mid)
	tt.Frame()
	var times []time.Duration
	for range 200 {
		t0 := time.Now()
		tt.Type("x")
		tt.Frame()
		times = append(times, time.Since(t0))
	}
	slices.Sort(times)
	t.Logf("%d KB: median %v, p95 %v, worst %v per keystroke", len(text)/1024, times[len(times)/2], times[len(times)*95/100], times[len(times)-1])
}
