<p align="center">
  <img src="app/Resources/Deckle-1024.png" width="128" height="128" alt="Deckle icon">
</p>

<h1 align="center">Deckle</h1>

<p align="center">A fast, native Markdown editor for macOS.</p>

<p align="center"><img src="docs/screenshot.png" width="900" alt="Deckle with a workspace open: the file tree, the note list and a note with a table, tasks and a callout"></p>

Deckle pairs an AppKit interface with a Rust core. Notes are plain `.md` files in a folder you choose.

> **Status:** early development. Deckle requires macOS 26 and is built from source.

## Features

- **Live styling.** Markdown is styled as you type, with syntax shown only around the selection.
- **Rich blocks.** Images, tables, KaTeX math and Mermaid diagrams render inline.
- **Extended syntax.** Wikilinks, footnotes, tasks, callouts, highlights, front matter and code highlighting in about 20 languages.
- **Workspaces.** A file tree, a note list with previews, and tabs with history.
- **Search and commands.** Quick open (⌘P), full-text search (⇧⌘F) and a command palette (⇧⌘P).
- **Backlinks.** Follow links with ⌘-click and see which notes link to the current one.
- **Typing helpers.** List continuation, a `/` block menu, note-name completion and image paste.
- **Themes.** Nine light and dark palettes with configurable fonts and line width.
- **Print and PDF export.** Output matches the editor, including math and diagrams.
- **Chinese and Japanese.** Per-line glyph forms and separate font choices for CJK text.

See the [user guide](docs/usage.md) for details.

## Requirements

- macOS 26 with the Swift toolchain (Xcode Command Line Tools)
- Rust, installed through [rustup](https://rustup.rs)

## Build and run

```sh
scripts/bundle.sh                    # release build; pass `debug` for a debug build
open build/Deckle.app
open -a build/Deckle.app ~/Notes     # open a folder as the workspace
open -a build/Deckle.app note.md     # open a file in a tab
```

The script builds the Rust core and the Swift app, then assembles an ad-hoc signed `build/Deckle.app`. Set `DECKLE_OUT` and `DECKLE_BUNDLE_ID` to build a separate copy with its own settings.

Run the core's tests with `cargo test --release`.

## Project layout

| Path | Description |
|---|---|
| `core/` | Rust library: Markdown parsing, code highlighting, workspace indexing and search |
| `app/` | SwiftPM package for the AppKit app |
| `app/Sources/CDeckleCore/deckle_core.h` | C interface between the core and the app |
| `app/Resources/Bundled/` | Bundled KaTeX, Mermaid and fonts |
| `scripts/bundle.sh` | Build and packaging script |

## Documentation

- [User guide](docs/usage.md)
- [Architecture](docs/architecture.md)
- [Performance](docs/performance.md)

## License

Deckle is released under the [MIT License](LICENSE).

Deckle bundles the following third-party software:

| Component | Version | License |
|---|---|---|
| [KaTeX](https://katex.org) | 0.16.22 | [MIT](app/Resources/Bundled/Renderer/LICENSE-KaTeX.txt), © Khan Academy and other contributors |
| [Mermaid](https://mermaid.js.org) | 11.12.0 | [MIT](app/Resources/Bundled/Renderer/LICENSE-Mermaid.txt), © Knut Sveidqvist |
| [LXGW WenKai Lite](https://github.com/lxgw/LxgwWenKai-Lite) | | [SIL Open Font License 1.1](app/Resources/Bundled/Fonts/OFL.txt), © LXGW and The Klee Project Authors |
