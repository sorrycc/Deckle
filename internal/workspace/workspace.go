// Package workspace is a folder of notes. A background scan indexes its
// files, a watcher keeps the index current, and queries for the note list,
// quick open, full-text search and links read from it.
package workspace

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"deckle/internal/markdown"

	"github.com/egoist/mygo"
)

// EventKind says what changed.
type EventKind int

const (
	// EventIndex: the index finished a scan or took in changes, and lists
	// of notes are stale.
	EventIndex EventKind = iota
	// EventFolder: the contents of the folder at Path changed.
	EventFolder
	// EventFile: the file at Path was written.
	EventFile
)

// An Event is a change the workspace saw.
type Event struct {
	Kind EventKind
	Path string
}

// A Note is what the note list and the link index read from a note.
type Note struct {
	Title   string
	Excerpt string
	// Image is the note's first image, as an absolute path.
	Image    string
	Modified time.Time
	// Links are the targets of its wikilinks, lowercased.
	Links []string
}

type index struct {
	// files are every file, by absolute path, sorted.
	files []string
	set   map[string]bool
	notes map[string]*Note
	// names are files by lowercased name, and by name without extension.
	names map[string][]string
}

func newIndex() *index {
	return &index{set: map[string]bool{}, notes: map[string]*Note{}, names: map[string][]string{}}
}

func (x *index) add(path string, note *Note) {
	if !x.set[path] {
		x.set[path] = true
		i, _ := slices.BinarySearch(x.files, path)
		x.files = slices.Insert(x.files, i, path)
		for _, k := range nameKeys(path) {
			x.names[k] = append(x.names[k], path)
		}
	}
	if note != nil {
		x.notes[path] = note
	} else {
		delete(x.notes, path)
	}
}

// addAll adds many files at once, faster than one at a time.
func (x *index) addAll(paths []string) {
	for _, p := range paths {
		if x.set[p] {
			continue
		}
		x.set[p] = true
		x.files = append(x.files, p)
		for _, k := range nameKeys(p) {
			x.names[k] = append(x.names[k], p)
		}
	}
	slices.Sort(x.files)
}

func (x *index) remove(path string) {
	if x.set[path] {
		delete(x.set, path)
		if i, ok := slices.BinarySearch(x.files, path); ok {
			x.files = slices.Delete(x.files, i, i+1)
		}
		for _, k := range nameKeys(path) {
			paths := slices.DeleteFunc(x.names[k], func(p string) bool { return p == path })
			if len(paths) == 0 {
				delete(x.names, k)
			} else {
				x.names[k] = paths
			}
		}
	}
	delete(x.notes, path)
}

func nameKeys(path string) []string {
	name := strings.ToLower(filepath.Base(path))
	keys := []string{name}
	if stem := strings.TrimSuffix(name, strings.ToLower(filepath.Ext(name))); stem != name && stem != "" {
		keys = append(keys, stem)
	}
	return keys
}

// A Workspace is an open folder of notes. Its methods are safe from any
// goroutine.
type Workspace struct {
	root    string
	mu      sync.RWMutex
	idx     *index
	onEvent func(Event)
	closed  atomic.Bool
	search  atomic.Uint64
	ctx     context.Context
	cancel  context.CancelFunc
}

// IsMarkdown reports whether path is a note.
func IsMarkdown(path string) bool {
	return markdown.LanguageForExtension(strings.TrimPrefix(filepath.Ext(path), ".")) == "markdown"
}

// IsIgnored reports whether a file or folder name is left out: hidden
// files and the folders of tools, which are not part of the notes.
func IsIgnored(name string) bool {
	return strings.HasPrefix(name, ".") || name == "node_modules"
}

func (w *Workspace) isIgnoredPath(path string) bool {
	rel, err := filepath.Rel(w.root, path)
	if err != nil || strings.HasPrefix(rel, "..") {
		return true
	}
	for _, c := range strings.Split(rel, string(filepath.Separator)) {
		if c != "." && IsIgnored(c) {
			return true
		}
	}
	return false
}

func readNote(path string) *Note {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	n := extract(string(b), path)
	if st, err := os.Stat(path); err == nil {
		n.Modified = st.ModTime()
	}
	return n
}

// Open opens the folder at root as a workspace and starts indexing and
// watching it. onEvent runs on a goroutine of the workspace.
func Open(root string, onEvent func(Event)) *Workspace {
	// The watcher reports real paths, so the index holds them too.
	if real, err := filepath.EvalSymlinks(root); err == nil {
		root = real
	}
	if abs, err := filepath.Abs(root); err == nil {
		root = abs
	}
	ctx, cancel := context.WithCancel(context.Background())
	w := &Workspace{root: root, idx: newIndex(), onEvent: onEvent, ctx: ctx, cancel: cancel}
	go w.scan()
	go w.watch()
	return w
}

// Close stops the workspace's scan, watch and searches.
func (w *Workspace) Close() {
	w.closed.Store(true)
	w.search.Add(1)
	w.cancel()
}

// Root is the workspace's folder with links resolved.
func (w *Workspace) Root() string { return w.root }

func (w *Workspace) emit(kind EventKind, path string) {
	if !w.closed.Load() && w.onEvent != nil {
		w.onEvent(Event{kind, path})
	}
}

func walk(dir string, closed *atomic.Bool) []string {
	var files []string
	stack := []string{dir}
	for len(stack) > 0 {
		if closed != nil && closed.Load() {
			return nil
		}
		d := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		entries, err := os.ReadDir(d)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if IsIgnored(e.Name()) {
				continue
			}
			// A link to a folder is listed, not followed: it may loop back.
			switch t := e.Type(); {
			case t.IsDir():
				stack = append(stack, filepath.Join(d, e.Name()))
			case t.IsRegular():
				files = append(files, filepath.Join(d, e.Name()))
			}
		}
	}
	return files
}

func (w *Workspace) scan() {
	files := walk(w.root, &w.closed)
	if w.closed.Load() {
		return
	}
	// File names first, so quick open works while the notes are read.
	w.mu.Lock()
	w.idx.addAll(files)
	w.mu.Unlock()
	w.emit(EventIndex, w.root)

	var notes []string
	for _, f := range files {
		if IsMarkdown(f) {
			notes = append(notes, f)
		}
	}
	workers := min(runtime.NumCPU(), 8)
	chunk := max((len(notes)+workers-1)/workers, 1)
	var wg sync.WaitGroup
	for start := 0; start < len(notes); start += chunk {
		part := notes[start:min(start+chunk, len(notes))]
		wg.Go(func() {
			type read struct {
				path string
				note *Note
			}
			batch := make([]read, 0, 256)
			flush := func() {
				w.mu.Lock()
				for _, r := range batch {
					w.idx.add(r.path, r.note)
				}
				w.mu.Unlock()
				batch = batch[:0]
			}
			for _, p := range part {
				if w.closed.Load() {
					return
				}
				if n := readNote(p); n != nil {
					batch = append(batch, read{p, n})
				}
				if len(batch) == 256 {
					flush()
				}
			}
			flush()
		})
	}
	wg.Wait()
	w.emit(EventIndex, w.root)
}

func (w *Workspace) watch() {
	for !w.closed.Load() {
		fw, err := mygo.WatchFiles(w.ctx, w.root, mygo.FileWatchOptions{
			Recursive: true,
			Ignore: func(path string, isDir bool) bool {
				for _, c := range strings.Split(path, "/") {
					if c != "." && IsIgnored(c) {
						return true
					}
				}
				return false
			},
			Debounce:   120 * time.Millisecond,
			MaxEntries: 1 << 21,
		})
		if err != nil {
			return
		}
		for {
			events, err := fw.Next(w.ctx)
			if err != nil {
				fw.Close()
				break
			}
			paths := map[string]bool{}
			for _, e := range events {
				paths[filepath.Join(w.root, filepath.FromSlash(e.Path))] = true
				if e.OldPath != "" {
					paths[filepath.Join(w.root, filepath.FromSlash(e.OldPath))] = true
				}
			}
			w.refresh(paths)
		}
		if w.closed.Load() {
			return
		}
		// The watch overflowed or lost its folder: read everything again.
		time.Sleep(time.Second)
		w.Rescan()
	}
}

// Rescan reads the folder again and takes in what differs.
func (w *Workspace) Rescan() {
	files := walk(w.root, &w.closed)
	seen := map[string]bool{}
	paths := map[string]bool{}
	for _, f := range files {
		seen[f] = true
	}
	w.mu.RLock()
	for _, f := range w.idx.files {
		if !seen[f] {
			paths[f] = true
		}
	}
	for _, f := range files {
		if !w.idx.set[f] {
			paths[f] = true
		} else if n := w.idx.notes[f]; n != nil {
			if st, err := os.Stat(f); err == nil && !st.ModTime().Equal(n.Modified) {
				paths[f] = true
			}
		}
	}
	w.mu.RUnlock()
	if len(paths) > 0 {
		w.refresh(paths)
	}
}

// refresh takes in what the watcher saw at paths.
func (w *Workspace) refresh(paths map[string]bool) {
	folders := map[string]bool{}
	var written []string
	sorted := make([]string, 0, len(paths))
	for p := range paths {
		sorted = append(sorted, p)
	}
	slices.Sort(sorted)
	for _, path := range sorted {
		if w.isIgnoredPath(path) {
			continue
		}
		w.mu.RLock()
		known := w.idx.set[path]
		w.mu.RUnlock()
		st, err := os.Stat(path)
		switch {
		case err == nil && st.Mode().IsRegular():
			var note *Note
			if IsMarkdown(path) {
				note = readNote(path)
			}
			w.mu.Lock()
			w.idx.add(path, note)
			w.mu.Unlock()
			if known {
				written = append(written, path)
			} else {
				folders[filepath.Dir(path)] = true
			}
		case err == nil && st.IsDir():
			// A folder that appeared, perhaps moved in with files.
			for _, f := range walk(path, nil) {
				w.mu.RLock()
				has := w.idx.set[f]
				w.mu.RUnlock()
				if !has {
					var note *Note
					if IsMarkdown(f) {
						note = readNote(f)
					}
					w.mu.Lock()
					w.idx.add(f, note)
					w.mu.Unlock()
				}
			}
			folders[path] = true
			folders[filepath.Dir(path)] = true
		default:
			// Gone: the file, or a folder and everything in it.
			w.mu.Lock()
			i, _ := slices.BinarySearch(w.idx.files, path)
			var inside []string
			for ; i < len(w.idx.files); i++ {
				f := w.idx.files[i]
				if f != path && !strings.HasPrefix(f, path+string(filepath.Separator)) {
					break
				}
				inside = append(inside, f)
			}
			for _, f := range inside {
				w.idx.remove(f)
			}
			w.mu.Unlock()
			folders[filepath.Dir(path)] = true
		}
	}
	for f := range folders {
		w.emit(EventFolder, f)
	}
	for _, f := range written {
		w.emit(EventFile, f)
	}
	if len(folders) > 0 || len(written) > 0 {
		w.emit(EventIndex, w.root)
	}
}

// Touch reads the file at path again now, as after the app saved it, so
// lists and links are current without waiting for the watcher.
func (w *Workspace) Touch(path string) {
	w.refresh(map[string]bool{path: true})
}

// HasFiles reports whether the scan has listed the folder's files.
func (w *Workspace) FileCount() int {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return len(w.idx.files)
}

// Note is what the index read from the note at path.
func (w *Workspace) Note(path string) (Note, bool) {
	w.mu.RLock()
	defer w.mu.RUnlock()
	n := w.idx.notes[path]
	if n == nil {
		return Note{}, false
	}
	return *n, true
}

// ListNotes lists the notes under dir, newest first or by title.
func (w *Workspace) ListNotes(dir string, byTitle bool) []string {
	if real, err := filepath.EvalSymlinks(dir); err == nil {
		dir = real
	}
	w.mu.RLock()
	defer w.mu.RUnlock()
	prefix := strings.TrimSuffix(dir, string(filepath.Separator)) + string(filepath.Separator)
	type entry struct {
		path string
		note *Note
	}
	var notes []entry
	for p, n := range w.idx.notes {
		if strings.HasPrefix(p, prefix) {
			notes = append(notes, entry{p, n})
		}
	}
	if byTitle {
		slices.SortFunc(notes, func(a, b entry) int {
			if c := NaturalCompare(a.note.Title, b.note.Title); c != 0 {
				return c
			}
			return strings.Compare(a.path, b.path)
		})
	} else {
		slices.SortFunc(notes, func(a, b entry) int {
			if c := b.note.Modified.Compare(a.note.Modified); c != 0 {
				return c
			}
			return strings.Compare(a.path, b.path)
		})
	}
	out := make([]string, len(notes))
	for i, e := range notes {
		out[i] = e.path
	}
	return out
}

// Folders lists the folders under dir, for the file tree.
func Folders(dir string) (folders, files []string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil
	}
	for _, e := range entries {
		if IsIgnored(e.Name()) {
			continue
		}
		p := filepath.Join(dir, e.Name())
		if e.IsDir() {
			folders = append(folders, p)
		} else if e.Type().IsRegular() {
			files = append(files, p)
		}
	}
	return
}

// A FileMatch is a file quick open found.
type FileMatch struct {
	Path, Rel, Title string
	// Indices are the byte offsets in Rel of the characters matched.
	Indices []int
	IsNote  bool
}

// FindFiles finds the files whose path or title matches query loosely,
// best first. With no query, the notes changed last.
func (w *Workspace) FindFiles(query string, limit int, notesOnly bool) []FileMatch {
	w.mu.RLock()
	defer w.mu.RUnlock()
	rel := func(p string) string {
		r, err := filepath.Rel(w.root, p)
		if err != nil {
			return p
		}
		return filepath.ToSlash(r)
	}
	row := func(p string, indices []int) FileMatch {
		m := FileMatch{Path: p, Rel: rel(p), Indices: indices}
		if n := w.idx.notes[p]; n != nil {
			m.Title, m.IsNote = n.Title, true
		}
		return m
	}
	if strings.TrimSpace(query) == "" {
		type e struct {
			p string
			n *Note
		}
		var notes []e
		for p, n := range w.idx.notes {
			notes = append(notes, e{p, n})
		}
		slices.SortFunc(notes, func(a, b e) int {
			if c := b.n.Modified.Compare(a.n.Modified); c != 0 {
				return c
			}
			return strings.Compare(a.p, b.p)
		})
		var out []FileMatch
		for _, n := range notes[:min(limit, len(notes))] {
			out = append(out, row(n.p, nil))
		}
		return out
	}
	q := []rune(strings.ToLower(strings.ReplaceAll(query, " ", "")))
	// The query as typed, in one piece: a title that begins with it, or
	// holds it whole, is a closer match than one with its words apart.
	whole := strings.ToLower(strings.TrimSpace(query))
	type scored struct {
		score int
		path  string
	}
	var found []scored
	pos := make([]int, len(q))
	for _, p := range w.idx.files {
		note := w.idx.notes[p]
		if notesOnly && note == nil {
			continue
		}
		best, ok := score(rel(p), q, pos)
		// A note is found by its title as well as its path: the title is
		// what the list shows, and a match there is the one meant.
		if note != nil && note.Title != "" {
			if s, tok := score(note.Title, q, pos); tok {
				title := strings.ToLower(note.Title)
				switch {
				case strings.HasPrefix(title, whole):
					s += 64
				case strings.Contains(title, whole):
					s += 40
				default:
					s += 16
				}
				if !ok || s > best {
					best, ok = s, true
				}
			}
		}
		if ok {
			if note != nil {
				// Notes before other files, at an equal match.
				best += 8
			}
			found = append(found, scored{best, p})
		}
	}
	slices.SortFunc(found, func(a, b scored) int {
		if a.score != b.score {
			return b.score - a.score
		}
		if len(a.path) != len(b.path) {
			return len(a.path) - len(b.path)
		}
		return strings.Compare(a.path, b.path)
	})
	var out []FileMatch
	for _, f := range found[:min(limit, len(found))] {
		r := rel(f.path)
		var indices []int
		if _, ok := score(r, q, pos); ok {
			indices = slices.Clone(pos)
		}
		out = append(out, row(f.path, indices))
	}
	return out
}

// ResolveLink finds the note or file a wikilink's target names, seen from
// the note at from. It is "" when there is none.
func (w *Workspace) ResolveLink(target, from string) string {
	if i := strings.IndexAny(target, "|#"); i >= 0 {
		target = target[:i]
	}
	target = strings.TrimSpace(target)
	if target == "" {
		return ""
	}
	fromDir := filepath.Dir(from)
	if from == "" {
		fromDir = w.root
	}
	for _, base := range []string{fromDir, w.root} {
		for _, c := range []string{filepath.Join(base, target), filepath.Join(base, target+".md")} {
			if st, err := os.Stat(c); err == nil && st.Mode().IsRegular() {
				return c
			}
		}
	}
	w.mu.RLock()
	defer w.mu.RUnlock()
	name := strings.ToLower(target[strings.LastIndexByte(target, '/')+1:])
	paths := w.idx.names[name]
	suffix := strings.ToLower(target)
	best, rank := "", 0
	for _, p := range paths {
		relp, _ := filepath.Rel(w.root, p)
		relLower := strings.ToLower(strings.TrimSuffix(filepath.ToSlash(relp), filepath.Ext(relp)))
		// A target with folders must match them.
		if strings.Contains(target, "/") && !strings.HasSuffix(relLower, suffix) && !strings.HasSuffix(strings.ToLower(p), suffix) {
			continue
		}
		r := 1
		if IsMarkdown(p) {
			r += 2
		}
		if filepath.Dir(p) == fromDir {
			r += 4
		}
		if r > rank {
			best, rank = p, r
		}
	}
	return best
}

func (w *Workspace) linkKeys(path string) ([]string, string) {
	keys := nameKeys(path)
	rel, err := filepath.Rel(w.root, path)
	if err != nil {
		rel = path
	}
	rel = strings.ToLower(strings.TrimSuffix(filepath.ToSlash(rel), filepath.Ext(rel)))
	return keys, rel
}

// linksTo reports whether a wikilink's lowercased target names the note
// with name keys and workspace-relative path rel: by name, by path, or by
// a path's tail.
func linksTo(keys []string, rel, target string) bool {
	return slices.Contains(keys, target) || rel == target ||
		(len(rel) > len(target) && strings.HasSuffix(rel, target) && rel[len(rel)-len(target)-1] == '/')
}

// BacklinkCount is how many notes link to the note at path, from the index
// alone.
func (w *Workspace) BacklinkCount(path string) int {
	keys, rel := w.linkKeys(path)
	w.mu.RLock()
	defer w.mu.RUnlock()
	n := 0
	for p, note := range w.idx.notes {
		if p != path && slices.ContainsFunc(note.Links, func(l string) bool { return linksTo(keys, rel, l) }) {
			n++
		}
	}
	return n
}

// A Backlink is a note that links to another, with the lines that do.
type Backlink struct {
	Path, Title string
	Lines       []BacklinkLine
}

// A BacklinkLine is a line that links, as it reads.
type BacklinkLine struct {
	Line int
	Text string
	// Offset is where the line starts in the note, in UTF-16 units.
	Offset int
}

// Backlinks lists the notes that link to the note at path.
func (w *Workspace) Backlinks(path string) []Backlink {
	keys, rel := w.linkKeys(path)
	type src struct{ path, title string }
	var sources []src
	w.mu.RLock()
	for p, note := range w.idx.notes {
		if p != path && slices.ContainsFunc(note.Links, func(l string) bool { return linksTo(keys, rel, l) }) {
			sources = append(sources, src{p, note.Title})
		}
	}
	w.mu.RUnlock()
	slices.SortFunc(sources, func(a, b src) int { return strings.Compare(a.path, b.path) })
	var out []Backlink
	for _, s := range sources[:min(200, len(sources))] {
		b, err := os.ReadFile(s.path)
		if err != nil {
			continue
		}
		bl := Backlink{Path: s.path, Title: s.title}
		offset := 0
		for n, line := range strings.Split(string(b), "\n") {
			var targets []string
			linksIn(line, &targets)
			if slices.ContainsFunc(targets, func(l string) bool { return linksTo(keys, rel, l) }) {
				shown := []rune(plain(stripBlockPrefix(line)))
				bl.Lines = append(bl.Lines, BacklinkLine{Line: n + 1, Text: string(shown[:min(160, len(shown))]), Offset: offset})
			}
			offset += markdown.UnitsOf(line) + 1
			if len(bl.Lines) >= 5 {
				break
			}
		}
		out = append(out, bl)
	}
	return out
}
