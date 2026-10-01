//! The style span shared with the app, and its kinds. Keep in sync with
//! `deckle_core.h`.

/// A styled range within one line. `elem_start..elem_end` is the whole
/// element the piece belongs to, which may cover several lines: a marker is
/// shown while the selection touches its element, and a block drawn as a
/// widget covers its element.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    pub start: u32,
    pub end: u32,
    pub elem_start: u32,
    pub elem_end: u32,
    pub kind: u8,
    pub level: u8,
    pub flags: u16,
}

pub const HEADING: u8 = 1;
/// Syntax that is hidden away from the selection.
pub const MARKER: u8 = 2;
pub const EMPHASIS: u8 = 3;
pub const STRONG: u8 = 4;
pub const STRIKE: u8 = 5;
pub const CODE: u8 = 6;
pub const LINK: u8 = 7;
pub const LINK_DEST: u8 = 8;
pub const IMAGE: u8 = 9;
pub const IMAGE_DEST: u8 = 10;
pub const WIKI_LINK: u8 = 11;
pub const WIKI_TARGET: u8 = 12;
pub const FOOTNOTE_REF: u8 = 13;
pub const FOOTNOTE_DEF: u8 = 14;
pub const SUPERSCRIPT: u8 = 15;
pub const SUBSCRIPT: u8 = 16;
pub const INLINE_MATH: u8 = 17;
pub const MATH_BLOCK: u8 = 18;
pub const CODE_BLOCK: u8 = 19;
pub const BLOCK_QUOTE: u8 = 20;
pub const CALLOUT_TAG: u8 = 21;
pub const LIST_MARKER: u8 = 22;
pub const TASK_MARKER: u8 = 23;
pub const THEMATIC_BREAK: u8 = 24;
pub const TABLE: u8 = 25;
pub const TABLE_CELL: u8 = 26;
pub const HTML: u8 = 27;
pub const FRONT_MATTER: u8 = 28;
pub const HIGHLIGHT: u8 = 29;

// Tokens of highlighted code.
pub const TOKEN_KEYWORD: u8 = 40;
pub const TOKEN_STRING: u8 = 41;
pub const TOKEN_COMMENT: u8 = 42;
pub const TOKEN_NUMBER: u8 = 43;
pub const TOKEN_TYPE: u8 = 44;
pub const TOKEN_FUNCTION: u8 = 45;
pub const TOKEN_CONSTANT: u8 = 46;
pub const TOKEN_PROPERTY: u8 = 47;
pub const TOKEN_PUNCTUATION: u8 = 48;
pub const TOKEN_INSERTED: u8 = 49;
pub const TOKEN_DELETED: u8 = 50;

// Flags of CODE_BLOCK and FRONT_MATTER lines.
pub const CODE_FENCE_OPEN: u16 = 1;
pub const CODE_FENCE_CLOSE: u16 = 2;
pub const CODE_DIAGRAM: u16 = 4;
pub const CODE_MATH: u16 = 8;

// Flags of TABLE lines. A TABLE_CELL has its alignment in the low bits and
// the header flag shifted left by four.
pub const TABLE_HEADER: u16 = 1;
pub const TABLE_DELIMITER: u16 = 2;
