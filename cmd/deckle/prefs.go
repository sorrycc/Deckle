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
	pw.w = mygo.NewWindow(mygo.WindowOptions{Title: "Settings", Width: 620, Height: 520, DisableResize: true, DisableMaximize: true, Content: ui.View(pw.view)})
	pw.w.OnClosed(func() { a.prefs = nil })
	a.prefs = pw
}

// chineseScript is the Chinese of Han characters, from the setting or
// the system's languages.
func chineseScript(s string) string {
	if s == "zh-Hans" || s == "zh-Hant" || s == "zh-HK" {
		return s
	}
	// Every frame asks, and asking the system goes through the main loop:
	// its answer is kept until the settings change.
	if systemChinese == "" {
		systemChinese = systemChineseScript()
	}
	return systemChinese
}

// systemChinese is the system's Chinese, once asked.
var systemChinese string

func systemChineseScript() string {
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
	useTheme(c, th)
	set := func(f func(p *settings.Prefs)) { a.s.SetPrefs(f) }
	field := func(label string, build func()) {
		ui.Row(c.Key(label)).Gap(16).AlignItems(ui.Center).Children(func() {
			ui.Text(c, label).Width(160).TextAlign(ui.End).TextColor(th.Text)
			ui.Row(c).Grow(1).Gap(8).AlignItems(ui.Center).Children(build)
		})
	}
	ui.Column(c).Fill().Background(th.Background).TextColor(th.Text).Children(func() {
		// The tabs of a settings window, as a toolbar of icons over their
		// names, under the window's title.
		ui.Row(c.Key("tabs")).Padding(8, 14, 10, 14).Gap(2).Justify(ui.Center).Background(th.Panel).
			BorderWidth(0, 0, 1, 0).BorderColor(th.Border).DragWindow().Children(func() {
			for i, tb := range []struct {
				name string
				icon *ui.SVG
			}{{"General", iconGeneral}, {"Editor", iconTextSize}, {"Chinese & Japanese", iconLanguage}, {"Updates", iconUpdates}} {
				b := ui.Column(c.Key(tb.name)).MinWidth(76).Padding(6, 10).Gap(3).Radius(8).AlignItems(ui.Center).Cursor(ui.CursorDefault).Label(tb.name)
				color := th.Secondary
				if pw.tab == i {
					b.Background(th.Text.Alpha(0.07))
					color = th.Accent
				} else if b.Hovered() {
					b.Background(th.Text.Alpha(0.04))
				}
				if b.Clicked() {
					pw.tab = i
				}
				b.Children(func() {
					ui.Icon(c, tb.icon).FontSize(22).TextColor(color)
					t := ui.Text(c, tb.name).FontSize(11.5).TextColor(th.Text)
					if pw.tab == i {
						t.FontWeight(600)
					}
				})
			}
		})
		ui.Column(c.Key("pane")).Grow(1).Padding(24, 28).Gap(16).Children(func() {
			switch pw.tab {
			case 0:
				ui.Text(c, "Theme").FontSize(13).FontWeight(600)
				ui.Grid(c.Key("themes")).Columns(5).Gap(14).Margin(0, 0, 10, 0).Children(func() {
					for _, id := range theme.IDs() {
						if themeCard(c, id, p.Theme == id, th) {
							set(func(p *settings.Prefs) { p.Theme = id })
						}
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
				// A few lines in the fonts chosen, as notes show them.
				look := a.lookOf(th)
				ui.Column(c.Key("preview")).Margin(8, 0, 0, 0).Padding(16, 20).Gap(6).Radius(10).Background(th.Panel).Border(1, th.Border).Children(func() {
					ui.Text(c, "Preview").FontSize(11).FontWeight(600).TextColor(th.Secondary)
					ui.Text(c, "The quiet hours").Font(look.Fonts.BodyFamily("")).FontSize(look.Fonts.Heading(2)).Bold().TextColor(th.Heading)
					ui.Text(c, "Five days in late November, when the maples turn and the paths empty out before eight.").
						Font(look.Fonts.BodyFamily("")).FontSize(look.Fonts.Size).LineHeight(look.LineHeight).TextColor(th.Text)
					ui.Text(c, "go run ./cmd/deckle").Font(look.Fonts.MonoFamily()).FontSize(look.Fonts.MonoSize()).TextColor(th.CodeText)
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
					labeledSelect(c.Key("cjk"), &cur, opts, func(s string) string { return names[s] }).Width(260)
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
				field("", func() {
					ui.Text(c, "A line with kana is drawn as Japanese; one with Han characters alone in the forms chosen here, or as Japanese in a note that is mostly Japanese.").
						FontSize(12).TextColor(th.Secondary).MaxWidth(360)
				})
				// The same Han characters in the forms each line takes.
				look := a.lookOf(th)
				ui.Column(c.Key("cjk-preview")).Margin(8, 0, 0, 0).Padding(16, 20).Gap(8).Radius(10).Background(th.Panel).Border(1, th.Border).Children(func() {
					ui.Text(c, "Preview").FontSize(11).FontWeight(600).TextColor(th.Secondary)
					sample := func(text, lang, label string) {
						ui.Row(c).Gap(12).AlignItems(ui.Center).Children(func() {
							ui.Text(c, text).Font(look.Fonts.BodyFamily(lang)).Lang(lang).FontSize(look.Fonts.Size + 2).TextColor(th.Text).Grow(1)
							ui.Text(c, label).FontSize(11).TextColor(th.Secondary)
						})
					}
					sample("海内存知己，天涯若比邻。", look.Fonts.ChineseScript, "Chinese")
					sample("春はあけぼの。やうやう白くなりゆく山ぎは。", "ja", "Japanese")
				})
			case 3:
				// The app, and which version this is.
				ui.Row(c.Key("about")).Padding(16, 20).Gap(16).Radius(10).AlignItems(ui.Center).Background(th.Panel).Border(1, th.Border).Margin(0, 0, 8, 0).Children(func() {
					if appIcon != nil {
						ui.Image(c, appIcon).Size(56, 56)
					}
					ui.Column(c).Grow(1).Gap(3).Children(func() {
						ui.Text(c, "Deckle").FontSize(17).Bold()
						version := "Development build"
						if v := mygo.App.Version(); v != "" {
							version = "Version " + v
						}
						ui.Text(c, version).FontSize(12.5).TextColor(th.Secondary)
					})
				})
				if !mygo.Updater.Enabled() {
					ui.Text(c, "This copy of Deckle doesn't update itself.").FontSize(12.5).TextColor(th.Secondary).AlignSelf(ui.Center)
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
						updater.CheckForUpdates()
					}
				})
			}
		})
	})
}

// themeCard is a theme's swatch: its page, a heading and lines of text
// in its colors, and its name; it reports a click.
func themeCard(c *ui.Context, id string, selected bool, cur theme.Theme) bool {
	card := ui.Column(c.Key("theme-" + id)).Gap(6).AlignItems(ui.Center).Cursor(ui.CursorDefault).Label(theme.Name(id))
	clicked := card.Clicked()
	hovered := card.Hovered()
	card.Children(func() {
		swatch := func(t theme.Theme) {
			ui.Column(c).Grow(1).Basis(0).Padding(9, 10).Gap(5).Background(t.Background).Children(func() {
				ui.Text(c, "Aa").FontSize(15).Bold().TextColor(t.Heading)
				ui.Box(c).Height(3).Radius(2).Width(40).Background(t.Text.Alpha(0.55))
				ui.Row(c).Gap(4).Children(func() {
					ui.Box(c).Height(3).Radius(2).Width(18).Background(t.Accent)
					ui.Box(c).Height(3).Radius(2).Width(22).Background(t.Text.Alpha(0.3))
				})
			})
		}
		frame := ui.Row(c).Height(68).FillWidth().AlignItems(ui.Stretch).Radius(9).Clip().Border(1, cur.Border)
		switch {
		case selected:
			frame.Shadow(0, 0, 0, 2, cur.Accent)
		case hovered:
			frame.Shadow(0, 0, 0, 2, cur.Text.Alpha(0.15))
		}
		frame.Children(func() {
			if id == "system" {
				swatch(theme.System(false, cur.Accent))
				swatch(theme.System(true, cur.Accent))
				return
			}
			swatch(theme.Resolve(id, false, cur.Accent))
		})
		name := ui.Text(c, theme.Name(id)).FontSize(11.5).SingleLine().TextColor(cur.Secondary)
		if selected {
			name.TextColor(cur.Text).FontWeight(600)
		}
	})
	return clicked
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
