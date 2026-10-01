//! A workspace: a folder of notes. A background scan indexes its files, a
//! watcher keeps the index current, and queries for the note list, quick
//! open, full-text search and links read from it.

use crate::highlight::language_for_extension;
use notify::{RecursiveMode, Watcher};
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};
use std::ffi::{CString, c_char, c_int, c_void};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, UNIX_EPOCH};

/// The index finished a scan or took in changes: lists of notes are stale.
pub const EVENT_INDEX: c_int = 0;
/// The contents of the folder at `path` changed.
pub const EVENT_FOLDER: c_int = 1;
/// The file at `path` was written.
pub const EVENT_FILE: c_int = 2;

pub type EventFn = unsafe extern "C" fn(ctx: *mut c_void, kind: c_int, path: *const c_char);
pub type SearchFn = unsafe extern "C" fn(ctx: *mut c_void, token: u64, json: *const c_char);

unsafe extern "C" {
    static _dispatch_main_q: c_void;
    fn dispatch_async_f(queue: *const c_void, context: *mut c_void, work: unsafe extern "C" fn(*mut c_void));
}

/// Runs `work` on the main thread.
fn on_main<F: FnOnce() + Send + 'static>(work: F) {
    unsafe extern "C" fn run<F: FnOnce()>(ctx: *mut c_void) {
        let work = unsafe { Box::from_raw(ctx as *mut F) };
        work();
    }
    let ctx = Box::into_raw(Box::new(work)) as *mut c_void;
    unsafe { dispatch_async_f(&raw const _dispatch_main_q, ctx, run::<F>) };
}

/// A pointer the app gave us, passed back to it on the main thread only.
#[derive(Clone, Copy)]
struct Context(*mut c_void);
unsafe impl Send for Context {}
unsafe impl Sync for Context {}

#[derive(Clone, Default)]
struct Note {
    title: String,
    excerpt: String,
    /// The first image of the note, as an absolute path.
    image: String,
    /// Seconds since 1970.
    modified: u64,
    /// The targets of its wikilinks, lowercased.
    links: Vec<String>,
}

#[derive(Default)]
struct Index {
    /// Every file, by absolute path.
    files: BTreeSet<PathBuf>,
    notes: HashMap<PathBuf, Note>,
    /// Files by lowercased name without extension, and by lowercased name.
    names: HashMap<String, Vec<PathBuf>>,
}

impl Index {
    fn add(&mut self, path: &Path, note: Option<Note>) {
        if self.files.insert(path.to_path_buf()) {
            for key in name_keys(path) {
                self.names.entry(key).or_default().push(path.to_path_buf());
            }
        }
        match note {
            Some(note) => {
                self.notes.insert(path.to_path_buf(), note);
            }
            None => {
                self.notes.remove(path);
            }
        }
    }

    fn remove(&mut self, path: &Path) {
        if self.files.remove(path) {
            for key in name_keys(path) {
                if let Some(paths) = self.names.get_mut(&key) {
                    paths.retain(|p| p != path);
                    if paths.is_empty() {
                        self.names.remove(&key);
                    }
                }
            }
        }
        self.notes.remove(path);
    }
}

fn name_keys(path: &Path) -> Vec<String> {
    let mut keys = Vec::new();
    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
        keys.push(name.to_lowercase());
    }
    if let Some(stem) = path.file_stem().and_then(|n| n.to_str()) {
        let stem = stem.to_lowercase();
        if !keys.contains(&stem) {
            keys.push(stem);
        }
    }
    keys
}

struct Shared {
    root: PathBuf,
    index: RwLock<Index>,
    /// The notes of the last list query, in order.
    listed: Mutex<Vec<PathBuf>>,
    ctx: Context,
    event: EventFn,
    closed: AtomicBool,
    /// The newest search; older ones stop when they see it.
    search: AtomicU64,
}

pub struct Workspace {
    shared: Arc<Shared>,
    _watcher: Option<notify::RecommendedWatcher>,
}

fn is_markdown(path: &Path) -> bool {
    path.extension().and_then(|e| e.to_str()).is_some_and(|e| language_for_extension(e) == "markdown")
}

/// Hidden files and the folders of tools, which are not part of the notes.
fn is_ignored(name: &str) -> bool {
    name.starts_with('.') || name == "node_modules"
}

fn is_ignored_path(root: &Path, path: &Path) -> bool {
    path.strip_prefix(root).map_or(true, |rel| rel.components().any(|c| c.as_os_str().to_str().is_none_or(is_ignored)))
}

fn modified(path: &Path) -> u64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_secs())
}

/// Reads what the note list and the link index need from a note.
fn read_note(path: &Path) -> Option<Note> {
    let bytes = std::fs::read(path).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    let mut note = extract(&text, path);
    note.modified = modified(path);
    Some(note)
}

fn extract(text: &str, path: &Path) -> Note {
    let mut note = Note::default();
    let mut lines = text.lines().peekable();
    if lines.peek().is_some_and(|l| l.trim_end() == "---") {
        lines.next();
        for line in lines.by_ref() {
            let line = line.trim_end();
            if line == "---" || line == "..." {
                break;
            }
            if let Some(value) = line.strip_prefix("title:") {
                note.title = value.trim().trim_matches(|c| c == '"' || c == '\'').to_string();
            }
        }
    }
    let mut in_fence = false;
    let mut excerpt = String::new();
    for line in lines {
        let trimmed = line.trim();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence {
            continue;
        }
        links_in(line, &mut note.links);
        if note.image.is_empty() {
            if let Some(src) = first_image(trimmed) {
                note.image = resolve_image(src, path);
            }
        }
        if trimmed.is_empty() {
            continue;
        }
        // Headings and images are not part of the excerpt.
        if let Some(heading) = atx_heading(trimmed) {
            if note.title.is_empty() {
                note.title = plain(heading);
            }
            continue;
        }
        if trimmed.starts_with("![") {
            continue;
        }
        if excerpt.len() < 320 {
            let text = plain(trimmed);
            if !text.is_empty() {
                if !excerpt.is_empty() {
                    excerpt.push(' ');
                }
                excerpt.push_str(&text);
            }
        }
    }
    if note.title.is_empty() {
        note.title = path.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
    }
    note.excerpt = excerpt.chars().take(200).collect();
    note.links.sort();
    note.links.dedup();
    note
}

fn atx_heading(line: &str) -> Option<&str> {
    let hashes = line.bytes().take_while(|&b| b == b'#').count();
    if (1..=6).contains(&hashes) && line.as_bytes().get(hashes) == Some(&b' ') {
        Some(line[hashes..].trim().trim_end_matches('#').trim())
    } else {
        None
    }
}

/// `line` as it reads, without Markdown's syntax.
fn plain(line: &str) -> String {
    let line = line.trim_start_matches(|c: char| matches!(c, '#' | '>' | '-' | '*' | '+' | ' ') || c.is_ascii_digit());
    let line = line.trim_start_matches(['.', ')', ' ']);
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    let mut previous = ' ';
    while let Some(c) = chars.next() {
        let doubled = chars.peek() == Some(&c) || previous == c;
        previous = c;
        match c {
            '_' | '~' | '=' if doubled => {}
            '*' | '`' => {}
            '!' if chars.peek() == Some(&'[') => {}
            '[' => {
                // A wikilink reads as its label, or its target.
                if chars.peek() == Some(&'[') {
                    chars.next();
                    let mut inner = String::new();
                    while let Some(d) = chars.next() {
                        if d == ']' {
                            chars.next();
                            break;
                        }
                        inner.push(d);
                    }
                    out.push_str(inner.rsplit('|').next().unwrap_or(&inner));
                }
            }
            ']' => {
                // A link's destination is left out.
                if chars.peek() == Some(&'(') {
                    for d in chars.by_ref() {
                        if d == ')' {
                            break;
                        }
                    }
                }
            }
            _ => out.push(c),
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The targets of the wikilinks in `line`: what comes before | and #.
fn links_in(line: &str, out: &mut Vec<String>) {
    let mut rest = line;
    while let Some(i) = rest.find("[[") {
        rest = &rest[i + 2..];
        let Some(end) = rest.find("]]") else { break };
        let inner = &rest[..end];
        let target = inner.split(['|', '#']).next().unwrap_or("").trim();
        if !target.is_empty() {
            out.push(target.to_lowercase());
        }
        rest = &rest[end + 2..];
    }
}

fn first_image(line: &str) -> Option<&str> {
    if let Some(i) = line.find("![[") {
        let rest = &line[i + 3..];
        let end = rest.find("]]")?;
        return Some(rest[..end].split('|').next().unwrap_or("").trim());
    }
    let i = line.find("![")?;
    let rest = &line[i..];
    let open = rest.find("](")? + 2;
    let rest = &rest[open..];
    let end = rest.find([')', ' '])?;
    Some(rest[..end].trim_matches(['<', '>']))
}

fn resolve_image(src: &str, note: &Path) -> String {
    if src.is_empty() || src.contains("://") {
        return String::new();
    }
    let decoded = percent_decode(src);
    let path = note.parent().unwrap_or(Path::new("/")).join(&decoded);
    if path.is_file() { path.to_string_lossy().into_owned() } else { String::new() }
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Some(v) = std::str::from_utf8(&bytes[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

impl Shared {
    fn emit(self: &Arc<Self>, kind: c_int, path: &Path) {
        let shared = self.clone();
        let path = CString::new(path.to_string_lossy().as_bytes()).unwrap_or_default();
        on_main(move || {
            if !shared.closed.load(Ordering::Acquire) {
                unsafe { (shared.event)(shared.ctx.0, kind, path.as_ptr()) };
            }
        });
    }

    fn scan(self: &Arc<Self>) {
        let mut files = Vec::new();
        let mut stack = vec![self.root.clone()];
        while let Some(dir) = stack.pop() {
            if self.closed.load(Ordering::Acquire) {
                return;
            }
            let Ok(entries) = std::fs::read_dir(&dir) else { continue };
            for entry in entries.flatten() {
                let name = entry.file_name();
                if name.to_str().is_none_or(is_ignored) {
                    continue;
                }
                match entry.file_type() {
                    Ok(t) if t.is_dir() => stack.push(entry.path()),
                    Ok(t) if t.is_file() => files.push(entry.path()),
                    // A link to a folder is listed, not followed: it may
                    // loop back.
                    _ => {}
                }
            }
        }
        // File names first, so quick open works while the notes are read.
        {
            let mut index = self.index.write().unwrap();
            for path in &files {
                index.add(path, None);
            }
        }
        self.emit(EVENT_INDEX, &self.root);

        let notes: Vec<&PathBuf> = files.iter().filter(|p| is_markdown(p)).collect();
        let workers = std::thread::available_parallelism().map_or(4, |n| n.get()).min(8);
        let chunk = notes.len().div_ceil(workers).max(1);
        std::thread::scope(|scope| {
            for part in notes.chunks(chunk) {
                scope.spawn(move || {
                    let mut read = Vec::with_capacity(256);
                    for path in part {
                        if self.closed.load(Ordering::Acquire) {
                            return;
                        }
                        if let Some(note) = read_note(path) {
                            read.push(((*path).clone(), note));
                        }
                        if read.len() == 256 {
                            let mut index = self.index.write().unwrap();
                            for (path, note) in read.drain(..) {
                                index.add(&path, Some(note));
                            }
                        }
                    }
                    let mut index = self.index.write().unwrap();
                    for (path, note) in read {
                        index.add(&path, Some(note));
                    }
                });
            }
        });
        self.emit(EVENT_INDEX, &self.root);
    }

    /// Takes in what the watcher saw at `paths`.
    fn refresh(self: &Arc<Self>, paths: BTreeSet<PathBuf>) {
        let mut folders = BTreeSet::new();
        let mut written = Vec::new();
        for path in paths {
            if is_ignored_path(&self.root, &path) {
                continue;
            }
            let known_file = self.index.read().unwrap().files.contains(&path);
            match std::fs::metadata(&path) {
                Ok(meta) if meta.is_file() => {
                    let note = if is_markdown(&path) { read_note(&path) } else { None };
                    self.index.write().unwrap().add(&path, note);
                    if known_file {
                        written.push(path.clone());
                    } else if let Some(parent) = path.parent() {
                        folders.insert(parent.to_path_buf());
                    }
                }
                Ok(meta) if meta.is_dir() => {
                    // A folder that appeared, perhaps moved in with files.
                    let mut found = Vec::new();
                    let mut stack = vec![path.clone()];
                    while let Some(dir) = stack.pop() {
                        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
                        for entry in entries.flatten() {
                            if entry.file_name().to_str().is_none_or(is_ignored) {
                                continue;
                            }
                            match entry.file_type() {
                                Ok(t) if t.is_dir() => stack.push(entry.path()),
                                Ok(t) if t.is_file() => found.push(entry.path()),
                                _ => {}
                            }
                        }
                    }
                    for file in found {
                        if !self.index.read().unwrap().files.contains(&file) {
                            let note = if is_markdown(&file) { read_note(&file) } else { None };
                            self.index.write().unwrap().add(&file, note);
                        }
                    }
                    folders.insert(path.clone());
                    if let Some(parent) = path.parent() {
                        folders.insert(parent.to_path_buf());
                    }
                }
                _ => {
                    // Gone: the file, or a folder and everything in it.
                    let mut index = self.index.write().unwrap();
                    let inside: Vec<PathBuf> =
                        index.files.range(path.clone()..).take_while(|p| p.starts_with(&path)).cloned().collect();
                    for file in inside {
                        index.remove(&file);
                    }
                    if let Some(parent) = path.parent() {
                        folders.insert(parent.to_path_buf());
                    }
                }
            }
        }
        for folder in &folders {
            self.emit(EVENT_FOLDER, folder);
        }
        for file in &written {
            self.emit(EVENT_FILE, file);
        }
        if !folders.is_empty() || !written.is_empty() {
            self.emit(EVENT_INDEX, &self.root);
        }
    }
}

impl Workspace {
    pub fn open(root: &str, ctx: *mut c_void, event: EventFn) -> Workspace {
        // The watcher reports real paths, so the index holds them too.
        let root = std::fs::canonicalize(root).unwrap_or_else(|_| PathBuf::from(root));
        let shared = Arc::new(Shared {
            root: root.clone(),
            index: RwLock::new(Index::default()),
            listed: Mutex::new(Vec::new()),
            ctx: Context(ctx),
            event,
            closed: AtomicBool::new(false),
            search: AtomicU64::new(0),
        });
        let scanner = shared.clone();
        std::thread::spawn(move || scanner.scan());

        let (tx, rx) = mpsc::channel::<PathBuf>();
        let watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
            if let Ok(event) = result {
                if matches!(event.kind, notify::EventKind::Access(_)) {
                    return;
                }
                for path in event.paths {
                    let _ = tx.send(path);
                }
            }
        })
        .and_then(|mut w| w.watch(&root, RecursiveMode::Recursive).map(|_| w))
        .ok();
        let refresher = shared.clone();
        std::thread::spawn(move || {
            // Gathers a burst of changes into one refresh.
            while let Ok(first) = rx.recv() {
                let mut paths = BTreeSet::from([first]);
                while let Ok(path) = rx.recv_timeout(Duration::from_millis(120)) {
                    paths.insert(path);
                    if paths.len() > 5000 {
                        break;
                    }
                }
                if refresher.closed.load(Ordering::Acquire) {
                    return;
                }
                refresher.refresh(paths);
            }
        });
        Workspace { shared, _watcher: watcher }
    }

    pub fn close(&self) {
        self.shared.closed.store(true, Ordering::Release);
        self.shared.search.fetch_add(1, Ordering::AcqRel);
    }

    pub fn root(&self) -> &Path {
        &self.shared.root
    }

    /// Lists the notes under `dir` for paging, newest first or by title, and
    /// returns how many there are.
    pub fn list_notes(&self, dir: &str, by_title: bool) -> u32 {
        let dir = std::fs::canonicalize(dir).unwrap_or_else(|_| PathBuf::from(dir));
        let index = self.shared.index.read().unwrap();
        let mut notes: Vec<(&PathBuf, &Note)> = index.notes.iter().filter(|(p, _)| p.starts_with(&dir)).collect();
        if by_title {
            notes.sort_by(|a, b| a.1.title.to_lowercase().cmp(&b.1.title.to_lowercase()).then(a.0.cmp(b.0)));
        } else {
            notes.sort_by(|a, b| b.1.modified.cmp(&a.1.modified).then(a.0.cmp(b.0)));
        }
        let listed: Vec<PathBuf> = notes.into_iter().map(|(p, _)| p.clone()).collect();
        let count = listed.len() as u32;
        *self.shared.listed.lock().unwrap() = listed;
        count
    }

    /// A page of the last list, as a JSON array.
    pub fn notes_page(&self, offset: u32, limit: u32) -> String {
        let listed = self.shared.listed.lock().unwrap();
        let index = self.shared.index.read().unwrap();
        let rows: Vec<Value> = listed
            .iter()
            .skip(offset as usize)
            .take(limit as usize)
            .map(|path| {
                let note = index.notes.get(path).cloned().unwrap_or_default();
                json!({
                    "path": path.to_string_lossy(),
                    "title": note.title,
                    "excerpt": note.excerpt,
                    "image": note.image,
                    "modified": note.modified,
                })
            })
            .collect();
        Value::Array(rows).to_string()
    }

    /// Files whose path matches `query` loosely, best first. With no query,
    /// the notes changed last.
    pub fn find_files(&self, query: &str, limit: u32, notes_only: bool) -> String {
        let index = self.shared.index.read().unwrap();
        let root = &self.shared.root;
        let row = |path: &Path, indices: &[u32]| {
            let rel = path.strip_prefix(root).unwrap_or(path).to_string_lossy().into_owned();
            let title = index.notes.get(path).map(|n| n.title.clone()).unwrap_or_default();
            json!({ "path": path.to_string_lossy(), "rel": rel, "title": title, "indices": indices })
        };
        if query.trim().is_empty() {
            let mut notes: Vec<(&PathBuf, &Note)> = index.notes.iter().collect();
            notes.sort_by(|a, b| b.1.modified.cmp(&a.1.modified).then(a.0.cmp(b.0)));
            return Value::Array(notes.iter().take(limit as usize).map(|(p, _)| row(p, &[])).collect()).to_string();
        }
        let mut matcher = Matcher::new(Config::DEFAULT.match_paths());
        let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
        let mut buf = Vec::new();
        let mut scored: Vec<(u32, &PathBuf)> = Vec::new();
        for path in &index.files {
            if notes_only && !index.notes.contains_key(path) {
                continue;
            }
            let rel = path.strip_prefix(root).unwrap_or(path).to_string_lossy();
            if let Some(score) = pattern.score(Utf32Str::new(&rel, &mut buf), &mut matcher) {
                // Notes before other files, at an equal match.
                let bonus = if index.notes.contains_key(path) { 8 } else { 0 };
                scored.push((score + bonus, path));
            }
        }
        scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.as_os_str().len().cmp(&b.1.as_os_str().len())).then(a.1.cmp(b.1)));
        let rows: Vec<Value> = scored
            .iter()
            .take(limit as usize)
            .map(|(_, path)| {
                let rel = path.strip_prefix(root).unwrap_or(path).to_string_lossy();
                let mut indices = Vec::new();
                pattern.indices(Utf32Str::new(&rel, &mut buf), &mut matcher, &mut indices);
                indices.sort_unstable();
                indices.dedup();
                // The app counts in UTF-16 units.
                let mut units = Vec::with_capacity(indices.len());
                let mut next = indices.iter().peekable();
                let mut unit = 0u32;
                for (i, ch) in rel.chars().enumerate() {
                    if next.peek() == Some(&&(i as u32)) {
                        units.push(unit);
                        next.next();
                    }
                    unit += ch.len_utf16() as u32;
                }
                row(path, &units)
            })
            .collect();
        Value::Array(rows).to_string()
    }

    /// Searches the text of every note on a background thread and reports
    /// through `done` on the main thread, unless a newer search started.
    pub fn search(&self, query: &str, token: u64, ctx: *mut c_void, done: SearchFn) {
        let shared = self.shared.clone();
        shared.search.store(token, Ordering::Release);
        let ctx = Context(ctx);
        let query = query.to_string();
        std::thread::spawn(move || {
            let ctx = ctx;
            let current = || shared.search.load(Ordering::Acquire) == token && !shared.closed.load(Ordering::Acquire);
            let mut paths: Vec<(PathBuf, String, u64)> = {
                let index = shared.index.read().unwrap();
                index.notes.iter().map(|(p, n)| (p.clone(), n.title.clone(), n.modified)).collect()
            };
            paths.sort_by(|a, b| b.2.cmp(&a.2).then(a.0.cmp(&b.0)));
            let sensitive = query.chars().any(|c| c.is_uppercase());
            let needle = if sensitive { query.clone() } else { query.to_lowercase() };
            let results = Mutex::new(Vec::new());
            if !needle.is_empty() {
                let workers = std::thread::available_parallelism().map_or(4, |n| n.get()).min(8);
                let chunk = paths.len().div_ceil(workers).max(1);
                std::thread::scope(|scope| {
                    for (part_index, part) in paths.chunks(chunk).enumerate() {
                        let (needle, results, current) = (&needle, &results, &current);
                        scope.spawn(move || {
                            let finder = memchr::memmem::Finder::new(needle.as_bytes());
                            for (i, (path, title, _)) in part.iter().enumerate() {
                                if !current() {
                                    return;
                                }
                                let Ok(bytes) = std::fs::read(path) else { continue };
                                let text = String::from_utf8_lossy(&bytes);
                                if let Some(hit) = search_file(&text, &finder, sensitive, path, title) {
                                    results.lock().unwrap().push((part_index * chunk + i, hit));
                                }
                            }
                        });
                    }
                });
            }
            if !current() {
                return;
            }
            let mut results = results.into_inner().unwrap();
            // Newest notes first, as the paths were ordered.
            results.sort_by_key(|(order, _)| *order);
            let total = results.len();
            let rows: Vec<Value> = results.into_iter().take(300).map(|(_, hit)| hit).collect();
            let json = CString::new(json!({ "files": rows, "total": total }).to_string()).unwrap_or_default();
            on_main(move || {
                let ctx = ctx;
                if shared.search.load(Ordering::Acquire) == token && !shared.closed.load(Ordering::Acquire) {
                    unsafe { done(ctx.0, token, json.as_ptr()) };
                }
            });
        });
    }

    /// The note or file a wikilink's target names, seen from the note at
    /// `from`. Empty when there is none.
    pub fn resolve_link(&self, target: &str, from: &str) -> String {
        let target = target.split(['|', '#']).next().unwrap_or("").trim();
        if target.is_empty() {
            return String::new();
        }
        let from_dir = Path::new(from).parent().unwrap_or(&self.shared.root).to_path_buf();
        for base in [&from_dir, &self.shared.root] {
            for candidate in [base.join(target), base.join(format!("{target}.md"))] {
                if candidate.is_file() {
                    return candidate.to_string_lossy().into_owned();
                }
            }
        }
        let index = self.shared.index.read().unwrap();
        let name = target.rsplit('/').next().unwrap_or(target).to_lowercase();
        let Some(paths) = index.names.get(&name) else { return String::new() };
        let suffix = target.to_lowercase();
        let mut best: Option<&PathBuf> = None;
        let mut best_rank = 0;
        for path in paths {
            let rel = path.strip_prefix(&self.shared.root).unwrap_or(path).with_extension("");
            let rel_lower = rel.to_string_lossy().to_lowercase();
            // A target with folders must match them.
            if target.contains('/') && !rel_lower.ends_with(&suffix) && !path.to_string_lossy().to_lowercase().ends_with(&suffix) {
                continue;
            }
            let rank = 1 + (is_markdown(path) as i32) * 2 + (path.parent() == Some(from_dir.as_path())) as i32 * 4;
            if rank > best_rank {
                best_rank = rank;
                best = Some(path);
            }
        }
        best.map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
    }

    /// The notes that link to the note at `path`, with the lines that do.
    pub fn backlinks(&self, path: &str) -> String {
        let path = Path::new(path);
        let keys = name_keys(path);
        let rel = path.strip_prefix(&self.shared.root).unwrap_or(path).with_extension("").to_string_lossy().to_lowercase();
        let sources: Vec<(PathBuf, String)> = {
            let index = self.shared.index.read().unwrap();
            let mut sources: Vec<(PathBuf, String)> = index
                .notes
                .iter()
                .filter(|(p, n)| p.as_path() != path && n.links.iter().any(|l| keys.contains(l) || *l == rel || rel.ends_with(&format!("/{l}"))))
                .map(|(p, n)| (p.clone(), n.title.clone()))
                .collect();
            sources.sort();
            sources
        };
        let mut rows = Vec::new();
        for (source, title) in sources.into_iter().take(200) {
            let Ok(bytes) = std::fs::read(&source) else { continue };
            let text = String::from_utf8_lossy(&bytes);
            let mut lines = Vec::new();
            let mut offset = 0u32;
            for (number, line) in text.split('\n').enumerate() {
                let mut targets = Vec::new();
                links_in(line, &mut targets);
                if targets.iter().any(|l| keys.contains(l) || *l == rel || rel.ends_with(&format!("/{l}"))) {
                    lines.push(json!({ "line": number + 1, "text": preview(line.trim(), 0).0, "offset": offset }));
                }
                offset += line.chars().map(|c| c.len_utf16() as u32).sum::<u32>() + 1;
                if lines.len() >= 5 {
                    break;
                }
            }
            rows.push(json!({ "path": source.to_string_lossy(), "title": title, "lines": lines }));
        }
        Value::Array(rows).to_string()
    }
}

/// At most 160 characters of `line` around byte `at`, and the UTF-16 offset
/// of `at` within them.
fn preview(line: &str, at: usize) -> (String, u32) {
    let mut start = at.saturating_sub(60);
    while !line.is_char_boundary(start) {
        start -= 1;
    }
    let lead: String = if start > 0 { "…".to_string() } else { String::new() };
    let body: String = line[start..].chars().take(160).collect();
    let before = line[start..at.max(start)].chars().map(|c| c.len_utf16() as u32).sum::<u32>();
    (format!("{lead}{body}"), before + lead.chars().count() as u32)
}

/// The matches of one note, or nothing when it has none.
fn search_file(text: &str, finder: &memchr::memmem::Finder, sensitive: bool, path: &Path, title: &str) -> Option<Value> {
    let lowered;
    let haystack = if sensitive {
        text
    } else {
        lowered = text.to_lowercase();
        // Lowercasing may change lengths; offsets only hold when it doesn't.
        if lowered.len() == text.len() { lowered.as_str() } else { text }
    };
    let mut matches = Vec::new();
    let mut count = 0;
    // Line starts and UTF-16 offsets are tracked as the matches advance.
    let (mut line_start, mut line_number, mut units, mut counted) = (0usize, 1usize, 0u32, 0usize);
    for at in finder.find_iter(haystack.as_bytes()) {
        count += 1;
        if matches.len() >= 5 || !text.is_char_boundary(at) {
            continue;
        }
        for (i, ch) in text[counted..at].char_indices() {
            if ch == '\n' {
                line_number += 1;
                line_start = counted + i + 1;
            }
            units += ch.len_utf16() as u32;
        }
        counted = at;
        let line_end = text[at..].find('\n').map_or(text.len(), |i| at + i);
        let line = &text[line_start..line_end];
        let lead = line.len() - line.trim_start().len();
        let (shown, column) = preview(line.trim_start(), (at - line_start).saturating_sub(lead));
        let needle_units = text.get(at..at + finder.needle().len()).map_or(0, |s| s.chars().map(|c| c.len_utf16() as u32).sum::<u32>());
        matches.push(json!({ "line": line_number, "text": shown, "column": column, "length": needle_units, "offset": units }));
    }
    (count > 0).then(|| json!({ "path": path.to_string_lossy(), "title": title, "count": count, "matches": matches }))
}
