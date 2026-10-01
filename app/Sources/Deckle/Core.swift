import CDeckleCore
import Foundation

/// A string the core returned, which it has to free.
private func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    defer { deckle_string_free(pointer) }
    return String(cString: pointer)
}

private func decode<T: Decodable>(_ type: T.Type, from json: String, fallback: T) -> T {
    (try? JSONDecoder().decode(type, from: Data(json.utf8))) ?? fallback
}

enum Language {
    /// "markdown", a language the code highlighter knows, or "" for plain text.
    static func name(for url: URL) -> String {
        String(cString: deckle_language_for_extension(url.pathExtension))
    }
}

/// The core's mirror of an open document, which parses it into style spans.
@MainActor
final class CoreDocument {
    // Only read after init, and freed in deinit, which may run off the main actor.
    private nonisolated(unsafe) let handle: OpaquePointer

    init(text: String, language: String) {
        let units = Array(text.utf16)
        handle = units.withUnsafeBufferPointer { deckle_doc_open($0.baseAddress, UInt32($0.count), language) }
    }

    deinit { deckle_doc_close(handle) }

    /// Mirrors an edit: `oldLength` units at `start` became `text`. Returns the
    /// range whose styling may have changed.
    func edit(at start: Int, oldLength: Int, text: String) -> NSRange {
        let units = Array(text.utf16)
        let range = units.withUnsafeBufferPointer {
            deckle_doc_edit(handle, UInt32(start), UInt32(oldLength), $0.baseAddress, UInt32($0.count))
        }
        return NSRange(location: Int(range.start), length: Int(range.end) - Int(range.start))
    }

    /// The 1-based line of a UTF-16 offset.
    func line(of offset: Int) -> Int { Int(deckle_doc_line_of(handle, UInt32(max(0, offset)))) }

    var wordCount: Int { Int(deckle_doc_count_words(handle)) }

    /// The spans that start in `range`, which should cover whole lines.
    func spans(in range: NSRange) -> [DeckleSpan] {
        var count: UInt32 = 0
        guard let spans = deckle_doc_spans(handle, UInt32(range.location), UInt32(range.upperBound), &count) else { return [] }
        return Array(UnsafeBufferPointer(start: spans, count: Int(count)))
    }

    /// One span for every element of `kind`, in order.
    func spans(ofKind kind: Int) -> [DeckleSpan] {
        var count: UInt32 = 0
        guard let spans = deckle_doc_spans_of_kind(handle, UInt8(kind), &count) else { return [] }
        return Array(UnsafeBufferPointer(start: spans, count: Int(count)))
    }
}

extension DeckleSpan {
    var range: NSRange { NSRange(location: Int(start), length: Int(end) - Int(start)) }
    var element: NSRange { NSRange(location: Int(elem_start), length: Int(elem_end) - Int(elem_start)) }
    var kindValue: Int { Int(kind) }
}

struct NoteSummary: Decodable {
    let path: String
    let title: String
    let excerpt: String
    let image: String
    let modified: TimeInterval
}

struct FileMatch: Decodable {
    let path: String
    let rel: String
    let title: String
    /// The UTF-16 offsets in `rel` that matched the query.
    let indices: [Int]
}

struct SearchResults: Decodable {
    struct File: Decodable {
        let path: String
        let title: String
        let count: Int
        let matches: [Match]
    }

    struct Match: Decodable {
        let line: Int
        let text: String
        let column: Int
        let length: Int
        let offset: Int
    }

    let files: [File]
    let total: Int
}

struct Backlink: Decodable {
    struct Line: Decodable {
        let line: Int
        let text: String
        let offset: Int
    }

    let path: String
    let title: String
    let lines: [Line]
}

/// A folder of notes, indexed and watched by the core.
@MainActor
final class Workspace {
    /// The folder by its real path, as the index names files.
    private(set) var url: URL
    /// The index changed: lists of notes are stale.
    var onIndexChange: (() -> Void)?
    /// The contents of a folder changed.
    var onFolderChange: ((URL) -> Void)?
    /// A file was written, by Deckle or by something else.
    var onFileChange: ((URL) -> Void)?

    private var handle: OpaquePointer?
    private var searchToken: UInt64 = 0
    private var searchDone: ((SearchResults) -> Void)?

    init(url: URL) {
        self.url = url
        let context = Unmanaged.passUnretained(self).toOpaque()
        handle = deckle_ws_open(url.path, context) { context, kind, path in
            guard let context, let path else { return }
            let url = URL(fileURLWithPath: String(cString: path))
            MainActor.assumeIsolated {
                let workspace = Unmanaged<Workspace>.fromOpaque(context).takeUnretainedValue()
                switch kind {
                case Int32(DeckleEventFolder): workspace.onFolderChange?(url)
                case Int32(DeckleEventFile): workspace.onFileChange?(url)
                default: workspace.onIndexChange?()
                }
            }
        }
        self.url = URL(fileURLWithPath: take(deckle_ws_root(handle)), isDirectory: true)
    }

    /// Stops the callbacks. The workspace answers nothing afterwards.
    func close() {
        deckle_ws_close(handle)
        handle = nil
    }

    var name: String { url.lastPathComponent }

    /// Lists the notes under `folder` and returns how many there are.
    func listNotes(in folder: URL, byTitle: Bool) -> Int {
        guard let handle else { return 0 }
        return Int(deckle_ws_list_notes(handle, folder.path, byTitle))
    }

    func notes(from offset: Int, count: Int) -> [NoteSummary] {
        guard let handle else { return [] }
        return decode([NoteSummary].self, from: take(deckle_ws_notes_page(handle, UInt32(offset), UInt32(count))), fallback: [])
    }

    func findFiles(_ query: String, limit: Int = 60, notesOnly: Bool = false) -> [FileMatch] {
        guard let handle else { return [] }
        return decode([FileMatch].self, from: take(deckle_ws_find_files(handle, query, UInt32(limit), notesOnly)), fallback: [])
    }

    /// Searches the text of every note. Only the newest search reports.
    func search(_ query: String, done: @escaping (SearchResults) -> Void) {
        guard let handle else { return }
        searchToken += 1
        searchDone = done
        let context = Unmanaged.passUnretained(self).toOpaque()
        deckle_ws_search(handle, query, searchToken, context) { context, token, json in
            guard let context, let json else { return }
            let text = String(cString: json)
            MainActor.assumeIsolated {
                let workspace = Unmanaged<Workspace>.fromOpaque(context).takeUnretainedValue()
                guard token == workspace.searchToken else { return }
                workspace.searchDone?(decode(SearchResults.self, from: text, fallback: SearchResults(files: [], total: 0)))
            }
        }
    }

    /// The file a wikilink's target names, seen from the note at `source`.
    func resolveLink(_ target: String, from source: URL) -> URL? {
        guard let handle else { return nil }
        let path = take(deckle_ws_resolve_link(handle, target, source.path))
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    func backlinks(to note: URL) -> [Backlink] {
        guard let handle else { return [] }
        return decode([Backlink].self, from: take(deckle_ws_backlinks(handle, note.path)), fallback: [])
    }
}
