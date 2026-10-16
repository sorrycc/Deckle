package markdown

import (
	"bytes"
	"strings"
)

// A small lexer for code: comments, strings, numbers, keywords and the like,
// by language. It knows no grammar, which keeps it fast and good enough for
// reading code in a note.

type lang struct {
	lineComments []string
	blockComment [2]string
	// Characters that open and close a string.
	quotes string
	// Strings that run over several lines.
	longStrings  [][2]string
	keywords     set
	constants    set
	types        set
	capitalTypes bool
	ignoreCase   bool
}

type set map[string]struct{}

func words(s ...string) set {
	m := make(set, len(s))
	for _, w := range s {
		m[w] = struct{}{}
	}
	return m
}

func (s set) has(w string) bool { _, ok := s[w]; return ok }

var basicConstants = words("true", "false", "null")

func base() lang { return lang{quotes: `"'`, constants: basicConstants} }

func cLike() lang {
	l := base()
	l.lineComments = []string{"//"}
	l.blockComment = [2]string{"/*", "*/"}
	l.capitalTypes = true
	return l
}

var langs = map[string]*lang{}

func init() {
	add := func(l lang, names ...string) {
		for _, n := range names {
			langs[n] = &l
		}
	}
	l := cLike()
	l.quotes = `"`
	l.keywords = words("as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if",
		"impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
		"struct", "super", "trait", "type", "unsafe", "use", "where", "while")
	l.constants = words("true", "false", "None", "Some", "Ok", "Err")
	l.types = words("bool", "char", "str", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f32", "f64")
	add(l, "rust", "rs")

	l = cLike()
	l.quotes = `"`
	l.longStrings = [][2]string{{`"""`, `"""`}}
	l.keywords = words("actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default",
		"defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func",
		"guard", "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating", "open", "operator",
		"override", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "some",
		"static", "struct", "subscript", "super", "switch", "throw", "throws", "try", "typealias", "var", "weak",
		"where", "while")
	l.constants = words("true", "false", "nil")
	add(l, "swift")

	l = cLike()
	l.longStrings = [][2]string{{"`", "`"}}
	l.keywords = words("abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
		"declare", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for", "from",
		"function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "namespace",
		"new", "of", "private", "protected", "public", "readonly", "return", "satisfies", "set", "static", "super",
		"switch", "this", "throw", "try", "type", "typeof", "var", "void", "while", "with", "yield")
	l.constants = words("true", "false", "null", "undefined", "NaN", "Infinity")
	l.types = words("any", "boolean", "never", "number", "object", "string", "symbol", "unknown", "bigint")
	add(l, "javascript", "js", "jsx", "mjs", "cjs", "typescript", "ts", "tsx", "mts")

	l = base()
	l.lineComments = []string{"#"}
	l.longStrings = [][2]string{{`"""`, `"""`}, {"'''", "'''"}}
	l.keywords = words("and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
		"finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "case", "nonlocal", "not",
		"or", "pass", "raise", "return", "try", "while", "with", "yield", "self")
	l.constants = words("True", "False", "None")
	l.types = words("int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object")
	l.capitalTypes = true
	add(l, "python", "py")

	l = cLike()
	l.longStrings = [][2]string{{"`", "`"}}
	l.keywords = words("break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go",
		"goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var")
	l.constants = words("true", "false", "nil", "iota")
	l.types = words("bool", "byte", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any")
	add(l, "go", "golang")

	l = cLike()
	l.keywords = words("alignas", "auto", "break", "case", "catch", "class", "const", "constexpr", "continue", "default", "delete",
		"do", "else", "enum", "explicit", "extern", "final", "for", "friend", "goto", "if", "inline", "namespace",
		"new", "noexcept", "operator", "override", "private", "protected", "public", "register", "return", "sizeof",
		"static", "struct", "switch", "template", "this", "throw", "try", "typedef", "typename", "union", "using",
		"virtual", "volatile", "while", "#include", "#define", "#if", "#ifdef", "#ifndef", "#else", "#endif", "#pragma", "#import")
	l.constants = words("true", "false", "NULL", "nullptr", "nil", "YES", "NO")
	l.types = words("bool", "char", "double", "float", "int", "long", "short", "signed", "unsigned", "void", "size_t", "uint8_t",
		"uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t")
	add(l, "c", "h", "cpp", "c++", "cc", "cxx", "hpp", "objc", "objective-c", "m", "mm")

	l = cLike()
	l.longStrings = [][2]string{{`"""`, `"""`}}
	l.keywords = words("abstract", "as", "async", "await", "break", "case", "catch", "class", "companion", "const", "continue", "data",
		"default", "do", "else", "enum", "extends", "final", "finally", "for", "fun", "get", "if", "implements",
		"import", "in", "instanceof", "interface", "internal", "is", "lateinit", "namespace", "new", "object",
		"open", "override", "package", "private", "protected", "public", "return", "sealed", "set", "static", "super",
		"suspend", "switch", "this", "throw", "throws", "try", "using", "val", "var", "void", "when", "while", "yield")
	l.types = words("boolean", "byte", "char", "double", "float", "int", "long", "short", "string", "bool", "dynamic")
	add(l, "java", "kotlin", "kt", "scala", "csharp", "cs", "c#", "dart")

	l = base()
	l.lineComments = []string{"#"}
	l.keywords = words("alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "for", "if",
		"in", "module", "next", "not", "or", "redo", "require", "rescue", "retry", "return", "self", "super", "then",
		"unless", "until", "when", "while", "yield")
	l.constants = words("true", "false", "nil")
	l.capitalTypes = true
	add(l, "ruby", "rb")

	l = cLike()
	l.lineComments = []string{"//", "#"}
	l.keywords = words("abstract", "as", "break", "case", "catch", "class", "const", "continue", "default", "do", "echo", "else",
		"elseif", "extends", "final", "finally", "fn", "for", "foreach", "function", "if", "implements", "interface",
		"namespace", "new", "private", "protected", "public", "return", "static", "switch", "throw", "trait", "try",
		"use", "var", "while")
	add(l, "php")

	l = base()
	l.lineComments = []string{"#"}
	l.keywords = words("if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function",
		"return", "local", "export", "source", "alias", "set", "unset", "echo", "exit", "cd")
	add(l, "shell", "sh", "bash", "zsh", "fish", "console")

	l = base()
	l.lineComments = []string{"--"}
	l.blockComment = [2]string{"/*", "*/"}
	l.quotes = `'"`
	l.keywords = words("select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "index",
		"view", "drop", "alter", "add", "column", "join", "left", "right", "inner", "outer", "on", "as", "and", "or",
		"not", "in", "is", "like", "between", "group", "by", "order", "having", "limit", "offset", "union", "all",
		"distinct", "primary", "key", "foreign", "references", "default", "case", "when", "then", "else", "end",
		"begin", "commit", "rollback", "with", "exists", "asc", "desc")
	l.types = words("int", "integer", "text", "varchar", "boolean", "date", "timestamp", "real", "blob", "bigint", "numeric")
	l.ignoreCase = true
	add(l, "sql")

	l = base()
	l.lineComments = []string{"--"}
	l.blockComment = [2]string{"--[[", "]]"}
	l.keywords = words("and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or",
		"repeat", "return", "then", "until", "while")
	l.constants = words("true", "false", "nil")
	add(l, "lua")

	l = cLike()
	l.quotes = `"`
	l.keywords = words("const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "struct", "enum", "union",
		"defer", "errdefer", "try", "catch", "comptime", "inline", "break", "continue", "orelse", "test", "export",
		"extern", "usingnamespace", "and", "or")
	l.constants = words("true", "false", "null", "undefined")
	add(l, "zig")

	l = base()
	l.blockComment = [2]string{"/*", "*/"}
	add(l, "css", "scss", "less")

	l = base()
	l.lineComments = []string{"#", ";"}
	l.longStrings = [][2]string{{`"""`, `"""`}, {"'''", "'''"}}
	add(l, "toml", "ini", "conf")

	l = base()
	l.lineComments = []string{"#"}
	l.constants = words("true", "false", "null", "yes", "no", "~")
	add(l, "yaml", "yml")

	l = base()
	l.lineComments = []string{"//"}
	l.blockComment = [2]string{"/*", "*/"}
	l.quotes = `"`
	add(l, "json", "jsonc", "json5")

	l = base()
	l.blockComment = [2]string{"<!--", "-->"}
	add(l, "html", "xml", "svg", "vue", "svelte")

	add(base(), "diff", "patch")
}

// LanguageForExtension is the language a file is written in, by its
// extension without the dot: "markdown", a language the lexer knows, or ""
// when unknown.
func LanguageForExtension(ext string) string {
	switch strings.ToLower(ext) {
	case "md", "markdown", "mdown", "mkd", "mdx":
		return "markdown"
	case "rs":
		return "rust"
	case "swift":
		return "swift"
	case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts":
		return "javascript"
	case "py":
		return "python"
	case "go":
		return "go"
	case "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm":
		return "c"
	case "java", "kt", "scala", "cs", "dart":
		return "java"
	case "rb":
		return "ruby"
	case "php":
		return "php"
	case "sh", "bash", "zsh", "fish":
		return "shell"
	case "sql":
		return "sql"
	case "lua":
		return "lua"
	case "zig":
		return "zig"
	case "css", "scss", "less":
		return "css"
	case "toml", "ini", "conf":
		return "toml"
	case "yaml", "yml":
		return "yaml"
	case "json", "jsonc", "json5":
		return "json"
	case "html", "htm", "xml", "svg", "vue", "svelte":
		return "html"
	case "diff", "patch":
		return "diff"
	}
	return ""
}

// pushToken adds a token, one piece per line, as every span is.
func pushToken(out *[]Span, t []byte, base int, kind Kind, start, end int) {
	s := start
	for s < end {
		e := end
		if i := bytes.IndexByte(t[s:end], '\n'); i >= 0 {
			e = s + i
		}
		if e > s {
			a, b := base+s, base+e
			*out = append(*out, Span{Start: a, End: b, ElemStart: a, ElemEnd: b, Kind: kind})
		}
		s = e + 1
	}
}

func isIdent(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_' || b >= 0x80
}

func isDigit(b byte) bool { return b >= '0' && b <= '9' }
func isAlnum(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9'
}
func isSpace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\f' || b == '\v'
}

// Lex lexes text as the language name and appends its tokens to out, with
// base added to every offset. It does nothing for a language it doesn't
// know.
func Lex(name, text string, base int, out *[]Span) {
	l := langs[name]
	if l == nil {
		return
	}
	t := []byte(text)
	if name == "diff" || name == "patch" {
		pos := 0
		for pos < len(t) {
			end := len(t)
			if i := bytes.IndexByte(t[pos:], '\n'); i >= 0 {
				end = pos + i
			}
			if end > pos {
				switch t[pos] {
				case '+':
					pushToken(out, t, base, TokenInserted, pos, end)
				case '-':
					pushToken(out, t, base, TokenDeleted, pos, end)
				case '@':
					pushToken(out, t, base, TokenKeyword, pos, end)
				}
			}
			pos = end + 1
		}
		return
	}
	markup := name == "html" || name == "xml" || name == "svg" || name == "vue" || name == "svelte"
	keyed := false
	switch name {
	case "yaml", "yml", "toml", "ini", "conf", "json", "jsonc", "json5", "css", "scss", "less":
		keyed = true
	}
	i := 0
	inTag := false
	lineStart, scanned := 0, 0
	for i < len(t) {
		if i > scanned {
			if p := bytes.LastIndexByte(t[scanned:i], '\n'); p >= 0 {
				lineStart = scanned + p + 1
			}
			scanned = i
		}
		c := t[i]
		if isSpace(c) {
			if c == '\n' {
				lineStart = i + 1
			}
			i++
			scanned = i
			continue
		}
		rest := t[i:]
		if open := l.blockComment[0]; open != "" && bytes.HasPrefix(rest, []byte(open)) {
			end := len(t)
			if j := bytes.Index(rest[len(open):], []byte(l.blockComment[1])); j >= 0 {
				end = i + len(open) + j + len(l.blockComment[1])
			}
			pushToken(out, t, base, TokenComment, i, end)
			i = end
			continue
		}
		lineComment := false
		for _, p := range l.lineComments {
			if bytes.HasPrefix(rest, []byte(p)) {
				lineComment = true
				break
			}
		}
		if lineComment {
			end := len(t)
			if j := bytes.IndexByte(rest, '\n'); j >= 0 {
				end = i + j
			}
			pushToken(out, t, base, TokenComment, i, end)
			i = end
			continue
		}
		if ls := longString(l, rest); ls != nil {
			j := i + len(ls[0])
			end := len(t)
			for j < len(t) {
				if t[j] == '\\' {
					j += 2
				} else if bytes.HasPrefix(t[j:], []byte(ls[1])) {
					end = j + len(ls[1])
					break
				} else {
					j++
				}
			}
			end = min(end, len(t))
			pushToken(out, t, base, TokenString, i, end)
			i = end
			continue
		}
		if strings.IndexByte(l.quotes, c) >= 0 {
			// A Rust lifetime or a lone apostrophe is not a string.
			j := i + 1
			closed := false
			for j < len(t) && t[j] != '\n' {
				if t[j] == '\\' {
					j += 2
				} else if t[j] == c {
					closed = true
					j++
					break
				} else {
					j++
				}
			}
			j = min(j, len(t))
			if closed {
				// A quoted key of JSON and the like.
				k := j
				for k < len(t) && t[k] == ' ' {
					k++
				}
				kind := TokenString
				if keyed && k < len(t) && t[k] == ':' {
					kind = TokenProperty
				}
				pushToken(out, t, base, kind, i, j)
				i = j
			} else {
				i++
			}
			continue
		}
		if markup {
			if c == '<' {
				j := i + 1
				if j < len(t) && t[j] == '/' {
					j++
				}
				nameStart := j
				for j < len(t) && (isIdent(t[j]) || t[j] == '-' || t[j] == ':') {
					j++
				}
				pushToken(out, t, base, TokenPunctuation, i, nameStart)
				pushToken(out, t, base, TokenKeyword, nameStart, j)
				inTag = true
				i = max(j, i+1)
				continue
			}
			if c == '>' || (c == '/' && i+1 < len(t) && t[i+1] == '>') {
				end := i + 2
				if c == '>' {
					end = i + 1
				}
				pushToken(out, t, base, TokenPunctuation, i, end)
				inTag = false
				i = end
				continue
			}
			if inTag && isIdent(c) {
				j := i
				for j < len(t) && (isIdent(t[j]) || t[j] == '-' || t[j] == ':') {
					j++
				}
				pushToken(out, t, base, TokenProperty, i, j)
				i = j
				continue
			}
			// Text between tags, up to the next tag.
			if !inTag {
				if j := bytes.IndexByte(rest, '<'); j >= 0 {
					i += max(j, 1)
				} else {
					i = len(t)
				}
				continue
			}
		}
		if isDigit(c) || (c == '.' && i+1 < len(t) && isDigit(t[i+1])) {
			j := i + 1
			for j < len(t) && (isAlnum(t[j]) || t[j] == '.' || t[j] == '_') {
				j++
			}
			pushToken(out, t, base, TokenNumber, i, j)
			i = j
			continue
		}
		if isIdent(c) || c == '#' || c == '@' || c == '$' {
			j := i + 1
			for j < len(t) && (isIdent(t[j]) || (keyed && t[j] == '-')) {
				j++
			}
			word := string(t[i:j])
			lookup := word
			if l.ignoreCase {
				lookup = strings.ToLower(word)
			}
			k := j
			for k < len(t) && t[k] == ' ' {
				k++
			}
			var next byte
			if k < len(t) {
				next = t[k]
			}
			leadsLine := func() bool {
				if !keyed || (next != ':' && next != '=') {
					return false
				}
				for _, b := range t[lineStart:i] {
					if b != ' ' && b != '\t' && b != '-' {
						return false
					}
				}
				return true
			}
			upper := c >= 'A' && c <= 'Z'
			var kind Kind
			switch {
			case leadsLine():
				kind = TokenProperty
			case l.keywords.has(lookup):
				kind = TokenKeyword
			case l.constants.has(lookup):
				kind = TokenConstant
			case l.types.has(lookup):
				kind = TokenType
			case c == '@' || (c == '#' && j > i+1 && !keyed):
				kind = TokenProperty
			case c == '#' && keyed && j > i+1:
				kind = TokenNumber
			case l.capitalTypes && upper && strings.ContainsFunc(word, func(r rune) bool { return r >= 'a' && r <= 'z' }):
				kind = TokenType
			case next == '(' && j < len(t) && t[j] == '(':
				kind = TokenFunction
			case l.capitalTypes && upper && len(word) > 1:
				kind = TokenConstant
			}
			if kind != 0 {
				pushToken(out, t, base, kind, i, j)
			}
			i = j
			continue
		}
		if name == "toml" && c == '[' && lineStart == i {
			end := len(t)
			if j := bytes.IndexByte(rest, '\n'); j >= 0 {
				end = i + j
			}
			pushToken(out, t, base, TokenType, i, end)
			i = end
			continue
		}
		i++
	}
}

func longString(l *lang, rest []byte) *[2]string {
	for k := range l.longStrings {
		if bytes.HasPrefix(rest, []byte(l.longStrings[k][0])) {
			return &l.longStrings[k]
		}
	}
	return nil
}

// KnowsLanguage reports whether the lexer highlights name.
func KnowsLanguage(name string) bool { return langs[name] != nil }
