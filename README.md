<p align="center">
  <img src="app/Resources/Quill-1024.png" width="128" height="128" alt="Quill icon">
</p>

# Quill

A fast Markdown editor for macOS, with a native AppKit interface and a Rust core. Notes stay plain `.md` files in a folder of your choosing.

## Features

- **Live-styled Markdown.** Headings, emphasis, links, code and quotes are styled as you type. The syntax around them is hidden except where the selection is.
- **Rich blocks in place.** Images, tables, math (KaTeX) and Mermaid diagrams are drawn in place of their source and turn back into source when the insertion point enters them.
- **Extended syntax.** Wikilinks, footnotes, tasks, callouts, superscript and subscript, `==highlights==`, front matter and highlighted code in about 20 languages.
- **Workspaces.** Any folder is a workspace: a file tree with starred files, a note list with excerpts and thumbnails, and tabs with back and forward.
- **Quick open, search and commands.** ⌘P opens any file, ⇧⌘F searches the text of every note, and ⇧⌘P runs any menu command.
- **Links both ways.** ⌘-click a link to follow it. A `[[link]]` to a note that doesn't exist creates it, and each note lists the notes that link to it.
- **Typing helpers.** Lists and quotes continue on Return, `/` at the start of a line inserts a block, and `[[` completes note names. Pasted or dropped images are saved next to the note.
- **Themes.** System, plus nine palettes in light and dark, with the font, size, line height and line width of your choice.

## Requirements

- macOS 26 with the Swift toolchain (Xcode Command Line Tools)
- Rust, installed through [rustup](https://rustup.rs)

## Build and run

```sh
scripts/bundle.sh                    # release build; pass `debug` for a debug build
open build/Quill.app
open -a build/Quill.app ~/Notes      # open a folder as the workspace
```

The script builds the Rust core and the Swift app, then assembles an ad-hoc signed `build/Quill.app`. `QUILL_OUT` and `QUILL_BUNDLE_ID` build a second copy with settings of its own.

`cargo test --release` runs the core's tests. One checks every edit against a fresh parse of the whole note, and one prints parse and edit times for a document of about 800 KB.

## Performance

Measured on the development machine with a release build:

| | |
|---|---|
| Typing in the middle of a 1 MB note | 5 ms median, 10 ms worst per keystroke, including layout and drawing |
| Window shown after launch | about 310 ms warm; over a second on the first launch after a build, while macOS checks the new binary |
| 50,000-note workspace | file list ready in 0.4 s, full index in 2.1 s, both on background threads |

`build/Quill.app/Contents/MacOS/Quill -timing YES` prints launch and indexing times. `-benchmark 300` types 300 characters into the open note and prints the time each took. See [Usage](docs/usage.md) for the other launch arguments.

## Project layout

| Path | Description |
|---|---|
| `core/` | Rust static library: parses Markdown into style spans, highlights code, indexes and watches the workspace, and runs search. |
| `app/` | SwiftPM package with the AppKit app. No Xcode project is required. |
| `app/Sources/CQuillCore/quill_core.h` | The C interface between the two. |
| `app/Resources/Bundled/Renderer/` | KaTeX and Mermaid, loaded in an offscreen web view only when a note has math or a diagram. |
| `scripts/bundle.sh` | Builds everything and assembles `build/Quill.app`. |

## How the editor works

The text view is a TextKit 2 `NSTextView` over plain text. The core keeps a copy of the text and splits it into sections at points where a new top-level block must begin, such as headings, and parses each section with pulldown-cmark. An edit reparses only the sections it touches and reports the range whose styling changed. Styling is applied when a paragraph is laid out, through the content storage's delegate, so the text storage, undo and the saved file stay plain Markdown. A custom layout fragment draws code block backgrounds, quote bars, callouts and widgets.

## License

[MIT](LICENSE)
