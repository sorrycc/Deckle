package markdown

import (
	"bytes"
	"slices"
	"strings"
)

type builder struct {
	text  []byte
	refs  map[string]bool
	spans []Span
}

// push adds a span, one piece per line it covers. blocks keeps the pieces
// of empty lines, which a block's background still has to cover.
func (b *builder) push(kind Kind, start, end int, elem seg, level uint8, flags uint16, blocks bool) {
	end = min(end, len(b.text))
	if start > end {
		return
	}
	for {
		lineEnd := end
		if i := bytes.IndexByte(b.text[start:end], '\n'); i >= 0 {
			lineEnd = start + i
		}
		pieceEnd := lineEnd
		if pieceEnd > start && b.text[pieceEnd-1] == '\r' {
			pieceEnd--
		}
		if pieceEnd > start || blocks {
			b.spans = append(b.spans, Span{Start: start, End: pieceEnd, ElemStart: elem.start, ElemEnd: elem.end, Kind: kind, Level: level, Flags: flags})
		}
		if lineEnd >= end {
			break
		}
		start = lineEnd + 1
		if start >= end && !blocks {
			break
		}
	}
}

func (b *builder) inline(kind Kind, s, e int, elem seg) { b.push(kind, s, e, elem, 0, 0, false) }
func (b *builder) marker(s, e int, elem seg)            { b.push(Marker, s, e, elem, 0, 0, false) }

// trimEnd is the range without the line break and spaces at its end.
func (b *builder) trimEnd(s, e int) seg {
	e = min(e, len(b.text))
	for e > s && isSpace(b.text[e-1]) {
		e--
	}
	return seg{s, e}
}

// lineAt is the line around pos, without its line break.
func (b *builder) lineAt(pos int) seg {
	pos = min(pos, len(b.text))
	start := bytes.LastIndexByte(b.text[:pos], '\n') + 1
	end := len(b.text)
	if i := bytes.IndexByte(b.text[pos:], '\n'); i >= 0 {
		end = pos + i
	}
	return seg{start, end}
}

// ParseSection parses one section. Offsets in the result are bytes from
// its start. Only the first section reads front matter.
func ParseSection(text string, first bool) []Span {
	b := &builder{text: []byte(text)}
	from := 0
	if first {
		from = b.frontMatter()
	}
	doc, refs := parseBlocks(b.text, from)
	b.refs = refs
	b.blocks(doc, nil)
	// Outer spans before the ones they contain, so the inner style wins.
	slices.SortStableFunc(b.spans, func(x, y Span) int {
		if x.Start != y.Start {
			return x.Start - y.Start
		}
		return y.End - x.End
	})
	return b.spans
}

// frontMatter reads a YAML block between --- lines at the start, and
// returns where the rest of the text begins.
func (b *builder) frontMatter() int {
	t := b.text
	first := b.lineAt(0)
	if string(bytes.TrimSuffix(t[:first.end], []byte("\r"))) != "---" || first.end >= len(t) {
		return 0
	}
	pos := first.end + 1
	for pos < len(t) {
		line := b.lineAt(pos)
		l := string(bytes.TrimSuffix(t[line.start:line.end], []byte("\r")))
		if l == "---" || l == "..." {
			if line.start == first.end+1 {
				return 0
			}
			elem := b.trimEnd(0, line.end)
			last := line.start
			for p := 0; ; {
				ln := b.lineAt(p)
				var flags uint16
				if ln.start == 0 {
					flags |= CodeFenceOpen
				}
				if ln.start == last {
					flags |= CodeFenceClose
				}
				b.push(FrontMatter, ln.start, min(ln.end, elem.end), elem, 0, flags, true)
				p = ln.end + 1
				if p > elem.end || p >= len(t) {
					break
				}
			}
			if last > first.end+1 {
				Lex("yaml", string(t[first.end+1:last-1]), first.end+1, &b.spans)
			}
			return min(line.end+1, len(t))
		}
		pos = line.end + 1
	}
	return 0
}

func (b *builder) blocks(parent *block, item *block) {
	for i, c := range parent.children {
		switch c.kind {
		case bQuote:
			b.quote(c)
			b.blocks(c, nil)
		case bItem:
			line := b.lineAt(c.markerStart)
			var ordered uint16
			if c.ordered {
				ordered = 1
			}
			b.push(ListMarker, c.markerStart, c.markerEnd, line, c.listDepth, ordered, false)
			b.blocks(c, c)
		case bFootnote:
			line := b.lineAt(c.markerStart)
			b.inline(FootnoteDef, c.markerStart, c.markerEnd, line)
			// The brackets hide, as other syntax does.
			b.marker(c.markerStart, c.markerStart+2, line)
			b.marker(c.markerEnd-2, c.markerEnd, line)
			b.blocks(c, nil)
		case bPara:
			lines := c.lines
			if item != nil && i == 0 && len(lines) > 0 {
				lines = b.task(lines)
			}
			b.paragraph(c, lines)
		case bHeading:
			b.heading(c)
		case bFenced, bIndented:
			b.code(c)
		case bHTML:
			e := b.trimEnd(c.start, c.end)
			b.inline(HTML, e.start, e.end, e)
		case bTable:
			b.table(c)
		case bRule:
			e := b.trimEnd(c.start, c.end)
			b.inline(ThematicBreak, e.start, e.end, e)
		}
	}
}

// task takes a task's box off the start of an item's first paragraph.
func (b *builder) task(lines []seg) []seg {
	s := lines[0]
	t := b.text[s.start:s.end]
	if len(t) < 3 || t[0] != '[' || t[2] != ']' || (t[1] != ' ' && t[1] != 'x' && t[1] != 'X') {
		return lines
	}
	if len(t) > 3 && t[3] != ' ' && t[3] != '\t' {
		return lines
	}
	var checked uint16
	if t[1] != ' ' {
		checked = 1
	}
	b.push(TaskMarker, s.start, s.start+3, b.lineAt(s.start), 0, checked, false)
	rest := s.start + 3
	for rest < s.end && (b.text[rest] == ' ' || b.text[rest] == '\t') {
		rest++
	}
	out := append([]seg{{rest, s.end}}, lines[1:]...)
	return out
}

func (b *builder) quote(q *block) {
	elem := b.trimEnd(q.start, q.end)
	callout := calloutKind(b.text[elem.start:b.lineAt(elem.start).end])
	b.push(BlockQuote, elem.start, elem.end, elem, q.depth+1, callout, true)
	for k, m := range q.markers {
		line := b.lineAt(m.start)
		b.marker(m.start, m.end, line)
		if k == 0 && callout != 0 && bytes.HasPrefix(b.text[m.end:line.end], []byte("[!")) {
			if close := bytes.IndexByte(b.text[m.end:line.end], ']'); close >= 0 {
				b.push(CalloutTag, m.end, m.end+close+1, line, 0, callout, false)
			}
		}
	}
}

func (b *builder) heading(h *block) {
	if h.setext {
		elem := b.trimEnd(h.start, h.end)
		b.push(Heading, elem.start, elem.end, elem, uint8(h.level), 0, false)
		content := h.lines[:len(h.lines)-1]
		if len(content) > 0 {
			last := content[len(content)-1]
			innerEnd := b.trimEnd(last.start, last.end).end
			tail := innerEnd
			for tail < elem.end && b.text[tail] == ' ' {
				tail++
			}
			b.marker(tail, elem.end, elem)
			trimmed := append([]seg(nil), content...)
			trimmed[len(trimmed)-1].end = innerEnd
			b.inlines(trimmed, seg{-1, -1})
		}
		return
	}
	line := h.lines[0]
	elem := b.trimEnd(line.start, line.end)
	b.push(Heading, elem.start, elem.end, elem, uint8(h.level), 0, false)
	s := elem.start + h.level
	for s < elem.end && (b.text[s] == ' ' || b.text[s] == '\t') {
		s++
	}
	e := elem.end
	// A closing run of #, after a space.
	k := e
	for k > s && b.text[k-1] == '#' {
		k--
	}
	if k == s || b.text[k-1] == ' ' || b.text[k-1] == '\t' {
		e = k
		for e > s && (b.text[e-1] == ' ' || b.text[e-1] == '\t') {
			e--
		}
	}
	if e <= s {
		return
	}
	b.marker(elem.start, s, elem)
	tail := e
	for tail < elem.end && b.text[tail] == ' ' {
		tail++
	}
	b.marker(tail, elem.end, elem)
	b.inlines([]seg{{s, e}}, seg{-1, -1})
}

func (b *builder) paragraph(p *block, lines []seg) {
	if len(lines) == 0 {
		return
	}
	b.inlines(lines, b.trimEnd(p.start, p.end))
}

func (b *builder) code(c *block) {
	elem := b.trimEnd(c.start, c.end)
	fenced := c.kind == bFenced
	lang := ""
	if fenced {
		if f := strings.Fields(c.info); len(f) > 0 {
			lang = strings.ToLower(f[0])
		}
	}
	var widget uint16
	switch lang {
	case "mermaid":
		widget = CodeDiagram
	case "math", "latex", "tex":
		widget = CodeMath
	}
	firstLine := b.lineAt(elem.start)
	lastLine := b.lineAt(elem.end)
	closed := fenced && c.closed && lastLine.start > firstLine.start
	pos := elem.start
	for {
		line := b.lineAt(pos)
		start := max(line.start, elem.start)
		flags := widget
		if fenced && start == elem.start {
			flags |= CodeFenceOpen
		}
		if closed && line.start == lastLine.start {
			flags |= CodeFenceClose
		}
		b.push(CodeBlock, start, min(line.end, elem.end), elem, 0, flags, true)
		pos = line.end + 1
		if pos > elem.end || pos >= len(b.text) {
			break
		}
	}
	body := elem
	if fenced {
		start := min(firstLine.end+1, elem.end)
		end := elem.end
		if closed {
			end = max(lastLine.start-1, start)
		}
		body = seg{start, end}
	}
	if widget == 0 && lang != "" && body.end > body.start {
		Lex(lang, string(b.text[body.start:body.end]), body.start, &b.spans)
	}
}

func (b *builder) table(t *block) {
	elem := b.trimEnd(t.start, t.end)
	for row, line := range t.lines {
		full := b.lineAt(line.start)
		var flags uint16
		switch row {
		case 0:
			flags = TableHeader
		case 1:
			flags = TableDelimiter
		}
		b.push(Table, max(full.start, elem.start), min(full.end, elem.end), elem, 0, flags, true)
		if row == 1 {
			continue
		}
		for col, cell := range splitCells(b.text, line) {
			if col >= len(t.aligns) {
				break
			}
			flags := uint16(t.aligns[col])
			if row == 0 {
				flags |= TableHeader << 4
			}
			content := b.trimEnd(cell.start, cell.end)
			for content.start < content.end && b.text[content.start] == ' ' {
				content.start++
			}
			b.push(TableCell, content.start, content.end, full, uint8(min(col, 255)), flags, true)
			if content.end > content.start {
				b.inlines([]seg{content}, seg{-1, -1})
			}
		}
	}
}

// inlines parses the inline content of lines, and adds its spans. para is
// the paragraph the lines make, whose display math alone is a block.
func (b *builder) inlines(lines []seg, para seg) {
	var v []byte
	starts := make([]int, len(lines))
	for i, l := range lines {
		if i > 0 {
			v = append(v, '\n')
		}
		starts[i] = len(v)
		v = append(v, b.text[l.start:l.end]...)
	}
	src := func(p int) int {
		i, _ := slices.BinarySearch(starts, p+1)
		i = max(i-1, 0)
		off := p - starts[i]
		return min(lines[i].start+off, lines[i].end)
	}
	ip := parseInline(v, b.refs)
	for _, n := range ip.nodes {
		r := seg{src(n.start), src(n.end)}
		inner := seg{src(n.innerStart), src(n.innerEnd)}
		switch n.kind {
		case iEmph:
			kind := Emphasis
			switch {
			case n.ch == '~' && n.n == 1:
				// A single tilde is a subscript, not a strike; with a space
				// inside it is neither, and stays as typed.
				if bytes.ContainsAny(b.text[r.start+1:max(r.end-1, r.start+1)], " \t\n\r") {
					continue
				}
				kind = Subscript
			case n.ch == '~':
				kind = Strike
			case n.n == 2:
				kind = Strong
			}
			b.inline(kind, r.start, r.end, r)
			b.marker(r.start, inner.start, r)
			b.marker(inner.end, r.end, r)
		case iCode:
			b.inline(Code, r.start, r.end, r)
			if r.end-r.start > 2*n.n {
				b.marker(r.start, r.start+n.n, r)
				b.marker(r.end-n.n, r.end, r)
			}
		case iMath:
			b.inline(InlineMath, r.start, r.end, r)
			if r.end-r.start > 2 {
				b.marker(r.start, r.start+1, r)
				b.marker(r.end-1, r.end, r)
			}
		case iDisplayMath:
			// A block of its own when nothing else shares its paragraph.
			var alone uint16
			if para == r {
				line := b.lineAt(r.start)
				if strings.Trim(string(b.text[line.start:r.start]), " >") == "" {
					alone = 1
				}
			}
			b.push(MathBlock, r.start, r.end, r, 0, alone, true)
		case iHTML:
			b.inline(HTML, r.start, r.end, r)
		case iAutolink:
			if r.end-r.start > 2 {
				b.inline(Link, r.start+1, r.end-1, r)
				b.inline(LinkDest, r.start+1, r.end-1, r)
				b.marker(r.start, r.start+1, r)
				b.marker(r.end-1, r.end, r)
			}
		case iWiki:
			if r.end-r.start > 4 {
				innerEnd := r.end - 2
				target := seg{r.start + 2, innerEnd}
				label := target
				if n.pipe >= 0 {
					pipe := src(n.pipe)
					target.end = pipe
					label = seg{pipe + 1, innerEnd}
				}
				b.inline(WikiLink, label.start, label.end, r)
				b.marker(r.start, label.start, r)
				b.marker(innerEnd, r.end, r)
				b.inline(WikiTarget, target.start, target.end, r)
			}
		case iLink:
			if inner.end > inner.start {
				b.inline(Link, inner.start, inner.end, r)
				b.marker(r.start, inner.start, r)
				b.marker(inner.end, r.end, r)
				if d, ok := destination(b.text, inner.end, r.end); ok {
					b.inline(LinkDest, d.start, d.end, r)
				}
			}
		case iImage:
			line := b.lineAt(r.start)
			var alone uint16
			if strings.Trim(string(b.text[line.start:r.start]), " >") == "" && r.end <= line.end && strings.TrimSpace(string(b.text[r.end:line.end])) == "" {
				alone = 1
			}
			b.push(Image, r.start, r.end, r, 0, alone, false)
			if d, ok := destination(b.text, inner.end, r.end); ok {
				b.inline(ImageDest, d.start, d.end, r)
			}
		}
	}
	// Runs of plain text, a line at a time.
	for i := 0; i < len(v); {
		if ip.used[i] || ip.literal[i] || v[i] == '\n' {
			i++
			continue
		}
		j := i
		for j < len(v) && !ip.used[j] && !ip.literal[j] && v[j] != '\n' {
			j++
		}
		b.textRun(src(i), src(i)+(j-i))
		i = j
	}
}

// destination is the URL in the `](url "title")` that follows a link's
// text.
func destination(t []byte, from, to int) (seg, bool) {
	k := bytes.Index(t[from:to], []byte("]("))
	if k < 0 {
		return seg{}, false
	}
	start := from + k + 2
	for start < to && t[start] == ' ' {
		start++
	}
	end := start
	if start < len(t) && t[start] == '<' {
		start++
		j := bytes.IndexByte(t[start:to], '>')
		if j < 0 {
			return seg{}, false
		}
		end = start + j
	} else {
		depth := 0
	loop:
		for end < to {
			switch t[end] {
			case '(':
				depth++
			case ')':
				if depth == 0 {
					break loop
				}
				depth--
			case ' ', '\n':
				break loop
			}
			end++
		}
	}
	return seg{start, end}, end > start
}

// bareLinks marks web addresses written out in plain text.
func (b *builder) bareLinks(from, to int) {
	t := b.text
	pos := from
	for {
		i := bytes.Index(t[pos:to], []byte("://"))
		if i < 0 {
			return
		}
		at := pos + i
		var start int
		switch {
		case bytes.HasSuffix(t[from:at], []byte("https")):
			start = at - 5
		case bytes.HasSuffix(t[from:at], []byte("http")):
			start = at - 4
		default:
			pos = at + 3
			continue
		}
		end := at + 3
		for end < to && !isSpace(t[end]) && t[end] != '<' && t[end] != '>' && t[end] != '"' && t[end] != '`' {
			// Stop at the first character that is not part of a URL, which
			// in Chinese text is often the very next one.
			if t[end] >= 0x80 {
				break
			}
			end++
		}
		for end > at+3 && strings.IndexByte(".,;:!?)'", t[end-1]) >= 0 {
			end--
		}
		if end > at+3 && (start == from || !isAlnum(t[start-1])) {
			r := seg{start, end}
			b.inline(Link, start, end, r)
			b.inline(LinkDest, start, end, r)
		}
		pos = max(end, at+3)
	}
}

// calloutKind is the kind of callout a quote's first line opens, or 0:
// `> [!tip] Title`.
func calloutKind(line []byte) uint16 {
	start := 0
	for start < len(line) && (line[start] == ' ' || line[start] == '>') {
		start++
	}
	rest := line[start:]
	if !bytes.HasPrefix(rest, []byte("[!")) {
		return 0
	}
	close := bytes.IndexByte(rest, ']')
	if close < 0 {
		return 0
	}
	name := strings.ToLower(string(rest[2:close]))
	if name == "" {
		return 0
	}
	for i := 0; i < len(name); i++ {
		if !isAlnum(name[i]) {
			return 0
		}
	}
	switch name {
	case "tip", "hint", "success", "check", "done":
		return 2
	case "important", "question", "help", "faq", "example":
		return 3
	case "warning", "attention":
		return 4
	case "caution", "danger", "error", "failure", "fail", "bug":
		return 5
	}
	return 1
}

// textRun marks what the parser leaves as plain text but a note-taker
// expects to work: bare links, footnote references whose definition is
// elsewhere, ==marks==, and subscripts and superscripts inside a word.
func (b *builder) textRun(from, to int) {
	b.bareLinks(from, to)
	t := b.text
	at := func(i int) byte {
		if i < len(t) {
			return t[i]
		}
		return 0
	}
	// The end of a run of ch around content with no space in it.
	closeAt := func(f int, ch byte) int {
		limit := min(to, f+48)
		if f >= limit {
			return -1
		}
		for j := f; j < limit; j++ {
			c := t[j]
			if c == ch || isSpace(c) {
				if c == ch && j > f && at(j+1) != ch {
					return j
				}
				return -1
			}
		}
		return -1
	}
	i := from
	for i < to {
		c := t[i]
		var prev byte
		if i > from {
			prev = t[i-1]
		}
		switch {
		case c == '[' && at(i+1) == '^':
			if j := closeAt(i+2, ']'); j >= 0 && bytes.IndexByte(t[i+2:j], '[') < 0 {
				r := seg{i, j + 1}
				b.inline(FootnoteRef, i, j+1, r)
				b.marker(i, i+2, r)
				b.marker(j, j+1, r)
				i = j + 1
				continue
			}
		case (c == '~' || c == '^') && prev != c && prev != '[' && at(i+1) != c:
			if j := closeAt(i+1, c); j >= 0 {
				kind := Superscript
				if c == '~' {
					kind = Subscript
				}
				r := seg{i, j + 1}
				b.inline(kind, i, j+1, r)
				b.marker(i, i+1, r)
				b.marker(j, j+1, r)
				i = j + 1
				continue
			}
		case c == '=' && prev != '=' && at(i+1) == '=' && i+2 < to && at(i+2) != '=' && at(i+2) != ' ':
			limit := min(to, i+400)
			if off := bytes.Index(t[i+2:limit], []byte("==")); off > 0 {
				j := i + 2 + off
				if t[j-1] != ' ' && bytes.IndexByte(t[i+2:j], '\n') < 0 {
					r := seg{i, j + 2}
					b.inline(Highlight, i, j+2, r)
					b.marker(i, i+2, r)
					b.marker(j, j+2, r)
					i = j + 2
					continue
				}
			}
		}
		i++
	}
}
