package markdown

import (
	"bytes"
	"strings"
)

// The block structure of a section, after CommonMark: containers (quotes,
// list items, footnote definitions) hold leaves (paragraphs, headings, code,
// HTML, tables, rules). Every block keeps where it sits in the source, which
// is all the spans need.

type blockKind uint8

const (
	bDoc blockKind = iota
	bQuote
	bItem
	bFootnote
	bPara
	bHeading
	bFenced
	bIndented
	bHTML
	bTable
	bRule
	// A paragraph of link reference definitions alone, which shows nothing.
	bRefs
)

type seg struct{ start, end int }

type block struct {
	kind     blockKind
	parent   *block
	children []*block
	open     bool
	// start is where the block begins: the > of a quote, the marker of an
	// item, the first character of a leaf. end is the end of its last
	// line, without the line break.
	start, end int
	// lines are the content of a paragraph, heading or table row by row,
	// and the source lines of code and HTML.
	lines []seg

	// Quotes: their depth and the > of each line.
	depth   uint8
	markers []seg
	// Items and footnotes: the column their content starts at.
	indent      int
	markerStart int
	markerEnd   int
	ordered     bool
	listDepth   uint8
	// Fenced code.
	fenceCh     byte
	fenceLen    int
	fenceIndent int
	info        string
	closed      bool
	// HTML blocks: what ends them, or that a blank line does.
	htmlEnd   string
	htmlBlank bool
	// Headings.
	level  int
	setext bool
	// Tables.
	aligns []uint8
}

func (b *block) lastOpen() *block {
	if n := len(b.children); n > 0 && b.children[n-1].open {
		return b.children[n-1]
	}
	return nil
}

func (b *block) isContainer() bool {
	return b.kind == bDoc || b.kind == bQuote || b.kind == bItem || b.kind == bFootnote
}

type blockParser struct {
	src  []byte
	doc  *block
	refs map[string]bool
	// The line being read: its bounds, and the cursor in it.
	ls, le   int
	pos, col int
	// Where the first non-space is from the cursor, and its column.
	next, nextCol int
	blank         bool
}

func parseBlocks(src []byte, from int) (*block, map[string]bool) {
	p := &blockParser{src: src, refs: map[string]bool{}}
	p.doc = &block{kind: bDoc, open: true, start: from, end: from}
	pos := from
	for pos < len(src) {
		end := len(src)
		if i := bytes.IndexByte(src[pos:], '\n'); i >= 0 {
			end = pos + i
		}
		le := end
		if le > pos && src[le-1] == '\r' {
			le--
		}
		p.line(pos, le)
		pos = end + 1
	}
	p.closeAll(p.doc)
	return p.doc, p.refs
}

func (p *blockParser) findNext() {
	i, col := p.pos, p.col
	for i < p.le {
		switch p.src[i] {
		case ' ':
			col++
		case '\t':
			col += 4 - col%4
		default:
			p.next, p.nextCol, p.blank = i, col, false
			return
		}
		i++
	}
	p.next, p.nextCol, p.blank = p.le, col, true
}

func (p *blockParser) indent() int { return p.nextCol - p.col }

// advance moves the cursor n columns, taking a tab whole.
func (p *blockParser) advance(n int) {
	target := p.col + n
	for p.pos < p.le && p.col < target {
		if p.src[p.pos] == '\t' {
			p.col += 4 - p.col%4
		} else {
			p.col++
		}
		p.pos++
	}
}

func (p *blockParser) advanceTo(pos int) {
	for p.pos < pos {
		p.advance(1)
	}
}

func (p *blockParser) peek(i int) byte {
	if i < p.le {
		return p.src[i]
	}
	return 0
}

func (p *blockParser) line(ls, le int) {
	p.ls, p.le, p.pos, p.col = ls, le, ls, 0
	container := p.doc
	allMatched := true
	var matched []*block
	// Each open container the line continues.
	for {
		child := container.lastOpen()
		if child == nil || !child.isContainer() {
			break
		}
		p.findNext()
		ok := false
		switch child.kind {
		case bQuote:
			if p.indent() <= 3 && p.peek(p.next) == '>' {
				at := p.next
				p.advanceTo(p.next + 1)
				if c := p.peek(p.pos); c == ' ' || c == '\t' {
					p.advance(1)
				}
				child.markers = append(child.markers, seg{at, p.pos})
				ok = true
			}
		case bItem, bFootnote:
			if p.blank {
				ok = len(child.children) > 0
				p.advanceTo(p.next)
			} else if p.indent() >= child.indent {
				p.advance(child.indent)
				ok = true
			}
		}
		if !ok {
			allMatched = false
			break
		}
		matched = append(matched, child)
		container = child
	}
	tip := container
	for t := tip.lastOpen(); t != nil; t = t.lastOpen() {
		tip = t
	}
	leaf := container.lastOpen()
	p.findNext()

	// Leaves that take the line as it is.
	if leaf != nil && allMatched {
		switch leaf.kind {
		case bFenced:
			if p.indent() <= 3 {
				if ch, n := fenceRun(p.src[p.next:p.le]); n > 0 && ch == leaf.fenceCh && n >= leaf.fenceLen && isBlank(p.src[p.next+n:p.le]) {
					leaf.closed = true
					p.addLine(leaf, seg{p.next, p.le}, matched)
					leaf.open = false
					return
				}
			}
			p.advance(min(leaf.fenceIndent, p.indent()))
			p.addLine(leaf, seg{p.pos, p.le}, matched)
			return
		case bHTML:
			if leaf.htmlBlank && p.blank {
				leaf.open = false
				return
			}
			p.addLine(leaf, seg{p.pos, p.le}, matched)
			if leaf.htmlEnd != "" && bytes.Contains(p.src[p.pos:p.le], []byte(leaf.htmlEnd)) {
				leaf.open = false
			}
			return
		case bIndented:
			if p.indent() >= 4 {
				p.advance(4)
				p.addLine(leaf, seg{p.pos, p.le}, matched)
				return
			}
			if p.blank {
				p.addLine(leaf, seg{p.next, p.next}, matched)
				return
			}
		}
	}

	// Block starts.
	started := false
	for {
		p.findNext()
		if p.blank {
			break
		}
		ind := p.indent()
		if ind >= 4 {
			if tip.kind != bPara && !started && (tip.kind != bTable || !allMatched) {
				p.closeUnmatched(container)
				p.advance(4)
				b := p.add(container, bIndented, p.pos)
				p.addLine(b, seg{p.pos, p.le}, matched)
				return
			}
			break
		}
		at := p.next
		c := p.src[at]
		rest := p.src[at:p.le]
		if c == '>' {
			p.closeUnmatched(container)
			q := p.add(container, bQuote, at)
			for a := container; a != nil; a = a.parent {
				if a.kind == bQuote {
					q.depth++
				}
			}
			p.advanceTo(at + 1)
			if c := p.peek(p.pos); c == ' ' || c == '\t' {
				p.advance(1)
			}
			q.markers = append(q.markers, seg{at, p.pos})
			matched = append(matched, q)
			container, tip, started = q, q, true
			continue
		}
		if isATXHeading(rest) {
			p.closeUnmatched(container)
			h := p.add(container, bHeading, at)
			n := 0
			for n < len(rest) && rest[n] == '#' {
				n++
			}
			h.level = n
			p.addLine(h, seg{at, p.le}, matched)
			h.open = false
			return
		}
		if ch, n := fenceRun(rest); n > 0 && (ch == '~' || bytes.IndexByte(rest[n:], '`') < 0) {
			p.closeUnmatched(container)
			f := p.add(container, bFenced, at)
			f.fenceCh, f.fenceLen, f.fenceIndent = ch, n, ind
			f.info = strings.TrimSpace(string(rest[n:]))
			p.addLine(f, seg{at, p.le}, matched)
			return
		}
		if end, blankEnds, ok := htmlStart(rest, tip.kind == bPara); ok {
			p.closeUnmatched(container)
			h := p.add(container, bHTML, at)
			h.htmlEnd, h.htmlBlank = end, blankEnds
			p.addLine(h, seg{at, p.le}, matched)
			if end != "" && bytes.Contains(rest[2:], []byte(end)) {
				h.open = false
			}
			return
		}
		if tip.kind == bPara && tip.parent == container && allMatched && !started {
			if lvl := setextLevel(rest); lvl > 0 {
				tip.kind = bHeading
				tip.setext = true
				tip.level = lvl
				p.addLine(tip, seg{at, p.le}, matched)
				tip.open = false
				return
			}
		}
		if isThematicBreak(rest) {
			p.closeUnmatched(container)
			r := p.add(container, bRule, at)
			p.addLine(r, seg{at, p.le}, matched)
			r.open = false
			return
		}
		if c == '[' && p.peek(at+1) == '^' {
			if close := bytes.Index(rest, []byte("]:")); close > 2 && bytes.IndexAny(rest[2:close], " \t[]") < 0 {
				p.closeUnmatched(container)
				f := p.add(container, bFootnote, at)
				f.indent = 4 + p.indent()
				f.markerStart, f.markerEnd = at, at+close+2
				p.advanceTo(at + close + 2)
				f.end = p.pos
				matched = append(matched, f)
				container, tip, started = f, f, true
				continue
			}
		}
		if ok, ordered, mEnd := listMarker(rest, at); ok {
			// Only an item with text, and of a numbered list only the first,
			// interrupts a paragraph.
			after := p.src[mEnd:p.le]
			emptyItem := isBlank(after)
			interrupts := !emptyItem && (!ordered || bytes.HasPrefix(rest, []byte("1.")) || bytes.HasPrefix(rest, []byte("1)")))
			// The paragraph of an item of this list doesn't count: the
			// next item of the list starts after it, whatever its number.
			for b := tip; b != nil && b != container; b = b.parent {
				if b.kind == bItem && b.parent == container && b.ordered == ordered {
					interrupts = true
				}
			}
			if tip.kind != bPara || started || interrupts {
				p.closeUnmatched(container)
				item := p.add(container, bItem, at)
				item.ordered = ordered
				item.markerStart, item.markerEnd = at, mEnd
				for a := container; a != nil; a = a.parent {
					if a.kind == bItem {
						item.listDepth++
					}
				}
				item.listDepth++
				baseCol := p.col
				p.advanceTo(mEnd)
				markerCol := p.col
				p.findNext()
				spaces := p.indent()
				contentCol := markerCol + spaces
				switch {
				case p.blank:
					contentCol = markerCol + 1
				case spaces >= 5:
					contentCol = markerCol + 1
					p.advance(1)
				default:
					p.advance(spaces)
				}
				item.indent = contentCol - baseCol
				item.end = p.le
				matched = append(matched, item)
				container, tip, started = item, item, true
				continue
			}
		}
		if tip.kind == bPara && tip.parent == container && allMatched && !started && len(tip.lines) == 1 {
			if aligns := delimiterRow(rest); aligns != nil && len(aligns) == len(splitCells(p.src, tip.lines[0])) {
				tip.kind = bTable
				tip.aligns = aligns
				p.addLine(tip, seg{at, p.le}, matched)
				return
			}
		}
		break
	}

	// Lazy continuation of a paragraph, or the next row of a table.
	if !started && !p.blank && tip.kind == bPara {
		p.addLine(tip, seg{p.next, p.le}, matched)
		return
	}
	if !started && !p.blank && tip.kind == bTable && allMatched && tip.parent == container {
		p.addLine(tip, seg{p.next, p.le}, matched)
		return
	}
	p.closeUnmatched(container)
	if p.blank {
		for _, m := range matched {
			if m.kind == bQuote {
				m.end = max(m.end, p.le)
			}
		}
		return
	}
	para := p.add(container, bPara, p.next)
	p.addLine(para, seg{p.next, p.le}, matched)
}

func (p *blockParser) add(parent *block, kind blockKind, start int) *block {
	b := &block{kind: kind, parent: parent, open: true, start: start, end: start}
	parent.children = append(parent.children, b)
	return b
}

// addLine gives a line to a leaf, and extends the leaf, its containers and
// the containers the line continued to the line's end.
func (p *blockParser) addLine(b *block, s seg, matched []*block) {
	b.lines = append(b.lines, s)
	for a := b; a != nil; a = a.parent {
		a.end = max(a.end, s.end)
	}
	for _, m := range matched {
		m.end = max(m.end, s.end)
	}
}

func (p *blockParser) closeUnmatched(container *block) {
	if c := container.lastOpen(); c != nil {
		p.closeAll(c)
	}
}

func (p *blockParser) closeAll(b *block) {
	for c := b; c != nil; {
		next := c.lastOpen()
		if c.open {
			p.finish(c)
			c.open = false
		}
		c = next
	}
}

func (p *blockParser) finish(b *block) {
	if b.kind == bPara && b.open {
		p.takeRefs(b)
	}
}

// takeRefs takes the link reference definitions off the start of a
// paragraph, one per line.
func (p *blockParser) takeRefs(b *block) {
	n := 0
	for n < len(b.lines) {
		l := p.src[b.lines[n].start:b.lines[n].end]
		if len(l) < 4 || l[0] != '[' || l[1] == '^' {
			break
		}
		close := bytes.Index(l, []byte("]:"))
		if close < 2 || bytes.IndexByte(l[1:close], '[') >= 0 || bytes.IndexByte(l[1:close], ']') >= 0 {
			break
		}
		if isBlank(l[close+2:]) {
			break
		}
		p.refs[normalizeLabel(string(l[1:close]))] = true
		n++
	}
	if n > 0 {
		b.lines = b.lines[n:]
		if len(b.lines) == 0 {
			b.kind = bRefs
		} else {
			b.start = b.lines[0].start
		}
	}
}

func normalizeLabel(s string) string {
	return strings.ToLower(strings.Join(strings.Fields(s), " "))
}

func setextLevel(rest []byte) int {
	t := bytes.TrimRight(rest, " \t")
	if len(t) == 0 {
		return 0
	}
	for _, c := range t {
		if c != t[0] {
			return 0
		}
	}
	switch t[0] {
	case '=':
		return 1
	case '-':
		return 2
	}
	return 0
}

func isThematicBreak(rest []byte) bool {
	if len(rest) == 0 || (rest[0] != '-' && rest[0] != '*' && rest[0] != '_') {
		return false
	}
	n := 0
	for _, c := range rest {
		switch c {
		case rest[0]:
			n++
		case ' ', '\t':
		default:
			return false
		}
	}
	return n >= 3
}

// listMarker reads a bullet or numbered list marker at the start of rest,
// followed by a space or the end of the line, and returns where it ends.
func listMarker(rest []byte, at int) (ok, ordered bool, end int) {
	if len(rest) == 0 {
		return
	}
	i := 0
	if rest[0] == '-' || rest[0] == '*' || rest[0] == '+' {
		i = 1
	} else {
		for i < len(rest) && i < 9 && isDigit(rest[i]) {
			i++
		}
		if i == 0 || i >= len(rest) || (rest[i] != '.' && rest[i] != ')') {
			return
		}
		i++
		ordered = true
	}
	if i < len(rest) && rest[i] != ' ' && rest[i] != '\t' {
		return false, false, 0
	}
	return true, ordered, at + i
}

// delimiterRow reads the row of dashes under a table's header and returns
// the alignment of each column, or nil when rest is not one.
func delimiterRow(rest []byte) []uint8 {
	t := bytes.TrimSpace(rest)
	if bytes.IndexByte(t, '-') < 0 {
		return nil
	}
	piped := bytes.IndexByte(t, '|') >= 0
	t = bytes.TrimPrefix(t, []byte("|"))
	t = bytes.TrimSuffix(t, []byte("|"))
	cells := bytes.Split(t, []byte("|"))
	if len(cells) == 1 && !piped {
		return nil
	}
	aligns := make([]uint8, 0, len(cells))
	for _, c := range cells {
		c = bytes.TrimSpace(c)
		if len(c) == 0 {
			return nil
		}
		left, right := c[0] == ':', c[len(c)-1] == ':'
		dashes := bytes.Trim(c, ":")
		if len(dashes) == 0 || len(bytes.Trim(dashes, "-")) != 0 {
			return nil
		}
		var a uint8
		switch {
		case left && right:
			a = 2
		case left:
			a = 1
		case right:
			a = 3
		}
		aligns = append(aligns, a)
	}
	return aligns
}

// splitCells splits a table row at its unescaped pipes, and returns each
// cell's bytes, the pipes and outer spaces left out.
func splitCells(src []byte, row seg) []seg {
	s, e := row.start, row.end
	for s < e && (src[s] == ' ' || src[s] == '\t') {
		s++
	}
	for e > s && (src[e-1] == ' ' || src[e-1] == '\t') {
		e--
	}
	if s < e && src[s] == '|' {
		s++
	}
	if e > s && src[e-1] == '|' && (e-2 < s || src[e-2] != '\\') {
		e--
	}
	var cells []seg
	start := s
	for i := s; i < e; i++ {
		if src[i] == '\\' {
			i++
			continue
		}
		if src[i] == '|' {
			cells = append(cells, seg{start, i})
			start = i + 1
		}
	}
	cells = append(cells, seg{start, e})
	return cells
}

var htmlBlockTags = words("address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup",
	"dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset",
	"h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu",
	"menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody",
	"td", "tfoot", "th", "thead", "title", "tr", "track", "ul")

// htmlStart reads the start of an HTML block: what ends it, or that a
// blank line does.
func htmlStart(rest []byte, inPara bool) (end string, blankEnds, ok bool) {
	if len(rest) < 2 || rest[0] != '<' {
		return "", false, false
	}
	lower := bytes.ToLower(rest[:min(len(rest), 16)])
	for _, t := range []string{"script", "pre", "style", "textarea"} {
		if bytes.HasPrefix(lower[1:], []byte(t)) {
			n := 1 + len(t)
			if n == len(lower) || lower[n] == ' ' || lower[n] == '>' || lower[n] == '\t' {
				return "</" + t + ">", false, true
			}
		}
	}
	switch {
	case bytes.HasPrefix(rest, []byte("<!--")):
		return "-->", false, true
	case bytes.HasPrefix(rest, []byte("<?")):
		return "?>", false, true
	case bytes.HasPrefix(rest, []byte("<![CDATA[")):
		return "]]>", false, true
	case len(rest) > 2 && rest[1] == '!' && (rest[2] >= 'A' && rest[2] <= 'Z' || rest[2] >= 'a' && rest[2] <= 'z'):
		return ">", false, true
	}
	i := 1
	if rest[i] == '/' {
		i++
	}
	j := i
	for j < len(rest) && (isAlnum(rest[j]) || rest[j] == '-') {
		j++
	}
	if j == i {
		return "", false, false
	}
	name := strings.ToLower(string(rest[i:j]))
	if htmlBlockTags.has(name) && (j == len(rest) || rest[j] == ' ' || rest[j] == '\t' || rest[j] == '>' || bytes.HasPrefix(rest[j:], []byte("/>"))) {
		return "", true, true
	}
	// Any other complete tag alone on its line, which can't interrupt a
	// paragraph.
	if inPara {
		return "", false, false
	}
	if n := inlineHTML(rest, 0); n > 0 && isBlank(rest[n:]) && (rest[1] == '/' || isAlnum(rest[1])) {
		return "", true, true
	}
	return "", false, false
}
