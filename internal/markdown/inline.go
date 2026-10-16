package markdown

import (
	"bytes"
	"unicode"
	"unicode/utf8"
)

// The inline structure of a paragraph, heading or cell: code, math, HTML,
// links, wikilinks and emphasis, after CommonMark's delimiter algorithm.
// Its lines are joined with \n into one text, whose offsets map back to
// the source.

type inlineKind uint8

const (
	iEmph inlineKind = iota
	iCode
	iMath
	iDisplayMath
	iHTML
	iAutolink
	iWiki
	iLink
	iImage
)

type inlineNode struct {
	kind                 inlineKind
	start, end           int // the whole element
	innerStart, innerEnd int
	ch                   byte // of emphasis
	n                    int  // delimiters of emphasis, backticks of code
	pipe                 int  // of a wikilink, or -1
}

type delim struct {
	ch         byte
	pos, count int
	orig       int
	canOpen    bool
	canClose   bool
	removed    bool
}

type bracket struct {
	pos       int
	image     bool
	active    bool
	delimBase int
}

type inlineParser struct {
	v        []byte
	refs     map[string]bool
	nodes    []inlineNode
	delims   []*delim
	brackets []bracket
	// used marks syntax; literal marks the text of links and images. What
	// is neither is text.
	used    []bool
	literal []bool
}

func parseInline(v []byte, refs map[string]bool) *inlineParser {
	p := &inlineParser{v: v, refs: refs, used: make([]bool, len(v)), literal: make([]bool, len(v))}
	p.scan()
	p.processEmphasis(0)
	return p
}

func (p *inlineParser) at(i int) byte {
	if i >= 0 && i < len(p.v) {
		return p.v[i]
	}
	return 0
}

func (p *inlineParser) mark(flags []bool, s, e int) {
	for i := max(s, 0); i < e && i < len(flags); i++ {
		flags[i] = true
	}
}

func isASCIIPunct(c byte) bool {
	return c >= '!' && c <= '/' || c >= ':' && c <= '@' || c >= '[' && c <= '`' || c >= '{' && c <= '~'
}

func (p *inlineParser) scan() {
	v := p.v
	i := 0
	for i < len(v) {
		switch c := v[i]; c {
		case '\\':
			if i+1 < len(v) && (isASCIIPunct(v[i+1]) || v[i+1] == '\n') {
				p.mark(p.used, i, i+2)
				i += 2
				continue
			}
			i++
		case '`':
			n := run(v, i, '`')
			if j := closingTicks(v, i+n, n); j >= 0 {
				p.nodes = append(p.nodes, inlineNode{kind: iCode, start: i, end: j + n, n: n})
				p.mark(p.used, i, j+n)
				i = j + n
				continue
			}
			i += n
		case '<':
			if n := autolink(v, i); n > 0 {
				p.nodes = append(p.nodes, inlineNode{kind: iAutolink, start: i, end: i + n})
				p.mark(p.used, i, i+n)
				i += n
				continue
			}
			if n := inlineHTML(v, i); n > 0 {
				p.nodes = append(p.nodes, inlineNode{kind: iHTML, start: i, end: i + n})
				p.mark(p.used, i, i+n)
				i += n
				continue
			}
			i++
		case '$':
			if p.at(i+1) == '$' {
				if j := bytes.Index(v[i+2:], []byte("$$")); j > 0 {
					end := i + 2 + j + 2
					p.nodes = append(p.nodes, inlineNode{kind: iDisplayMath, start: i, end: end})
					p.mark(p.used, i, end)
					i = end
					continue
				}
				i += 2
				continue
			}
			if j := closingDollar(v, i+1); j > 0 {
				p.nodes = append(p.nodes, inlineNode{kind: iMath, start: i, end: j + 1})
				p.mark(p.used, i, j+1)
				i = j + 1
				continue
			}
			i++
		case '[':
			if p.at(i+1) == '[' {
				if n, pipe := wikilink(v, i); n > 0 {
					p.nodes = append(p.nodes, inlineNode{kind: iWiki, start: i, end: i + n, pipe: pipe})
					p.mark(p.used, i, i+n)
					i += n
					continue
				}
			}
			p.brackets = append(p.brackets, bracket{pos: i, active: true, delimBase: len(p.delims)})
			i++
		case '!':
			if p.at(i+1) == '[' && p.at(i+2) != '[' {
				p.brackets = append(p.brackets, bracket{pos: i, image: true, active: true, delimBase: len(p.delims)})
				i += 2
				continue
			}
			i++
		case ']':
			i = p.closeBracket(i)
		case '*', '_', '~':
			n := run(v, i, c)
			before, _ := utf8.DecodeLastRune(v[:i])
			if i == 0 {
				before = '\n'
			}
			after, _ := utf8.DecodeRune(v[i+n:])
			if i+n >= len(v) {
				after = '\n'
			}
			wsB, wsA := unicode.IsSpace(before), unicode.IsSpace(after)
			puB, puA := isPunct(before), isPunct(after)
			left := !wsA && (!puA || wsB || puB)
			right := !wsB && (!puB || wsA || puA)
			d := &delim{ch: c, pos: i, count: n, orig: n, canOpen: left, canClose: right}
			if c == '_' {
				d.canOpen = left && (!right || puB)
				d.canClose = right && (!left || puA)
			}
			if c == '~' && n > 2 {
				d.canOpen, d.canClose = false, false
			}
			p.delims = append(p.delims, d)
			i += n
		default:
			i++
		}
	}
}

func isPunct(r rune) bool {
	if r < utf8.RuneSelf {
		return isASCIIPunct(byte(r))
	}
	return unicode.IsPunct(r) || unicode.IsSymbol(r)
}

func run(v []byte, i int, c byte) int {
	n := 0
	for i+n < len(v) && v[i+n] == c {
		n++
	}
	return n
}

// closingTicks finds a run of exactly n backticks from i, or -1.
func closingTicks(v []byte, i, n int) int {
	for i < len(v) {
		j := bytes.IndexByte(v[i:], '`')
		if j < 0 {
			return -1
		}
		j += i
		m := run(v, j, '`')
		if m == n {
			return j
		}
		i = j + m
	}
	return -1
}

// closingDollar finds the $ that closes inline math opened before i: the
// math is not empty, does not start or end with a space, and the closing $
// is not followed by a digit.
func closingDollar(v []byte, i int) int {
	if i >= len(v) || v[i] == ' ' || v[i] == '\n' || v[i] == '\t' {
		return -1
	}
	for j := i; j < len(v); j++ {
		switch v[j] {
		case '\\':
			j++
		case '$':
			if j == i || v[j-1] == ' ' || v[j-1] == '\t' || v[j-1] == '\n' {
				return -1
			}
			if j+1 < len(v) && isDigit(v[j+1]) {
				return -1
			}
			return j
		}
	}
	return -1
}

// wikilink reads [[target]] or [[target|label]] at i: its length and where
// its pipe is, or 0.
func wikilink(v []byte, i int) (int, int) {
	j := bytes.Index(v[i+2:], []byte("]]"))
	if j <= 0 {
		return 0, -1
	}
	inner := v[i+2 : i+2+j]
	if bytes.IndexByte(inner, '\n') >= 0 || bytes.IndexByte(inner, '[') >= 0 || bytes.IndexByte(inner, ']') >= 0 {
		return 0, -1
	}
	pipe := -1
	if k := bytes.IndexByte(inner, '|'); k >= 0 {
		pipe = i + 2 + k
	}
	return j + 4, pipe
}

// autolink reads <scheme:address> or <user@host> at i, or returns 0.
func autolink(v []byte, i int) int {
	j := i + 1
	k := j
	for k < len(v) && (isAlnum(v[k]) || v[k] == '+' || v[k] == '.' || v[k] == '-') {
		k++
	}
	if k-j >= 2 && k-j <= 32 && k < len(v) && v[k] == ':' && (v[j] >= 'a' && v[j] <= 'z' || v[j] >= 'A' && v[j] <= 'Z') {
		for m := k + 1; m < len(v); m++ {
			switch c := v[m]; {
			case c == '>':
				return m + 1 - i
			case c == '<' || c <= ' ':
				return 0
			}
		}
		return 0
	}
	// An email address.
	at := -1
	for m := j; m < len(v); m++ {
		c := v[m]
		switch {
		case c == '>':
			if at > j && m > at+1 {
				return m + 1 - i
			}
			return 0
		case c == '@':
			if at >= 0 {
				return 0
			}
			at = m
		case isAlnum(c) || bytes.IndexByte([]byte(".!#$%&'*+/=?^_`{|}~-"), c) >= 0:
		default:
			return 0
		}
	}
	return 0
}

// inlineHTML reads a tag, a comment, a processing instruction, a
// declaration or CDATA at i, and returns its length, or 0.
func inlineHTML(v []byte, i int) int {
	rest := v[i:]
	find := func(open, close string) int {
		if !bytes.HasPrefix(rest, []byte(open)) {
			return -1
		}
		if j := bytes.Index(rest[len(open):], []byte(close)); j >= 0 {
			return len(open) + j + len(close)
		}
		return 0
	}
	for _, p := range [][2]string{{"<!--", "-->"}, {"<?", "?>"}, {"<![CDATA[", "]]>"}} {
		if n := find(p[0], p[1]); n >= 0 {
			return n
		}
	}
	if len(rest) > 2 && rest[1] == '!' && (rest[2] >= 'A' && rest[2] <= 'Z' || rest[2] >= 'a' && rest[2] <= 'z') {
		if j := bytes.IndexByte(rest, '>'); j > 0 {
			return j + 1
		}
		return 0
	}
	j := 1
	closing := false
	if j < len(rest) && rest[j] == '/' {
		closing = true
		j++
	}
	if j >= len(rest) || !(rest[j] >= 'a' && rest[j] <= 'z' || rest[j] >= 'A' && rest[j] <= 'Z') {
		return 0
	}
	for j < len(rest) && (isAlnum(rest[j]) || rest[j] == '-') {
		j++
	}
	if closing {
		for j < len(rest) && isSpace(rest[j]) {
			j++
		}
		if j < len(rest) && rest[j] == '>' {
			return j + 1
		}
		return 0
	}
	// Attributes, then > or />.
	var quote byte
	for ; j < len(rest); j++ {
		c := rest[j]
		switch {
		case quote != 0:
			if c == quote {
				quote = 0
			}
		case c == '"' || c == '\'':
			if j > 0 && rest[j-1] == '=' {
				quote = c
			} else {
				return 0
			}
		case c == '>':
			return j + 1
		case c == '<':
			return 0
		}
	}
	return 0
}

func (p *inlineParser) closeBracket(i int) int {
	if len(p.brackets) == 0 {
		return i + 1
	}
	op := p.brackets[len(p.brackets)-1]
	p.brackets = p.brackets[:len(p.brackets)-1]
	if !op.active {
		return i + 1
	}
	innerStart := op.pos + 1
	if op.image {
		innerStart = op.pos + 2
	}
	end := -1
	if p.at(i+1) == '(' {
		end = inlineDestination(p.v, i+2)
	}
	if end < 0 {
		label := ""
		after := i + 1
		if p.at(i+1) == '[' {
			if k := bytes.IndexByte(p.v[i+2:], ']'); k >= 0 {
				label = string(p.v[i+2 : i+2+k])
				after = i + 3 + k
			}
		}
		if label == "" {
			label = string(p.v[innerStart:i])
		}
		if len(label) > 0 && label[0] != '^' && p.refs[normalizeLabel(label)] {
			end = after
		}
	}
	if end < 0 {
		return i + 1
	}
	kind := iLink
	if op.image {
		kind = iImage
	}
	p.nodes = append(p.nodes, inlineNode{kind: kind, start: op.pos, end: end, innerStart: innerStart, innerEnd: i})
	p.mark(p.used, op.pos, innerStart)
	p.mark(p.used, i, end)
	p.mark(p.literal, innerStart, i)
	p.processEmphasis(op.delimBase)
	if !op.image {
		for k := range p.brackets {
			if !p.brackets[k].image {
				p.brackets[k].active = false
			}
		}
	}
	return end
}

// inlineDestination reads the `url "title")` of an inline link from i,
// just past its `(`, and returns where it ends, or -1.
func inlineDestination(v []byte, i int) int {
	skip := func() {
		for i < len(v) && (v[i] == ' ' || v[i] == '\t' || v[i] == '\n') {
			i++
		}
	}
	skip()
	if i < len(v) && v[i] == '<' {
		j := i + 1
		for j < len(v) && v[j] != '>' && v[j] != '\n' && v[j] != '<' {
			if v[j] == '\\' {
				j++
			}
			j++
		}
		if j >= len(v) || v[j] != '>' {
			return -1
		}
		i = j + 1
	} else {
		depth := 0
		for i < len(v) {
			c := v[i]
			if c == '\\' {
				i += 2
				continue
			}
			if c == '(' {
				depth++
			} else if c == ')' {
				if depth == 0 {
					break
				}
				depth--
			} else if c <= ' ' {
				break
			}
			i++
		}
	}
	start := i
	skip()
	if i < len(v) && (v[i] == '"' || v[i] == '\'' || v[i] == '(') && i > start {
		close := v[i]
		if close == '(' {
			close = ')'
		}
		j := i + 1
		for j < len(v) && v[j] != close {
			if v[j] == '\\' {
				j++
			}
			j++
		}
		if j >= len(v) {
			return -1
		}
		i = j + 1
		skip()
	}
	if i < len(v) && v[i] == ')' {
		return i + 1
	}
	return -1
}

func (p *inlineParser) processEmphasis(base int) {
	type key struct {
		ch   byte
		open bool
		mod  int
	}
	bottoms := map[key]int{}
	ds := p.delims
	for ci := base; ci < len(ds); ci++ {
		cl := ds[ci]
		if cl.removed || !cl.canClose || cl.count == 0 {
			continue
		}
		for cl.count > 0 {
			k := key{cl.ch, cl.canOpen, cl.orig % 3}
			bottom := base - 1
			if b, ok := bottoms[k]; ok && b > bottom {
				bottom = b
			}
			oi := -1
			for j := ci - 1; j > bottom; j-- {
				op := ds[j]
				if op.removed || op.ch != cl.ch || !op.canOpen || op.count == 0 {
					continue
				}
				if cl.ch == '~' {
					if op.count != cl.count {
						continue
					}
				} else if (op.canClose || cl.canOpen) && (op.orig+cl.orig)%3 == 0 && !(op.orig%3 == 0 && cl.orig%3 == 0) {
					continue
				}
				oi = j
				break
			}
			if oi < 0 {
				bottoms[k] = ci - 1
				if !cl.canOpen {
					cl.removed = true
				}
				break
			}
			op := ds[oi]
			n := 1
			if cl.ch == '~' {
				n = cl.count
			} else if op.count >= 2 && cl.count >= 2 {
				n = 2
			}
			start := op.pos + op.count - n
			end := cl.pos + n
			p.nodes = append(p.nodes, inlineNode{kind: iEmph, ch: cl.ch, n: n, start: start, end: end, innerStart: start + n, innerEnd: end - n})
			p.mark(p.used, start, start+n)
			p.mark(p.used, cl.pos, cl.pos+n)
			op.count -= n
			cl.pos += n
			cl.count -= n
			for j := oi + 1; j < ci; j++ {
				ds[j].removed = true
			}
			if op.count == 0 {
				op.removed = true
			}
		}
	}
	p.delims = p.delims[:base]
}
