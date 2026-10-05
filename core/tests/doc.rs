use deckle_core::doc::Doc;
use deckle_core::span::*;

const SAMPLE: &str = r#"---
title: Sample
tags: [a, b]
---

# Heading one

Some *emphasis*, **strong**, ~~strike~~, `code`, H~2~O, x^2^, ==marked== and a [link](https://example.com "t").
A [[Wiki Page|label]] and [[Plain]] with a footnote[^1] and https://deckle.md/docs. Math $a^2$.

> quoted **text**
> second line

> [!NOTE]
> A callout.

> [!tip] Titled
> Body.

- item one
- [x] done
  1. nested

```rust
fn main() { let x = "hi"; } // done
```

| Name | Count |
|:-----|------:|
| 中文 | 12 |

![alt](images/pic.png)

$$
E = mc^2
$$

Setext
======

***

[^1]: The note.
"#;

fn all(doc: &mut Doc) -> Vec<Span> {
    let end = doc.units() + 1;
    doc.spans_in(0, end).to_vec()
}

fn text_of(text: &str, s: &Span) -> String {
    let units: Vec<u16> = text.encode_utf16().collect();
    String::from_utf16_lossy(&units[s.start as usize..s.end as usize])
}

#[test]
fn sample_spans() {
    let mut doc = Doc::new(SAMPLE.to_string(), "markdown");
    let spans = all(&mut doc);
    let has = |kind: u8, text: &str| spans.iter().any(|s| s.kind == kind && text_of(SAMPLE, s) == text);
    if std::env::var("DUMP").is_ok() {
        for s in &spans {
            println!("{:>2} l{} f{} [{}..{}] e[{}..{}] {:?}", s.kind, s.level, s.flags, s.start, s.end, s.elem_start, s.elem_end, text_of(SAMPLE, s));
        }
    }
    assert!(has(HEADING, "# Heading one"));
    assert!(has(MARKER, "# "));
    assert!(has(EMPHASIS, "*emphasis*"));
    assert!(has(STRONG, "**strong**"));
    assert!(has(STRIKE, "~~strike~~"));
    assert!(has(CODE, "`code`"));
    assert!(has(SUBSCRIPT, "~2~"));
    assert!(has(SUPERSCRIPT, "^2^"));
    assert!(has(HIGHLIGHT, "==marked=="));
    assert!(has(LINK, "link"));
    assert!(has(LINK_DEST, "https://example.com"));
    assert!(has(MARKER, "](https://example.com \"t\")"));
    assert!(has(WIKI_LINK, "label"));
    assert!(has(WIKI_TARGET, "Wiki Page"));
    assert!(has(WIKI_LINK, "Plain"));
    assert!(has(FOOTNOTE_REF, "[^1]"));
    assert!(has(LINK, "https://deckle.md/docs"));
    assert!(has(INLINE_MATH, "$a^2$"));
    assert!(has(BLOCK_QUOTE, "> quoted **text**"));
    assert!(has(MARKER, "> "));
    assert!(has(CALLOUT_TAG, "[!NOTE]"));
    assert!(has(CALLOUT_TAG, "[!tip]"));
    assert!(has(LIST_MARKER, "-"));
    assert!(has(LIST_MARKER, "1."));
    assert!(has(TASK_MARKER, "[x]"));
    assert!(has(CODE_BLOCK, "```rust"));
    assert!(has(TOKEN_KEYWORD, "fn"));
    assert!(has(TOKEN_STRING, "\"hi\""));
    assert!(has(TOKEN_COMMENT, "// done"));
    assert!(has(TABLE, "| Name | Count |"));
    assert!(has(TABLE_CELL, "中文"));
    assert!(has(IMAGE, "![alt](images/pic.png)"));
    assert!(has(IMAGE_DEST, "images/pic.png"));
    assert!(has(MATH_BLOCK, "E = mc^2"));
    assert!(has(HEADING, "Setext"));
    assert!(has(THEMATIC_BREAK, "***"));
    assert!(has(FOOTNOTE_DEF, "[^1]:"));
    assert!(has(FRONT_MATTER, "title: Sample"));
    assert!(has(TOKEN_PROPERTY, "title"));
    // Every span stays on one line.
    for s in &spans {
        assert!(!text_of(SAMPLE, s).contains('\n'), "{s:?}");
        assert!(s.start <= s.end && s.elem_start <= s.start && s.end <= s.elem_end.max(s.end));
    }
}

#[test]
fn footnote_caret_is_not_a_superscript() {
    // The definition sits in another section, so the parser sees the
    // reference as text, and its caret must not open a superscript that
    // runs to the next one.
    let text = format!("# A\n\nFootnotes[^1] and H~2~O and x^2^ and ~a b~ end.\n\n{}\n[^1]: The note.\n", "## B\n\nfiller\n\n".repeat(3));
    let mut doc = Doc::new(text.clone(), "markdown");
    let spans = all(&mut doc);
    let of = |kind: u8| spans.iter().filter(|s| s.kind == kind).map(|s| text_of(&text, s)).collect::<Vec<_>>();
    assert_eq!(of(FOOTNOTE_REF), ["[^1]"]);
    assert_eq!(of(SUBSCRIPT), ["~2~"]);
    assert_eq!(of(SUPERSCRIPT), ["^2^"]);
    assert!(of(STRIKE).is_empty(), "{:?}", of(STRIKE));
}

/// A deterministic generator, so a failure can be replayed.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
}

#[test]
fn edits_match_a_fresh_parse() {
    let pieces = [
        "# ", "\n", "\n\n", "```", "```rust\n", "> ", "- ", "**", "*", "`", "[", "](x)", "[[", "]]", "|", "---\n", "$$", "$", "中文",
        "word ", "1. ", "~~", "<!--", "-->", "    ", "[^1]", "[^1]: ", "> [!tip] T\n", "==", "^", "\n# Title\n", "😀", "![a](b.png)", "~",
        "\r\n", "\t", "~~~\n", "<pre>\n", "</pre>", "<div>\n", "Foo\n===\n", "[r]: x\n", "[a][r]", "- a\n", "- [ ] t\n", "-\n", "- - -\n",
    ];
    let mut rng = Rng(0x9E3779B97F4A7C15);
    for round in 0..40 {
        let mut text: Vec<u16> = SAMPLE.repeat(1 + round % 3).encode_utf16().collect();
        let mut doc = Doc::new(String::from_utf16(&text).unwrap(), "markdown");
        for step in 0..120 {
            let mut start = rng.below(text.len() + 1);
            // Not in the middle of a surrogate pair.
            while start < text.len() && (0xDC00..0xE000).contains(&text[start]) {
                start += 1;
            }
            let mut end = (start + if rng.below(3) == 0 { rng.below(40) } else { 0 }).min(text.len());
            while end < text.len() && (0xDC00..0xE000).contains(&text[end]) {
                end += 1;
            }
            let insert = if rng.below(4) == 0 { "" } else { pieces[rng.below(pieces.len())] };
            let units: Vec<u16> = insert.encode_utf16().collect();
            let before = all(&mut doc);
            let dirty = doc.edit(start as u32, (end - start) as u32, insert);
            let delta = units.len() as i64 - (end - start) as i64;
            text.splice(start..end, units.iter().copied());
            let now = String::from_utf16(&text).unwrap();
            assert_eq!(doc.text(), now, "round {round} step {step}");
            let mut fresh = Doc::new(now.clone(), "markdown");
            let got = all(&mut doc);
            let want = all(&mut fresh);
            assert_eq!(got, want, "round {round} step {step}: insert {insert:?} at {start}..{end}");
            // Outside the reported range nothing changed.
            let outside_new: Vec<Span> = got.iter().filter(|s| s.end < dirty.0 || s.start > dirty.1).copied().collect();
            let outside_old: Vec<Span> = before
                .iter()
                .filter(|s| s.elem_end as usize + 1 < start || s.elem_start as usize > end)
                .filter_map(|s| {
                    let moved = |v: u32| if v as usize >= end { (v as i64 + delta) as u32 } else { v };
                    let shifted = if s.start as usize >= end {
                        Span { start: moved(s.start), end: moved(s.end), elem_start: moved(s.elem_start), elem_end: moved(s.elem_end), ..*s }
                    } else {
                        *s
                    };
                    (shifted.end < dirty.0 || shifted.start > dirty.1).then_some(shifted)
                })
                .collect();
            for s in &outside_old {
                assert!(outside_new.contains(s), "round {round} step {step}: {s:?} changed outside {dirty:?}, insert {insert:?} at {start}..{end}");
            }
            // A span of an element the edit is in, on a line outside the
            // reported range, kept everything but the element's far edge.
            for s in before.iter().filter(|s| !(s.elem_end as usize + 1 < start || s.elem_start as usize > end)) {
                let moved = |v: u32| (v as i64 + delta) as u32;
                let kept = if s.end < dirty.0 && (s.end as usize) < start {
                    vec![*s, Span { elem_end: moved(s.elem_end), ..*s }]
                } else if s.start as usize > end && moved(s.start) > dirty.1 {
                    let shifted = Span { start: moved(s.start), end: moved(s.end), elem_start: moved(s.elem_start), elem_end: moved(s.elem_end), ..*s };
                    vec![shifted, Span { elem_start: s.elem_start, ..shifted }]
                } else {
                    continue;
                };
                assert!(
                    kept.iter().any(|k| got.contains(k)),
                    "round {round} step {step}: {s:?} changed outside {dirty:?}, insert {insert:?} at {start}..{end}"
                );
            }
        }
    }
}

#[test]
fn typing_in_a_long_block_dirties_its_line() {
    let line = "let value = compute(1) // a line of code\n";
    for (open, body, close) in [("```swift\n", line, "```\n"), ("", "> a line of a long quote\n", "")] {
        let text = format!("# Title\n\n{open}{}{close}\nAfter.\n", body.repeat(400));
        let mut doc = Doc::new(text, "markdown");
        let at = (9 + open.len() + body.len() * 200 + 5) as u32;
        let dirty = doc.edit(at, 0, "x");
        assert!(dirty.0 <= at && dirty.1 > at, "{dirty:?} misses the edit at {at}");
        assert!((dirty.1 - dirty.0) as usize <= 2 * body.len(), "{dirty:?} is more than the line at {at}");
        let dirty = doc.edit(at, 1, "");
        assert!((dirty.1 - dirty.0) as usize <= 2 * body.len(), "{dirty:?} is more than the line at {at}");
    }
}

#[test]
fn large_document_timing() {
    let text = SAMPLE.replace("---\ntitle: Sample\ntags: [a, b]\n---\n", "").repeat(1500);
    let units = text.encode_utf16().count();
    let t = std::time::Instant::now();
    let mut doc = Doc::new(text.clone(), "markdown");
    let open = t.elapsed();
    let count = all(&mut doc).len();
    let mut worst = std::time::Duration::ZERO;
    let mut total = std::time::Duration::ZERO;
    for i in 0..200 {
        let at = (units / 200 * i) as u32;
        let t = std::time::Instant::now();
        doc.edit(at, 0, "x");
        let d = t.elapsed();
        worst = worst.max(d);
        total += d;
    }
    println!("{} bytes, {count} spans: open {open:?}, edit avg {:?}, worst {worst:?}", text.len(), total / 200);
}

#[test]
fn long_lines_lex_in_linear_time() {
    // A minified file: one line of hundreds of kilobytes.
    let text = "var a=function(b,c){return b+c};".repeat(16_000);
    let t = std::time::Instant::now();
    let mut doc = Doc::new(text, "javascript");
    let open = t.elapsed();
    let t = std::time::Instant::now();
    doc.edit(1000, 0, "x");
    let edit = t.elapsed();
    println!("minified js: open {open:?}, edit {edit:?}");
    assert!(open.as_millis() < 150, "open took {open:?}");
    assert!(edit.as_millis() < 150, "edit took {edit:?}");
}

#[test]
fn a_bad_section_stays_plain() {
    // Whatever the parser makes of it, the document survives and stays in
    // step with the text.
    let odd = "- [ ] \u{0}\n\n[^]: \n\n```\n\n~~~\n<pre>\n# \n\n|\n|-\n|\n\n$$\n$\n";
    let mut doc = Doc::new(odd.to_string(), "markdown");
    doc.edit(3, 2, "😀");
    assert!(doc.text().contains("😀"));
}
