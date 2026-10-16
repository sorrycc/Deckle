# Changelog

The update window and the GitHub release show the section of the version
they offer. Write notes under `## Unreleased`; `scripts/bump.sh` turns it
into `## <version>` for a release, and refuses to bump without notes.

## Unreleased

- Deckle is rewritten in Go on MyGo, which draws its window itself on the
  GPU. Typing in a long note takes about half the time it did, and Deckle
  now runs on macOS 13 or later, on Intel Macs too, and on Linux and
  Windows.
- The first launch takes the settings, workspaces, tabs and places of the
  version before it, and from then on Deckle updates itself with smaller
  updates that download only what changed.
- Settings are kept in a `settings.json` file rather than the user
  defaults.
- Spell checking, the Edit menu's Spelling, Substitutions and
  Transformations submenus, and beta updates are gone for now.
- A fresh look: the tree opens the folders of the note shown and marks
  it, the note list parts its notes with hairlines, an empty tab lists
  the shortcuts to begin with, the panels name their keys and quick open
  marks what matched, and the workspace switcher shows the workspace's
  name and folder.
- Settings has a toolbar, a theme picker of swatches and a preview of the
  editor's fonts, and buttons, check boxes and sliders take the theme's
  accent color.
- Search Notes lists a line once with every match in it marked, and its
  lines read without the tags of callouts and footnotes.
- A long note no longer runs under the line at the bottom of the window.
- Every item of a numbered list is a list item, not only the first.
- A heading further down a note no longer names it: a note without one
  before its text is named after its file.
- Clicking empty space in the tree, or Escape in the list, goes back to
  All Notes, and Deckle Help describes this version.

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
