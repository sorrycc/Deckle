package markdown

import "bytes"

// SplitSections returns the byte offsets where sections start: places
// where a new top-level block is certain to begin. The first is always 0.
// Each section is parsed on its own, so an edit reparses only the sections
// it touches.
func SplitSections(text string) []int {
	b := []byte(text)
	starts := []int{0}
	// The fence that opened a code block: its character, length and indent.
	var fenceCh byte
	fenceLen, fenceIndent := 0, 0
	inFence := false
	// The text that ends the HTML block we are in.
	htmlEnd := ""
	frontMatter := false
	prevBlank := true
	pos := 0
	first := true
	for pos < len(b) {
		end := len(b)
		if i := bytes.IndexByte(b[pos:], '\n'); i >= 0 {
			end = pos + i
		}
		line := b[pos:end]
		line = bytes.TrimSuffix(line, []byte("\r"))
		indent := 0
		for indent < len(line) && line[indent] == ' ' {
			indent++
		}
		blank := isBlank(line)

		if first {
			first = false
			if string(line) == "---" {
				frontMatter = true
				pos = end + 1
				continue
			}
		}
		if frontMatter {
			if s := string(line); s == "---" || s == "..." {
				frontMatter = false
				prevBlank = true
			}
			pos = end + 1
			continue
		}
		if htmlEnd != "" {
			if bytes.Contains(line, []byte(htmlEnd)) {
				htmlEnd = ""
			}
			prevBlank = false
			pos = end + 1
			continue
		}
		// A fence may sit in a quote or a list item.
		innerStart := 0
		for innerStart < len(line) && (line[innerStart] == ' ' || line[innerStart] == '>') {
			innerStart++
		}
		inner := line[innerStart:]
		ch, n := fenceRun(inner)
		if inFence {
			closes := n > 0 && ch == fenceCh && n >= fenceLen && isBlank(inner[n:])
			// A fence inside a list item or quote also ends where that item
			// does: at a line indented less that is not a quote line.
			dedent := fenceIndent >= 2 && !blank && innerStart < fenceIndent && innerStart == indent
			if closes {
				inFence = false
				prevBlank = false
				pos = end + 1
				continue
			} else if dedent {
				inFence = false
			} else {
				prevBlank = false
				pos = end + 1
				continue
			}
		}
		if n > 0 {
			// A backtick fence's info string has no backticks.
			if ch == '~' || bytes.IndexByte(inner[n:], '`') < 0 {
				inFence, fenceCh, fenceLen, fenceIndent = true, ch, n, innerStart
				// A fence at the margin after a blank line starts a block.
				if indent == 0 && innerStart == 0 && prevBlank && pos > 0 && lineHash(line)%chunk == 0 {
					starts = append(starts, pos)
				}
				prevBlank = false
				pos = end + 1
				continue
			}
		}
		if indent == 0 && !blank {
			if e := htmlBlockEnd(line); e != "" {
				if !bytes.Contains(line[2:], []byte(e)) {
					htmlEnd = e
				}
			} else if pos > 0 && (isATXHeading(line) || ((prevBlank || isBulletItem(line)) && lineHash(line)%chunk == 0)) {
				// A bullet item at the margin starts a block even without a
				// blank line before it, so a long tight list, such as a
				// checklist or a log, is parsed in pieces too.
				starts = append(starts, pos)
			}
		}
		prevBlank = blank
		pos = end + 1
	}
	return starts
}

// One paragraph in this many starts a section, besides every heading.
const chunk = 8

func lineHash(line []byte) uint32 {
	h := uint32(0x811c9dc5)
	for i, c := range line {
		if i == 48 {
			break
		}
		h = (h ^ uint32(c)) * 0x01000193
	}
	return h >> 7
}

func isBlank(b []byte) bool {
	for _, c := range b {
		if !isSpace(c) {
			return false
		}
	}
	return true
}

// fenceRun is the run of ``` or ~~~ (three or more) that s starts with.
func fenceRun(s []byte) (byte, int) {
	if len(s) == 0 || (s[0] != '`' && s[0] != '~') {
		return 0, 0
	}
	n := 0
	for n < len(s) && s[n] == s[0] {
		n++
	}
	if n < 3 {
		return 0, 0
	}
	return s[0], n
}

// isBulletItem is a bullet list item with text, which can begin a block
// anywhere: not a thematic break such as `- - -`, and not an empty item.
func isBulletItem(line []byte) bool {
	if len(line) < 2 || (line[0] != '-' && line[0] != '*' && line[0] != '+') || line[1] != ' ' {
		return false
	}
	for _, c := range line[2:] {
		if c != line[0] && c != ' ' && c != '\t' {
			return true
		}
	}
	return false
}

func isATXHeading(line []byte) bool {
	n := 0
	for n < len(line) && line[n] == '#' {
		n++
	}
	return n >= 1 && n <= 6 && (len(line) == n || line[n] == ' ' || line[n] == '\t')
}

// htmlBlockEnd is, for a line that opens an HTML block which blank lines
// don't end, the text that ends it.
func htmlBlockEnd(line []byte) string {
	if len(line) == 0 || line[0] != '<' {
		return ""
	}
	lower := bytes.ToLower(line[:min(len(line), 12)])
	for _, p := range [][2]string{{"<!--", "-->"}, {"<pre", "</pre>"}, {"<script", "</script>"}, {"<style", "</style>"}, {"<textarea", "</textarea>"}} {
		if bytes.HasPrefix(lower, []byte(p[0])) {
			return p[1]
		}
	}
	return ""
}
