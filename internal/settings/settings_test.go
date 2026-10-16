package settings

import (
	"path/filepath"
	"testing"
)

func TestDefaultsAndRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	s := Load(path)
	p := s.Prefs()
	if p.Theme != "system" || p.FontSize != 15 || p.LineHeight != 1.5 || p.LineWidth != 760 || !p.Hides() {
		t.Fatalf("defaults %+v", p)
	}
	s.SetPrefs(func(p *Prefs) { p.FontSize = 18; p.Theme = "nord" })
	s.Opened("/a")
	s.Opened("/b")
	s.Opened("/a")
	s.SetWorkspace("/a", Workspace{Tabs: []string{"/a/x.md"}, Positions: map[string]Position{"/a/x.md": {Location: 3}}})
	s.Flush()
	s2 := Load(path)
	if s2.Prefs().FontSize != 18 || s2.Prefs().Theme != "nord" {
		t.Fatalf("prefs %+v", s2.Prefs())
	}
	if r := s2.Recent(); len(r) != 2 || r[0] != "/a" {
		t.Fatalf("recent %v", r)
	}
	if w := s2.Workspace("/a"); w.Positions["/a/x.md"].Location != 3 {
		t.Fatalf("workspace %+v", w)
	}
}

func TestLegacyDefaults(t *testing.T) {
	js := `{"theme":"paper","editorFontSize":17,"hidesMarkers":false,"recentWorkspaces":["/n"],
	"workspaces":{"/n":{"tabs":["/n/a.md"],"selected":0,"positions":{"/n/a.md":{"location":5,"length":2,"scroll":10.5}}}}}`
	f, ok := fromDefaults([]byte(js))
	if !ok || f.Theme != "paper" || f.FontSize != 17 || f.HidesMarkers == nil || *f.HidesMarkers {
		t.Fatalf("%+v", f)
	}
	if p := f.Workspaces["/n"].Positions["/n/a.md"]; p.Location != 5 || p.Scroll != 10.5 {
		t.Fatalf("%+v", p)
	}
}

func TestPlist(t *testing.T) {
	x := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>theme</key><string>nord</string><key>editorFontSize</key><real>16</real>
<key>SULastCheckTime</key><date>2026-10-01T00:00:00Z</date><key>hidesMarkers</key><true/>
<key>recentWorkspaces</key><array><string>/x</string></array></dict></plist>`
	v, err := parsePlist([]byte(x))
	if err != nil {
		t.Fatal(err)
	}
	m := v.(map[string]any)
	if m["theme"] != "nord" || m["editorFontSize"] != 16.0 || m["hidesMarkers"] != true || len(m["recentWorkspaces"].([]any)) != 1 {
		t.Fatalf("%v", m)
	}
}
