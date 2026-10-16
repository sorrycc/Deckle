package settings

import (
	"encoding/json"
	"os/exec"
	"runtime"
)

// legacyDomain is the user defaults domain of Deckle's AppKit versions.
const legacyDomain = "dev.sorrycc.deckle"

// Legacy reads the settings of Deckle's AppKit versions from their user
// defaults, once: the theme, fonts and layout, the workspaces opened and
// the tabs and places of each. It reports false when there are none.
func Legacy() (File, bool) {
	if runtime.GOOS != "darwin" {
		return File{}, false
	}
	plist, err := exec.Command("defaults", "export", legacyDomain, "-").Output()
	if err != nil || len(plist) == 0 {
		return File{}, false
	}
	v, err := parsePlist(plist)
	if err != nil {
		return File{}, false
	}
	js, err := json.Marshal(v)
	if err != nil {
		return File{}, false
	}
	return fromDefaults(js)
}

func fromDefaults(js []byte) (File, bool) {
	var raw map[string]json.RawMessage
	if json.Unmarshal(js, &raw) != nil {
		return File{}, false
	}
	var f File
	str := func(k string, dst *string) {
		if v, ok := raw[k]; ok {
			json.Unmarshal(v, dst)
		}
	}
	num := func(k string, dst *float64) {
		if v, ok := raw[k]; ok {
			json.Unmarshal(v, dst)
		}
	}
	flag := func(k string) (bool, bool) {
		var b bool
		v, ok := raw[k]
		if ok {
			ok = json.Unmarshal(v, &b) == nil
		}
		return b, ok
	}
	strs := func(k string) []string {
		var out []string
		if v, ok := raw[k]; ok {
			json.Unmarshal(v, &out)
		}
		return out
	}
	str("theme", &f.Theme)
	str("editorFontFamily", &f.FontFamily)
	str("cjkFontFamily", &f.CJKFontFamily)
	str("chineseScript", &f.ChineseScript)
	str("codeFontFamily", &f.CodeFontFamily)
	num("editorFontSize", &f.FontSize)
	num("lineHeight", &f.LineHeight)
	num("lineWidth", &f.LineWidth)
	if b, ok := flag("hidesMarkers"); ok {
		f.HidesMarkers = &b
	}
	f.SortsNotesByTitle, _ = flag("sortsNotesByTitle")
	f.IncludeBetas, _ = flag("SUIncludeBetas")
	if b, ok := flag("includeBetas"); ok {
		f.IncludeBetas = b
	}
	str("lastWorkspace", &f.LastWorkspace)
	f.OpenWorkspaces = strs("openWorkspaces")
	f.RecentWorkspaces = strs("recentWorkspaces")
	f.Workspaces = map[string]*Workspace{}
	if v, ok := raw["workspaces"]; ok {
		var ws map[string]struct {
			Tabs      []string `json:"tabs"`
			Selected  int      `json:"selected"`
			Folder    string   `json:"folder"`
			Expanded  []string `json:"expanded"`
			Starred   []string `json:"starred"`
			Positions map[string]struct {
				Location float64 `json:"location"`
				Length   float64 `json:"length"`
				Scroll   float64 `json:"scroll"`
			} `json:"positions"`
		}
		if json.Unmarshal(v, &ws) == nil {
			for dir, w := range ws {
				nw := &Workspace{Tabs: w.Tabs, Selected: w.Selected, Folder: w.Folder, Expanded: w.Expanded, Starred: w.Starred, Positions: map[string]Position{}}
				for p, pos := range w.Positions {
					nw.Positions[p] = Position{Location: int(pos.Location), Length: int(pos.Length), Scroll: pos.Scroll}
				}
				f.Workspaces[dir] = nw
			}
		}
	}
	f.Migrated = true
	return f, true
}
