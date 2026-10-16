package main

import (
	_ "embed"
	"os"
	"path/filepath"
)

//go:embed resources/usage.md
var usageGuide []byte

// showHelp opens the user guide in a tab of the window in front, read
// only.
func (a *deckle) showHelp() {
	if len(a.wins) == 0 {
		a.showWelcome()
		return
	}
	w := a.wins[0]
	dir, err := os.UserCacheDir()
	if err != nil {
		dir = os.TempDir()
	}
	p := filepath.Join(dir, "Deckle", "Deckle Help.md")
	os.MkdirAll(filepath.Dir(p), 0o755)
	os.WriteFile(p, usageGuide, 0o644)
	w.post(func() {
		for i, t := range w.tabs {
			if t.path == p {
				w.selectTab(i)
				return
			}
		}
		t := &tab{path: p, readOnly: true}
		w.tabs = append(w.tabs, t)
		w.sel = len(w.tabs) - 1
		w.load(t)
		w.tabChanged(true)
	})
	w.show()
}
