//! Document and workspace core for Quill. Built as a static library and linked
//! into the Swift app. Every exported function is declared in
//! `app/Sources/CQuillCore/quill_core.h`.

pub mod doc;
pub mod highlight;
pub mod markdown;
pub mod span;
pub mod workspace;

use doc::Doc;
use span::Span;
use std::ffi::{CStr, CString, c_char, c_void};
use workspace::Workspace;

static VERSION: &CStr = c"quill-core 0.1.0";

/// Returns a static, NUL-terminated version string. The caller must not free it.
#[unsafe(no_mangle)]
pub extern "C" fn quill_core_version() -> *const c_char {
    VERSION.as_ptr()
}

/// # Safety
/// `s` must be null or a NUL-terminated string.
unsafe fn cstr(s: *const c_char) -> String {
    if s.is_null() { String::new() } else { unsafe { CStr::from_ptr(s) }.to_string_lossy().into_owned() }
}

fn into_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).unwrap_or_default().into_raw()
}

/// Frees a string this library returned.
///
/// # Safety
/// `s` must be null or a string returned by this library, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

/// The language name for a file extension: "markdown", a language the code
/// highlighter knows, or "". Static. Do not free.
///
/// # Safety
/// `ext` must be a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_language_for_extension(ext: *const c_char) -> *const c_char {
    let name = highlight::language_for_extension(&unsafe { cstr(ext) });
    // Every name is one of a few literals, stored here with its NUL.
    const NAMES: &[&CStr] = &[
        c"markdown", c"rust", c"swift", c"javascript", c"python", c"go", c"c", c"java", c"ruby", c"php", c"shell", c"sql",
        c"lua", c"zig", c"css", c"toml", c"yaml", c"json", c"html", c"diff",
    ];
    NAMES.iter().find(|n| n.to_bytes() == name.as_bytes()).map_or(c"".as_ptr(), |n| n.as_ptr())
}

/// Opens a document with the given UTF-16 text. Close it with
/// `quill_doc_close`.
///
/// # Safety
/// `text` must point to `len` UTF-16 units and `language` be NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_doc_open(text: *const u16, len: u32, language: *const c_char) -> *mut Doc {
    let text = String::from_utf16_lossy(unsafe { units(text, len) });
    Box::into_raw(Box::new(Doc::new(text, &unsafe { cstr(language) })))
}

unsafe fn units<'a>(text: *const u16, len: u32) -> &'a [u16] {
    if text.is_null() || len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(text, len as usize) } }
}

/// # Safety
/// `doc` must come from `quill_doc_open` and not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_doc_close(doc: *mut Doc) {
    if !doc.is_null() {
        drop(unsafe { Box::from_raw(doc) });
    }
}

#[repr(C)]
pub struct Range {
    pub start: u32,
    pub end: u32,
}

/// Replaces `old_len` UTF-16 units at `start` with `text`, mirroring an edit
/// of the editor's text. Returns the range whose styling may have changed.
///
/// # Safety
/// `doc` must be a live document and `text` point to `len` UTF-16 units.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_doc_edit(doc: *mut Doc, start: u32, old_len: u32, text: *const u16, len: u32) -> Range {
    let doc = unsafe { &mut *doc };
    let new = String::from_utf16_lossy(unsafe { units(text, len) });
    let (start, end) = doc.edit(start, old_len, &new);
    Range { start, end }
}

/// The spans that start in `start..end`, which should cover whole lines. The
/// result is valid until the next call with this document.
///
/// # Safety
/// `doc` must be a live document and `count` a valid pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_doc_spans(doc: *mut Doc, start: u32, end: u32, count: *mut u32) -> *const Span {
    let spans = unsafe { &mut *doc }.spans_in(start, end);
    unsafe { *count = spans.len() as u32 };
    spans.as_ptr()
}

/// One span for every element of `kind` in the document, in order. The result
/// is valid until the next call with this document.
///
/// # Safety
/// `doc` must be a live document and `count` a valid pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_doc_spans_of_kind(doc: *mut Doc, kind: u8, count: *mut u32) -> *const Span {
    let spans = unsafe { &mut *doc }.spans_of_kind(kind);
    unsafe { *count = spans.len() as u32 };
    spans.as_ptr()
}

/// The 1-based line that UTF-16 offset `units` is on.
///
/// # Safety
/// `doc` must be a live document.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_doc_line_of(doc: *const Doc, units: u32) -> u32 {
    unsafe { &*doc }.line_of(units)
}

/// The number of words in the document.
///
/// # Safety
/// `doc` must be a live document.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_doc_count_words(doc: *const Doc) -> u32 {
    unsafe { &*doc }.count_words()
}

/// Opens the folder at `root` as a workspace and starts indexing it. `event`
/// runs on the main thread with `ctx`. Close it with `quill_ws_close`.
///
/// # Safety
/// `root` must be a NUL-terminated string, and `ctx` stay valid until the
/// workspace is closed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_ws_open(root: *const c_char, ctx: *mut c_void, event: workspace::EventFn) -> *mut Workspace {
    Box::into_raw(Box::new(Workspace::open(&unsafe { cstr(root) }, ctx, event)))
}

/// Stops the workspace's callbacks and frees it. Call on the main thread.
///
/// # Safety
/// `ws` must come from `quill_ws_open` and not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_ws_close(ws: *mut Workspace) {
    if !ws.is_null() {
        let ws = unsafe { Box::from_raw(ws) };
        ws.close();
    }
}

/// The workspace's folder with links resolved, as the index names it. Free
/// with `quill_string_free`.
///
/// # Safety
/// `ws` must be a live workspace.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_ws_root(ws: *const Workspace) -> *mut c_char {
    into_c(unsafe { &*ws }.root().to_string_lossy().into_owned())
}

/// Lists the notes under `dir`, newest first or by title, and returns how
/// many there are. Read them with `quill_ws_notes_page`.
///
/// # Safety
/// `ws` must be a live workspace and `dir` a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_ws_list_notes(ws: *const Workspace, dir: *const c_char, by_title: bool) -> u32 {
    unsafe { &*ws }.list_notes(&unsafe { cstr(dir) }, by_title)
}

/// `limit` notes of the last list from `offset`, as a JSON array of
/// {path, title, excerpt, image, modified}. Free with `quill_string_free`.
///
/// # Safety
/// `ws` must be a live workspace.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_ws_notes_page(ws: *const Workspace, offset: u32, limit: u32) -> *mut c_char {
    into_c(unsafe { &*ws }.notes_page(offset, limit))
}

/// Files whose path matches `query` loosely, best first, as a JSON array of
/// {path, rel, title, indices}. Free with `quill_string_free`.
///
/// # Safety
/// `ws` must be a live workspace and `query` a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_ws_find_files(ws: *const Workspace, query: *const c_char, limit: u32, notes_only: bool) -> *mut c_char {
    into_c(unsafe { &*ws }.find_files(&unsafe { cstr(query) }, limit, notes_only))
}

/// Searches the text of every note. `done` runs on the main thread with the
/// results as JSON, valid during the call, unless a search with another
/// token started meanwhile.
///
/// # Safety
/// `ws` must be a live workspace, `query` a NUL-terminated string, and `ctx`
/// stay valid until the workspace is closed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_ws_search(ws: *const Workspace, query: *const c_char, token: u64, ctx: *mut c_void, done: workspace::SearchFn) {
    unsafe { &*ws }.search(&unsafe { cstr(query) }, token, ctx, done);
}

/// The path of the file a wikilink's `target` names, seen from the note at
/// `from`, or an empty string. Free with `quill_string_free`.
///
/// # Safety
/// `ws` must be a live workspace, `target` and `from` NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_ws_resolve_link(ws: *const Workspace, target: *const c_char, from: *const c_char) -> *mut c_char {
    into_c(unsafe { &*ws }.resolve_link(&unsafe { cstr(target) }, &unsafe { cstr(from) }))
}

/// The notes linking to the note at `path`, as a JSON array of
/// {path, title, lines: [{line, text, offset}]}. Free with `quill_string_free`.
///
/// # Safety
/// `ws` must be a live workspace and `path` a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn quill_ws_backlinks(ws: *const Workspace, path: *const c_char) -> *mut c_char {
    into_c(unsafe { &*ws }.backlinks(&unsafe { cstr(path) }))
}
