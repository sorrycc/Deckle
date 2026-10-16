package editor

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"deckle/internal/markdown"

	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"
)

// Commands are the editor's commands by name, for menus and shortcuts.
var Commands = []string{
	"toggleBold", "toggleItalic", "toggleStrikethrough", "toggleInlineCode", "toggleHighlight", "insertLink",
	"heading0", "heading1", "heading2", "heading3", "heading4", "heading5", "heading6",
	"toggleBulletList", "toggleNumberedList", "toggleTaskList", "toggleTaskDone", "toggleQuote", "toggleCodeBlock",
	"indentItems", "outdentItems", "find", "findNext", "findPrevious", "replace", "useSelectionForFind",
}

// Run runs a command by name, and reports whether it did anything.
func (e *Editor) Run(name string) bool {
	if strings.HasPrefix(name, "heading") {
		if lvl, err := strconv.Atoi(strings.TrimPrefix(name, "heading")); err == nil {
			prefix := ""
			if lvl > 0 {
				prefix = strings.Repeat("#", lvl) + " "
			}
			return e.setLinePrefix(prefix, headingPattern, false)
		}
	}
	switch name {
	case "find":
		e.find.show(e, false)
		return true
	case "replace":
		e.find.show(e, true)
		return true
	case "findNext":
		e.find.step(e, 1)
		return true
	case "findPrevious":
		e.find.step(e, -1)
		return true
	case "useSelectionForFind":
		a, z := e.selection()
		if a != z {
			e.find.query = e.buf.Slice(a, z)
			e.find.refresh(e)
		}
		return true
	}
	if e.ReadOnly || !e.markdown {
		return false
	}
	switch name {
	case "toggleBold":
		e.toggleWrap("**")
	case "toggleItalic":
		e.toggleWrap("*")
	case "toggleStrikethrough":
		e.toggleWrap("~~")
	case "toggleInlineCode":
		e.toggleWrap("`")
	case "toggleHighlight":
		e.toggleWrap("==")
	case "insertLink":
		a, z := e.selection()
		inner := e.buf.Slice(a, z)
		at := a + markdown.UnitsOf(inner) + 3
		e.Replace(a, z, "["+inner+"](url)", [2]int{at, at + 3})
	case "toggleBulletList":
		return e.setLinePrefix("- ", listPattern, true)
	case "toggleTaskList":
		return e.setLinePrefix("- [ ] ", listPattern, true)
	case "toggleQuote":
		return e.setLinePrefix("> ", quotePattern, true)
	case "toggleNumberedList":
		e.toggleNumbered()
	case "toggleCodeBlock":
		e.toggleCodeBlock()
	case "toggleTaskDone":
		return e.toggleTaskDone()
	case "indentItems":
		return e.shiftItems(1)
	case "outdentItems":
		return e.shiftItems(-1)
	default:
		return false
	}
	return true
}

// IsOn reports whether what a Format command toggles is on at the
// selection, for the menu's check marks.
func (e *Editor) IsOn(name string) bool {
	if !e.markdown || e.buf.Len() == 0 {
		return name == "heading0"
	}
	a, z := e.selection()
	la, lz := e.buf.LineAt(a), e.buf.LineAt(z)
	spans := e.buf.doc.SpansIn(e.buf.LineStart(la), e.buf.LineEnd(lz)+1)
	inside := func(k markdown.Kind) bool {
		return slices.ContainsFunc(spans, func(s markdown.Span) bool { return s.Kind == k && s.Start <= a && z <= s.End })
	}
	has := func(f func(s markdown.Span) bool) bool { return slices.ContainsFunc(spans, f) }
	if lvl, ok := strings.CutPrefix(name, "heading"); ok {
		n, _ := strconv.Atoi(lvl)
		for _, s := range spans {
			if s.Kind == markdown.Heading {
				return int(s.Level) == n
			}
		}
		return n == 0
	}
	switch name {
	case "toggleBold":
		return inside(markdown.Strong)
	case "toggleItalic":
		return inside(markdown.Emphasis)
	case "toggleStrikethrough":
		return inside(markdown.Strike)
	case "toggleInlineCode":
		return inside(markdown.Code)
	case "toggleHighlight":
		return inside(markdown.Highlight)
	case "toggleQuote":
		return has(func(s markdown.Span) bool { return s.Kind == markdown.BlockQuote })
	case "toggleCodeBlock":
		return has(func(s markdown.Span) bool { return s.Kind == markdown.CodeBlock })
	case "toggleTaskList":
		return has(func(s markdown.Span) bool { return s.Kind == markdown.TaskMarker })
	case "toggleBulletList":
		return has(func(s markdown.Span) bool { return s.Kind == markdown.ListMarker && s.Flags == 0 }) &&
			!has(func(s markdown.Span) bool { return s.Kind == markdown.TaskMarker })
	case "toggleNumberedList":
		return has(func(s markdown.Span) bool { return s.Kind == markdown.ListMarker && s.Flags != 0 })
	}
	return false
}

// CanRun reports whether a command can run now, for the menus.
func (e *Editor) CanRun(name string) bool {
	switch name {
	case "find", "findNext", "findPrevious", "useSelectionForFind":
		return true
	case "replace":
		return !e.ReadOnly
	case "toggleTaskDone":
		return e.markdown && !e.ReadOnly && len(e.taskEdits()) > 0
	}
	return e.markdown && !e.ReadOnly
}

var (
	headingPattern = regexp.MustCompile(`^#{1,6}[ \t]+`)
	listPattern    = regexp.MustCompile(`^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?`)
	quotePattern   = regexp.MustCompile(`^>[ \t]?`)
	numberedPrefix = regexp.MustCompile(`^[ \t]*\d+[.)][ \t]+`)
	// itemPattern reads a list item or quote up to the caret: indent and
	// quote marks, then a list marker, a task box and the space before the
	// text.
	itemPattern = regexp.MustCompile(`^([ \t]*(?:>[ \t]?)*)(?:([-*+]|\d{1,9}[.)])([ \t]+\[[ xX]\])?([ \t]+))?(.*)$`)
)

// toggleWrap wraps the selection in mark, or takes the marks away if it
// has them.
func (e *Editor) toggleWrap(mark string) {
	a, z := e.selection()
	n := markdown.UnitsOf(mark)
	if a-n >= 0 && z+n <= e.buf.Len() && e.buf.Slice(a-n, a) == mark && e.buf.Slice(z, z+n) == mark {
		e.Replace(a-n, z+n, e.buf.Slice(a, z), [2]int{a - n, z - n})
		return
	}
	e.Replace(a, z, mark+e.buf.Slice(a, z)+mark, [2]int{a + n, z + n})
}

// selectedLines are the units of the lines the selection touches,
// newline of the last included.
func (e *Editor) selectedLines() (int, int) {
	a, z := e.selection()
	la, lz := e.buf.LineAt(a), e.buf.LineAt(z)
	if z > a && lz > la && z == e.buf.LineStart(lz) {
		lz--
	}
	end := e.buf.LineEnd(lz)
	if lz+1 < e.buf.Lines() {
		end++
	}
	return e.buf.LineStart(la), end
}

// splitLines is s as lines, each with its line break.
func splitLines(s string) (lines, endings []string) {
	for s != "" {
		i := strings.IndexByte(s, '\n')
		if i < 0 {
			lines, endings = append(lines, s), append(endings, "")
			break
		}
		line := s[:i]
		end := "\n"
		if strings.HasSuffix(line, "\r") {
			line, end = line[:len(line)-1], "\r\n"
		}
		lines, endings = append(lines, line), append(endings, end)
		s = s[i+1:]
	}
	if len(lines) == 0 {
		lines, endings = []string{""}, []string{""}
	}
	return
}

// setLinePrefix gives the selected lines prefix in place of what pattern
// matches at their start. With toggles, lines that all have it lose it.
func (e *Editor) setLinePrefix(prefix string, pattern *regexp.Regexp, toggles bool) bool {
	if e.ReadOnly || !e.markdown {
		return false
	}
	a, z := e.selectedLines()
	lines, endings := splitLines(e.buf.Slice(a, z))
	all := toggles
	for _, l := range lines {
		if !strings.HasPrefix(l, prefix) {
			all = false
		}
	}
	var b strings.Builder
	for i, l := range lines {
		bare := pattern.ReplaceAllString(l, "")
		if !all {
			bare = prefix + bare
		}
		b.WriteString(bare + endings[i])
	}
	out := b.String()
	end := a + markdown.UnitsOf(out) - markdown.UnitsOf(endings[len(endings)-1])
	e.Replace(a, z, out, [2]int{end, end})
	return true
}

// toggleNumbered numbers the selected lines from 1, or takes the numbers
// away when they all have one.
func (e *Editor) toggleNumbered() {
	a, z := e.selectedLines()
	lines, endings := splitLines(e.buf.Slice(a, z))
	all := true
	for _, l := range lines {
		if !numberedPrefix.MatchString(l) {
			all = false
		}
	}
	var b strings.Builder
	for i, l := range lines {
		bare := listPattern.ReplaceAllString(l, "")
		if !all {
			bare = strconv.Itoa(i+1) + ". " + bare
		}
		b.WriteString(bare + endings[i])
	}
	out := b.String()
	end := a + markdown.UnitsOf(out) - markdown.UnitsOf(endings[len(endings)-1])
	e.Replace(a, z, out, [2]int{end, end})
}

// isCode reports whether the line at u is in a code block or front matter.
func (e *Editor) isCode(u int) bool {
	if !e.markdown {
		return true
	}
	for _, sp := range e.buf.lineSpans(e.buf.LineAt(u)) {
		if sp.Kind == markdown.CodeBlock || sp.Kind == markdown.FrontMatter {
			return true
		}
	}
	return false
}

func (e *Editor) codeBlockElement(u int) ([2]int, bool) {
	for _, sp := range e.buf.lineSpans(e.buf.LineAt(u)) {
		if sp.Kind == markdown.CodeBlock {
			return [2]int{sp.ElemStart, sp.ElemEnd}, true
		}
	}
	return [2]int{}, false
}

// toggleCodeBlock fences the selected lines as a code block, or unfences
// a block the selection is in.
func (e *Editor) toggleCodeBlock() {
	a, _ := e.selection()
	if block, ok := e.codeBlockElement(a); ok {
		fence := func(flag uint16, u int) bool {
			for _, sp := range e.buf.lineSpans(e.buf.LineAt(u)) {
				if sp.Kind == markdown.CodeBlock && sp.Flags&flag != 0 {
					return true
				}
			}
			return false
		}
		lines := strings.Split(e.buf.Slice(block[0], block[1]), "\n")
		if len(lines) < 2 || !fence(markdown.CodeFenceOpen, block[0]) {
			return
		}
		lines = lines[1:]
		if fence(markdown.CodeFenceClose, max(block[0], block[1]-1)) {
			lines = lines[:len(lines)-1]
		}
		inner := strings.Join(lines, "\n")
		e.Replace(block[0], block[1], inner, [2]int{block[0], block[0] + markdown.UnitsOf(inner)})
		return
	}
	s, z := e.selectedLines()
	body := e.buf.Slice(s, z)
	hadBreak := strings.HasSuffix(body, "\n")
	body = strings.TrimSuffix(body, "\n")
	out := "```\n" + body + "\n```"
	if hadBreak {
		out += "\n"
	}
	// The caret after the opening fence, to name the language.
	e.Replace(s, z, out, [2]int{s + 3, s + 3})
}

type textEdit struct {
	a, z int
	text string
}

// taskEdits are what ⌘↩ would change in the selected lines, in order: on
// one item it steps from a list item to an open task, a done one and back;
// over several it ticks every task, or clears them all when all are done;
// with no tasks among them, each item gets a box.
func (e *Editor) taskEdits() []textEdit {
	if !e.markdown {
		return nil
	}
	a, z := e.selectedLines()
	if z <= a && e.buf.Len() > 0 {
		return nil
	}
	spans := e.buf.doc.SpansIn(a, z+1)
	type item struct {
		marker markdown.Span
		task   *markdown.Span
	}
	var items []item
	for l := e.buf.LineAt(a); l <= e.buf.LineAt(max(a, z-1)); l++ {
		ls, le := e.buf.LineStart(l), e.buf.LineEnd(l)
		var m *markdown.Span
		for k := range spans {
			s := &spans[k]
			if s.Kind == markdown.ListMarker && s.Start >= ls && s.Start <= le && (m == nil || s.Start > m.Start) {
				m = s
			}
		}
		if m == nil {
			continue
		}
		it := item{marker: *m}
		for k := range spans {
			s := &spans[k]
			if s.Kind == markdown.TaskMarker && s.ElemStart == m.ElemStart && s.Start >= m.End {
				it.task = s
				break
			}
		}
		items = append(items, it)
	}
	box := func(m markdown.Span) textEdit {
		r, _ := e.buf.RuneAt(m.End)
		if r == ' ' || r == '\t' {
			return textEdit{m.End, m.End, " [ ]"}
		}
		return textEdit{m.End, m.End, " [ ] "}
	}
	if len(items) == 1 {
		it := items[0]
		switch {
		case it.task == nil:
			return []textEdit{box(it.marker)}
		case it.task.Flags == 0:
			return []textEdit{{it.task.Start, it.task.End, "[x]"}}
		default:
			return []textEdit{{it.marker.End, it.task.End, ""}}
		}
	}
	var tasks []*markdown.Span
	for _, it := range items {
		if it.task != nil {
			tasks = append(tasks, it.task)
		}
	}
	var out []textEdit
	if len(tasks) == 0 {
		for _, it := range items {
			out = append(out, box(it.marker))
		}
		return out
	}
	check := slices.ContainsFunc(tasks, func(t *markdown.Span) bool { return t.Flags == 0 })
	for _, t := range tasks {
		if (t.Flags != 0) != check {
			text := "[ ]"
			if check {
				text = "[x]"
			}
			out = append(out, textEdit{t.Start, t.End, text})
		}
	}
	return out
}

func (e *Editor) toggleTaskDone() bool {
	edits := e.taskEdits()
	if len(edits) == 0 {
		return false
	}
	a, z := e.selection()
	moved := func(u int) int {
		shift := 0
		for _, ed := range edits {
			n := markdown.UnitsOf(ed.text)
			if ed.z <= u {
				shift += n - (ed.z - ed.a)
			} else if ed.a < u {
				return ed.a + n + shift
			}
		}
		return u + shift
	}
	var changes []change
	for _, ed := range edits {
		changes = append(changes, change{at: ed.a, old: e.buf.Slice(ed.a, ed.z), new: ed.text})
	}
	e.hist.breakStep()
	e.apply(changes, [2]int{moved(a), moved(z)}, stepEdit)
	e.hist.breakStep()
	return true
}

// newline continues a list or a quote on Return, and ends it on an empty
// item.
func (e *Editor) newline() {
	a, z := e.selection()
	if !e.markdown || a != z || e.hasMarked || e.isCode(a) {
		e.typeText(a, z, "\n")
		return
	}
	l := e.buf.LineAt(a)
	ls := e.buf.LineStart(l)
	head := e.buf.Slice(ls, a)
	m := itemPattern.FindStringSubmatch(head)
	if m == nil || (m[2] == "" && !strings.Contains(m[1], ">")) {
		e.typeText(a, z, "\n")
		return
	}
	prefix, marker, task, gap, content := m[1], m[2], m[3], m[4], m[5]
	if strings.TrimSpace(content) == "" {
		// Nothing typed in this item: Return takes its marker away.
		if strings.TrimSpace(e.buf.Slice(a, e.buf.LineEnd(l))) != "" {
			e.typeText(a, z, "\n")
			return
		}
		e.Replace(ls, a, "", [2]int{ls, ls})
		return
	}
	if len(marker) > 1 {
		if n, err := strconv.Atoi(marker[:len(marker)-1]); err == nil {
			marker = strconv.Itoa(n+1) + marker[len(marker)-1:]
		}
	}
	if task != "" {
		task = " [ ]"
	}
	ins := "\n" + prefix + marker + task + gap
	end := a + markdown.UnitsOf(ins)
	e.Replace(a, z, ins, [2]int{end, end})
}

// shiftItems moves the selected list items in or out by a level.
func (e *Editor) shiftItems(dir int) bool {
	if !e.markdown || e.isCode(e.caret) {
		return false
	}
	a, z := e.selection()
	s, end := e.selectedLines()
	lines, endings := splitLines(e.buf.Slice(s, end))
	var out strings.Builder
	any := false
	for i, l := range lines {
		m := itemPattern.FindStringSubmatch(l)
		isItem := m != nil && m[2] != ""
		switch {
		case !isItem:
			out.WriteString(l)
		case dir > 0:
			any = true
			out.WriteString("  " + l)
		case strings.HasPrefix(l, "\t"):
			any = true
			out.WriteString(l[1:])
		default:
			n := 0
			for n < 2 && n < len(l) && l[n] == ' ' {
				n++
			}
			any = any || n > 0
			out.WriteString(l[n:])
		}
		out.WriteString(endings[i])
	}
	if !any {
		return a != z && dir < 0
	}
	repl := out.String()
	delta := markdown.UnitsOf(repl) - (end - s)
	sel := [2]int{max(s, a+delta), max(s, a+delta)}
	if a != z {
		sel = [2]int{s, s + markdown.UnitsOf(repl)}
	}
	if a == z {
		// The caret moves with its line.
		l0 := e.buf.LineAt(a)
		if l0 == e.buf.LineAt(s) {
			sel = [2]int{max(s, a+delta), max(s, a+delta)}
		}
	}
	e.Replace(s, end, repl, sel)
	return true
}

// LinkAt is what can be followed at unit u: a link's destination, a
// wikilink's target or a footnote.
func (e *Editor) LinkAt(u int) (Link, bool) {
	if !e.markdown || e.buf.Len() == 0 {
		return Link{}, false
	}
	spans := e.buf.lineSpans(e.buf.LineAt(min(u, e.buf.Len())))
	text := func(k markdown.Kind, s markdown.Span) (string, bool) {
		for _, o := range spans {
			if o.Kind == k && o.ElemStart == s.ElemStart && o.ElemEnd == s.ElemEnd {
				return e.buf.Slice(o.Start, o.End), true
			}
		}
		return "", false
	}
	for _, s := range spans {
		if s.ElemStart > u || u > s.ElemEnd {
			continue
		}
		switch s.Kind {
		case markdown.WikiLink, markdown.WikiTarget:
			if t, ok := text(markdown.WikiTarget, s); ok {
				return Link{Wiki: t}, true
			}
		case markdown.Link, markdown.LinkDest:
			if t, ok := text(markdown.LinkDest, s); ok {
				return Link{URL: t}, true
			}
		case markdown.Image, markdown.ImageDest:
			if t, ok := text(markdown.ImageDest, s); ok {
				return Link{URL: t}, true
			}
		case markdown.FootnoteRef:
			return Link{Footnote: strings.Trim(e.buf.Slice(s.Start, s.End), "[]^")}, true
		}
	}
	return Link{}, false
}

// linkElement is the text of the link at u: what a ⌘-click would follow.
func (e *Editor) linkElement(u int) ([2]int, bool) {
	if !e.markdown || e.buf.Len() == 0 {
		return [2]int{}, false
	}
	spans := e.buf.lineSpans(e.buf.LineAt(min(u, e.buf.Len())))
	for _, s := range spans {
		if s.ElemStart > u || u > s.ElemEnd {
			continue
		}
		switch s.Kind {
		case markdown.Link, markdown.WikiLink, markdown.FootnoteRef:
			return [2]int{s.Start, s.End}, true
		case markdown.LinkDest, markdown.WikiTarget:
			for _, o := range spans {
				if (o.Kind == markdown.Link || o.Kind == markdown.WikiLink) && o.ElemStart == s.ElemStart && o.ElemEnd == s.ElemEnd {
					return [2]int{o.Start, o.End}, true
				}
			}
			return [2]int{s.Start, s.End}, true
		}
	}
	return [2]int{}, false
}

// JumpToFootnote moves between a footnote's reference and its definition.
func (e *Editor) JumpToFootnote(label string) {
	text := e.buf.Text()
	def := strings.Index(text, "[^"+label+"]:")
	cur := e.buf.Byte(e.caret)
	if def >= 0 {
		le := strings.IndexByte(text[def:], '\n')
		if le < 0 {
			le = len(text) - def
		}
		if !(cur >= def && cur <= def+le) {
			at := e.buf.Unit(def + len("[^"+label+"]:"))
			e.SetSelection(at, at)
			return
		}
	}
	if ref := strings.Index(text, "[^"+label+"]"); ref >= 0 {
		at := e.buf.Unit(ref + len("[^"+label+"]"))
		e.SetSelection(at, at)
	}
}

// paste pastes files as links, an image saved beside the note, or text.
func (e *Editor) paste(plain bool) {
	a, z := e.selection()
	if e.markdown && !plain {
		data := e.services.ReadClipboardData(transfer.FileList, transfer.PNG)
		if files, err := data.Files(); err == nil && len(files) > 0 {
			e.InsertFiles(files, a, z)
			return
		}
		if png, err := data.Read(transfer.PNG); err == nil && len(png) > 0 && e.services.ReadClipboard() == "" {
			e.insertImageData(png, "png", a, z)
			return
		}
	}
	if s := e.services.ReadClipboard(); s != "" {
		e.hist.breakStep()
		e.replace(a, z, s, stepEdit)
		e.hist.breakStep()
		e.selectionChanged()
	}
}

var imageExts = map[string]bool{".png": true, ".jpg": true, ".jpeg": true, ".gif": true, ".webp": true, ".bmp": true, ".svg": true, ".heic": true, ".tiff": true}

// IsImage reports whether path is an image, by its extension.
func IsImage(path string) bool { return imageExts[strings.ToLower(filepath.Ext(path))] }

// InsertFiles links files in place of a..z: an image to show, a note, or
// any other file. Images from outside the note's folder are copied into
// its assets folder first.
func (e *Editor) InsertFiles(files []string, a, z int) {
	var b strings.Builder
	for _, f := range files {
		link := f
		if IsImage(f) && e.Hooks.SaveImage != nil && !strings.HasPrefix(f, filepath.Dir(e.path)+string(filepath.Separator)) {
			if data, err := os.ReadFile(f); err == nil {
				if p, err := e.Hooks.SaveImage(data, strings.TrimPrefix(filepath.Ext(f), ".")); err == nil {
					link = p
				}
			}
		} else if e.Hooks.LinkFile != nil {
			link = e.Hooks.LinkFile(f)
		}
		b.WriteString(e.linkTo(f, link, a+markdown.UnitsOf(b.String())))
	}
	s := b.String()
	end := a + markdown.UnitsOf(s)
	e.Replace(a, z, s, [2]int{end, end})
}

func (e *Editor) insertImageData(data []byte, ext string, a, z int) {
	if e.Hooks.SaveImage == nil {
		return
	}
	p, err := e.Hooks.SaveImage(data, ext)
	if err != nil {
		return
	}
	s := e.linkTo("pasted."+ext, p, a)
	end := a + markdown.UnitsOf(s)
	e.Replace(a, z, s, [2]int{end, end})
}

// linkTo is the Markdown that links file by rel, at unit at: an image on
// a line of its own, a note as a wikilink, another file as a link.
func (e *Editor) linkTo(file, rel string, at int) string {
	enc := encodePath(rel)
	base := filepath.Base(file)
	name := strings.TrimSuffix(base, filepath.Ext(base))
	switch {
	case IsImage(file):
		s := "![" + name + "](" + enc + ")"
		if r, _ := e.buf.RuneBefore(at); at > 0 && r != '\n' {
			s = "\n" + s
		}
		return s
	case markdown.LanguageForExtension(strings.TrimPrefix(filepath.Ext(file), ".")) == "markdown":
		return "[[" + name + "]]"
	}
	return "[" + base + "](" + enc + ")"
}

// encodePath escapes what a Markdown link's destination can't hold.
func encodePath(p string) string {
	r := strings.NewReplacer(" ", "%20", "(", "%28", ")", "%29", "<", "%3C", ">", "%3E")
	return r.Replace(filepath.ToSlash(p))
}

// InsertText types s at the selection, as a drop or a completion does.
func (e *Editor) InsertText(s string) {
	a, z := e.selection()
	end := a + markdown.UnitsOf(s)
	e.Replace(a, z, s, [2]int{end, end})
}

// FocusPoint is where the caret is in the element, for popovers.
func (e *Editor) FocusPoint() ui.Point {
	x, y, h := e.caretAt(e.caret, e.affinity)
	return ui.Point{X: e.colX + x, Y: e.toView(y) + h}
}
