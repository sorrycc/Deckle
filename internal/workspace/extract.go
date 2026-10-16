package workspace

import (
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"
)

func lines(text string) []string {
	ls := strings.Split(text, "\n")
	for i, l := range ls {
		ls[i] = strings.TrimSuffix(l, "\r")
	}
	if n := len(ls); n > 0 && ls[n-1] == "" {
		ls = ls[:n-1]
	}
	return ls
}

func extract(text, path string) *Note {
	n := &Note{}
	ls := lines(text)
	i := 0
	if len(ls) > 0 && strings.TrimRight(ls[0], " \t") == "---" {
		for i = 1; i < len(ls); i++ {
			line := strings.TrimRight(ls[i], " \t")
			if line == "---" || line == "..." {
				i++
				break
			}
			if v, ok := strings.CutPrefix(line, "title:"); ok {
				n.Title = strings.Trim(strings.TrimSpace(v), `"'`)
			}
		}
	}
	inFence := false
	var excerpt strings.Builder
	for ; i < len(ls); i++ {
		line := ls[i]
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
			inFence = !inFence
			continue
		}
		if inFence {
			continue
		}
		linksIn(line, &n.Links)
		if n.Image == "" {
			if src, ok := firstImage(trimmed); ok {
				n.Image = resolveImage(src, path)
			}
		}
		if trimmed == "" || isRule(trimmed) {
			continue
		}
		// Headings and images are not part of the excerpt.
		if h, ok := atxHeading(trimmed); ok {
			if n.Title == "" {
				n.Title = plain(h)
			}
			continue
		}
		if strings.HasPrefix(trimmed, "![") {
			continue
		}
		if excerpt.Len() < 320 {
			// A table's row reads as its cells; the row of dashes under its
			// header says nothing.
			if isTableDelimiter(trimmed) {
				continue
			}
			t := plain(stripBlockPrefix(tableCells(trimmed)))
			if t != "" {
				if excerpt.Len() > 0 {
					excerpt.WriteByte(' ')
				}
				excerpt.WriteString(t)
			}
		}
	}
	if n.Title == "" {
		base := filepath.Base(path)
		n.Title = strings.TrimSuffix(base, filepath.Ext(base))
	}
	r := []rune(excerpt.String())
	n.Excerpt = string(r[:min(200, len(r))])
	slices.Sort(n.Links)
	n.Links = slices.Compact(n.Links)
	return n
}

// NaturalCompare orders titles as a person reads them: case doesn't
// matter, and runs of digits compare by value, so "Note 2" comes before
// "Note 10".
func NaturalCompare(a, b string) int {
	i, j := 0, 0
	for {
		if i >= len(a) && j >= len(b) {
			return 0
		}
		if i >= len(a) {
			return -1
		}
		if j >= len(b) {
			return 1
		}
		x, xs := utf8.DecodeRuneInString(a[i:])
		y, ys := utf8.DecodeRuneInString(b[j:])
		if isASCIIDigit(x) && isASCIIDigit(y) {
			ia, jb := i, j
			for ia < len(a) && isASCIIDigit(rune(a[ia])) {
				ia++
			}
			for jb < len(b) && isASCIIDigit(rune(b[jb])) {
				jb++
			}
			ta, tb := strings.TrimLeft(a[i:ia], "0"), strings.TrimLeft(b[j:jb], "0")
			if len(ta) != len(tb) {
				return len(ta) - len(tb)
			}
			if c := strings.Compare(ta, tb); c != 0 {
				return c
			}
			i, j = ia, jb
			continue
		}
		lx, ly := unicode.ToLower(x), unicode.ToLower(y)
		if lx != ly {
			if lx < ly {
				return -1
			}
			return 1
		}
		i += xs
		j += ys
	}
}

func isASCIIDigit(r rune) bool { return r >= '0' && r <= '9' }

func atxHeading(line string) (string, bool) {
	n := 0
	for n < len(line) && line[n] == '#' {
		n++
	}
	if n >= 1 && n <= 6 && n < len(line) && line[n] == ' ' {
		return strings.TrimSpace(strings.TrimRight(strings.TrimSpace(line[n:]), "#")), true
	}
	return "", false
}

// isTableDelimiter reports whether line is the row of dashes and colons
// under a table's header.
func isTableDelimiter(line string) bool {
	inner := strings.Trim(strings.TrimSpace(line), "|")
	if inner == "" || !strings.Contains(inner, "-") {
		return false
	}
	for _, c := range inner {
		if !strings.ContainsRune("|-: \t", c) {
			return false
		}
	}
	return true
}

// tableCells is a table row as its cells, separated by dots, or line as it
// is when it isn't one.
func tableCells(line string) string {
	if !strings.HasPrefix(line, "|") {
		return line
	}
	var cells []string
	for _, c := range strings.Split(strings.Trim(line, "|"), "|") {
		if c = strings.TrimSpace(c); c != "" {
			cells = append(cells, c)
		}
	}
	return strings.Join(cells, " · ")
}

// isRule is a thematic break, or the underline of a setext heading.
func isRule(line string) bool {
	var marks []rune
	for _, c := range line {
		if c != ' ' {
			marks = append(marks, c)
		}
	}
	if len(marks) < 3 || !strings.ContainsRune("-*_=", marks[0]) {
		return false
	}
	for _, c := range marks {
		if c != marks[0] {
			return false
		}
	}
	return true
}

// stripBlockPrefix is line without the block syntax at its start: heading
// marks, quote marks, list markers and task boxes. "2026-09-28" is not a
// list item, and a [x] is a task box only after a list marker.
func stripBlockPrefix(line string) string {
	afterMarker := false
	for {
		t := strings.TrimLeft(line, " \t")
		blank := func(i int) bool { return i >= len(t) || t[i] == ' ' || t[i] == '\t' }
		hashes := 0
		for hashes < len(t) && t[hashes] == '#' {
			hashes++
		}
		was := afterMarker
		afterMarker = false
		digits := 0
		for digits < len(t) && isASCIIDigit(rune(t[digits])) {
			digits++
		}
		switch {
		case hashes >= 1 && hashes <= 6 && blank(hashes):
			line = t[hashes:]
		case strings.HasPrefix(t, ">"):
			line = t[1:]
		case len(t) > 0 && (t[0] == '-' || t[0] == '*' || t[0] == '+') && blank(1):
			line = t[1:]
			afterMarker = true
		case digits > 0 && digits < 10 && digits < len(t) && (t[digits] == '.' || t[digits] == ')') && blank(digits+1):
			line = t[digits+1:]
			afterMarker = true
		case was && len(t) >= 3 && t[0] == '[' && (t[1] == ' ' || t[1] == 'x' || t[1] == 'X') && t[2] == ']' && blank(3):
			line = t[3:]
		default:
			return t
		}
	}
}

// plain is line as it reads, without Markdown's inline syntax.
func plain(line string) string {
	r := []rune(line)
	var out []rune
	prev := ' '
	for i := 0; i < len(r); i++ {
		c := r[i]
		var next rune
		if i+1 < len(r) {
			next = r[i+1]
		}
		doubled := next == c || prev == c
		prev = c
		switch {
		case (c == '_' || c == '~' || c == '=') && doubled:
		case c == '*' || c == '`':
		case c == '!' && next == '[':
		case c == '[':
			// A wikilink reads as its label, or its target.
			if next == '[' {
				i++
				var inner []rune
				for i+1 < len(r) {
					i++
					if r[i] == ']' {
						if i+1 < len(r) {
							i++
						}
						break
					}
					inner = append(inner, r[i])
				}
				s := string(inner)
				out = append(out, []rune(s[strings.LastIndexByte(s, '|')+1:])...)
			}
		case c == ']':
			// A link's destination is left out, when it is all there.
			if next == '(' && slices.Contains(r[i+1:], ')') {
				for i+1 < len(r) {
					i++
					if r[i] == ')' {
						break
					}
				}
			}
		default:
			out = append(out, c)
		}
	}
	return strings.Join(strings.Fields(string(out)), " ")
}

// linksIn adds the targets of the wikilinks in line: what comes before |
// and #, lowercased.
func linksIn(line string, out *[]string) {
	rest := line
	for {
		i := strings.Index(rest, "[[")
		if i < 0 {
			return
		}
		rest = rest[i+2:]
		end := strings.Index(rest, "]]")
		if end < 0 {
			return
		}
		inner := rest[:end]
		if k := strings.IndexAny(inner, "|#"); k >= 0 {
			inner = inner[:k]
		}
		if t := strings.TrimSpace(inner); t != "" {
			*out = append(*out, strings.ToLower(t))
		}
		rest = rest[end+2:]
	}
}

func firstImage(line string) (string, bool) {
	if i := strings.Index(line, "![["); i >= 0 {
		rest := line[i+3:]
		end := strings.Index(rest, "]]")
		if end < 0 {
			return "", false
		}
		s := rest[:end]
		if k := strings.IndexByte(s, '|'); k >= 0 {
			s = s[:k]
		}
		return strings.TrimSpace(s), true
	}
	i := strings.Index(line, "![")
	if i < 0 {
		return "", false
	}
	rest := line[i:]
	open := strings.Index(rest, "](")
	if open < 0 {
		return "", false
	}
	rest = rest[open+2:]
	end := strings.IndexAny(rest, ") ")
	if end < 0 {
		return "", false
	}
	return strings.Trim(rest[:end], "<>"), true
}

func resolveImage(src, note string) string {
	if src == "" || strings.Contains(src, "://") {
		return ""
	}
	if d, err := url.PathUnescape(src); err == nil {
		src = d
	}
	p := filepath.Join(filepath.Dir(note), src)
	if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() {
		return p
	}
	return ""
}

// Plain is a line as it reads, without block or inline syntax.
func Plain(line string) string { return plain(stripBlockPrefix(line)) }
