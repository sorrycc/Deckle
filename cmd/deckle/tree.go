package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"

	"deckle/internal/editor"
	"deckle/internal/theme"
	"deckle/internal/workspace"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"
)

// tree is the sidebar: the workspace, its starred files and its folders
// and files, read as they are opened.
type tree struct {
	w        *window
	expanded map[string]bool
	children map[string][]treeEntry
	// selected is the folder the list shows, or the file the editor does.
	renaming    string
	renameText  string
	focusRename bool
	scroll      ui.ScrollState
}

type treeEntry struct {
	path string
	dir  bool
}

func newTree(w *window) *tree {
	t := &tree{w: w, expanded: map[string]bool{}, children: map[string][]treeEntry{}}
	for _, p := range w.state.Expanded {
		t.expanded[p] = true
	}
	return t
}

func (t *tree) expandedPaths() []string {
	var out []string
	for p, on := range t.expanded {
		if on {
			out = append(out, p)
		}
	}
	slices.Sort(out)
	return out
}

// entries are the folders and files of dir, folders first, each sorted as
// a person reads names.
func (t *tree) entries(dir string) []treeEntry {
	if e, ok := t.children[dir]; ok {
		return e
	}
	folders, files := workspace.Folders(dir)
	cmp := func(a, b string) int { return workspace.NaturalCompare(filepath.Base(a), filepath.Base(b)) }
	slices.SortFunc(folders, cmp)
	slices.SortFunc(files, cmp)
	var out []treeEntry
	for _, f := range folders {
		out = append(out, treeEntry{f, true})
	}
	for _, f := range files {
		out = append(out, treeEntry{f, false})
	}
	t.children[dir] = out
	return out
}

// folderChanged forgets what it read of a folder that changed.
func (t *tree) folderChanged(dir string) {
	delete(t.children, dir)
	if r := realPath(dir); r != dir {
		delete(t.children, r)
	}
	for k := range t.children {
		if realPath(k) == realPath(dir) {
			delete(t.children, k)
		}
	}
	// Stars of files that went go with them.
	kept := slices.DeleteFunc(slices.Clone(t.w.state.Starred), func(p string) bool {
		_, err := os.Stat(p)
		return err != nil
	})
	if len(kept) != len(t.w.state.Starred) {
		t.w.state.Starred = kept
		t.w.saveSession()
	}
}

func (t *tree) reloadAll() { clear(t.children) }

// reveal opens the folders that hold path, so the tree shows the note
// the editor does.
func (t *tree) reveal(path string) {
	root := t.w.root
	for dir := filepath.Dir(path); len(dir) > len(root) && strings.HasPrefix(dir, root+string(filepath.Separator)); dir = filepath.Dir(dir) {
		t.expanded[dir] = true
	}
}

func (t *tree) view(c *ui.Context, th theme.Theme) {
	w := t.w
	bar := c.TitleBar()
	ui.Column(c.Key("sidebar")).Fill().Padding(8).Background(th.Background).Children(func() {
		ui.Column(c.Key("sidebar-panel")).Fill().Radius(12).Background(th.Panel).Border(1, th.Border).Children(func() {
			ui.Row(c.Key("sidebar-top")).Height(titleBarHeight()-8).Padding(0, 8, 0, max(bar.Left, 8)+4).AlignItems(ui.Center).DragWindow().Children(func() {
				ui.Box(c).Grow(1)
				if iconButton(c, "hide-sidebar", iconSidebar, "Hide Sidebar", th).Clicked() {
					w.state.SidebarHidden = true
				}
			})
			ui.Scroll(c.Key("tree")).Grow(1).Padding(4, 6).Children(func() {
				ui.Column(c).Gap(1).Children(func() {
					t.row(c, th, w.root, true, 0, true)
					if len(w.state.Starred) > 0 {
						ui.Text(c, "Starred").FontSize(11).Bold().TextColor(th.Secondary).Padding(10, 10, 4, 10)
						for _, p := range w.state.Starred {
							t.row(c, th, p, false, 0, false)
						}
						ui.Box(c).Height(8)
					}
					for _, e := range t.entries(w.root) {
						t.node(c, th, e, 0)
					}
				})
			})
			t.switcher(c, th)
		})
	})
}

func (t *tree) node(c *ui.Context, th theme.Theme, e treeEntry, depth int) {
	t.row(c, th, e.path, e.dir, depth, false)
	if e.dir && t.expanded[e.path] {
		for _, ch := range t.entries(e.path) {
			t.node(c, th, ch, depth+1)
		}
	}
}

// row is a row of the tree: a folder that lists its notes when chosen, or
// a file that opens.
func (t *tree) row(c *ui.Context, th theme.Theme, path string, dir bool, depth int, isRoot bool) {
	w := t.w
	key := path
	if !isRoot && slices.Contains(w.state.Starred, path) && depth == 0 && !dir && filepath.Dir(path) != w.root {
		key = "star:" + path
	}
	selected := false
	if dir {
		selected = w.list.folder == path || (isRoot && w.list.folder == "")
	} else if cur := w.tab(); cur != nil {
		selected = cur.path == path
	}
	r := ui.Row(c.Key(key)).Height(28).Padding(0, 8, 0, 6+float32(depth)*16).Gap(6).Radius(7).AlignItems(ui.Center).Cursor(ui.CursorDefault)
	// The note open is marked in the accent; the folder the list shows,
	// which is often an ancestor of it, more quietly.
	switch {
	case selected && !dir:
		r.Background(th.Accent.Alpha(0.16))
	case selected:
		r.Background(th.Text.Alpha(0.07))
	case r.Hovered():
		r.Background(th.Text.Alpha(0.045))
	}
	name := filepath.Base(path)
	if isRoot {
		name = "All Notes"
	} else if !dir && workspace.IsMarkdown(path) {
		name = strings.TrimSuffix(name, filepath.Ext(name))
	}
	if r.Clicked() {
		switch {
		case dir:
			if isRoot {
				w.list.show("")
			} else {
				w.list.show(path)
			}
		default:
			w.open(path, openOptions{focus: false})
		}
	}
	if r.DoubleClicked() && !dir {
		w.open(path, openOptions{newTab: true, focus: true})
	}
	r.ContextMenu(func(m *ui.Menu) { t.menu(m, path, dir, isRoot) })
	if !isRoot {
		if data, err := transfer.FileData(path); err == nil {
			r.DragData(data)
		}
	}
	if dir {
		opts := transfer.DropOptions{Formats: []transfer.Format{transfer.FileList}}
		if _, over := ui.DataDragOver(r, opts); over {
			r.Background(th.Accent.Alpha(0.22))
		}
		if drop, ok := ui.DropData(r, opts); ok {
			if files, err := drop.Data.Files(); err == nil {
				w.post(func() { w.dropInto(path, files) })
			}
		}
	}
	r.Children(func() {
		if dir && !isRoot {
			open := t.expanded[path]
			ch := ui.Box(c.Key("chevron")).Size(14, 14).Center()
			if ch.Clicked() {
				t.expanded[path] = !open
			}
			ch.Children(func() {
				ic := ui.Icon(c, iconChevron).FontSize(11).TextColor(th.Secondary)
				if !open {
					ic.Rotate(-90)
				}
			})
		} else if !isRoot {
			ui.Box(c).Width(14)
		}
		ic := iconNote
		switch {
		case isRoot:
			ic = iconLibrary
		case dir:
			ic = iconFolder
		case key != path:
			ic = iconStar
		case editor.IsImage(path):
			ic = iconImage
		case !workspace.IsMarkdown(path):
			ic = iconFile
		}
		color := th.Secondary
		if selected || isRoot {
			color = th.Accent
		}
		ui.Icon(c, ic).FontSize(15).TextColor(color)
		if t.renaming == path {
			in := ui.TextInput(c.Key("rename"), &t.renameText).Grow(1).FontSize(13)
			if t.focusRename {
				in.Focus()
				t.focusRename = false
			}
			if in.Submitted() {
				t.finishRename()
			}
			if in.Shortcut(0, ui.KeyEscape) || (!in.Focused() && !t.focusRename) {
				if !in.Focused() {
					t.finishRename()
				} else {
					t.renaming = ""
				}
			}
			return
		}
		label := ui.Text(c, name).SingleLine().FontSize(13).Grow(1).TextColor(th.Text)
		if selected {
			label.FontWeight(600)
		}
	})
}

func (t *tree) menu(m *ui.Menu, path string, dir, isRoot bool) {
	w := t.w
	folder := path
	if !dir {
		folder = filepath.Dir(path)
	}
	if m.Item("New Note").Chosen() {
		w.post(func() { w.createNote(folder, "Untitled", "", true) })
	}
	if m.Item("New Folder").Chosen() {
		w.post(func() {
			p := freeName(folder, "New Folder", "")
			if os.Mkdir(p, 0o755) == nil {
				t.expanded[folder] = true
				t.folderChanged(folder)
				t.startRename(p)
			}
		})
	}
	m.Separator()
	if !dir {
		if m.Item("Open in New Tab").Chosen() {
			w.open(path, openOptions{newTab: true, focus: true})
		}
		starred := slices.Contains(w.state.Starred, path)
		label := "Star"
		if starred {
			label = "Remove Star"
		}
		if m.Item(label).Chosen() {
			if starred {
				w.state.Starred = slices.DeleteFunc(w.state.Starred, func(p string) bool { return p == path })
			} else {
				w.state.Starred = append(w.state.Starred, path)
			}
			w.saveSession()
		}
	}
	if !isRoot && m.Item("Rename…").Chosen() {
		t.startRename(path)
	}
	if m.Item("Reveal in Finder").Chosen() {
		revealInFinder(path)
	}
	if !isRoot {
		m.Separator()
		if m.Item("Move to Trash").Chosen() {
			w.post(func() { w.trash(path) })
		}
	}
}

func (t *tree) startRename(path string) {
	t.renaming = path
	name := filepath.Base(path)
	if workspace.IsMarkdown(path) {
		name = strings.TrimSuffix(name, filepath.Ext(name))
	}
	t.renameText = name
	t.focusRename = true
}

// finishRename renames the file to what was typed; a note keeps its
// extension.
func (t *tree) finishRename() {
	path := t.renaming
	t.renaming = ""
	name := strings.TrimSpace(t.renameText)
	if path == "" || name == "" || strings.ContainsRune(name, filepath.Separator) {
		return
	}
	if st, err := os.Stat(path); err == nil && !st.IsDir() && workspace.IsMarkdown(path) && filepath.Ext(name) == "" {
		name += filepath.Ext(path)
	}
	target := filepath.Join(filepath.Dir(path), name)
	if target == path {
		return
	}
	if _, err := os.Stat(target); err == nil && !strings.EqualFold(target, path) {
		go mygo.Dialog.Message(mygo.MessageOptions{Parent: t.w.w, Type: mygo.MessageWarning, Message: "“" + name + "” is already taken.", Detail: "Choose another name."})
		return
	}
	if err := os.Rename(path, target); err != nil {
		go mygo.Dialog.Message(mygo.MessageOptions{Parent: t.w.w, Type: mygo.MessageWarning, Message: "The file can't be renamed.", Detail: err.Error()})
		return
	}
	t.w.moved(path, target)
}

// switcher is the menu at the bottom of the sidebar that shows another
// workspace in the window.
func (t *tree) switcher(c *ui.Context, th theme.Theme) {
	w := t.w
	ui.Column(c.Key("switcher-row")).Padding(6).BorderWidth(1, 0, 0, 0).BorderColor(th.Border).Children(func() {
		b := ui.ButtonBase(c.Key("switcher")).Label("Workspace").Height(40).Padding(0, 8).Radius(8).FocusRing(false)
		if b.Hovered() || b.Pressed() {
			b.Background(th.Text.Alpha(0.06))
		}
		b.Menu(func(m *ui.Menu) {
			for _, dir := range w.a.s.Recent() {
				if dir == w.root {
					continue
				}
				d := dir
				if m.Item(shortenHome(d)).Chosen() {
					w.a.switchWorkspace(w, d)
				}
			}
			m.Separator()
			if m.Item("Open Folder…").Chosen() {
				w.a.chooseWorkspace(w.w, w)
			}
		})
		b.Children(func() {
			ui.Row(c).Fill().Gap(9).AlignItems(ui.Center).Children(func() {
				// The workspace's initial on a tile of the accent.
				ui.Box(c).Size(24, 24).Radius(6).Center().Background(th.Accent).Children(func() {
					ui.Text(c, initial(w.name)).FontSize(12).Bold().TextColor(th.OnAccent())
				})
				ui.Column(c).Grow(1).MinWidth(0).Children(func() {
					ui.Text(c, w.name).FontSize(12.5).Bold().SingleLine().TextColor(th.Text)
					ui.Text(c, shortenHome(filepath.Dir(w.root))).FontSize(10.5).SingleLine().TextColor(th.Secondary)
				})
				ui.Icon(c, iconUpDown).FontSize(13).TextColor(th.Secondary)
			})
		})
	})
}

// initial is the first letter of a name, as a capital.
func initial(name string) string {
	for _, r := range name {
		return strings.ToUpper(string(r))
	}
	return "?"
}

func shortenHome(p string) string {
	if home, err := os.UserHomeDir(); err == nil && strings.HasPrefix(p, home+string(filepath.Separator)) {
		return "~" + p[len(home):]
	}
	return p
}

// createNote makes a note in folder, and opens it with its name to type.
func (w *window) createNote(folder, name, text string, open bool) string {
	p := freeName(folder, name, "md")
	if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
		go mygo.Dialog.Message(mygo.MessageOptions{Parent: w.w, Type: mygo.MessageWarning, Message: "The note can't be created.", Detail: err.Error()})
		return ""
	}
	w.ws.Touch(p)
	w.tree.folderChanged(folder)
	if open {
		w.open(p, openOptions{focus: true})
	}
	return p
}

// newNote makes a note in the folder the list shows.
func (w *window) newNote() {
	folder := w.list.folder
	if folder == "" {
		folder = w.root
	}
	w.createNote(folder, "Untitled", "", true)
}

// trash moves a file or folder to the Trash, and closes its tabs.
func (w *window) trash(path string) {
	if err := mygo.Shell.TrashItem(path); err != nil {
		go mygo.Dialog.Message(mygo.MessageOptions{Parent: w.w, Type: mygo.MessageWarning, Message: "“" + filepath.Base(path) + "” can't be moved to the Trash.", Detail: err.Error()})
		return
	}
	for i := len(w.tabs) - 1; i >= 0; i-- {
		t := w.tabs[i]
		if t.path == path || strings.HasPrefix(t.path, path+string(filepath.Separator)) {
			t.ed = nil
			if len(w.tabs) == 1 {
				w.tabs[0] = &tab{}
			} else {
				w.tabs = slices.Delete(w.tabs, i, i+1)
				if w.sel >= len(w.tabs) {
					w.sel = len(w.tabs) - 1
				}
			}
		}
	}
	w.ws.Touch(path)
	w.tree.folderChanged(filepath.Dir(path))
	w.load(w.tab())
	w.tabChanged(false)
}

// moved takes a file or folder that moved: its tabs and stars follow.
func (w *window) moved(old, target string) {
	follow := func(p string) (string, bool) {
		if p == old {
			return target, true
		}
		if strings.HasPrefix(p, old+string(filepath.Separator)) {
			return target + p[len(old):], true
		}
		return p, false
	}
	for _, t := range w.tabs {
		if np, ok := follow(t.path); ok {
			t.path = np
			if t.ed != nil {
				t.ed.SetPath(np)
			}
		}
	}
	for i, p := range w.state.Starred {
		w.state.Starred[i], _ = follow(p)
	}
	if np, ok := follow(w.list.folder); ok {
		w.list.folder = np
	}
	if w.tree.expanded[old] {
		w.tree.expanded[target] = true
	}
	w.ws.Touch(old)
	w.ws.Touch(target)
	w.tree.folderChanged(filepath.Dir(old))
	w.tree.folderChanged(filepath.Dir(target))
	w.tabChanged(false)
}

func (w *window) closeOthers(keep int) {
	if keep < 0 || keep >= len(w.tabs) {
		return
	}
	w.saveAll()
	w.tabs = []*tab{w.tabs[keep]}
	w.sel = 0
	w.tabChanged(true)
}

func (w *window) closeAfter(i int) {
	if i < 0 || i >= len(w.tabs) {
		return
	}
	w.saveAll()
	w.tabs = w.tabs[:i+1]
	w.sel = min(w.sel, i)
	w.load(w.tab())
	w.tabChanged(true)
}

func revealInFinder(p string) { mygo.Shell.ShowItemInFolder(p) }
func openDefault(p string)    { mygo.Shell.OpenPath(p) }

// dropInto moves files dropped on a folder there, or copies them in from
// outside the workspace.
func (w *window) dropInto(folder string, files []string) {
	root := realPath(w.root) + string(filepath.Separator)
	for _, f := range files {
		if f == folder || filepath.Dir(f) == folder || strings.HasPrefix(folder, f+string(filepath.Separator)) {
			continue
		}
		target := freeName(folder, strings.TrimSuffix(filepath.Base(f), filepath.Ext(f)), strings.TrimPrefix(filepath.Ext(f), "."))
		if strings.HasPrefix(realPath(f), root) {
			if err := os.Rename(f, target); err != nil {
				go mygo.Dialog.Message(mygo.MessageOptions{Parent: w.w, Type: mygo.MessageWarning, Message: "“" + filepath.Base(f) + "” can't be moved.", Detail: err.Error()})
				continue
			}
			w.moved(f, target)
		} else if err := copyPath(f, target); err != nil {
			go mygo.Dialog.Message(mygo.MessageOptions{Parent: w.w, Type: mygo.MessageWarning, Message: "“" + filepath.Base(f) + "” can't be copied.", Detail: err.Error()})
		} else {
			w.ws.Touch(target)
			w.tree.folderChanged(folder)
		}
	}
	w.tree.expanded[folder] = true
}

// copyPath copies a file, or a folder and what it holds.
func copyPath(from, to string) error {
	st, err := os.Stat(from)
	if err != nil {
		return err
	}
	if !st.IsDir() {
		data, err := os.ReadFile(from)
		if err != nil {
			return err
		}
		return os.WriteFile(to, data, st.Mode().Perm())
	}
	if err := os.MkdirAll(to, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(from)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if err := copyPath(filepath.Join(from, e.Name()), filepath.Join(to, e.Name())); err != nil {
			return err
		}
	}
	return nil
}
