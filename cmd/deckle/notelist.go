package main

import (
	"path/filepath"
	"sync"
	"time"

	"deckle/internal/theme"
	"deckle/internal/workspace"

	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"
)

// noteList is the middle column: the notes of a folder and the folders
// under it, each with its title, when it changed, the start of its text
// and its first image.
type noteList struct {
	w      *window
	folder string // "" for the whole workspace
	notes  []string
	stale  bool
	byWhat bool
	state  ui.ListState
	reveal bool
	focus  bool
	thumbs *thumbnails
}

func newNoteList(w *window) *noteList {
	l := &noteList{w: w, stale: true, thumbs: &thumbnails{m: map[string]*thumb{}}}
	l.state.Key = func(i int) any {
		if i < len(l.notes) {
			return l.notes[i]
		}
		return i
	}
	return l
}

func (l *noteList) show(folder string) {
	l.folder = folder
	l.stale = true
	l.w.saveSession()
}

func (l *noteList) refresh() {
	byTitle := l.w.a.s.Prefs().SortsNotesByTitle
	dir := l.folder
	if dir == "" {
		dir = l.w.ws.Root()
	}
	l.notes = l.w.ws.ListNotes(dir, byTitle)
	l.byWhat = byTitle
	l.stale = false
}

func (l *noteList) view(c *ui.Context, th theme.Theme) {
	w := l.w
	if l.stale || l.byWhat != w.a.s.Prefs().SortsNotesByTitle {
		l.refresh()
	}
	title := w.name
	if l.folder != "" {
		title = filepath.Base(l.folder)
	}
	ui.Column(c.Key("notelist")).Fill().Background(th.Background).Children(func() {
		ui.Row(c.Key("list-top")).Height(titleBarHeight()).Padding(0, 12).AlignItems(ui.Center).DragWindow().Children(func() {
			ui.Box(c).Grow(1)
			if iconButton(c, "new-note", iconNewNote, "New Note", th).Clicked() {
				w.newNote()
			}
		})
		ui.Row(c.Key("list-head")).Padding(4, 16, 10, 24).Gap(8).AlignItems(ui.Center).Children(func() {
			ui.Text(c, title).Bold().FontSize(15).SingleLine()
			ui.Text(c, itoa(len(l.notes))).FontSize(12).TextColor(th.Secondary)
			ui.Box(c).Grow(1)
			ic, tip := iconClock, "Sorted by Date"
			if l.byWhat {
				ic, tip = iconSortAZ, "Sorted by Title"
			}
			if iconButton(c, "sort", ic, tip, th).Clicked() {
				w.a.s.SetPrefs(func(p *settingsPrefs) { p.SortsNotesByTitle = !p.SortsNotesByTitle })
			}
		})
		cur := ""
		if t := w.tab(); t != nil {
			cur = t.path
		}
		if l.reveal {
			l.reveal = false
			for i, p := range l.notes {
				if p == cur {
					l.state.ScrollTo(i, ui.Center)
					break
				}
			}
		}
		list := ui.List(c.Key("notes"), &l.state, len(l.notes), func(i int) {
			l.row(c, th, l.notes[i], l.notes[i] == cur)
		}).Grow(1).Padding(0, 12, 12, 12)
		if l.focus {
			list.Focus()
			l.focus = false
		}
		// Return hands the keyboard to the editor.
		if list.Shortcut(0, ui.KeyEnter) {
			w.focusEditor = true
		}
		list.Children(func() {
			if len(l.notes) == 0 {
				ui.Column(c).Padding(40, 20).Gap(6).AlignItems(ui.Center).Children(func() {
					ui.Text(c, "No Notes").Bold().TextColor(th.Secondary)
					ui.Text(c, "Notes in this folder show here.").FontSize(12).TextColor(th.Secondary)
				})
			}
		})
	})
}

func (l *noteList) row(c *ui.Context, th theme.Theme, path string, selected bool) {
	w := l.w
	n, _ := w.ws.Note(path)
	r := ui.Row(c.Key(path)).Padding(10, 14).Gap(10).Radius(10).Cursor(ui.CursorDefault).Height(84)
	if selected {
		r.Background(th.Text.Alpha(0.07))
	} else if r.Hovered() {
		r.Background(th.Text.Alpha(0.03))
	}
	if r.Clicked() {
		w.open(path, openOptions{focus: false})
	}
	if r.DoubleClicked() {
		w.open(path, openOptions{newTab: true, focus: true})
	}
	if data, err := transfer.FileData(path); err == nil {
		r.DragData(data)
	}
	r.ContextMenu(func(m *ui.Menu) {
		if m.Item("Open in New Tab").Chosen() {
			w.open(path, openOptions{newTab: true, focus: true})
		}
		if m.Item("Reveal in Finder").Chosen() {
			revealInFinder(path)
		}
		m.Separator()
		if m.Item("Move to Trash").Chosen() {
			w.post(func() { w.trash(path) })
		}
	})
	r.Children(func() {
		ui.Column(c).Grow(1).MinWidth(0).Gap(3).Children(func() {
			ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
				ui.Text(c, n.Title).Bold().FontSize(13.5).SingleLine().Grow(1)
				ui.Text(c, shortDate(n.Modified)).FontSize(11.5).TextColor(th.Secondary).SingleLine()
			})
			ui.Row(c).Gap(10).Children(func() {
				ui.Text(c, n.Excerpt).FontSize(12.5).TextColor(th.Secondary).MaxLines(2).Grow(1).MinWidth(0)
				if n.Image != "" {
					if img := l.thumbs.get(n.Image, w.post); img != nil {
						ui.Image(c, img).Size(44, 44).Radius(6).Border(1, th.Border).Fit(ui.Cover)
					}
				}
			})
		})
	})
}

// shortDate is the time for today, a weekday's name this week, the day
// for this year, the full date before that.
func shortDate(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	now := time.Now()
	y1, m1, d1 := t.Date()
	y2, m2, d2 := now.Date()
	switch {
	case y1 == y2 && m1 == m2 && d1 == d2:
		return t.Format("3:04 PM")
	case now.Sub(t) < 48*time.Hour && d2-d1 == 1:
		return "Yesterday"
	case y1 == y2:
		return t.Format("Jan 2")
	}
	return t.Format("Jan 2, 2006")
}

// thumbnails are small versions of the notes' first images, decoded off
// the main thread, a few at a time.
type thumbnails struct {
	mu sync.Mutex
	m  map[string]*thumb
}

type thumb struct {
	img     ui.ImageSource
	loading bool
}

var thumbSlots = make(chan struct{}, 3)

func (t *thumbnails) get(path string, post func(func())) ui.ImageSource {
	t.mu.Lock()
	defer t.mu.Unlock()
	if th, ok := t.m[path]; ok {
		return th.img
	}
	th := &thumb{loading: true}
	t.m[path] = th
	go func() {
		thumbSlots <- struct{}{}
		img := decodeThumb(path, 96)
		<-thumbSlots
		t.mu.Lock()
		th.img, th.loading = img, false
		t.mu.Unlock()
		post(func() {})
	}()
	return nil
}

var _ = workspace.IsMarkdown
