// C interface of the Rust crate in core/. Keep in sync with core/src/lib.rs.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Static version string. Do not free.
const char *quill_core_version(void);

// Frees a string this library returned.
void quill_string_free(char *s);

// The language name for a file extension: "markdown", a language the code
// highlighter knows, or "". Static. Do not free.
const char *quill_language_for_extension(const char *ext);

// MARK: Documents

// A styled range within one line, in UTF-16 units. elem_start..elem_end is
// the whole element the piece belongs to, which may cover several lines.
typedef struct QuillSpan {
    uint32_t start;
    uint32_t end;
    uint32_t elem_start;
    uint32_t elem_end;
    uint8_t kind;
    uint8_t level;
    uint16_t flags;
} QuillSpan;

typedef struct QuillRange {
    uint32_t start;
    uint32_t end;
} QuillRange;

// Span kinds. Keep in sync with core/src/span.rs.
enum {
    QuillHeading = 1,
    QuillMarker = 2, // syntax hidden away from the selection
    QuillEmphasis = 3,
    QuillStrong = 4,
    QuillStrike = 5,
    QuillCode = 6,
    QuillLink = 7,
    QuillLinkDest = 8,
    QuillImage = 9,     // flags: 1 when alone on its line
    QuillImageDest = 10,
    QuillWikiLink = 11,
    QuillWikiTarget = 12,
    QuillFootnoteRef = 13,
    QuillFootnoteDef = 14,
    QuillSuperscript = 15,
    QuillSubscript = 16,
    QuillInlineMath = 17,
    QuillMathBlock = 18,  // flags: 1 when alone in its paragraph
    QuillCodeBlock = 19,  // flags: QuillCodeFenceOpen and the like
    QuillBlockQuote = 20, // level: depth, flags: callout kind or 0
    QuillCalloutTag = 21, // flags: callout kind
    QuillListMarker = 22, // level: depth, flags: 1 when ordered
    QuillTaskMarker = 23, // flags: 1 when checked
    QuillThematicBreak = 24,
    QuillTable = 25,     // flags: QuillTableHeader, QuillTableDelimiter
    QuillTableCell = 26, // level: column, flags: alignment | header << 4
    QuillHTML = 27,
    QuillFrontMatter = 28,
    QuillHighlight = 29,

    QuillTokenKeyword = 40,
    QuillTokenString = 41,
    QuillTokenComment = 42,
    QuillTokenNumber = 43,
    QuillTokenType = 44,
    QuillTokenFunction = 45,
    QuillTokenConstant = 46,
    QuillTokenProperty = 47,
    QuillTokenPunctuation = 48,
    QuillTokenInserted = 49,
    QuillTokenDeleted = 50,
};

enum {
    QuillCodeFenceOpen = 1,
    QuillCodeFenceClose = 2,
    QuillCodeDiagram = 4,
    QuillCodeMath = 8,
};

enum {
    QuillTableHeader = 1,
    QuillTableDelimiter = 2,
};

typedef struct QuillDoc QuillDoc;

// Opens a document with the given UTF-16 text. `language` is "markdown", a
// language the code highlighter knows, or "" for plain text.
QuillDoc *quill_doc_open(const uint16_t *text, uint32_t len, const char *language);
void quill_doc_close(QuillDoc *doc);

// Replaces `old_len` UTF-16 units at `start` with `text`, mirroring an edit of
// the editor's text. Returns the range whose styling may have changed.
QuillRange quill_doc_edit(QuillDoc *doc, uint32_t start, uint32_t old_len, const uint16_t *text, uint32_t len);

// The spans that start in start..end, which should cover whole lines, sorted
// by start with outer spans first. Valid until the next call with this document.
const QuillSpan *quill_doc_spans(QuillDoc *doc, uint32_t start, uint32_t end, uint32_t *count);

// One span for every element of `kind` in the document, in order. Valid until
// the next call with this document.
const QuillSpan *quill_doc_spans_of_kind(QuillDoc *doc, uint8_t kind, uint32_t *count);

// The 1-based line that UTF-16 offset `units` is on.
uint32_t quill_doc_line_of(const QuillDoc *doc, uint32_t units);
// Words as a writer counts them, each CJK character being one.
uint32_t quill_doc_count_words(const QuillDoc *doc);

// MARK: Workspaces

enum {
    QuillEventIndex = 0,  // the index changed: lists of notes are stale
    QuillEventFolder = 1, // the contents of the folder at `path` changed
    QuillEventFile = 2,   // the file at `path` was written
};

typedef struct QuillWorkspace QuillWorkspace;
// Runs on the main thread.
typedef void (*QuillWorkspaceEvent)(void *ctx, int kind, const char *path);
typedef void (*QuillSearchDone)(void *ctx, uint64_t token, const char *json);

// Opens the folder at `root` as a workspace and starts indexing it.
QuillWorkspace *quill_ws_open(const char *root, void *ctx, QuillWorkspaceEvent event);
// Stops the workspace's callbacks and frees it. Call on the main thread.
void quill_ws_close(QuillWorkspace *ws);
// The workspace's folder with links resolved. Free with quill_string_free.
char *quill_ws_root(const QuillWorkspace *ws);

// Lists the notes under `dir`, newest first or by title, and returns how many
// there are. Read them with quill_ws_notes_page.
uint32_t quill_ws_list_notes(const QuillWorkspace *ws, const char *dir, bool by_title);
// JSON array of {path, title, excerpt, image, modified}. Free with quill_string_free.
char *quill_ws_notes_page(const QuillWorkspace *ws, uint32_t offset, uint32_t limit);

// Files whose path matches `query` loosely, best first: a JSON array of
// {path, rel, title, indices}. Free with quill_string_free.
char *quill_ws_find_files(const QuillWorkspace *ws, const char *query, uint32_t limit, bool notes_only);

// Searches the text of every note. `done` runs on the main thread with
// {files: [{path, title, count, matches: [{line, text, column, length, offset}]}], total},
// valid during the call, unless a search with another token started meanwhile.
void quill_ws_search(const QuillWorkspace *ws, const char *query, uint64_t token, void *ctx, QuillSearchDone done);

// The path of the file a wikilink's target names, seen from the note at
// `from`, or "". Free with quill_string_free.
char *quill_ws_resolve_link(const QuillWorkspace *ws, const char *target, const char *from);

// The notes linking to the note at `path`: a JSON array of
// {path, title, lines: [{line, text, offset}]}. Free with quill_string_free.
char *quill_ws_backlinks(const QuillWorkspace *ws, const char *path);
