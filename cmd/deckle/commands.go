package main

import (
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"

	"deckle/internal/settings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

type settingsPrefs = settings.Prefs

// command is a command of the menus and the palette: what it runs, by id,
// in the window in front.
type command struct {
	id, title, accel, menu string
	// hidden keeps it out of the menus, its shortcut still working.
	hidden bool
	keys   string
}

// commands are the window's commands, in the order the menus list them.
var commands = []command{
	{id: "newNote", title: "New Note", accel: "CmdOrCtrl+N", menu: "File"},
	{id: "newTab", title: "New Tab", accel: "CmdOrCtrl+T", menu: "File"},
	{id: "newWindow", title: "New Window", accel: "CmdOrCtrl+Shift+N", menu: "File"},
	{id: "open", title: "Open…", accel: "CmdOrCtrl+O", menu: "File"},
	{id: "recent", title: "Open Recent", menu: "File"},
	{id: "quickOpen", title: "Quick Open…", accel: "CmdOrCtrl+P", menu: "File"},
	{id: "-", menu: "File"},
	{id: "closeTab", title: "Close Tab", accel: "CmdOrCtrl+W", menu: "File"},
	{id: "closeWindow", title: "Close Window", accel: "CmdOrCtrl+Shift+W", menu: "File"},
	{id: "reopenTab", title: "Reopen Closed Tab", accel: "CmdOrCtrl+Shift+T", menu: "File"},
	{id: "save", title: "Save", accel: "CmdOrCtrl+S", menu: "File"},
	{id: "-", menu: "File"},
	{id: "reveal", title: "Reveal in Finder", accel: "CmdOrCtrl+Alt+R", menu: "File"},
	{id: "trash", title: "Move to Trash", accel: "CmdOrCtrl+Backspace", menu: "File"},
	{id: "-", menu: "File"},
	{id: "exportPDF", title: "Export as PDF…", menu: "File"},
	{id: "print", title: "Print…", accel: "CmdOrCtrl+Alt+P", menu: "File"},

	{id: "find", title: "Find…", accel: "CmdOrCtrl+F", menu: "Find"},
	{id: "replace", title: "Find and Replace…", accel: "CmdOrCtrl+Alt+F", menu: "Find"},
	{id: "findNext", title: "Find Next", accel: "CmdOrCtrl+G", menu: "Find"},
	{id: "findPrevious", title: "Find Previous", accel: "CmdOrCtrl+Shift+G", menu: "Find"},
	{id: "useSelectionForFind", title: "Use Selection for Find", accel: "CmdOrCtrl+E", menu: "Find"},
	{id: "jumpToSelection", title: "Jump to Selection", accel: "CmdOrCtrl+J", menu: "Find"},

	{id: "toggleBold", title: "Bold", accel: "CmdOrCtrl+B", menu: "Format"},
	{id: "toggleItalic", title: "Italic", accel: "CmdOrCtrl+I", menu: "Format"},
	{id: "toggleStrikethrough", title: "Strikethrough", accel: "CmdOrCtrl+Shift+X", menu: "Format"},
	{id: "toggleHighlight", title: "Highlight", accel: "CmdOrCtrl+Shift+H", menu: "Format"},
	{id: "toggleInlineCode", title: "Code", accel: "CmdOrCtrl+Shift+E", menu: "Format"},
	{id: "insertLink", title: "Link", accel: "CmdOrCtrl+K", menu: "Format"},
	{id: "-", menu: "Format"},
	{id: "heading1", title: "Heading 1", accel: "CmdOrCtrl+Alt+1", menu: "Format"},
	{id: "heading2", title: "Heading 2", accel: "CmdOrCtrl+Alt+2", menu: "Format"},
	{id: "heading3", title: "Heading 3", accel: "CmdOrCtrl+Alt+3", menu: "Format"},
	{id: "heading4", title: "Heading 4", accel: "CmdOrCtrl+Alt+4", menu: "Format"},
	{id: "heading5", title: "Heading 5", accel: "CmdOrCtrl+Alt+5", menu: "Format"},
	{id: "heading6", title: "Heading 6", accel: "CmdOrCtrl+Alt+6", menu: "Format"},
	{id: "heading0", title: "Body", accel: "CmdOrCtrl+Alt+0", menu: "Format"},
	{id: "-", menu: "Format"},
	{id: "toggleBulletList", title: "Bulleted List", accel: "CmdOrCtrl+Shift+8", menu: "Format"},
	{id: "toggleNumberedList", title: "Numbered List", accel: "CmdOrCtrl+Shift+7", menu: "Format"},
	{id: "toggleTaskList", title: "Task List", accel: "CmdOrCtrl+Shift+9", menu: "Format"},
	{id: "toggleTaskDone", title: "Toggle Done", accel: "CmdOrCtrl+Enter", menu: "Format"},
	{id: "toggleQuote", title: "Quote", accel: "CmdOrCtrl+'", menu: "Format"},
	{id: "toggleCodeBlock", title: "Code Block", accel: "CmdOrCtrl+Alt+C", menu: "Format"},
	{id: "-", menu: "Format"},
	{id: "indentItems", title: "Indent", accel: "CmdOrCtrl+Alt+]", menu: "Format"},
	{id: "outdentItems", title: "Outdent", accel: "CmdOrCtrl+Alt+[", menu: "Format"},

	{id: "toggleSidebar", title: "Toggle Sidebar", accel: "CmdOrCtrl+Ctrl+S", menu: "View"},
	{id: "toggleNoteList", title: "Toggle Note List", accel: "CmdOrCtrl+Ctrl+L", menu: "View"},
	{id: "-", menu: "View"},
	{id: "searchNotes", title: "Search Notes…", accel: "CmdOrCtrl+Shift+F", menu: "View"},
	{id: "commands", title: "Commands…", accel: "CmdOrCtrl+Shift+P", menu: "View"},
	{id: "goToHeading", title: "Go to Heading…", accel: "CmdOrCtrl+Shift+O", menu: "View"},
	{id: "backlinks", title: "Show Backlinks", accel: "CmdOrCtrl+Shift+B", menu: "View"},
	{id: "-", menu: "View"},
	{id: "actualSize", title: "Actual Size", accel: "CmdOrCtrl+0", menu: "View"},
	{id: "zoomIn", title: "Zoom In", accel: "CmdOrCtrl+=", menu: "View"},
	{id: "zoomInPlus", title: "Zoom In", accel: "CmdOrCtrl+Plus", menu: "View", hidden: true},
	{id: "zoomOut", title: "Zoom Out", accel: "CmdOrCtrl+-", menu: "View"},

	{id: "back", title: "Back", accel: "CmdOrCtrl+[", menu: "Go"},
	{id: "forward", title: "Forward", accel: "CmdOrCtrl+]", menu: "Go"},
	{id: "-", menu: "Go"},
	{id: "focusList", title: "Note List", accel: "CmdOrCtrl+Alt+L", menu: "Go"},
	{id: "focusEditor", title: "Editor", accel: "CmdOrCtrl+Alt+E", menu: "Go"},
	{id: "-", menu: "Go"},
	{id: "nextTab", title: "Show Next Tab", accel: "Ctrl+Tab", menu: "Go"},
	{id: "previousTab", title: "Show Previous Tab", accel: "Ctrl+Shift+Tab", menu: "Go"},
	{id: "tab1", title: "Tab 1", accel: "CmdOrCtrl+1", menu: "Go", hidden: true},
	{id: "tab2", title: "Tab 2", accel: "CmdOrCtrl+2", menu: "Go", hidden: true},
	{id: "tab3", title: "Tab 3", accel: "CmdOrCtrl+3", menu: "Go", hidden: true},
	{id: "tab4", title: "Tab 4", accel: "CmdOrCtrl+4", menu: "Go", hidden: true},
	{id: "tab5", title: "Tab 5", accel: "CmdOrCtrl+5", menu: "Go", hidden: true},
	{id: "tab6", title: "Tab 6", accel: "CmdOrCtrl+6", menu: "Go", hidden: true},
	{id: "tab7", title: "Tab 7", accel: "CmdOrCtrl+7", menu: "Go", hidden: true},
	{id: "tab8", title: "Tab 8", accel: "CmdOrCtrl+8", menu: "Go", hidden: true},
	{id: "tab9", title: "Last Tab", accel: "CmdOrCtrl+9", menu: "Go", hidden: true},
}

// keysLabel is an accelerator as the palette shows it.
func keysLabel(accel string) string {
	if accel == "" {
		return ""
	}
	mac := runtime.GOOS == "darwin"
	r := strings.NewReplacer("CmdOrCtrl+", "⌘", "Ctrl+", "⌃", "Shift+", "⇧", "Alt+", "⌥", "Backspace", "⌫", "Enter", "↩", "Plus", "+", "Tab", "⇥")
	if !mac {
		return strings.NewReplacer("CmdOrCtrl+", "Ctrl+").Replace(accel)
	}
	// The modifiers in the order macOS's menus show them: ⌃⌥⇧⌘.
	parts := strings.Split(accel, "+")
	key := parts[len(parts)-1]
	if key == "" && len(parts) > 1 {
		key = "+"
		parts = parts[:len(parts)-1]
	}
	var mods string
	for _, m := range []string{"Ctrl", "Alt", "Shift", "CmdOrCtrl"} {
		if slices.Contains(parts[:len(parts)-1], m) {
			mods += m + "+"
		}
	}
	return r.Replace(mods + key)
}

// commandList is the commands the palette offers.
func (w *window) commandList() []command {
	var out []command
	for _, c := range commands {
		if c.id == "-" || c.hidden || c.id == "recent" {
			continue
		}
		c.keys = keysLabel(c.accel)
		out = append(out, c)
	}
	return append(out,
		command{id: "settings", title: "Settings…", keys: keysLabel("CmdOrCtrl+,")},
		command{id: "welcome", title: "Welcome to Deckle", keys: keysLabel("CmdOrCtrl+Shift+1")},
		command{id: "help", title: "Deckle Help"},
	)
}

// run runs a command in the window.
func (w *window) run(id string) {
	ed := w.editor()
	switch id {
	case "newNote":
		w.newNote()
	case "newTab":
		w.newTab()
	case "newWindow":
		w.a.showWelcome()
	case "open":
		w.a.chooseWorkspace(w.w, nil)
	case "quickOpen":
		w.palette.show(modeFiles, "")
	case "closeTab":
		w.closeTab(w.sel)
	case "closeWindow":
		w.w.Close()
	case "reopenTab":
		w.reopenClosedTab()
	case "save":
		if t := w.tab(); t != nil {
			w.save(t)
		}
	case "reveal":
		if t := w.tab(); t != nil && t.path != "" {
			revealInFinder(t.path)
		}
	case "trash":
		// ⌘⌫ deletes to the start of the line while the editor has the
		// keyboard; elsewhere it trashes the note shown.
		if ed != nil && ed.Focused() {
			ed.DeleteToLineStart()
			return
		}
		if t := w.tab(); t != nil && t.path != "" && !t.readOnly {
			w.trash(t.path)
		}
	case "exportPDF":
		w.exportPDF()
	case "print":
		w.print()
	case "jumpToSelection":
		if ed != nil {
			ed.RevealCentered()
		}
	case "toggleSidebar":
		w.state.SidebarHidden = !w.state.SidebarHidden
		w.saveSession()
	case "toggleNoteList":
		w.state.ListHidden = !w.state.ListHidden
		w.saveSession()
	case "searchNotes":
		a, z := 0, 0
		q := ""
		if ed != nil {
			a, z = ed.Selection()
			if z > a && z-a < 100 {
				q = ed.Buffer().Slice(a, z)
			}
		}
		w.palette.show(modeSearch, q)
	case "commands":
		w.palette.show(modeCommands, "")
	case "goToHeading":
		w.palette.show(modeHeadings, "")
	case "backlinks":
		w.palette.show(modeBacklinks, "")
	case "actualSize":
		w.a.s.SetPrefs(func(p *settings.Prefs) { p.FontSize = 15 })
	case "zoomIn", "zoomInPlus":
		if t := w.tab(); t != nil && t.image != nil {
			t.zoom = max(t.zoomOr(), 0.1) * 1.25
			return
		}
		w.a.s.SetPrefs(func(p *settings.Prefs) { p.FontSize = min(40, w.a.s.Prefs().FontSize+1) })
	case "zoomOut":
		if t := w.tab(); t != nil && t.image != nil {
			t.zoom = max(t.zoomOr()/1.25, 0.05)
			return
		}
		w.a.s.SetPrefs(func(p *settings.Prefs) { p.FontSize = max(9, w.a.s.Prefs().FontSize-1) })
	case "back":
		w.goBack(false)
	case "forward":
		w.goBack(true)
	case "focusList":
		w.state.ListHidden = false
		w.list.focus = true
	case "focusEditor":
		w.focusEditor = true
	case "nextTab":
		w.selectTab((w.sel + 1) % len(w.tabs))
	case "previousTab":
		w.selectTab((w.sel + len(w.tabs) - 1) % len(w.tabs))
	case "settings":
		w.a.showPrefs()
	case "welcome":
		w.a.showWelcome()
	case "help":
		w.a.showHelp()
	default:
		if strings.HasPrefix(id, "tab") {
			n := int(id[3] - '0')
			if n == 9 {
				n = len(w.tabs)
			}
			w.selectTab(n - 1)
			return
		}
		if ed != nil {
			ed.Run(id)
		}
	}
}

func (t *tab) zoomOr() float32 {
	if t.zoom > 0 {
		return t.zoom
	}
	return 1
}

// shortcuts are keys the window takes that no menu has.
func (w *window) shortcuts(c *ui.Context) {
	if c.Shortcut(0, ui.KeyEscape) && w.palette.open {
		w.palette.close()
	}
}

// setMenu builds the menu bar, and the Dock's menu of recent workspaces.
func (a *deckle) setMenu() {
	if !a.ready {
		return
	}
	run := func(id string) func(*mygo.MenuItem, *mygo.Window) {
		return func(_ *mygo.MenuItem, win *mygo.Window) { a.run(id, win) }
	}
	menus := map[string][]*mygo.MenuItem{}
	for _, c := range commands {
		if c.id == "-" {
			menus[c.menu] = append(menus[c.menu], mygo.Separator())
			continue
		}
		if c.id == "recent" {
			menus[c.menu] = append(menus[c.menu], &mygo.MenuItem{Label: c.title, Submenu: a.recentMenu()})
			continue
		}
		menus[c.menu] = append(menus[c.menu], &mygo.MenuItem{Label: c.title, Accelerator: c.accel, Hidden: c.hidden, Click: run(c.id)})
	}
	appItems := []*mygo.MenuItem{
		{Role: mygo.RoleAbout, Label: "About Deckle"},
	}
	if updatesAvailable() {
		appItems = append(appItems, &mygo.MenuItem{Label: "Check for Updates…", Click: func(*mygo.MenuItem, *mygo.Window) { checkForUpdates() }})
	}
	appItems = append(appItems,
		mygo.Separator(),
		&mygo.MenuItem{Label: "Settings…", Accelerator: "CmdOrCtrl+,", Click: func(*mygo.MenuItem, *mygo.Window) { a.showPrefs() }},
		mygo.Separator(),
		&mygo.MenuItem{Role: mygo.RoleServices},
		mygo.Separator(),
		&mygo.MenuItem{Role: mygo.RoleHide},
		&mygo.MenuItem{Role: mygo.RoleHideOthers},
		&mygo.MenuItem{Role: mygo.RoleUnhide},
		mygo.Separator(),
		&mygo.MenuItem{Role: mygo.RoleQuit},
	)
	edit := []*mygo.MenuItem{
		{Role: mygo.RoleUndo}, {Role: mygo.RoleRedo}, mygo.Separator(),
		{Role: mygo.RoleCut}, {Role: mygo.RoleCopy}, {Role: mygo.RolePaste}, {Role: mygo.RolePasteAndMatchStyle},
		{Role: mygo.RoleDelete}, {Role: mygo.RoleSelectAll}, mygo.Separator(),
		{Label: "Find", Submenu: menus["Find"]},
		mygo.Separator(),
		{Role: mygo.RoleStartSpeaking}, {Role: mygo.RoleStopSpeaking},
	}
	view := append(menus["View"], mygo.Separator(), &mygo.MenuItem{Role: mygo.RoleToggleFullScreen})
	win := []*mygo.MenuItem{
		{Role: mygo.RoleMinimize}, {Role: mygo.RoleZoom}, mygo.Separator(),
		{Label: "Welcome to Deckle", Accelerator: "CmdOrCtrl+Shift+1", Click: func(*mygo.MenuItem, *mygo.Window) { a.showWelcome() }},
		mygo.Separator(),
		{Role: mygo.RoleFront},
	}
	help := []*mygo.MenuItem{
		{Label: "Deckle Help", Accelerator: "CmdOrCtrl+?", Click: func(*mygo.MenuItem, *mygo.Window) { a.showHelp() }},
		{Label: "Markdown Reference", Click: func(*mygo.MenuItem, *mygo.Window) { a.showHelp() }},
	}
	mygo.App.SetMenu(mygo.NewMenu([]*mygo.MenuItem{
		{Label: "Deckle", Role: mygo.RoleAppMenu, Submenu: appItems},
		{Label: "File", Submenu: menus["File"]},
		{Label: "Edit", Submenu: edit},
		{Label: "Format", Submenu: menus["Format"]},
		{Label: "View", Submenu: view},
		{Label: "Go", Submenu: menus["Go"]},
		{Label: "Window", Role: mygo.RoleWindow, Submenu: win},
		{Label: "Help", Role: mygo.RoleHelp, Submenu: help},
	}))
	var dock []*mygo.MenuItem
	for _, dir := range a.s.Recent() {
		d := dir
		dock = append(dock, &mygo.MenuItem{Label: filepath.Base(d), ToolTip: d, Click: func(*mygo.MenuItem, *mygo.Window) { a.openWorkspace(d, true) }})
	}
	if runtime.GOOS == "darwin" {
		if len(dock) > 0 {
			mygo.App.Dock.SetMenu(mygo.NewMenu(dock))
		} else {
			mygo.App.Dock.SetMenu(nil)
		}
	}
}

func (a *deckle) recentMenu() []*mygo.MenuItem {
	var items []*mygo.MenuItem
	front := ""
	if len(a.wins) > 0 {
		front = a.wins[0].root
	}
	for _, dir := range a.s.Recent() {
		if dir == front {
			continue
		}
		d := dir
		items = append(items, &mygo.MenuItem{Label: shortenHome(d), Click: func(*mygo.MenuItem, *mygo.Window) {
			if _, err := os.Stat(d); err != nil {
				a.s.Forget(d)
				a.setMenu()
				return
			}
			a.openWorkspace(d, true)
		}})
	}
	if len(items) > 0 {
		items = append(items, mygo.Separator())
	}
	items = append(items, &mygo.MenuItem{Label: "Clear Menu", Disabled: len(items) == 0, Click: func(*mygo.MenuItem, *mygo.Window) {
		a.s.Update(func(st *settings.State) { st.RecentWorkspaces = nil })
		a.setMenu()
	}})
	return items
}

// run runs a command of the menus in the window it was chosen in, or the
// one in front.
func (a *deckle) run(id string, win *mygo.Window) {
	var target *window
	for _, w := range a.wins {
		if w.w == win {
			target = w
		}
	}
	if target == nil && len(a.wins) > 0 {
		target = a.wins[0]
	}
	switch id {
	case "open":
		a.chooseWorkspace(win, nil)
		return
	case "newWindow":
		a.showWelcome()
		return
	}
	if target == nil {
		return
	}
	w := target
	w.post(func() { w.run(id) })
}
