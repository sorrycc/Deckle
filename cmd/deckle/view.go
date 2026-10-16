package main

import (
	"fmt"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"

	"deckle/internal/editor"
	"deckle/internal/theme"
	"deckle/internal/workspace"

	"github.com/egoist/mygo/ui"
)

func itoa(n int) string { return strconv.Itoa(n) }

func isLetterOrDigit(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }

func urlUnescape(s string) (string, error) { return url.PathUnescape(s) }

// currentTheme is the theme the settings choose, for the desktop c shows.
func currentTheme(c *ui.Context, id string) theme.Theme {
	t := c.Theme()
	return theme.Resolve(id, t.Dark, t.Accent)
}

// useTheme gives the controls of a view the colors of th: buttons, check
// boxes, inputs and the focus ring in its accent, on its page.
func useTheme(c *ui.Context, th theme.Theme) {
	t := *c.Theme()
	t.Accent = th.Accent
	t.AccentHover = th.Accent.Mix(th.Text, 0.12)
	t.AccentPressed = th.Accent.Mix(th.Text, 0.24)
	t.AccentText = th.OnAccent()
	t.Focus = th.Accent.Alpha(0.5)
	t.Selection = th.Selection
	t.Background = th.Background
	t.Text = th.Text
	t.TextMuted = th.Secondary
	c.SetTheme(&t)
}

// lookOf is how editors show text, from the settings.
func (a *deckle) lookOf(th theme.Theme) editor.Look {
	p := a.s.Prefs()
	return editor.Look{
		Theme:        th,
		Fonts:        theme.Fonts{Body: p.FontFamily, Size: float32(p.FontSize), Mono: p.CodeFontFamily, CJK: p.CJKFontFamily, ChineseScript: chineseScript(p.ChineseScript)},
		LineHeight:   float32(p.LineHeight),
		LineWidth:    float32(p.LineWidth),
		HidesMarkers: p.Hides(),
	}
}

// view builds the window: the sidebar, the note list and the pane of tabs.
func (w *window) view(c *ui.Context) {
	w.runQueue()
	th := currentTheme(c, w.a.s.Prefs().Theme)
	w.theme = th
	w.look = w.a.lookOf(th)
	useTheme(c, th)
	w.shortcuts(c)
	root := ui.Box(c).Fill().Background(th.Background).TextColor(th.Text)
	root.Children(func() {
		w.renderer.host(c)
		ui.Row(c.Key("main")).Absolute().Top(0).Left(0).Right(0).Bottom(0).AlignItems(ui.Stretch).Children(func() {
			pane := func() { w.pane(c, th) }
			listAndPane := func() {
				if w.state.ListHidden {
					pane()
					return
				}
				ui.Split(c.Key("split-list"), &w.state.ListWidth, func() { w.list.view(c, th) }, pane).Fill()
			}
			if w.state.SidebarHidden {
				listAndPane()
				return
			}
			ui.Split(c.Key("split-side"), &w.state.SidebarWidth, func() { w.tree.view(c, th) }, listAndPane).Fill()
		})
		w.palette.view(c, th)
	})
}

// titleBar is the room at the top of a column, under the window's buttons,
// which drags the window.
func titleBarHeight() float32 { return 52 }

// pane builds the tabs, the editor of the one shown and the status bar.
func (w *window) pane(c *ui.Context, th theme.Theme) {
	ui.Column(c.Key("pane")).Fill().Background(th.Background).Children(func() {
		w.tabBar(c, th)
		// Basis 0 and no minimum, so a note longer than the pane leaves the
		// status bar its room instead of running under it.
		ui.Box(c.Key("content")).Grow(1).Basis(0).MinHeight(0).Clip().Children(func() {
			w.content(c, th)
		})
		w.statusBar(c, th)
	})
}

func iconButton(c *ui.Context, key string, svg *ui.SVG, tip string, th theme.Theme) ui.Element {
	b := ui.Box(c.Key(key)).Size(30, 30).Radius(8).Center().Focusable().FocusRing(false).Cursor(ui.CursorDefault).Tooltip(tip)
	if b.Hovered() {
		b.Background(th.Text.Alpha(0.07))
	}
	b.Children(func() { ui.Icon(c, svg).FontSize(17).TextColor(th.Secondary) })
	return b
}

// tabBar is the title bar of the pane: back and forward, the tabs, a new
// tab and search.
func (w *window) tabBar(c *ui.Context, th theme.Theme) {
	bar := c.TitleBar()
	left := float32(10)
	if w.state.SidebarHidden && w.state.ListHidden {
		left = bar.Left + 8
	}
	ui.Row(c.Key("tabbar")).Height(titleBarHeight()).Padding(0, max(bar.Right, 8)+4, 0, left).Gap(4).AlignItems(ui.Center).DragWindow().Children(func() {
		if w.state.SidebarHidden && w.state.ListHidden {
			if iconButton(c, "sidebar", iconSidebar, "Show Sidebar", th).Clicked() {
				w.state.SidebarHidden = false
			}
		}
		t := w.tab()
		back := iconButton(c, "back", iconBack, "Back", th)
		if t != nil && len(t.back) > 0 && back.Clicked() {
			w.goBack(false)
		}
		fwd := iconButton(c, "forward", iconForward, "Forward", th)
		if t != nil && len(t.forward) > 0 && fwd.Clicked() {
			w.goBack(true)
		}
		ui.Row(c.Key("tabs")).Grow(1).Gap(2).AlignItems(ui.Center).MinWidth(0).Children(func() {
			closeAt := -1
			for i, t := range w.tabs {
				title := "New Tab"
				ic := iconNote
				if t.path != "" {
					title = tabTitle(t)
					if editor.IsImage(t.path) {
						ic = iconImage
					} else if !workspace.IsMarkdown(t.path) {
						ic = iconFile
					}
				}
				el := ui.Row(c.Key(fmt.Sprintf("tab-%p", t))).Grow(1).MaxWidth(240).MinWidth(60).Height(30).Radius(8).Padding(0, 8).Gap(6).AlignItems(ui.Center).
					Cursor(ui.CursorDefault).Tooltip(t.path)
				hovered := el.Hovered()
				if i == w.sel {
					el.Background(th.Text.Alpha(0.08))
				} else if hovered {
					el.Background(th.Text.Alpha(0.04))
				}
				if el.Clicked() {
					w.selectTab(i)
				}
				el.ContextMenu(func(m *ui.Menu) {
					if m.Item("Close Tab").Chosen() {
						closeAt = i
					}
					if m.Item("Close Other Tabs").Disabled(len(w.tabs) < 2).Chosen() {
						w.post(func() { w.closeOthers(i) })
					}
					if m.Item("Close Tabs to the Right").Disabled(i == len(w.tabs)-1).Chosen() {
						w.post(func() { w.closeAfter(i) })
					}
					m.Separator()
					if m.Item("Reveal in Finder").Disabled(t.path == "").Chosen() {
						revealInFinder(t.path)
					}
					if m.Item("Copy Path").Disabled(t.path == "").Chosen() {
						c.Services().WriteClipboard(t.path)
					}
					if m.Item("Open in Default App").Disabled(t.path == "").Chosen() {
						openDefault(t.path)
					}
				})
				el.Children(func() {
					color := th.Secondary
					if i == w.sel {
						color = th.Text
					}
					ui.Icon(c, ic).FontSize(14).TextColor(color)
					ui.Text(c, title).SingleLine().Grow(1).FontSize(13).TextColor(color)
					if hovered || i == w.sel {
						x := ui.Box(c.Key("x")).Size(16, 16).Radius(4).Center()
						if x.Hovered() {
							x.Background(th.Text.Alpha(0.1))
						}
						if x.Clicked() {
							closeAt = i
						}
						x.Children(func() { ui.Icon(c, iconClose).FontSize(11).TextColor(th.Secondary) })
					}
				})
			}
			if closeAt >= 0 {
				i := closeAt
				w.post(func() { w.closeTab(i) })
			}
		})
		if iconButton(c, "newtab", iconPlus, "New Tab", th).Clicked() {
			w.newTab()
		}
		if iconButton(c, "search", iconSearch, "Search Notes", th).Clicked() {
			w.palette.show(modeSearch, "")
		}
	})
}

func tabTitle(t *tab) string {
	if t.path == "" {
		return "New Tab"
	}
	if workspace.IsMarkdown(t.path) {
		base := filepath.Base(t.path)
		return base[:len(base)-len(filepath.Ext(base))]
	}
	return filepath.Base(t.path)
}

// content builds what the tab shown holds.
func (w *window) content(c *ui.Context, th theme.Theme) {
	t := w.tab()
	switch {
	case t == nil || t.path == "":
		w.emptyTab(c, th)
	case t.loadErr != "":
		ui.Column(c).Fill().Center().Gap(6).Children(func() {
			ui.Text(c, "This file can't be opened").Bold()
			ui.Text(c, t.loadErr).TextColor(th.Secondary).FontSize(12)
		})
	case t.image != nil:
		w.imageView(c, t, th)
	case t.ed != nil:
		el := t.ed.View(c.Key(fmt.Sprintf("ed-%p-%s", t, t.path)), w.look).Fill()
		if w.focusEditor {
			el.Focus()
			w.focusEditor = false
		}
		if t.ed.IsMarkdown() {
			w.outline(c, t.ed, th)
		}
	}
}

func (w *window) emptyTab(c *ui.Context, th theme.Theme) {
	ui.Column(c).Fill().Center().Padding(24).Children(func() {
		ui.Column(c).Width(300).Gap(4).Children(func() {
			ui.Box(c).Size(52, 52).Radius(14).Center().Background(th.Accent.Alpha(0.12)).AlignSelf(ui.Center).Children(func() {
				ui.Icon(c, iconNote).FontSize(24).TextColor(th.Accent)
			})
			ui.Text(c, "No Note Open").FontSize(17).Bold().TextColor(th.Text).AlignSelf(ui.Center).Margin(14, 0, 2, 0)
			ui.Text(c, w.name+" · "+itoa(len(w.list.notes))+" notes").FontSize(12.5).TextColor(th.Secondary).AlignSelf(ui.Center).Margin(0, 0, 18, 0)
			for _, s := range []struct{ id, title, accel string }{
				{"newNote", "New Note", "CmdOrCtrl+N"},
				{"quickOpen", "Open a Note", "CmdOrCtrl+P"},
				{"searchNotes", "Search Notes", "CmdOrCtrl+Shift+F"},
				{"commands", "Commands", "CmdOrCtrl+Shift+P"},
			} {
				r := ui.Row(c.Key("hint-"+s.id)).Height(34).Padding(0, 10).Radius(8).AlignItems(ui.Center).Cursor(ui.CursorDefault)
				if r.Hovered() {
					r.Background(th.Text.Alpha(0.05))
				}
				if r.Clicked() {
					id := s.id
					w.post(func() { w.run(id) })
				}
				r.Children(func() {
					ui.Text(c, s.title).FontSize(13).TextColor(th.Text).Grow(1)
					keycaps(c, th, keysLabel(s.accel))
				})
			}
		})
	})
}

// keycaps shows a shortcut's keys, each on a cap.
func keycaps(c *ui.Context, th theme.Theme, keys string) {
	ui.Row(c).Gap(3).Children(func() {
		for _, k := range splitKeys(keys) {
			ui.Box(c).MinWidth(20).Height(20).Padding(0, 5).Radius(5).Center().
				Background(th.Text.Alpha(0.05)).Border(1, th.Border).Children(func() {
				ui.Text(c, k).FontSize(11).TextColor(th.Secondary)
			})
		}
	})
}

// splitKeys splits a shortcut's label into its keys: "⇧⌘F" into ⇧, ⌘ and
// F; "Ctrl+Shift+F" at its pluses.
func splitKeys(keys string) []string {
	if strings.Contains(keys, "+") && len(keys) > 1 {
		return strings.Split(keys, "+")
	}
	var out []string
	rs := []rune(keys)
	for i, r := range rs {
		if strings.ContainsRune("⌘⌃⇧⌥", r) || i == len(rs)-1 {
			out = append(out, string(r))
			continue
		}
		// A key with a name of several letters, as Tab.
		out = append(out, string(rs[i:]))
		break
	}
	return out
}

// statusBar shows how many notes link to this one, where the caret is,
// and how many words the note has.
func (w *window) statusBar(c *ui.Context, th theme.Theme) {
	t := w.tab()
	ui.Row(c.Key("status")).Height(26).Padding(0, 16).Gap(16).AlignItems(ui.Center).Children(func() {
		if t != nil && t.ed != nil && t.ed.IsMarkdown() && w.backlinks > 0 {
			n := w.backlinks
			label := itoa(n) + " backlink"
			if n != 1 {
				label += "s"
			}
			b := ui.Row(c.Key("backlinks")).Gap(4).AlignItems(ui.Center).Cursor(ui.CursorDefault)
			if b.Clicked() {
				w.palette.show(modeBacklinks, "")
			}
			b.Children(func() {
				ui.Icon(c, iconLink).FontSize(12).TextColor(th.Secondary)
				ui.Text(c, label).FontSize(11.5).TextColor(th.Secondary)
			})
		}
		ui.Box(c).Grow(1)
		switch {
		case t != nil && t.ed != nil:
			line, col := t.ed.CaretLine()
			ui.Text(c, fmt.Sprintf("Ln %d, Col %d", line, col)).FontSize(11.5).TextColor(th.Secondary)
			if t.ed.IsMarkdown() {
				label := itoa(w.words) + " words"
				if w.words == 1 {
					label = "1 word"
				}
				ui.Text(c, label).FontSize(11.5).TextColor(th.Secondary)
			} else if lang := t.ed.Buffer().Language(); lang != "" {
				ui.Text(c, languageName(lang)).FontSize(11.5).TextColor(th.Secondary)
			}
		case t != nil && t.image != nil:
			ui.Text(c, fmt.Sprintf("%.0f × %.0f", t.imgW, t.imgH)).FontSize(11.5).TextColor(th.Secondary)
		}
	})
}

func languageName(l string) string {
	names := map[string]string{"javascript": "JavaScript", "json": "JSON", "html": "HTML", "css": "CSS", "sql": "SQL", "yaml": "YAML", "toml": "TOML", "php": "PHP"}
	if n, ok := names[l]; ok {
		return n
	}
	if l == "" {
		return "Plain Text"
	}
	return string(unicode.ToUpper(rune(l[0]))) + l[1:]
}

// outline is the ticks at the right edge of a note, one per heading; the
// pointer over them shows the outline, a click jumps.
func (w *window) outline(c *ui.Context, ed *editor.Editor, th theme.Theme) {
	hs := ed.Headings()
	if len(hs) == 0 {
		return
	}
	// A note with more headings than fit shows its top levels.
	top := 6
	for top > 1 {
		n := 0
		for _, h := range hs {
			if h.Level <= top {
				n++
			}
		}
		if n <= 40 {
			break
		}
		top--
	}
	var shown []editor.Heading
	for _, h := range hs {
		if h.Level <= top {
			shown = append(shown, h)
		}
	}
	current := -1
	caret, _ := ed.Selection()
	for i, h := range shown {
		if h.At <= caret {
			current = i
		}
	}
	rail := ui.Column(c.Key("outline")).Absolute().Right(6).Top(0).Bottom(0).Justify(ui.Center).AlignItems(ui.End)
	hovered := rail.Hovered()
	rail.Children(func() {
		if hovered {
			ui.Column(c.Key("outline-list")).Padding(8).Gap(1).Radius(10).Background(th.Background).Border(1, th.Border).
				Shadow(0, 8, 24, 0, ui.RGBA(0, 0, 0, 0.15)).MaxHeight(480).Width(260).Children(func() {
				ui.Scroll(c).Children(func() {
					for i, h := range shown {
						row := ui.Row(c.Key(fmt.Sprintf("h%d", i))).Padding(4, 8, 4, 8+float32(h.Level-1)*12).Radius(6).Cursor(ui.CursorDefault)
						if row.Hovered() {
							row.Background(th.Text.Alpha(0.07))
						}
						if row.Clicked() {
							at := h.At
							ed.SetSelection(at, at)
							ed.RevealCentered()
							w.focusEditor = true
						}
						row.Children(func() {
							t := ui.Text(c, h.Title).SingleLine().FontSize(12.5)
							if i == current {
								t.TextColor(th.Accent).Bold()
							} else {
								t.TextColor(th.Text)
							}
						})
					}
				})
			})
			return
		}
		ui.Column(c.Key("ticks")).Gap(6).Padding(8, 4).Children(func() {
			for i, h := range shown {
				color := th.Text.Alpha(0.3)
				if i == current {
					color = th.Accent
				}
				width := float32(16 - (h.Level-1)*3)
				ui.Box(c.Key(fmt.Sprintf("t%d", i))).Width(max(width, 6)).Height(2).Radius(1).Background(color)
			}
		})
	})
}

// imageView shows an image tab, fitted to the pane; ⌘-scroll and the
// zoom commands zoom it.
func (w *window) imageView(c *ui.Context, t *tab, th theme.Theme) {
	ui.ScrollBoth(c.Key("image-" + t.path)).Fill().Children(func() {
		ui.Box(c).MinWidth(0).Fill().Center().Padding(24).Children(func() {
			img := ui.Image(c, t.image)
			if t.zoom > 0 {
				img.Size(t.imgW*t.zoom, t.imgH*t.zoom)
			} else {
				img.MaxWidth(t.imgW).MaxHeight(t.imgH).Fill()
			}
		})
	})
}

func (w *window) loadImage(t *tab) {
	path := t.path
	go func() {
		img, iw, ih, err := decodeFile(path)
		w.post(func() {
			if t.path != path {
				return
			}
			if err != nil {
				t.loadErr = err.Error()
				return
			}
			t.image, t.imgW, t.imgH = img, iw, ih
		})
	}()
}
