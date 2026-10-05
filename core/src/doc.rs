//! An open document: its text, mirrored from the editor, and the spans of
//! each of its sections. Offsets that cross the C interface are in UTF-16
//! units, as the editor's text storage counts.

use crate::highlight;
use crate::markdown;
use crate::span::*;

struct Section {
    bytes: u32,
    units: u32,
    /// Offsets are UTF-16 units from the section's start.
    spans: Vec<Span>,
}

pub struct Doc {
    text: String,
    /// "markdown", a language the lexer knows, or empty for plain text.
    language: String,
    sections: Vec<Section>,
    /// Where each section starts, in bytes and in UTF-16 units, with the
    /// document's length at the end.
    byte_starts: Vec<u32>,
    unit_starts: Vec<u32>,
    /// The result of the last query, kept alive for the caller to read.
    scratch: Vec<Span>,
}

/// UTF-16 offsets for every byte offset of `text`, its length included.
fn unit_offsets(text: &str) -> Option<Vec<u32>> {
    if text.is_ascii() {
        return None;
    }
    let mut map = Vec::with_capacity(text.len() + 1);
    let mut units = 0u32;
    for ch in text.chars() {
        for _ in 0..ch.len_utf8() {
            map.push(units);
        }
        units += ch.len_utf16() as u32;
    }
    map.push(units);
    Some(map)
}

fn units_of(text: &str) -> u32 {
    if text.is_ascii() { text.len() as u32 } else { text.chars().map(|c| c.len_utf16() as u32).sum() }
}

/// The byte offset of UTF-16 offset `units` in `text`.
fn byte_of(text: &str, units: u32) -> usize {
    if text.is_ascii() {
        return (units as usize).min(text.len());
    }
    let mut seen = 0u32;
    for (i, ch) in text.char_indices() {
        if seen >= units {
            return i;
        }
        seen += ch.len_utf16() as u32;
    }
    text.len()
}

impl Doc {
    pub fn new(text: String, language: &str) -> Doc {
        let mut doc = Doc {
            text,
            language: language.to_string(),
            sections: Vec::new(),
            byte_starts: Vec::new(),
            unit_starts: Vec::new(),
            scratch: Vec::new(),
        };
        let bounds = doc.bounds();
        doc.sections = (0..bounds.len() - 1).map(|i| doc.parse(bounds[i], bounds[i + 1], i == 0)).collect();
        doc.index();
        doc
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    /// Section boundaries in bytes, the text's length last.
    fn bounds(&self) -> Vec<usize> {
        let mut bounds = if self.language == "markdown" { markdown::split_sections(&self.text) } else { vec![0] };
        bounds.push(self.text.len());
        bounds
    }

    fn parse(&self, start: usize, end: usize, first: bool) -> Section {
        let text = &self.text[start..end];
        // A parser that trips over some odd input leaves its section plain
        // rather than taking the editor down with it.
        let parsed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            if self.language == "markdown" {
                markdown::parse_section(text, first)
            } else {
                let mut spans = Vec::new();
                // Past this size the lexer would hold up typing.
                if text.len() < 2_000_000 {
                    highlight::lex(&self.language, text, 0, &mut spans);
                }
                spans
            }
        }));
        let mut spans = parsed.unwrap_or_default();
        let units = match unit_offsets(text) {
            None => text.len() as u32,
            Some(map) => {
                let at = |b: u32| map[(b as usize).min(map.len() - 1)];
                for s in &mut spans {
                    s.start = at(s.start);
                    s.end = at(s.end);
                    s.elem_start = at(s.elem_start);
                    s.elem_end = at(s.elem_end);
                }
                *map.last().unwrap()
            }
        };
        Section { bytes: (end - start) as u32, units, spans }
    }

    fn index(&mut self) {
        self.byte_starts.clear();
        self.unit_starts.clear();
        let (mut b, mut u) = (0, 0);
        for s in &self.sections {
            self.byte_starts.push(b);
            self.unit_starts.push(u);
            b += s.bytes;
            u += s.units;
        }
        self.byte_starts.push(b);
        self.unit_starts.push(u);
    }

    pub fn units(&self) -> u32 {
        *self.unit_starts.last().unwrap()
    }

    /// The section holding UTF-16 offset `units`.
    fn section_at(&self, units: u32) -> usize {
        let i = self.unit_starts.partition_point(|&s| s <= units);
        i.saturating_sub(1).min(self.sections.len().saturating_sub(1))
    }

    fn byte_at(&self, units: u32) -> usize {
        let i = self.section_at(units);
        let start = self.byte_starts[i] as usize;
        let end = self.byte_starts[i + 1] as usize;
        start + byte_of(&self.text[start..end], units - self.unit_starts[i])
    }

    /// Replaces `old_len` units at `start` with `new`, and returns the range
    /// whose styling may have changed, in units of the new text.
    pub fn edit(&mut self, start: u32, old_len: u32, new: &str) -> (u32, u32) {
        let start = start.min(self.units());
        let old_end = (start.saturating_add(old_len)).min(self.units());
        let byte_start = self.byte_at(start);
        let byte_old_end = self.byte_at(old_end).max(byte_start);
        let new_units = units_of(new);
        self.text.replace_range(byte_start..byte_old_end, new);
        // The sections are reworked from the new text. Should that trip over
        // some odd input, the whole document is parsed afresh instead.
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            self.reparse(start, old_end, new_units, byte_start, byte_old_end, new.len())
        })) {
            Ok(dirty) => dirty,
            Err(_) => {
                let bounds = self.bounds();
                self.sections = (0..bounds.len() - 1).map(|i| self.parse(bounds[i], bounds[i + 1], i == 0)).collect();
                self.index();
                (0, self.units())
            }
        }
    }

    fn reparse(&mut self, start: u32, old_end: u32, new_units: u32, byte_start: usize, byte_old_end: usize, new_len: usize) -> (u32, u32) {
        let byte_new_end = byte_start + new_len;
        let byte_delta = byte_new_end as i64 - byte_old_end as i64;
        let unit_delta = new_units as i64 - (old_end - start) as i64;

        let bounds = self.bounds();
        let mut old: Vec<Option<Section>> = std::mem::take(&mut self.sections).into_iter().map(Some).collect();
        let old_byte_starts = std::mem::take(&mut self.byte_starts);
        let old_unit_starts = std::mem::take(&mut self.unit_starts);
        // The old section that covered exactly these bytes of the old text.
        let find = |s: i64, e: i64| -> Option<usize> {
            if s < 0 {
                return None;
            }
            let i = old_byte_starts.binary_search(&(s as u32)).ok()?;
            (i + 1 < old_byte_starts.len() && old_byte_starts[i + 1] as i64 == e).then_some(i)
        };
        let mut sections = Vec::with_capacity(bounds.len() - 1);
        let mut parsed: Vec<usize> = Vec::new();
        for i in 0..bounds.len() - 1 {
            let (s, e) = (bounds[i], bounds[i + 1]);
            // The first section alone reads front matter, so a section only
            // keeps its spans while it keeps being first, or not first.
            let kept = if e <= byte_start && e > s {
                find(s as i64, e as i64)
            } else if s >= byte_new_end && e > s {
                find(s as i64 - byte_delta, e as i64 - byte_delta)
            } else {
                None
            }
            .filter(|&j| (j == 0) == (i == 0));
            match kept.and_then(|j| old[j].take()) {
                Some(section) => sections.push(section),
                None => {
                    sections.push(self.parse(s, e, i == 0));
                    parsed.push(i);
                }
            }
        }
        self.sections = sections;
        self.index();

        // Narrow the changed range to where the spans differ.
        let first = *parsed.first().unwrap_or(&0);
        let last = *parsed.last().unwrap_or(&0);
        let contiguous = parsed.len() == last - first + 1;
        let mut dirty = (start, start + new_units);
        let region = (self.unit_starts[first], self.unit_starts[last + 1]);
        let replaced: Vec<(usize, Section)> = old.into_iter().enumerate().filter_map(|(i, s)| s.map(|s| (i, s))).collect();
        if !contiguous || replaced.is_empty() {
            return (dirty.0.min(region.0), dirty.1.max(region.1));
        }
        let absolute = |base: u32, s: &Span| Span {
            start: s.start + base,
            end: s.end + base,
            elem_start: s.elem_start + base,
            elem_end: s.elem_end + base,
            ..*s
        };
        let mut before = Vec::new();
        for (i, section) in &replaced {
            before.extend(section.spans.iter().map(|sp| absolute(old_unit_starts[*i], sp)));
        }
        let mut after = Vec::new();
        for i in first..=last {
            after.extend(self.sections[i].spans.iter().map(|sp| absolute(self.unit_starts[i], sp)));
        }
        let shift = |s: &Span| Span {
            start: (s.start as i64 + unit_delta) as u32,
            end: (s.end as i64 + unit_delta) as u32,
            elem_start: (s.elem_start as i64 + unit_delta) as u32,
            elem_end: (s.elem_end as i64 + unit_delta) as u32,
            ..*s
        };
        // A line of a long block, such as a code block or a quote, looks the
        // same when the block grows or shrinks around an edit elsewhere in
        // it: its span keeps everything but the far edge of its element,
        // which moves with the text. Such lines are not dirty, so typing in
        // a block of thousands of lines restyles the line typed in, not the
        // block. The editor restyles the first line of a block it draws as
        // a whole, a table or a diagram, itself.
        let same_before = |b: &Span, a: &Span| {
            b.end < start
                && (b == a
                    || (b.elem_end >= old_end
                        && Span { elem_end: (b.elem_end as i64 + unit_delta) as u32, ..*b } == *a))
        };
        let same_after = |b: &Span, a: &Span| {
            let moved = shift(b);
            b.start > old_end && (moved == *a || (b.elem_start <= start && Span { elem_start: b.elem_start, ..moved } == *a))
        };
        let mut head = 0;
        while head < before.len() && head < after.len() && same_before(&before[head], &after[head]) {
            head += 1;
        }
        let mut tail = 0;
        while tail < before.len() - head && tail < after.len() - head {
            if !same_after(&before[before.len() - 1 - tail], &after[after.len() - 1 - tail]) {
                break;
            }
            tail += 1;
        }
        for s in &after[head..after.len() - tail] {
            dirty.0 = dirty.0.min(s.start);
            dirty.1 = dirty.1.max(s.end);
        }
        for s in &before[head..before.len() - tail] {
            dirty.0 = dirty.0.min(s.start.min(start));
            dirty.1 = dirty.1.max(((s.end as i64 + unit_delta).max(0) as u32).min(region.1));
        }
        (dirty.0.max(region.0.min(start)), dirty.1.min(self.units()))
    }

    /// The 1-based line that UTF-16 offset `units` is on.
    pub fn line_of(&self, units: u32) -> u32 {
        let end = self.byte_at(units.min(self.units()));
        memchr::memchr_iter(b'\n', &self.text.as_bytes()[..end]).count() as u32 + 1
    }

    /// Words as a writer counts them: runs of letters and digits, and each
    /// Chinese, Japanese or Korean character on its own.
    pub fn count_words(&self) -> u32 {
        let mut count = 0;
        let mut in_word = false;
        for ch in self.text.chars() {
            let wide = matches!(ch as u32, 0x2E80..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF | 0x20000..=0x2FA1F)
                && !matches!(ch as u32, 0x3000..=0x303F);
            if wide {
                count += 1;
                in_word = false;
            } else if ch.is_alphanumeric() {
                if !in_word {
                    count += 1;
                }
                in_word = true;
            } else if ch != '\'' && ch != '’' {
                in_word = false;
            }
        }
        count
    }

    /// The spans that start in `start..end`, which should be whole lines.
    pub fn spans_in(&mut self, start: u32, end: u32) -> &[Span] {
        let mut scratch = std::mem::take(&mut self.scratch);
        scratch.clear();
        if !self.sections.is_empty() && end > start {
            let first = self.section_at(start);
            for i in first..self.sections.len() {
                let base = self.unit_starts[i];
                if base >= end {
                    break;
                }
                let spans = &self.sections[i].spans;
                let from = spans.partition_point(|s| s.start + base < start);
                for s in &spans[from..] {
                    if s.start + base >= end {
                        break;
                    }
                    scratch.push(Span {
                        start: s.start + base,
                        end: s.end + base,
                        elem_start: s.elem_start + base,
                        elem_end: s.elem_end + base,
                        ..*s
                    });
                }
            }
        }
        self.scratch = scratch;
        &self.scratch
    }

    /// Every span of `kind`, one per element.
    pub fn spans_of_kind(&mut self, kind: u8) -> &[Span] {
        let mut scratch = std::mem::take(&mut self.scratch);
        scratch.clear();
        for (i, section) in self.sections.iter().enumerate() {
            let base = self.unit_starts[i];
            for s in &section.spans {
                if s.kind == kind && s.start == s.elem_start {
                    scratch.push(Span {
                        start: s.start + base,
                        end: s.end + base,
                        elem_start: s.elem_start + base,
                        elem_end: s.elem_end + base,
                        ..*s
                    });
                }
            }
        }
        self.scratch = scratch;
        &self.scratch
    }
}
