package workspace

import (
	"bytes"
	"os"
	"runtime"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"deckle/internal/markdown"
)

// score matches q in s, preferring the characters of the base name, then
// those at word starts and following one another. It puts the byte offsets
// of the characters matched in pos, which is as long as q.
func score(s string, q []rune, pos []int) (int, bool) {
	j := 0
	for i := 0; i < len(s) && j < len(q); {
		r, size := rune(s[i]), 1
		if r >= utf8.RuneSelf {
			r, size = utf8.DecodeRuneInString(s[i:])
		}
		if lower(r) == q[j] {
			j++
		}
		i += size
	}
	if j < len(q) {
		return 0, false
	}
	base := strings.LastIndexByte(s, '/') + 1
	// Match greedily from the end, so that the base name takes what it
	// can, then score the positions.
	k := len(q) - 1
	for i := len(s); i > 0 && k >= 0; {
		r, size := rune(s[i-1]), 1
		if r >= utf8.RuneSelf {
			r, size = utf8.DecodeLastRuneInString(s[:i])
		}
		i -= size
		if lower(r) == q[k] {
			pos[k] = i
			k--
		}
	}
	if k >= 0 {
		return 0, false
	}
	total := 0
	for n, p := range pos {
		total += 10
		if p >= base {
			total += 8
		}
		if p == 0 || isBoundary(s, p) {
			total += 12
		}
		if n > 0 && pos[n-1]+utf8.RuneLen(q[n-1]) == p {
			total += 15
		}
		if n == 0 && p == base {
			total += 10
		}
	}
	total -= (len(s) - base) / 4 // shorter names first
	total -= strings.Count(s, "/")
	return total, true
}

func lower(r rune) rune {
	if r < utf8.RuneSelf {
		if 'A' <= r && r <= 'Z' {
			r += 'a' - 'A'
		}
		return r
	}
	return unicode.ToLower(r)
}

func isBoundary(s string, i int) bool {
	prev, _ := utf8.DecodeLastRuneInString(s[:i])
	cur, _ := utf8.DecodeRuneInString(s[i:])
	switch prev {
	case '/', '_', '-', '.', ' ':
		return true
	}
	return unicode.IsLower(prev) && unicode.IsUpper(cur)
}

// SearchResult is what a search of every note found.
type SearchResult struct {
	Files []SearchFile
	// Total is how many notes matched; Files holds at most 300.
	Total int
}

// SearchFile is a note's matches.
type SearchFile struct {
	Path, Title string
	Count       int
	Matches     []SearchMatch
}

// SearchMatch is a match, as its line reads around it.
type SearchMatch struct {
	Line int
	Text string
	// Column and Length are where the match is in Text, in bytes.
	Column, Length int
	// Offset and Units are where the match is in the note, in UTF-16 units.
	Offset, Units int
}

// Search searches the text of every note on a goroutine of its own, and
// calls done there with the results, unless a newer search started.
func (w *Workspace) Search(query string, token uint64, done func(SearchResult)) {
	w.search.Store(token)
	go func() {
		current := func() bool { return w.search.Load() == token && !w.closed.Load() }
		type entry struct {
			path, title string
			mod         time.Time
		}
		w.mu.RLock()
		paths := make([]entry, 0, len(w.idx.notes))
		for p, n := range w.idx.notes {
			paths = append(paths, entry{p, n.Title, n.Modified})
		}
		w.mu.RUnlock()
		slices.SortFunc(paths, func(a, b entry) int {
			if c := b.mod.Compare(a.mod); c != 0 {
				return c
			}
			return strings.Compare(a.path, b.path)
		})
		sensitive := strings.IndexFunc(query, unicode.IsUpper) >= 0
		needle := query
		if !sensitive {
			needle = strings.ToLower(query)
		}
		type hit struct {
			order int
			file  SearchFile
		}
		var mu sync.Mutex
		var hits []hit
		if needle != "" {
			workers := min(runtime.NumCPU(), 8)
			chunk := max((len(paths)+workers-1)/workers, 1)
			var wg sync.WaitGroup
			for start := 0; start < len(paths); start += chunk {
				part := paths[start:min(start+chunk, len(paths))]
				wg.Go(func() {
					for i, e := range part {
						if !current() {
							return
						}
						b, err := os.ReadFile(e.path)
						if err != nil {
							continue
						}
						if f, ok := searchFile(string(b), needle, sensitive, e.path, e.title); ok {
							mu.Lock()
							hits = append(hits, hit{start + i, f})
							mu.Unlock()
						}
					}
				})
			}
			wg.Wait()
		}
		if !current() {
			return
		}
		// Newest notes first, as the paths were ordered.
		slices.SortFunc(hits, func(a, b hit) int { return a.order - b.order })
		res := SearchResult{Total: len(hits)}
		for _, h := range hits[:min(300, len(hits))] {
			res.Files = append(res.Files, h.file)
		}
		if current() {
			done(res)
		}
	}()
}

// searchFile finds the matches of one note.
func searchFile(text, needle string, sensitive bool, path, title string) (SearchFile, bool) {
	hay := []byte(text)
	if !sensitive {
		if isASCII(needle) {
			// An ASCII needle: folding only ASCII keeps every byte in place,
			// so the offsets found hold in the text as it is.
			hay = asciiLower(hay)
		} else if l := strings.ToLower(text); len(l) == len(text) {
			hay = []byte(l)
		}
	}
	nb := []byte(needle)
	f := SearchFile{Path: path, Title: title}
	lineStart, lineNumber, units, counted := 0, 1, 0, 0
	// A line is listed once, at its first match, however many it has.
	listedTo := -1
	for at := 0; ; {
		i := bytes.Index(hay[at:], nb)
		if i < 0 {
			break
		}
		m := at + i
		at = m + max(len(nb), 1)
		f.Count++
		if len(f.Matches) >= 5 || !utf8.RuneStart(text[m]) || m <= listedTo {
			continue
		}
		for k, r := range text[counted:m] {
			if r == '\n' {
				lineNumber++
				lineStart = counted + k + 1
			}
			units += markdownUnits(r)
		}
		counted = m
		lineEnd := len(text)
		if j := strings.IndexByte(text[m:], '\n'); j >= 0 {
			lineEnd = m + j
		}
		listedTo = lineEnd
		shown, column := plainPreview(text[lineStart:lineEnd], m-lineStart, len(nb))
		end := min(m+len(nb), len(text))
		f.Matches = append(f.Matches, SearchMatch{Line: lineNumber, Text: shown, Column: column, Length: min(len(nb), len(shown)-column), Offset: units, Units: markdown.UnitsOf(text[m:end])})
	}
	return f, f.Count > 0
}

func markdownUnits(r rune) int {
	if r >= 0x10000 {
		return 2
	}
	return 1
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

func asciiLower(b []byte) []byte {
	out := make([]byte, len(b))
	for i, c := range b {
		if 'A' <= c && c <= 'Z' {
			c += 'a' - 'A'
		}
		out[i] = c
	}
	return out
}

func floorRune(s string, i int) int {
	for i > 0 && i < len(s) && !utf8.RuneStart(s[i]) {
		i--
	}
	return i
}

func ceilRune(s string, i int) int {
	for i < len(s) && !utf8.RuneStart(s[i]) {
		i++
	}
	return min(i, len(s))
}

// plainPreview is line as it reads around the n bytes at at: block and
// inline syntax taken out on either side, the matched text itself kept as
// it is. It returns the text, at most about 160 characters, and the byte
// offset of the match within it.
func plainPreview(line string, at, n int) (string, int) {
	// The block prefix goes when the match isn't in it.
	trimmed := strings.TrimLeft(line, " \t")
	stripped := stripBlockPrefix(trimmed)
	removed := len(line) - len(stripped)
	if at >= removed {
		line, at = stripped, at-removed
	} else {
		line, at = trimmed, max(at-(len(line)-len(trimmed)), 0)
	}
	end := at + n
	if end > len(line) || !utf8.RuneStart(line[min(at, len(line)-1)]) {
		return preview(line, min(at, len(line)))
	}
	start := floorRune(line, max(at-60, 0))
	stop := ceilRune(line, min(end+100, len(line)))
	before, hit := line[start:at], line[at:end]
	// A match in the target of a [[target|label]] reads as the target: the
	// alias after the match goes, since neither half sees the whole link.
	after := line[end:stop]
	if open := strings.LastIndex(line[:at], "[["); open >= 0 && !strings.Contains(line[open:at], "]]") {
		if c := strings.Index(line[end:], "]]"); c >= 0 {
			close := end + c
			if b := strings.IndexByte(line[open+2:close], '|'); b >= 0 && end <= open+2+b {
				bar := open + 2 + b
				after = line[end:bar] + line[min(close+2, stop):stop]
			}
		}
	}
	// plain trims its ends, so a mark stands in for the match while each
	// side is cleaned, and the space beside the match survives.
	const mark = "\x01"
	shown := ""
	if start > 0 {
		shown = "…"
	}
	shown += strings.TrimSuffix(plain(before+mark), mark)
	column := len(shown)
	shown += hit
	shown += strings.TrimPrefix(plain(mark+after), mark)
	return shown, column
}

// preview is at most 160 characters of line around byte at, and the byte
// offset of at within them.
func preview(line string, at int) (string, int) {
	start := floorRune(line, max(at-60, 0))
	lead := ""
	if start > 0 {
		lead = "…"
	}
	body := []rune(line[start:])
	return lead + string(body[:min(160, len(body))]), len(lead) + (at - start)
}
