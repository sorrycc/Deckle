# Changelog

The update window and the GitHub release show the section of the version
they offer. Write notes under `## Unreleased`; `scripts/bump.sh` turns it
into `## <version>` for a release, and refuses to bump without notes. A
beta shows what `## Unreleased` holds at the time.

## Unreleased

## 0.1.1

- Each workspace opens in a window of its own, so several folders can be
  open at once in one app. File > New Window (⇧⌘N) picks another, the
  sidebar's switcher still replaces the window's workspace, and every
  window open at quit comes back at launch.

## 0.1.0

The first release of Deckle, a native Markdown editor for macOS 15 or later
on Apple silicon.

- Markdown is styled as you type, with the syntax shown only around the
  selection. Images, tables, KaTeX math and Mermaid diagrams render inline.
- Wikilinks, footnotes, tasks, callouts, highlights, front matter and code
  highlighting in about 20 languages.
- A workspace is a folder of `.md` files, with a file tree, a note list with
  previews, and tabs with history.
- Quick open (⌘P), full-text search (⇧⌘F), a command palette (⇧⌘P) and
  backlinks.
- Nine light and dark themes, print and PDF export that match the editor,
  and separate fonts and glyph forms for Chinese and Japanese.
- Installed copies update themselves. Settings → Updates → Include beta
  versions also offers betas.
