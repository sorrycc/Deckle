//! A small lexer for code: comments, strings, numbers, keywords and the like,
//! by language. It knows no grammar, which keeps it fast and good enough for
//! reading code in a note.

use crate::span::*;

struct Lang {
    line_comments: &'static [&'static str],
    block_comment: Option<(&'static str, &'static str)>,
    /// Characters that open and close a string.
    quotes: &'static [u8],
    /// Strings that run over several lines.
    long_strings: &'static [(&'static str, &'static str)],
    keywords: &'static [&'static str],
    constants: &'static [&'static str],
    types: &'static [&'static str],
    /// Names starting with a capital are types.
    capital_types: bool,
    keywords_ignore_case: bool,
}

const NONE: Lang = Lang {
    line_comments: &[],
    block_comment: None,
    quotes: b"\"'",
    long_strings: &[],
    keywords: &[],
    constants: &["true", "false", "null"],
    types: &[],
    capital_types: false,
    keywords_ignore_case: false,
};

const C_LIKE: Lang = Lang { line_comments: &["//"], block_comment: Some(("/*", "*/")), capital_types: true, ..NONE };

fn lang(name: &str) -> Option<Lang> {
    Some(match name {
        "rust" | "rs" => Lang {
            quotes: b"\"",
            keywords: &[
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if",
                "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
                "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
            ],
            constants: &["true", "false", "None", "Some", "Ok", "Err"],
            types: &[
                "bool", "char", "str", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize",
                "f32", "f64",
            ],
            ..C_LIKE
        },
        "swift" => Lang {
            quotes: b"\"",
            long_strings: &[("\"\"\"", "\"\"\"")],
            keywords: &[
                "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default",
                "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func",
                "guard", "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating", "open", "operator",
                "override", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "some",
                "static", "struct", "subscript", "super", "switch", "throw", "throws", "try", "typealias", "var", "weak",
                "where", "while",
            ],
            constants: &["true", "false", "nil"],
            ..C_LIKE
        },
        "javascript" | "js" | "jsx" | "mjs" | "cjs" | "typescript" | "ts" | "tsx" | "mts" => Lang {
            quotes: b"\"'",
            long_strings: &[("`", "`")],
            keywords: &[
                "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
                "declare", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for", "from",
                "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "namespace",
                "new", "of", "private", "protected", "public", "readonly", "return", "satisfies", "set", "static", "super",
                "switch", "this", "throw", "try", "type", "typeof", "var", "void", "while", "with", "yield",
            ],
            constants: &["true", "false", "null", "undefined", "NaN", "Infinity"],
            types: &["any", "boolean", "never", "number", "object", "string", "symbol", "unknown", "bigint"],
            ..C_LIKE
        },
        "python" | "py" => Lang {
            line_comments: &["#"],
            long_strings: &[("\"\"\"", "\"\"\""), ("'''", "'''")],
            keywords: &[
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
                "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "case", "nonlocal", "not",
                "or", "pass", "raise", "return", "try", "while", "with", "yield", "self",
            ],
            constants: &["True", "False", "None"],
            types: &["int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object"],
            capital_types: true,
            ..NONE
        },
        "go" | "golang" => Lang {
            long_strings: &[("`", "`")],
            keywords: &[
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go",
                "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type",
                "var",
            ],
            constants: &["true", "false", "nil", "iota"],
            types: &[
                "bool", "byte", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string",
                "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any",
            ],
            ..C_LIKE
        },
        "c" | "h" | "cpp" | "c++" | "cc" | "cxx" | "hpp" | "objc" | "objective-c" | "m" | "mm" => Lang {
            keywords: &[
                "alignas", "auto", "break", "case", "catch", "class", "const", "constexpr", "continue", "default", "delete",
                "do", "else", "enum", "explicit", "extern", "final", "for", "friend", "goto", "if", "inline", "namespace",
                "new", "noexcept", "operator", "override", "private", "protected", "public", "register", "return", "sizeof",
                "static", "struct", "switch", "template", "this", "throw", "try", "typedef", "typename", "union", "using",
                "virtual", "volatile", "while", "#include", "#define", "#if", "#ifdef", "#ifndef", "#else", "#endif", "#pragma",
                "#import",
            ],
            constants: &["true", "false", "NULL", "nullptr", "nil", "YES", "NO"],
            types: &[
                "bool", "char", "double", "float", "int", "long", "short", "signed", "unsigned", "void", "size_t", "uint8_t",
                "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t",
            ],
            ..C_LIKE
        },
        "java" | "kotlin" | "kt" | "scala" | "csharp" | "cs" | "c#" | "dart" => Lang {
            long_strings: &[("\"\"\"", "\"\"\"")],
            keywords: &[
                "abstract", "as", "async", "await", "break", "case", "catch", "class", "companion", "const", "continue", "data",
                "default", "do", "else", "enum", "extends", "final", "finally", "for", "fun", "get", "if", "implements",
                "import", "in", "instanceof", "interface", "internal", "is", "lateinit", "namespace", "new", "object",
                "open", "override", "package", "private", "protected", "public", "return", "sealed", "set", "static", "super",
                "suspend", "switch", "this", "throw", "throws", "try", "using", "val", "var", "void", "when", "while", "yield",
            ],
            constants: &["true", "false", "null"],
            types: &["boolean", "byte", "char", "double", "float", "int", "long", "short", "string", "bool", "dynamic"],
            ..C_LIKE
        },
        "ruby" | "rb" => Lang {
            line_comments: &["#"],
            keywords: &[
                "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "for", "if",
                "in", "module", "next", "not", "or", "redo", "require", "rescue", "retry", "return", "self", "super", "then",
                "unless", "until", "when", "while", "yield",
            ],
            constants: &["true", "false", "nil"],
            capital_types: true,
            ..NONE
        },
        "php" => Lang {
            line_comments: &["//", "#"],
            keywords: &[
                "abstract", "as", "break", "case", "catch", "class", "const", "continue", "default", "do", "echo", "else",
                "elseif", "extends", "final", "finally", "fn", "for", "foreach", "function", "if", "implements", "interface",
                "namespace", "new", "private", "protected", "public", "return", "static", "switch", "throw", "trait", "try",
                "use", "var", "while",
            ],
            ..C_LIKE
        },
        "shell" | "sh" | "bash" | "zsh" | "fish" | "console" => Lang {
            line_comments: &["#"],
            keywords: &[
                "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function",
                "return", "local", "export", "source", "alias", "set", "unset", "echo", "exit", "cd",
            ],
            ..NONE
        },
        "sql" => Lang {
            line_comments: &["--"],
            block_comment: Some(("/*", "*/")),
            quotes: b"'\"",
            keywords: &[
                "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "index",
                "view", "drop", "alter", "add", "column", "join", "left", "right", "inner", "outer", "on", "as", "and", "or",
                "not", "in", "is", "like", "between", "group", "by", "order", "having", "limit", "offset", "union", "all",
                "distinct", "primary", "key", "foreign", "references", "default", "case", "when", "then", "else", "end",
                "begin", "commit", "rollback", "with", "exists", "asc", "desc",
            ],
            types: &["int", "integer", "text", "varchar", "boolean", "date", "timestamp", "real", "blob", "bigint", "numeric"],
            keywords_ignore_case: true,
            ..NONE
        },
        "lua" => Lang {
            line_comments: &["--"],
            block_comment: Some(("--[[", "]]")),
            keywords: &[
                "and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or",
                "repeat", "return", "then", "until", "while",
            ],
            constants: &["true", "false", "nil"],
            ..NONE
        },
        "zig" => Lang {
            quotes: b"\"",
            keywords: &[
                "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "struct", "enum", "union",
                "defer", "errdefer", "try", "catch", "comptime", "inline", "break", "continue", "orelse", "test", "export",
                "extern", "usingnamespace", "and", "or",
            ],
            constants: &["true", "false", "null", "undefined"],
            ..C_LIKE
        },
        "css" | "scss" | "less" => Lang { block_comment: Some(("/*", "*/")), line_comments: &[], ..NONE },
        "toml" | "ini" | "conf" => Lang { line_comments: &["#", ";"], long_strings: &[("\"\"\"", "\"\"\""), ("'''", "'''")], ..NONE },
        "yaml" | "yml" => Lang { line_comments: &["#"], constants: &["true", "false", "null", "yes", "no", "~"], ..NONE },
        "json" | "jsonc" | "json5" => Lang { line_comments: &["//"], block_comment: Some(("/*", "*/")), quotes: b"\"", ..NONE },
        "html" | "xml" | "svg" | "vue" | "svelte" => Lang { block_comment: Some(("<!--", "-->")), ..NONE },
        "diff" | "patch" => NONE,
        _ => return None,
    })
}

/// The language a file is written in, by its extension. Empty when unknown.
pub fn language_for_extension(ext: &str) -> &'static str {
    match ext.to_ascii_lowercase().as_str() {
        "md" | "markdown" | "mdown" | "mkd" | "mdx" => "markdown",
        "rs" => "rust",
        "swift" => "swift",
        "js" | "jsx" | "mjs" | "cjs" | "ts" | "tsx" | "mts" => "javascript",
        "py" => "python",
        "go" => "go",
        "c" | "h" | "cpp" | "cc" | "cxx" | "hpp" | "m" | "mm" => "c",
        "java" | "kt" | "scala" | "cs" | "dart" => "java",
        "rb" => "ruby",
        "php" => "php",
        "sh" | "bash" | "zsh" | "fish" => "shell",
        "sql" => "sql",
        "lua" => "lua",
        "zig" => "zig",
        "css" | "scss" | "less" => "css",
        "toml" | "ini" | "conf" => "toml",
        "yaml" | "yml" => "yaml",
        "json" | "jsonc" | "json5" => "json",
        "html" | "htm" | "xml" | "svg" | "vue" | "svelte" => "html",
        "diff" | "patch" => "diff",
        _ => "",
    }
}

fn push(out: &mut Vec<Span>, text: &[u8], base: usize, kind: u8, start: usize, end: usize) {
    // One piece per line, as every span is.
    let mut s = start;
    while s < end {
        let e = memchr::memchr(b'\n', &text[s..end]).map_or(end, |i| s + i);
        if e > s {
            let (a, b) = ((base + s) as u32, (base + e) as u32);
            out.push(Span { start: a, end: b, elem_start: a, elem_end: b, kind, level: 0, flags: 0 });
        }
        s = e + 1;
    }
}

fn is_ident(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b >= 0x80
}

/// Lexes `text` as `name` and appends its tokens to `out`, with `base` added
/// to every offset. Does nothing for a language it doesn't know.
pub fn lex(name: &str, text: &str, base: usize, out: &mut Vec<Span>) {
    let Some(lang) = lang(name) else { return };
    let t = text.as_bytes();
    if matches!(name, "diff" | "patch") {
        let mut pos = 0;
        while pos < t.len() {
            let end = memchr::memchr(b'\n', &t[pos..]).map_or(t.len(), |i| pos + i);
            match t[pos] {
                b'+' => push(out, t, base, TOKEN_INSERTED, pos, end),
                b'-' => push(out, t, base, TOKEN_DELETED, pos, end),
                b'@' => push(out, t, base, TOKEN_KEYWORD, pos, end),
                _ => {}
            }
            pos = end + 1;
        }
        return;
    }
    let markup = matches!(name, "html" | "xml" | "svg" | "vue" | "svelte");
    let keyed = matches!(name, "yaml" | "yml" | "toml" | "ini" | "conf" | "json" | "jsonc" | "json5" | "css" | "scss" | "less");
    let mut i = 0;
    // Inside a tag of a markup language, where names are attributes.
    let mut in_tag = false;
    while i < t.len() {
        let c = t[i];
        if c.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        let rest = &t[i..];
        if let Some((open, close)) = lang.block_comment {
            if rest.starts_with(open.as_bytes()) {
                let end = memchr::memmem::find(&rest[open.len()..], close.as_bytes())
                    .map_or(t.len(), |j| i + open.len() + j + close.len());
                push(out, t, base, TOKEN_COMMENT, i, end);
                i = end;
                continue;
            }
        }
        if lang.line_comments.iter().any(|p| rest.starts_with(p.as_bytes())) {
            let end = memchr::memchr(b'\n', rest).map_or(t.len(), |j| i + j);
            push(out, t, base, TOKEN_COMMENT, i, end);
            i = end;
            continue;
        }
        if let Some((open, close)) = lang.long_strings.iter().find(|(open, _)| rest.starts_with(open.as_bytes())) {
            let mut j = i + open.len();
            let mut end = t.len();
            while j < t.len() {
                if t[j] == b'\\' {
                    j += 2;
                } else if t[j..].starts_with(close.as_bytes()) {
                    end = j + close.len();
                    break;
                } else {
                    j += 1;
                }
            }
            push(out, t, base, TOKEN_STRING, i, end.min(t.len()));
            i = end.min(t.len());
            continue;
        }
        if lang.quotes.contains(&c) {
            // A Rust lifetime or a lone apostrophe is not a string.
            let mut j = i + 1;
            let mut closed = false;
            while j < t.len() && t[j] != b'\n' {
                if t[j] == b'\\' {
                    j += 2;
                } else if t[j] == c {
                    closed = true;
                    j += 1;
                    break;
                } else {
                    j += 1;
                }
            }
            let j = j.min(t.len());
            if closed {
                // A quoted key of JSON and the like.
                let mut k = j;
                while k < t.len() && t[k] == b' ' {
                    k += 1;
                }
                let is_key = keyed && t.get(k) == Some(&b':');
                push(out, t, base, if is_key { TOKEN_PROPERTY } else { TOKEN_STRING }, i, j);
                i = j;
            } else {
                i += 1;
            }
            continue;
        }
        if markup {
            if c == b'<' {
                let mut j = i + 1;
                if t.get(j) == Some(&b'/') {
                    j += 1;
                }
                let name_start = j;
                while j < t.len() && (is_ident(t[j]) || t[j] == b'-' || t[j] == b':') {
                    j += 1;
                }
                push(out, t, base, TOKEN_PUNCTUATION, i, name_start);
                push(out, t, base, TOKEN_KEYWORD, name_start, j);
                in_tag = true;
                i = j.max(i + 1);
                continue;
            }
            if c == b'>' || (c == b'/' && t.get(i + 1) == Some(&b'>')) {
                let end = if c == b'>' { i + 1 } else { i + 2 };
                push(out, t, base, TOKEN_PUNCTUATION, i, end);
                in_tag = false;
                i = end;
                continue;
            }
            if in_tag && is_ident(c) {
                let mut j = i;
                while j < t.len() && (is_ident(t[j]) || t[j] == b'-' || t[j] == b':') {
                    j += 1;
                }
                push(out, t, base, TOKEN_PROPERTY, i, j);
                i = j;
                continue;
            }
            // Text between tags, up to the next tag.
            if !in_tag {
                i = memchr::memchr(b'<', rest).map_or(t.len(), |j| i + j.max(1));
                continue;
            }
        }
        if c.is_ascii_digit() || (c == b'.' && t.get(i + 1).is_some_and(|d| d.is_ascii_digit())) {
            let mut j = i + 1;
            while j < t.len() && (t[j].is_ascii_alphanumeric() || t[j] == b'.' || t[j] == b'_') {
                j += 1;
            }
            push(out, t, base, TOKEN_NUMBER, i, j);
            i = j;
            continue;
        }
        if is_ident(c) || c == b'#' || c == b'@' || c == b'$' {
            let mut j = i + 1;
            while j < t.len() && (is_ident(t[j]) || (keyed && t[j] == b'-')) {
                j += 1;
            }
            // Offsets may fall inside a character after a stray backslash.
            let word = std::str::from_utf8(&t[i..j]).unwrap_or("");
            let lower;
            let lookup = if lang.keywords_ignore_case {
                lower = word.to_ascii_lowercase();
                lower.as_str()
            } else {
                word
            };
            let mut k = j;
            while k < t.len() && t[k] == b' ' {
                k += 1;
            }
            let next = t.get(k).copied();
            // A key of YAML, TOML or CSS: a name before : or = on its line.
            let line_start = memchr::memrchr(b'\n', &t[..i]).map_or(0, |p| p + 1);
            let leads_line = t[line_start..i].iter().all(|b| matches!(b, b' ' | b'\t' | b'-'));
            let kind = if keyed && leads_line && matches!(next, Some(b':') | Some(b'=')) {
                TOKEN_PROPERTY
            } else if lang.keywords.contains(&lookup) {
                TOKEN_KEYWORD
            } else if lang.constants.contains(&lookup) {
                TOKEN_CONSTANT
            } else if lang.types.contains(&lookup) {
                TOKEN_TYPE
            } else if c == b'@' || (c == b'#' && j > i + 1 && !keyed) {
                TOKEN_PROPERTY
            } else if c == b'#' && keyed && j > i + 1 {
                TOKEN_NUMBER
            } else if lang.capital_types && c.is_ascii_uppercase() && word.bytes().any(|b| b.is_ascii_lowercase()) {
                TOKEN_TYPE
            } else if next == Some(b'(') && t.get(j) == Some(&b'(') {
                TOKEN_FUNCTION
            } else if lang.capital_types && c.is_ascii_uppercase() && word.len() > 1 {
                TOKEN_CONSTANT
            } else {
                0
            };
            if kind != 0 {
                push(out, t, base, kind, i, j);
            }
            i = j;
            continue;
        }
        if name == "toml" && c == b'[' && memchr::memrchr(b'\n', &t[..i]).map_or(0, |p| p + 1) == i {
            let end = memchr::memchr(b'\n', rest).map_or(t.len(), |j| i + j);
            push(out, t, base, TOKEN_TYPE, i, end);
            i = end;
            continue;
        }
        i += 1;
    }
}
