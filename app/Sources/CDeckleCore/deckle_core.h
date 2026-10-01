// C interface of the Rust crate in core/. Keep in sync with core/src/lib.rs.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Static version string. Do not free.
const char *deckle_core_version(void);

// Frees a string this library returned.
void deckle_string_free(char *s);

// The language name for a file extension: "markdown", a language the code
// highlighter knows, or "". Static. Do not free.
const char *deckle_language_for_extension(const char *ext);

// MARK: Documents

// A styled range within one line, in UTF-16 units. elem_start..elem_end is
// the whole element the piece belongs to, which may cover several lines.
typedef struct DeckleSpan {
    uint32_t start;
    uint32_t end;
    uint32_t elem_start;
    uint32_t elem_end;
    uint8_t kind;
    uint8_t level;
    uint16_t flags;
} DeckleSpan;

typedef struct DeckleRange {
    uint32_t start;
    uint32_t end;
} DeckleRange;

// Span kinds. Keep in sync with core/src/span.rs.
enum {
    DeckleHeading = 1,
    DeckleMarker = 2, // syntax hidden away from the selection
    DeckleEmphasis = 3,
    DeckleStrong = 4,
    DeckleStrike = 5,
    DeckleCode = 6,
    DeckleLink = 7,
    DeckleLinkDest = 8,
    DeckleImage = 9,     // flags: 1 when alone on its line
    DeckleImageDest = 10,
    DeckleWikiLink = 11,
    DeckleWikiTarget = 12,
    DeckleFootnoteRef = 13,
    DeckleFootnoteDef = 14,
    DeckleSuperscript = 15,
    DeckleSubscript = 16,
    DeckleInlineMath = 17,
    DeckleMathBlock = 18,  // flags: 1 when alone in its paragraph
    DeckleCodeBlock = 19,  // flags: DeckleCodeFenceOpen and the like
    DeckleBlockQuote = 20, // level: depth, flags: callout kind or 0
    DeckleCalloutTag = 21, // flags: callout kind
    DeckleListMarker = 22, // level: depth, flags: 1 when ordered
    DeckleTaskMarker = 23, // flags: 1 when checked
    DeckleThematicBreak = 24,
    DeckleTable = 25,     // flags: DeckleTableHeader, DeckleTableDelimiter
    DeckleTableCell = 26, // level: column, flags: alignment | header << 4
    DeckleHTML = 27,
    DeckleFrontMatter = 28,
    DeckleHighlight = 29,

    DeckleTokenKeyword = 40,
    DeckleTokenString = 41,
    DeckleTokenComment = 42,
    DeckleTokenNumber = 43,
    DeckleTokenType = 44,
    DeckleTokenFunction = 45,
    DeckleTokenConstant = 46,
    DeckleTokenProperty = 47,
    DeckleTokenPunctuation = 48,
    DeckleTokenInserted = 49,
    DeckleTokenDeleted = 50,
};

enum {
    DeckleCodeFenceOpen = 1,
    DeckleCodeFenceClose = 2,
    DeckleCodeDiagram = 4,
    DeckleCodeMath = 8,
};

enum {
    DeckleTableHeader = 1,
    DeckleTableDelimiter = 2,
};

typedef struct DeckleDoc DeckleDoc;

// Opens a document with the given UTF-16 text. `language` is "markdown", a
// language the code highlighter knows, or "" for plain text.
DeckleDoc *deckle_doc_open(const uint16_t *text, uint32_t len, const char *language);
void deckle_doc_close(DeckleDoc *doc);

// Replaces `old_len` UTF-16 units at `start` with `text`, mirroring an edit of
// the editor's text. Returns the range whose styling may have changed.
DeckleRange deckle_doc_edit(DeckleDoc *doc, uint32_t start, uint32_t old_len, const uint16_t *text, uint32_t len);

// The spans that start in start..end, which should cover whole lines, sorted
// by start with outer spans first. Valid until the next call with this document.
const DeckleSpan *deckle_doc_spans(DeckleDoc *doc, uint32_t start, uint32_t end, uint32_t *count);

// One span for every element of `kind` in the document, in order. Valid until
// the next call with this document.
const DeckleSpan *deckle_doc_spans_of_kind(DeckleDoc *doc, uint8_t kind, uint32_t *count);

// The 1-based line that UTF-16 offset `units` is on.
uint32_t deckle_doc_line_of(const DeckleDoc *doc, uint32_t units);
// Words as a writer counts them, each CJK character being one.
uint32_t deckle_doc_count_words(const DeckleDoc *doc);

// MARK: Workspaces

enum {
    DeckleEventIndex = 0,  // the index changed: lists of notes are stale
    DeckleEventFolder = 1, // the contents of the folder at `path` changed
    DeckleEventFile = 2,   // the file at `path` was written
};

typedef struct DeckleWorkspace DeckleWorkspace;
// Runs on the main thread.
typedef void (*DeckleWorkspaceEvent)(void *ctx, int kind, const char *path);
typedef void (*DeckleSearchDone)(void *ctx, uint64_t token, const char *json);

// Opens the folder at `root` as a workspace and starts indexing it.
DeckleWorkspace *deckle_ws_open(const char *root, void *ctx, DeckleWorkspaceEvent event);
// Stops the workspace's callbacks and frees it. Call on the main thread.
void deckle_ws_close(DeckleWorkspace *ws);
// The workspace's folder with links resolved. Free with deckle_string_free.
char *deckle_ws_root(const DeckleWorkspace *ws);

// Lists the notes under `dir`, newest first or by title, and returns how many
// there are. Read them with deckle_ws_notes_page.
uint32_t deckle_ws_list_notes(const DeckleWorkspace *ws, const char *dir, bool by_title);
// JSON array of {path, title, excerpt, image, modified}. Free with deckle_string_free.
char *deckle_ws_notes_page(const DeckleWorkspace *ws, uint32_t offset, uint32_t limit);

// Files whose path matches `query` loosely, best first: a JSON array of
// {path, rel, title, indices}. Free with deckle_string_free.
char *deckle_ws_find_files(const DeckleWorkspace *ws, const char *query, uint32_t limit, bool notes_only);

// Searches the text of every note. `done` runs on the main thread with
// {files: [{path, title, count, matches: [{line, text, column, length, offset}]}], total},
// valid during the call, unless a search with another token started meanwhile.
void deckle_ws_search(const DeckleWorkspace *ws, const char *query, uint64_t token, void *ctx, DeckleSearchDone done);

// The path of the file a wikilink's target names, seen from the note at
// `from`, or "". Free with deckle_string_free.
char *deckle_ws_resolve_link(const DeckleWorkspace *ws, const char *target, const char *from);

// The notes linking to the note at `path`: a JSON array of
// {path, title, lines: [{line, text, offset}]}. Free with deckle_string_free.
char *deckle_ws_backlinks(const DeckleWorkspace *ws, const char *path);
