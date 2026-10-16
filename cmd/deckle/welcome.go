package main

import (
	_ "embed"
	"os"
	"path/filepath"

	"deckle/internal/settings"
	"deckle/internal/theme"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

//go:embed resources/icon.png
var iconPNG []byte

var appIcon = func() *ui.Bitmap {
	b, _ := ui.DecodeBitmap(iconPNG)
	return b
}()

// welcomeWindow is the window for when no workspace is open: a button to
// choose a folder, and the folders opened before.
type welcomeWindow struct {
	a        *deckle
	w        *mygo.Window
	selected int
}

// showWelcome shows the Welcome window, or brings it forward.
func (a *deckle) showWelcome() {
	if a.welcome != nil {
		a.welcome.w.Show()
		a.welcome.w.Focus()
		return
	}
	ww := &welcomeWindow{a: a}
	ww.w = mygo.NewWindow(mygo.WindowOptions{
		Title: "Welcome to Deckle", Width: 720, Height: 440, DisableResize: true, DisableMaximize: true,
		TitleBarStyle: mygo.TitleBarHidden, Content: ui.View(ww.view),
	})
	ww.w.OnFileDrop(func(e *mygo.FileDropEvent) { mygo.RunOnMain(func() { a.open(e.Paths) }) })
	ww.w.OnClosed(func() {
		if a.welcome == ww {
			a.welcome = nil
		}
	})
	a.welcome = ww
}

func (ww *welcomeWindow) close() {
	ww.w.Close()
	ww.a.welcome = nil
}

func (ww *welcomeWindow) view(c *ui.Context) {
	a := ww.a
	th := currentTheme(c, a.s.Prefs().Theme)
	recent := a.s.Recent()
	ui.Row(c).Fill().Background(th.Background).TextColor(th.Text).AlignItems(ui.Stretch).Children(func() {
		ui.Column(c.Key("brand")).Width(300).Padding(56, 32, 32, 32).Gap(14).AlignItems(ui.Center).DragWindow().Children(func() {
			if appIcon != nil {
				ui.Image(c, appIcon).Size(112, 112)
			}
			ui.Text(c, "Deckle").FontSize(28).Bold()
			ui.Text(c, "A fast, native Markdown editor.").FontSize(13).TextColor(th.Secondary)
			ui.Box(c).Height(12)
			if ui.PrimaryButton(c, "Open Folder…").Clicked() {
				a.chooseWorkspace(ww.w, nil)
			}
			ui.Text(c, "Or drop a folder here.").FontSize(11.5).TextColor(th.Secondary)
		})
		ui.Column(c.Key("recent")).Grow(1).Background(th.Panel).Padding(36, 14, 14, 14).Gap(2).Children(func() {
			ui.Text(c, "Recent").FontSize(11).Bold().TextColor(th.Secondary).Padding(0, 10, 6, 10)
			if len(recent) == 0 {
				ui.Text(c, "Workspaces you open show here.").FontSize(12.5).TextColor(th.Secondary).Padding(10)
			}
			forget := ""
			for i, dir := range recent {
				d := dir
				r := ui.Row(c.Key(d)).Padding(8, 10).Gap(10).Radius(8).AlignItems(ui.Center).Cursor(ui.CursorDefault).Focusable()
				if i == ww.selected {
					r.Background(th.Accent.Alpha(0.14))
				} else if r.Hovered() {
					r.Background(th.Text.Alpha(0.05))
				}
				if r.Clicked() {
					ww.selected = i
					ww.open(d)
				}
				if r.Shortcut(0, ui.KeyBackspace) || r.Shortcut(0, ui.KeyDelete) {
					forget = d
				}
				r.ContextMenu(func(m *ui.Menu) {
					if m.Item("Open").Chosen() {
						ww.open(d)
					}
					if m.Item("Reveal in Finder").Chosen() {
						revealInFinder(d)
					}
					m.Separator()
					if m.Item("Remove from Recent").Chosen() {
						a.s.Forget(d)
						a.setMenu()
					}
				})
				r.Children(func() {
					ui.Icon(c, iconFolder).FontSize(18).TextColor(th.Accent)
					ui.Column(c).Grow(1).MinWidth(0).Children(func() {
						ui.Text(c, filepath.Base(d)).FontSize(13.5).Bold().SingleLine()
						ui.Text(c, shortenHome(filepath.Dir(d))).FontSize(11.5).TextColor(th.Secondary).SingleLine()
					})
				})
			}
			if forget != "" {
				a.s.Forget(forget)
				a.setMenu()
			}
		})
	})
	_ = theme.Theme{}
}

func (ww *welcomeWindow) open(dir string) {
	if _, err := os.Stat(dir); err != nil {
		go mygo.Dialog.Message(mygo.MessageOptions{Parent: ww.w, Type: mygo.MessageWarning, Message: "“" + filepath.Base(dir) + "” can't be found.", Detail: "It was moved or deleted."})
		ww.a.s.Forget(dir)
		return
	}
	ww.a.openWorkspace(dir, true)
}

var _ = settings.Prefs{}
