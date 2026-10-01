//! Turns Markdown into the style spans the editor draws with.
//!
//! The parse is by section: `split_sections` cuts the text where a new
//! top-level block is certain to begin, and each section is parsed on its own.
//! An edit then reparses only the sections it touches.

use crate::highlight;
use crate::span::*;
use pulldown_cmark::{BlockQuoteKind, CodeBlockKind, Event, LinkType, Options, Parser, Tag};
use std::ops::Range;

/// Byte offsets where sections start. The first is always 0.
pub fn split_sections(text: &str) -> Vec<usize> {
    let bytes = text.as_bytes();
    let mut starts = vec![0];
    // The fence that opened a code block: its character, length and indent.
    let mut fence: Option<(u8, usize, usize)> = None;
    // The text that ends the HTML block we are in.
    let mut html_end: Option<&'static str> = None;
    let mut front_matter = false;
    let mut prev_blank = true;
    let mut pos = 0;
    let mut first = true;
    while pos < bytes.len() {
        let end = memchr::memchr(b'\n', &bytes[pos..]).map_or(bytes.len(), |i| pos + i);
        let line = &bytes[pos..end];
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        let indent = line.iter().take_while(|&&b| b == b' ').count();
        let blank = line.iter().all(|b| b.is_ascii_whitespace());

        if first {
            first = false;
            if line == b"---" {
                front_matter = true;
                pos = end + 1;
                continue;
            }
        }
        if front_matter {
            if line == b"---" || line == b"..." {
                front_matter = false;
                prev_blank = true;
            }
            pos = end + 1;
            continue;
        }
        if let Some(end_text) = html_end {
            if memchr::memmem::find(line, end_text.as_bytes()).is_some() {
                html_end = None;
            }
            prev_blank = false;
            pos = end + 1;
            continue;
        }
        // A fence may sit in a quote or a list item.
        let inner_start = line.iter().position(|&b| b != b' ' && b != b'>').unwrap_or(line.len());
        let inner = &line[inner_start..];
        let run = fence_run(inner);
        if let Some((ch, len, open_indent)) = fence {
            let closes = run.is_some_and(|(c, n)| c == ch && n >= len && inner[n..].iter().all(|b| b.is_ascii_whitespace()));
            // A fence inside a list item or quote also ends where that item
            // does: at a line indented less that is not a quote line.
            let dedent = open_indent >= 2 && !blank && inner_start < open_indent && inner_start == indent;
            if closes {
                fence = None;
                prev_blank = false;
                pos = end + 1;
                continue;
            } else if dedent {
                fence = None;
            } else {
                prev_blank = false;
                pos = end + 1;
                continue;
            }
        }
        if let Some((ch, len)) = run {
            // A backtick fence's info string has no backticks.
            if ch == b'~' || !inner[len..].contains(&b'`') {
                fence = Some((ch, len, inner_start));
                // A fence at the margin after a blank line starts a block.
                if indent == 0 && inner_start == 0 && prev_blank && pos > 0 && line_hash(line) % CHUNK == 0 {
                    starts.push(pos);
                }
                prev_blank = false;
                pos = end + 1;
                continue;
            }
        }
        if indent == 0 && !blank {
            if let Some(end_text) = html_block_end(line) {
                if memchr::memmem::find(&line[2..], end_text.as_bytes()).is_none() {
                    html_end = Some(end_text);
                }
            } else if pos > 0 && (is_atx_heading(line) || (prev_blank && line_hash(line) % CHUNK == 0)) {
                starts.push(pos);
            }
        }
        prev_blank = blank;
        pos = end + 1;
    }
    starts
}

/// One paragraph in this many starts a section, besides every heading.
const CHUNK: u32 = 8;

fn line_hash(line: &[u8]) -> u32 {
    let mut hash: u32 = 0x811c9dc5;
    for &b in line.iter().take(48) {
        hash = (hash ^ b as u32).wrapping_mul(0x01000193);
    }
    hash >> 7
}

fn fence_run(s: &[u8]) -> Option<(u8, usize)> {
    let ch = *s.first()?;
    if ch != b'`' && ch != b'~' {
        return None;
    }
    let n = s.iter().take_while(|&&b| b == ch).count();
    (n >= 3).then_some((ch, n))
}

fn is_atx_heading(line: &[u8]) -> bool {
    let n = line.iter().take_while(|&&b| b == b'#').count();
    (1..=6).contains(&n) && (line.len() == n || line[n] == b' ' || line[n] == b'\t')
}

/// For a line that opens an HTML block which blank lines don't end, the text
/// that ends it.
fn html_block_end(line: &[u8]) -> Option<&'static str> {
    if line.first() != Some(&b'<') {
        return None;
    }
    let lower: Vec<u8> = line.iter().take(12).map(|b| b.to_ascii_lowercase()).collect();
    for (open, close) in [
        (&b"<!--"[..], "-->"),
        (b"<pre", "</pre>"),
        (b"<script", "</script>"),
        (b"<style", "</style>"),
        (b"<textarea", "</textarea>"),
    ] {
        if lower.starts_with(open) {
            return Some(close);
        }
    }
    None
}

/// Superscripts and subscripts are left to `text_run`: the parser's own
/// run from any `^` to the next, across words, so `[^1] … x^2^` became one
/// superscript from the footnote's caret.
fn options(first_section: bool) -> Options {
    let mut o = Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_MATH
        | Options::ENABLE_GFM
        | Options::ENABLE_WIKILINKS;
    if first_section {
        o |= Options::ENABLE_YAML_STYLE_METADATA_BLOCKS;
    }
    o
}

struct Open<'a> {
    tag: Tag<'a>,
    range: Range<usize>,
    /// The span of the children seen so far.
    inner: Option<Range<usize>>,
}

struct Builder<'a> {
    text: &'a str,
    spans: Vec<Span>,
}

impl Builder<'_> {
    /// Adds a span, one piece per line it covers. `blocks` keeps the pieces of
    /// empty lines, which a block's background still has to cover.
    fn push(&mut self, kind: u8, range: Range<usize>, elem: Range<usize>, level: u8, flags: u16, blocks: bool) {
        let bytes = self.text.as_bytes();
        let mut start = range.start;
        let end = range.end.min(bytes.len());
        if start > end {
            return;
        }
        loop {
            let line_end = memchr::memchr(b'\n', &bytes[start..end]).map_or(end, |i| start + i);
            let mut piece_end = line_end;
            if piece_end > start && bytes[piece_end - 1] == b'\r' {
                piece_end -= 1;
            }
            if piece_end > start || blocks {
                self.spans.push(Span {
                    start: start as u32,
                    end: piece_end as u32,
                    elem_start: elem.start as u32,
                    elem_end: elem.end as u32,
                    kind,
                    level,
                    flags,
                });
            }
            if line_end >= end {
                break;
            }
            start = line_end + 1;
            if start >= end && !blocks {
                break;
            }
        }
    }

    fn inline(&mut self, kind: u8, range: Range<usize>, elem: Range<usize>) {
        self.push(kind, range, elem, 0, 0, false);
    }

    fn marker(&mut self, range: Range<usize>, elem: Range<usize>) {
        self.push(MARKER, range, elem, 0, 0, false);
    }

    /// `range` without the line break and spaces at its end.
    fn trim_end(&self, range: Range<usize>) -> Range<usize> {
        let bytes = self.text.as_bytes();
        let mut end = range.end.min(bytes.len());
        while end > range.start && bytes[end - 1].is_ascii_whitespace() {
            end -= 1;
        }
        range.start..end
    }

    /// The line around `pos`, without its line break.
    fn line_at(&self, pos: usize) -> Range<usize> {
        let bytes = self.text.as_bytes();
        let pos = pos.min(bytes.len());
        let start = memchr::memrchr(b'\n', &bytes[..pos]).map_or(0, |i| i + 1);
        let end = memchr::memchr(b'\n', &bytes[pos..]).map_or(bytes.len(), |i| pos + i);
        start..end
    }
}

/// Parses one section. Offsets in the result are bytes from its start.
pub fn parse_section(text: &str, first_section: bool) -> Vec<Span> {
    let mut b = Builder { text, spans: Vec::new() };
    let bytes = text.as_bytes();
    let mut stack: Vec<Open> = Vec::new();
    let mut quote_depth = 0u8;
    let mut list_depth = 0u8;
    let mut table_column = 0u8;
    let mut table_head = false;
    let mut table_aligns: Vec<u8> = Vec::new();
    // Where Text events are literal: code blocks, links and images.
    let mut literal = 0usize;
    // Adjoining Text events, scanned as one once something else follows.
    let mut run: Option<Range<usize>> = None;

    for (event, range) in Parser::new_ext(text, options(first_section)).into_offset_iter() {
        if !matches!(event, Event::End(_)) {
            if let Some(top) = stack.last_mut() {
                top.inner = Some(match &top.inner {
                    None => range.clone(),
                    Some(r) => r.start..range.end.max(r.end),
                });
            }
        }
        match &event {
            Event::Text(_) if literal == 0 => {
                run = match run.take() {
                    Some(r) if r.end == range.start => Some(r.start..range.end),
                    Some(r) => {
                        text_run(&mut b, r);
                        Some(range.clone())
                    }
                    None => Some(range.clone()),
                };
                continue;
            }
            _ => {
                if let Some(r) = run.take() {
                    text_run(&mut b, r);
                }
            }
        }
        match event {
            Event::Start(tag) => {
                match &tag {
                    Tag::BlockQuote(_) => quote_depth += 1,
                    Tag::List(_) => list_depth += 1,
                    Tag::CodeBlock(_) | Tag::Link { .. } | Tag::Image { .. } | Tag::MetadataBlock(_) => literal += 1,
                    Tag::Table(aligns) => {
                        table_aligns = aligns.iter().map(|a| *a as u8).collect();
                    }
                    Tag::TableHead => {
                        table_head = true;
                        table_column = 0;
                    }
                    Tag::TableRow => table_column = 0,
                    _ => {}
                }
                stack.push(Open { tag, range, inner: None });
            }
            Event::End(_) => {
                let Some(open) = stack.pop() else { continue };
                let r = open.range.clone();
                match open.tag {
                    Tag::Heading { level, .. } => {
                        let elem = b.trim_end(r.clone());
                        b.push(HEADING, elem.clone(), elem.clone(), level as u8, 0, false);
                        if let Some(inner) = open.inner {
                            b.marker(elem.start..inner.start, elem.clone());
                            // A closing run of #, or the underline of a
                            // setext heading.
                            let tail_start = inner.end + bytes[inner.end..elem.end].iter().take_while(|&&c| c == b' ').count();
                            b.marker(tail_start..elem.end, elem.clone());
                        }
                    }
                    Tag::BlockQuote(kind) => {
                        quote_depth -= 1;
                        let elem = b.trim_end(r.clone());
                        let callout = match kind {
                            Some(BlockQuoteKind::Note) => 1,
                            Some(BlockQuoteKind::Tip) => 2,
                            Some(BlockQuoteKind::Important) => 3,
                            Some(BlockQuoteKind::Warning) => 4,
                            Some(BlockQuoteKind::Caution) => 5,
                            // A tag with a title after it, which the parser
                            // takes for text.
                            None => callout_kind(&bytes[elem.start..b.line_at(elem.start).end]),
                        };
                        b.push(BLOCK_QUOTE, elem.clone(), elem.clone(), quote_depth + 1, callout, true);
                        // The > of each line, for this quote's depth only.
                        let mut pos = elem.start;
                        let mut first_line = true;
                        while pos <= elem.end && pos < bytes.len() {
                            let line = b.line_at(pos);
                            let line_start = if first_line { elem.start } else { line.start };
                            let mut i = line_start;
                            let mut seen = 0;
                            // Outer quotes own the markers before this one.
                            let skip = if first_line { 0 } else { quote_depth };
                            while i < line.end {
                                match bytes[i] {
                                    b' ' => i += 1,
                                    b'>' if seen < skip => {
                                        seen += 1;
                                        i += 1;
                                    }
                                    b'>' => {
                                        let end = if bytes.get(i + 1) == Some(&b' ') { i + 2 } else { i + 1 };
                                        b.marker(i..end, line.clone());
                                        if first_line && callout != 0 && bytes[end..line.end].starts_with(b"[!") {
                                            if let Some(close) = memchr::memchr(b']', &bytes[end..line.end]) {
                                                b.push(CALLOUT_TAG, end..end + close + 1, line.clone(), 0, callout, false);
                                            }
                                        }
                                        break;
                                    }
                                    _ => break,
                                }
                            }
                            first_line = false;
                            pos = line.end + 1;
                        }
                    }
                    Tag::CodeBlock(kind) => {
                        literal -= 1;
                        let elem = b.trim_end(r.clone());
                        let fenced = matches!(kind, CodeBlockKind::Fenced(_));
                        let lang = match &kind {
                            CodeBlockKind::Fenced(info) => info.split_whitespace().next().unwrap_or("").to_ascii_lowercase(),
                            CodeBlockKind::Indented => String::new(),
                        };
                        let widget = match lang.as_str() {
                            "mermaid" => CODE_DIAGRAM,
                            "math" | "latex" | "tex" => CODE_MATH,
                            _ => 0,
                        };
                        let first_line = b.line_at(elem.start);
                        let last_line = b.line_at(elem.end);
                        let closed = fenced && last_line.start > first_line.start && {
                            let open_text = &bytes[elem.start..first_line.end];
                            let inner_start = last_line.start
                                + bytes[last_line.start..last_line.end].iter().take_while(|&&c| c == b' ' || c == b'>').count();
                            match (fence_run(open_text), fence_run(&bytes[inner_start..last_line.end])) {
                                (Some((c, n)), Some((c2, n2))) => c == c2 && n2 >= n,
                                _ => false,
                            }
                        };
                        let mut pos = elem.start;
                        loop {
                            let line = b.line_at(pos);
                            let start = line.start.max(elem.start);
                            let mut flags = widget;
                            if fenced && start == elem.start {
                                flags |= CODE_FENCE_OPEN;
                            }
                            if closed && line.start == last_line.start {
                                flags |= CODE_FENCE_CLOSE;
                            }
                            b.push(CODE_BLOCK, start..line.end.min(elem.end), elem.clone(), 0, flags, true);
                            pos = line.end + 1;
                            if pos > elem.end || pos >= bytes.len() {
                                break;
                            }
                        }
                        let body = if fenced {
                            let start = (first_line.end + 1).min(elem.end);
                            let end = if closed { last_line.start.saturating_sub(1).max(start) } else { elem.end };
                            start..end
                        } else {
                            elem.clone()
                        };
                        if widget == 0 && !lang.is_empty() && body.end > body.start {
                            highlight::lex(&lang, &text[body.clone()], body.start, &mut b.spans);
                        }
                    }
                    Tag::List(_) => list_depth -= 1,
                    Tag::Item => {
                        let mut i = r.start;
                        while i < r.end && bytes[i] == b' ' {
                            i += 1;
                        }
                        let start = i;
                        let mut ordered = 0;
                        if i < r.end && matches!(bytes[i], b'-' | b'*' | b'+') {
                            i += 1;
                        } else {
                            while i < r.end && bytes[i].is_ascii_digit() {
                                i += 1;
                            }
                            if i > start && i < r.end && matches!(bytes[i], b'.' | b')') {
                                i += 1;
                                ordered = 1;
                            } else {
                                i = start;
                            }
                        }
                        if i > start {
                            let line = b.line_at(start);
                            b.push(LIST_MARKER, start..i, line, list_depth, ordered, false);
                        }
                    }
                    Tag::Emphasis | Tag::Strong | Tag::Strikethrough => {
                        let kind = match open.tag {
                            Tag::Emphasis => EMPHASIS,
                            Tag::Strong => STRONG,
                            _ => STRIKE,
                        };
                        // A single tilde is a subscript, not a strike; with
                        // a space inside it is neither, and stays as typed.
                        let single = kind == STRIKE && bytes.get(r.start + 1) != Some(&b'~');
                        let kind = if single {
                            if bytes[r.start + 1..r.end.saturating_sub(1)].iter().any(|b| b.is_ascii_whitespace()) {
                                continue;
                            }
                            SUBSCRIPT
                        } else {
                            kind
                        };
                        b.inline(kind, r.clone(), r.clone());
                        if let Some(inner) = open.inner {
                            b.marker(r.start..inner.start, r.clone());
                            b.marker(inner.end..r.end, r.clone());
                        }
                    }
                    Tag::Link { link_type, .. } => {
                        literal -= 1;
                        match link_type {
                            LinkType::Autolink | LinkType::Email => {
                                if r.end - r.start > 2 {
                                    b.inline(LINK, r.start + 1..r.end - 1, r.clone());
                                    b.inline(LINK_DEST, r.start + 1..r.end - 1, r.clone());
                                    b.marker(r.start..r.start + 1, r.clone());
                                    b.marker(r.end - 1..r.end, r.clone());
                                }
                            }
                            LinkType::WikiLink { has_pothole } => {
                                if r.end - r.start > 4 {
                                    let inner_end = r.end - 2;
                                    let pipe = if has_pothole {
                                        memchr::memchr(b'|', &bytes[r.start + 2..inner_end]).map(|i| r.start + 2 + i)
                                    } else {
                                        None
                                    };
                                    let target = r.start + 2..pipe.unwrap_or(inner_end);
                                    let label = pipe.map_or(target.clone(), |p| p + 1..inner_end);
                                    b.inline(WIKI_LINK, label.clone(), r.clone());
                                    b.marker(r.start..label.start, r.clone());
                                    b.marker(inner_end..r.end, r.clone());
                                    b.inline(WIKI_TARGET, target, r.clone());
                                }
                            }
                            _ => {
                                if let Some(inner) = open.inner {
                                    b.inline(LINK, inner.clone(), r.clone());
                                    b.marker(r.start..inner.start, r.clone());
                                    b.marker(inner.end..r.end, r.clone());
                                    if let Some(dest) = destination(bytes, inner.end..r.end) {
                                        b.inline(LINK_DEST, dest, r.clone());
                                    }
                                }
                            }
                        }
                    }
                    Tag::Image { .. } => {
                        literal -= 1;
                        let line = b.line_at(r.start);
                        let alone = text[line.start..r.start].trim_matches(|c| c == ' ' || c == '>').is_empty()
                            && r.end <= line.end
                            && text[r.end..line.end].trim().is_empty();
                        b.push(IMAGE, r.clone(), r.clone(), 0, alone as u16, false);
                        let after = open.inner.map_or(r.start + 2, |i| i.end);
                        if let Some(dest) = destination(bytes, after..r.end) {
                            b.inline(IMAGE_DEST, dest, r.clone());
                        }
                    }
                    Tag::FootnoteDefinition(_) => {
                        if let Some(close) = memchr::memmem::find(&bytes[r.start..r.end], b"]:") {
                            let line = b.line_at(r.start);
                            b.inline(FOOTNOTE_DEF, r.start..r.start + close + 2, line);
                        }
                    }
                    Tag::Table(_) => {
                        let elem = b.trim_end(r.clone());
                        let mut pos = elem.start;
                        let mut row = 0;
                        loop {
                            let line = b.line_at(pos);
                            let flags = match row {
                                0 => TABLE_HEADER,
                                1 => TABLE_DELIMITER,
                                _ => 0,
                            };
                            b.push(TABLE, line.start.max(elem.start)..line.end.min(elem.end), elem.clone(), 0, flags, true);
                            row += 1;
                            pos = line.end + 1;
                            if pos > elem.end || pos >= bytes.len() {
                                break;
                            }
                        }
                    }
                    Tag::TableHead => table_head = false,
                    Tag::TableCell => {
                        let align = table_aligns.get(table_column as usize).copied().unwrap_or(0) as u16;
                        let flags = align | if table_head { TABLE_HEADER << 4 } else { 0 };
                        let mut cell = b.trim_end(r.clone());
                        while cell.start < cell.end && bytes[cell.start] == b' ' {
                            cell.start += 1;
                        }
                        // An empty cell still counts as a column.
                        let line = b.line_at(r.start);
                        b.push(TABLE_CELL, cell, line, table_column, flags, true);
                        table_column = table_column.saturating_add(1);
                    }
                    Tag::HtmlBlock => {
                        let elem = b.trim_end(r.clone());
                        b.inline(HTML, elem.clone(), elem);
                    }
                    Tag::MetadataBlock(_) => {
                        literal -= 1;
                        let elem = b.trim_end(r.clone());
                        let last = b.line_at(elem.end).start;
                        let mut pos = elem.start;
                        loop {
                            let line = b.line_at(pos);
                            let mut flags = 0;
                            if line.start == elem.start {
                                flags |= CODE_FENCE_OPEN;
                            }
                            if line.start == last && last > elem.start {
                                flags |= CODE_FENCE_CLOSE;
                            }
                            b.push(FRONT_MATTER, line.start..line.end.min(elem.end), elem.clone(), 0, flags, true);
                            pos = line.end + 1;
                            if pos > elem.end || pos >= bytes.len() {
                                break;
                            }
                        }
                        let first = b.line_at(elem.start);
                        if last > first.end + 1 {
                            highlight::lex("yaml", &text[first.end + 1..last - 1], first.end + 1, &mut b.spans);
                        }
                    }
                    _ => {}
                }
            }
            Event::Code(_) => {
                let ticks = bytes[range.start..range.end].iter().take_while(|&&c| c == b'`').count();
                b.inline(CODE, range.clone(), range.clone());
                if range.end - range.start > 2 * ticks {
                    b.marker(range.start..range.start + ticks, range.clone());
                    b.marker(range.end - ticks..range.end, range.clone());
                }
            }
            Event::InlineMath(_) => {
                b.inline(INLINE_MATH, range.clone(), range.clone());
                if range.end - range.start > 2 {
                    b.marker(range.start..range.start + 1, range.clone());
                    b.marker(range.end - 1..range.end, range.clone());
                }
            }
            Event::DisplayMath(_) => {
                // A block of its own when nothing else shares its paragraph.
                let alone = stack.last().is_some_and(|p| {
                    matches!(p.tag, Tag::Paragraph) && b.trim_end(p.range.clone()) == range && {
                        let line = b.line_at(range.start);
                        text[line.start..range.start].trim_matches(|c| c == ' ' || c == '>').is_empty()
                    }
                });
                b.push(MATH_BLOCK, range.clone(), range.clone(), 0, alone as u16, true);
            }
            Event::FootnoteReference(_) => b.inline(FOOTNOTE_REF, range.clone(), range.clone()),
            Event::InlineHtml(_) => b.inline(HTML, range.clone(), range.clone()),
            Event::TaskListMarker(checked) => {
                let line = b.line_at(range.start);
                b.push(TASK_MARKER, range.clone(), line, 0, checked as u16, false);
            }
            Event::Rule => {
                let elem = b.trim_end(range.clone());
                b.inline(THEMATIC_BREAK, elem.clone(), elem);
            }
            _ => {}
        }
    }
    if let Some(r) = run.take() {
        text_run(&mut b, r);
    }
    let mut spans = b.spans;
    // Outer spans before the ones they contain, so the inner style wins.
    spans.sort_by(|a, b| a.start.cmp(&b.start).then(b.end.cmp(&a.end)));
    spans
}

/// The URL in the `](url "title")` that follows a link's text.
fn destination(bytes: &[u8], range: Range<usize>) -> Option<Range<usize>> {
    let open = range.start + memchr::memmem::find(&bytes[range.start..range.end], b"](")? + 2;
    let mut start = open;
    while start < range.end && bytes[start] == b' ' {
        start += 1;
    }
    let mut end = start;
    if bytes.get(start) == Some(&b'<') {
        start += 1;
        end = start + memchr::memchr(b'>', &bytes[start..range.end])?;
    } else {
        let mut depth = 0;
        while end < range.end {
            match bytes[end] {
                b'(' => depth += 1,
                b')' if depth == 0 => break,
                b')' => depth -= 1,
                b' ' | b'\n' => break,
                _ => {}
            }
            end += 1;
        }
    }
    (end > start).then_some(start..end)
}

/// Web addresses written out in plain text.
fn bare_links(b: &mut Builder, range: Range<usize>) {
    let bytes = b.text.as_bytes();
    let mut pos = range.start;
    while let Some(i) = memchr::memmem::find(&bytes[pos..range.end], b"://") {
        let at = pos + i;
        let start = if bytes[range.start..at].ends_with(b"https") {
            at - 5
        } else if bytes[range.start..at].ends_with(b"http") {
            at - 4
        } else {
            pos = at + 3;
            continue;
        };
        let mut end = at + 3;
        while end < range.end && !bytes[end].is_ascii_whitespace() && !matches!(bytes[end], b'<' | b'>' | b'"' | b'`') {
            // Stop at the first character that is not part of a URL, which
            // in Chinese text is often the very next one.
            if bytes[end] >= 0x80 {
                break;
            }
            end += 1;
        }
        while end > at + 3 && matches!(bytes[end - 1], b'.' | b',' | b';' | b':' | b'!' | b'?' | b')' | b'\'') {
            end -= 1;
        }
        if end > at + 3 && (start == range.start || !bytes[start - 1].is_ascii_alphanumeric()) {
            b.inline(LINK, start..end, start..end);
            b.inline(LINK_DEST, start..end, start..end);
        }
        pos = end.max(at + 3);
    }
}

/// The kind of callout a quote's first line opens, or 0: `> [!tip] Title`.
fn callout_kind(line: &[u8]) -> u16 {
    let start = line.iter().position(|&b| b != b' ' && b != b'>').unwrap_or(line.len());
    let rest = &line[start..];
    if !rest.starts_with(b"[!") {
        return 0;
    }
    let Some(close) = memchr::memchr(b']', rest) else { return 0 };
    let name = rest[2..close].to_ascii_lowercase();
    if name.is_empty() || !name.iter().all(|b| b.is_ascii_alphanumeric()) {
        return 0;
    }
    match name.as_slice() {
        b"tip" | b"hint" | b"success" | b"check" | b"done" => 2,
        b"important" | b"question" | b"help" | b"faq" | b"example" => 3,
        b"warning" | b"attention" => 4,
        b"caution" | b"danger" | b"error" | b"failure" | b"fail" | b"bug" => 5,
        _ => 1,
    }
}

/// What the parser leaves as plain text but a note-taker expects to work:
/// bare links, footnote references whose definition is elsewhere, ==marks==,
/// and subscripts and superscripts inside a word.
fn text_run(b: &mut Builder, range: Range<usize>) {
    bare_links(b, range.clone());
    let bytes = b.text.as_bytes();
    let mut i = range.start;
    // The end of a run of `ch` around content with no space in it.
    let close = |from: usize, ch: u8| -> Option<usize> {
        let limit = range.end.min(from + 48);
        if from >= limit {
            return None;
        }
        let j = from + bytes[from..limit].iter().position(|&c| c == ch || c.is_ascii_whitespace())?;
        (bytes[j] == ch && j > from && bytes.get(j + 1) != Some(&ch)).then_some(j)
    };
    while i < range.end {
        let c = bytes[i];
        let prev = if i > range.start { bytes[i - 1] } else { 0 };
        match c {
            b'[' if bytes.get(i + 1) == Some(&b'^') => {
                if let Some(j) = close(i + 2, b']') {
                    if !bytes[i + 2..j].contains(&b'[') {
                        b.inline(FOOTNOTE_REF, i..j + 1, i..j + 1);
                        i = j + 1;
                        continue;
                    }
                }
            }
            b'~' | b'^' if prev != c && prev != b'[' && bytes.get(i + 1) != Some(&c) => {
                if let Some(j) = close(i + 1, c) {
                    let kind = if c == b'~' { SUBSCRIPT } else { SUPERSCRIPT };
                    b.inline(kind, i..j + 1, i..j + 1);
                    b.marker(i..i + 1, i..j + 1);
                    b.marker(j..j + 1, i..j + 1);
                    i = j + 1;
                    continue;
                }
            }
            b'=' if prev != b'=' && bytes.get(i + 1) == Some(&b'=') && i + 2 < range.end && !matches!(bytes[i + 2], b'=' | b' ') => {
                let limit = range.end.min(i + 400);
                if let Some(off) = memchr::memmem::find(&bytes[i + 2..limit], b"==") {
                    let j = i + 2 + off;
                    if off > 0 && bytes[j - 1] != b' ' && !bytes[i + 2..j].contains(&b'\n') {
                        b.inline(HIGHLIGHT, i..j + 2, i..j + 2);
                        b.marker(i..i + 2, i..j + 2);
                        b.marker(j..j + 2, i..j + 2);
                        i = j + 2;
                        continue;
                    }
                }
            }
            _ => {}
        }
        i += 1;
    }
}
