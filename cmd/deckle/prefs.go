package main

import (
	"os"
	"strings"

	"deckle/internal/settings"
	"deckle/internal/theme"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/updater"
	"github.com/egoist/mygo/ui"
)

// prefsWindow is the Settings window: the theme, the fonts, the column of
// text, Chinese and Japanese, and updates.
type prefsWindow struct {
	a    *deckle
	w    *mygo.Window
	tab  int
	fam  string
	code string
	cjk  string
}

func (a *deckle) showPrefs() {
	if a.prefs != nil {
		a.prefs.w.Show()
		a.prefs.w.Focus()
		return
	}
	p := a.s.Prefs()
	pw := &prefsWindow{a: a, fam: p.FontFamily, code: p.CodeFontFamily, cjk: p.CJKFontFamily}
	if os.Getenv("DECKLE_SETTINGS_TAB") != "" {
		pw.tab = int(os.Getenv("DECKLE_SETTINGS_TAB")[0] - '0')
	}
	pw.w = mygo.NewWindow(mygo.WindowOptions{Title: "Settings", Width: 560, Height: 480, DisableResize: true, DisableMaximize: true, Content: ui.View(pw.view)})
	pw.w.OnClosed(func() { a.prefs = nil })
	a.prefs = pw
}

// chineseScript is the Chinese of Han characters, from the setting or
// the system's languages.
func chineseScript(s string) string {
	if s == "zh-Hans" || s == "zh-Hant" || s == "zh-HK" {
		return s
	}
	for _, l := range mygo.App.PreferredLanguages() {
		if strings.HasPrefix(l, "zh") {
			switch {
			case strings.Contains(l, "HK") || strings.Contains(l, "MO"):
				return "zh-HK"
			case strings.Contains(l, "Hant") || strings.Contains(l, "TW"):
				return "zh-Hant"
			}
			return "zh-Hans"
		}
	}
	return "zh-Hans"
}

func (pw *prefsWindow) view(c *ui.Context) {
	a := pw.a
	p := a.s.Prefs()
	th := currentTheme(c, p.Theme)
	set := func(f func(p *settings.Prefs)) { a.s.SetPrefs(f) }
	field := func(label string, build func()) {
		ui.Row(c.Key(label)).Gap(16).AlignItems(ui.Center).Children(func() {
			ui.Text(c, label).Width(160).TextAlign(ui.End).TextColor(th.Text)
			ui.Row(c).Grow(1).Gap(8).AlignItems(ui.Center).Children(build)
		})
	}
	ui.Column(c).Fill().Background(th.Background).TextColor(th.Text).Children(func() {
		ui.Row(c.Key("tabs")).Padding(14).Gap(4).Center().Children(func() {
			for i, name := range []string{"General", "Editor", "Chinese & Japanese", "Updates"} {
				b := ui.Button(c, name).Selected(pw.tab == i)
				if b.Clicked() {
					pw.tab = i
				}
			}
		})
		ui.Box(c).Height(1).Background(th.Border)
		ui.Column(c.Key("pane")).Grow(1).Padding(24, 32).Gap(16).Children(func() {
			switch pw.tab {
			case 0:
				field("Theme:", func() {
					ids := theme.IDs()
					cur := p.Theme
					labeledSelect(c.Key("theme"), &cur, ids, func(id string) string { return theme.Name(id) }).Width(220)
					if cur != p.Theme {
						set(func(p *settings.Prefs) { p.Theme = cur })
					}
				})
				field("Markdown syntax:", func() {
					hides := p.Hides()
					if ui.Checkbox(c, &hides, "Show only around the selection").Changed() {
						set(func(p *settings.Prefs) { p.HidesMarkers = &hides })
					}
				})
				field("Note list:", func() {
					by := p.SortsNotesByTitle
					if ui.Checkbox(c, &by, "Sort by title").Changed() {
						set(func(p *settings.Prefs) { p.SortsNotesByTitle = by })
					}
				})
			case 1:
				field("Font:", func() {
					in := ui.TextInput(c.Key("font"), &pw.fam).Placeholder("System").Width(220)
					if in.Submitted() || (in.Changed() && pw.fam == "") {
						f := strings.TrimSpace(pw.fam)
						set(func(p *settings.Prefs) { p.FontFamily = f })
					}
				})
				field("Code font:", func() {
					in := ui.TextInput(c.Key("code"), &pw.code).Placeholder("System Monospace").Width(220)
					if in.Submitted() || (in.Changed() && pw.code == "") {
						f := strings.TrimSpace(pw.code)
						set(func(p *settings.Prefs) { p.CodeFontFamily = f })
					}
				})
				field("Size:", func() {
					v := p.FontSize
					if ui.Slider(c.Key("size"), &v, 9, 40).Step(1).Width(220).Changed() {
						set(func(p *settings.Prefs) { p.FontSize = v })
					}
					ui.Text(c, itoa(int(v))+" pt").TextColor(th.Secondary)
				})
				field("Line height:", func() {
					v := p.LineHeight
					if ui.Slider(c.Key("lh"), &v, 1, 2.4).Step(0.05).Width(220).Changed() {
						set(func(p *settings.Prefs) { p.LineHeight = v })
					}
					ui.Text(c, strings.TrimRight(strings.TrimRight(ftoa(v), "0"), ".")).TextColor(th.Secondary)
				})
				field("Line width:", func() {
					v := p.LineWidth
					if ui.Slider(c.Key("lw"), &v, 400, 1400).Step(20).Width(220).Changed() {
						set(func(p *settings.Prefs) { p.LineWidth = v })
					}
					ui.Text(c, itoa(int(v))+" pt").TextColor(th.Secondary)
				})
			case 2:
				field("Chinese and Japanese:", func() {
					opts := []string{"", "serif", "LXGW WenKai Lite"}
					names := map[string]string{"": "System", "serif": "Songti / Mincho", "LXGW WenKai Lite": "LXGW WenKai"}
					cur := p.CJKFontFamily
					if !contains(opts, cur) {
						opts = append(opts, cur)
						names[cur] = cur
					}
					labeledSelect(c.Key("cjk"), &cur, opts, func(s string) string { return names[s] }).Width(220)
					if cur != p.CJKFontFamily {
						set(func(p *settings.Prefs) { p.CJKFontFamily = cur })
					}
				})
				field("Han characters:", func() {
					opts := []string{"", "zh-Hans", "zh-Hant", "zh-HK"}
					names := map[string]string{"": "As the system's languages", "zh-Hans": "Simplified Chinese", "zh-Hant": "Traditional Chinese (Taiwan)", "zh-HK": "Traditional Chinese (Hong Kong)"}
					cur := p.ChineseScript
					labeledSelect(c.Key("script"), &cur, opts, func(s string) string { return names[s] }).Width(260)
					if cur != p.ChineseScript {
						set(func(p *settings.Prefs) { p.ChineseScript = cur })
					}
				})
				ui.Text(c, "A line with kana is drawn as Japanese; one with Han characters alone in the forms chosen here, or as Japanese in a note that is mostly Japanese.").
					FontSize(12).TextColor(th.Secondary).MaxWidth(440).AlignSelf(ui.Center)
			case 3:
				if !updatesAvailable() {
					ui.Text(c, "This copy of Deckle doesn't update itself.").TextColor(th.Secondary).AlignSelf(ui.Center)
					return
				}
				field("Updates:", func() {
					on := updater.AutomaticChecks()
					if ui.Checkbox(c, &on, "Check for updates automatically").Changed() {
						updater.SetAutomaticChecks(on)
					}
				})
				field("", func() {
					if ui.Button(c, "Check Now").Clicked() {
						checkForUpdates()
					}
				})
			}
		})
	})
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// labeledSelect chooses one of ids into cur, showing each by its label.
func labeledSelect(c *ui.Context, cur *string, ids []string, label func(string) string) ui.Element {
	names := make([]string, len(ids))
	shown := label(*cur)
	for i, id := range ids {
		names[i] = label(id)
	}
	el := ui.Select(c, &shown, names)
	for i, n := range names {
		if n == shown {
			*cur = ids[i]
		}
	}
	return el
}
