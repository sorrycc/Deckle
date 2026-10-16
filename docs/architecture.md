# Architecture

Deckle is one Go program, drawn by [MyGo](https://github.com/egoist/mygo)'s native UI on the GPU: Metal on
macOS, Direct3D 11 on Windows and OpenGL on Linux. It has no webview, but for math, diagrams and printing.

## Markdown

`internal/markdown` turns a note into style spans: a piece of a line, its kind (a heading, a marker, a link, a
token of code…), and the element it belongs to. A marker shows while the selection touches its element.

The text is split into sections at points where a new top-level block must begin, such as headings. Each
section is parsed on its own, by a CommonMark block parser and a delimiter-stack inline parser written for this,
which keep where every element is in the source. An edit reparses only the sections it touches, and reports the
range whose styling changed: typing in a block of thousands of lines restyles the line typed in. A small
lexer highlights code in about 20 languages.

## Editor

`internal/editor` is the editor, on MyGo's text input client: it owns its text, selection, undo and an input
method's composition, which stays in the text, marked, until it is committed, as in NSTextView.

Each line of the note is laid out on its own, from its spans, as text layouts of the system's text engine
(Core Text, DirectWrite, Pango): a list item's marker and box apart from its text, whose wrapped rows line up
with it, and each row of a wrapped line on its own, so rows stand a line height apart. Syntax away from the
selection is kept in the text at a size too small to see. Only the lines in view are laid out; the heights of
the others are estimated, and summed in Fenwick trees, so a note of 100,000 lines scrolls as one of 100.

Images, tables, math and diagrams are widgets drawn above their line, whose source then folds to nothing.

## Rendering

KaTeX and Mermaid run in a web view of the window, made when a note first has math or a diagram, kept under
the native UI and out of sight, and let go after a while unused. Each result is captured as a picture. Printing
and PDF export render the note as HTML, through goldmark, in a web view of their own.

## Workspaces

`internal/workspace` reads a folder of notes on a few goroutines: names first, so quick open works at once, then
each note's title, excerpt, first image and links. MyGo's file watch (FSEvents on macOS) keeps the index current.
Full-text search reads the notes in parallel, newest first, and drops a search a newer one replaced.

## Settings

The settings and the windows' state are one JSON file in the app's data folder. The first launch after Deckle
0.1 reads that version's user defaults: its theme, fonts, workspaces, and the tabs and places of each.

## Tests

`go test ./...` runs the tests, the UI's headless. One test checks every incremental edit against a fresh parse of
the whole note. `TestTypingSpeed` prints how long typing in a note of 300 KB takes, frame included.
