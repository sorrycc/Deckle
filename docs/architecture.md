# Architecture

Deckle has two parts:

- **`core/`** is a Rust static library. It parses Markdown into style spans, highlights code, indexes and watches the workspace, and runs search.
- **`app/`** is a SwiftPM package containing the AppKit app. It links the core through the C interface in `app/Sources/CDeckleCore/deckle_core.h`.

## Editor

The text view is a TextKit 2 `NSTextView` over plain text.

The core keeps its own copy of the text and splits it into sections at points where a new top-level block must begin, such as headings. Each section is parsed with pulldown-cmark. An edit reparses only the sections it touches and reports the range whose styling changed.

Styling is applied when a paragraph is laid out, through the content storage's delegate. The text storage, undo history and saved file therefore stay plain Markdown. A custom layout fragment draws code block backgrounds, quote bars, callouts and widgets.

## Rendering

KaTeX and Mermaid live in `app/Resources/Bundled/Renderer/`. They load in an offscreen web view only when a note contains math or a diagram.

## Fonts

LXGW WenKai Lite, Regular and Medium, is bundled in `app/Resources/Bundled/Fonts/` under the SIL Open Font License. The app registers it through `ATSApplicationFontsPath`.

## Tests

`cargo test --release` runs the core's tests. One test checks every incremental edit against a fresh parse of the whole note. Another prints parse and edit times for a document of about 800 KB.
