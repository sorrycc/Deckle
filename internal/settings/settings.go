// Package settings keeps Deckle's settings and the state of its windows in
// one JSON file, written a moment after each change.
package settings

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

// Prefs are what the Settings window shows.
type Prefs struct {
	// Theme is a theme's ID: "system" follows light and dark mode.
	Theme string `json:"theme"`
	// FontFamily is an installed family for text, or "" for the system's.
	FontFamily string `json:"editorFontFamily"`
	// CJKFontFamily is the face of Chinese and Japanese: "" for the
	// system's, "serif", or an installed family.
	CJKFontFamily string `json:"cjkFontFamily"`
	// ChineseScript is the Chinese of Han characters in text without
	// kana: zh-Hans, zh-Hant or zh-HK; "" follows the system's languages.
	ChineseScript string `json:"chineseScript"`
	// CodeFontFamily is an installed family for code, or "".
	CodeFontFamily string  `json:"codeFontFamily"`
	FontSize       float64 `json:"editorFontSize"`
	// LineHeight is a multiple of the font's.
	LineHeight float64 `json:"lineHeight"`
	// LineWidth is the widest a line of text gets, in points.
	LineWidth float64 `json:"lineWidth"`
	// HidesMarkers shows Markdown's syntax only around the selection.
	HidesMarkers *bool `json:"hidesMarkers,omitempty"`
	// SortsNotesByTitle sorts the note list by title, not by date.
	SortsNotesByTitle bool `json:"sortsNotesByTitle"`
	// IncludeBetas offers beta versions as updates.
	IncludeBetas bool `json:"includeBetas"`
}

// Position is where a note was left: its selection, in UTF-16 units, and
// how far down it was scrolled.
type Position struct {
	Location int     `json:"location"`
	Length   int     `json:"length"`
	Scroll   float64 `json:"scroll,omitempty"`
}

// Workspace is what is remembered of a workspace: its tabs, the folder
// its list shows, the folders open in its tree and the starred files.
type Workspace struct {
	Tabs      []string            `json:"tabs,omitempty"`
	Selected  int                 `json:"selected"`
	Folder    string              `json:"folder,omitempty"`
	Expanded  []string            `json:"expanded,omitempty"`
	Starred   []string            `json:"starred,omitempty"`
	Positions map[string]Position `json:"positions,omitempty"`
	// The widths of the sidebar and the note list, and whether each is
	// shown.
	SidebarWidth  float32 `json:"sidebarWidth,omitempty"`
	ListWidth     float32 `json:"listWidth,omitempty"`
	SidebarHidden bool    `json:"sidebarHidden,omitempty"`
	ListHidden    bool    `json:"listHidden,omitempty"`
}

// State is the app's windows and workspaces.
type State struct {
	LastWorkspace string `json:"lastWorkspace,omitempty"`
	// OpenWorkspaces have a window open, the front one last, to open again
	// at launch.
	OpenWorkspaces []string `json:"openWorkspaces,omitempty"`
	// RecentWorkspaces were opened before, newest first.
	RecentWorkspaces []string              `json:"recentWorkspaces,omitempty"`
	Workspaces       map[string]*Workspace `json:"workspaces,omitempty"`
	// Migrated is set once the settings of Deckle's AppKit versions were
	// read.
	Migrated bool `json:"migrated,omitempty"`
}

// File is the settings file: preferences and state.
type File struct {
	Prefs
	State
}

// Settings is the settings, kept in a file. Its methods are safe from any
// goroutine.
type Settings struct {
	mu      sync.Mutex
	path    string
	f       File
	pending *time.Timer
	// Changed runs after the preferences change.
	changed []func()
}

// Load reads the settings at path, or starts them anew.
func Load(path string) *Settings {
	s := &Settings{path: path}
	if b, err := os.ReadFile(path); err == nil {
		json.Unmarshal(b, &s.f)
	}
	if s.f.Workspaces == nil {
		s.f.Workspaces = map[string]*Workspace{}
	}
	return s
}

// Exists reports whether a settings file was there to read.
func Exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// Path is where the settings are kept.
func (s *Settings) Path() string { return s.path }

// Prefs returns the preferences, with their defaults filled in.
func (s *Settings) Prefs() Prefs {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.f.Prefs
	if p.Theme == "" {
		p.Theme = "system"
	}
	if p.FontSize < 9 {
		p.FontSize = 15
	}
	p.FontSize = min(p.FontSize, 40)
	if p.LineHeight < 1 {
		p.LineHeight = 1.5
	}
	p.LineHeight = min(p.LineHeight, 2.4)
	if p.LineWidth < 360 {
		p.LineWidth = 760
	}
	if p.HidesMarkers == nil {
		t := true
		p.HidesMarkers = &t
	}
	return p
}

// HidesMarkers reports whether the syntax shows only around the selection.
func (p Prefs) Hides() bool { return p.HidesMarkers == nil || *p.HidesMarkers }

// SetPrefs changes the preferences.
func (s *Settings) SetPrefs(f func(p *Prefs)) {
	s.mu.Lock()
	f(&s.f.Prefs)
	changed := slices.Clone(s.changed)
	s.mu.Unlock()
	s.save()
	for _, c := range changed {
		c()
	}
}

// OnChange runs f after the preferences change.
func (s *Settings) OnChange(f func()) {
	s.mu.Lock()
	s.changed = append(s.changed, f)
	s.mu.Unlock()
}

// State changes the state with f, and saves it.
func (s *Settings) Update(f func(st *State)) {
	s.mu.Lock()
	f(&s.f.State)
	s.mu.Unlock()
	s.save()
}

// Read reads the state with f.
func (s *Settings) Read(f func(st *State)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f(&s.f.State)
}

// Workspace returns a copy of what is remembered of the workspace at dir.
func (s *Settings) Workspace(dir string) Workspace {
	s.mu.Lock()
	defer s.mu.Unlock()
	if w := s.f.Workspaces[dir]; w != nil {
		c := *w
		c.Positions = map[string]Position{}
		for k, v := range w.Positions {
			c.Positions[k] = v
		}
		return c
	}
	return Workspace{Positions: map[string]Position{}}
}

// SetWorkspace remembers w for the workspace at dir.
func (s *Settings) SetWorkspace(dir string, w Workspace) {
	s.Update(func(st *State) {
		if st.Workspaces == nil {
			st.Workspaces = map[string]*Workspace{}
		}
		st.Workspaces[dir] = &w
	})
}

// Opened records that the workspace at dir was opened.
func (s *Settings) Opened(dir string) {
	s.Update(func(st *State) {
		st.LastWorkspace = dir
		st.RecentWorkspaces = append([]string{dir}, slices.DeleteFunc(st.RecentWorkspaces, func(r string) bool { return r == dir })...)
		if len(st.RecentWorkspaces) > 12 {
			st.RecentWorkspaces = st.RecentWorkspaces[:12]
		}
	})
}

// Forget takes dir off the recent workspaces.
func (s *Settings) Forget(dir string) {
	s.Update(func(st *State) {
		st.RecentWorkspaces = slices.DeleteFunc(st.RecentWorkspaces, func(r string) bool { return r == dir })
	})
}

// Recent lists the workspaces opened before, newest first.
func (s *Settings) Recent() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.f.RecentWorkspaces)
}

// save writes the settings a moment after the last change.
func (s *Settings) save() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pending != nil {
		s.pending.Stop()
	}
	s.pending = time.AfterFunc(300*time.Millisecond, func() { s.Flush() })
}

// Flush writes the settings now.
func (s *Settings) Flush() {
	s.mu.Lock()
	if s.pending != nil {
		s.pending.Stop()
		s.pending = nil
	}
	b, err := json.MarshalIndent(s.f, "", "  ")
	s.mu.Unlock()
	if err != nil || s.path == "" {
		return
	}
	os.MkdirAll(filepath.Dir(s.path), 0o755)
	tmp := s.path + ".tmp"
	if os.WriteFile(tmp, b, 0o644) == nil {
		os.Rename(tmp, s.path)
	}
}

// Replace sets the whole file, as a migration does.
func (s *Settings) Replace(f File) {
	s.mu.Lock()
	s.f = f
	if s.f.Workspaces == nil {
		s.f.Workspaces = map[string]*Workspace{}
	}
	s.mu.Unlock()
	s.save()
}
