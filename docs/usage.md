# Using Quill

## Workspaces

A workspace is a folder. Open one with File > Open Folder… (⌘O), by dropping a folder on the app, or from the switcher at the bottom of the sidebar. Quill reopens the last workspace and its tabs at launch. Hidden files and `node_modules` folders are left out.

Selecting a folder in the tree lists its notes, including those in folders under it, newest first or by title (the button at the top of the list). The workspace's own row, at the top of the tree, lists every note. Clicking empty space in the tree, ⌘-clicking the selected row or pressing Escape goes back to it. Titles sort as a person reads them, so "Note 2" comes before "Note 10". Each row shows the note's title, when it was last changed, the first two lines of its text and its first image. Selecting a note opens it in the current tab. ⌘-click or double-click opens it in a new tab.

Image files open in a tab of their own, fitted to the pane, and pinch or ⌘-scroll zooms them. Other text files open with their code highlighted.

Right-click in the tree to create notes and folders, rename, star, reveal in Finder or move to the Trash. Drag files onto a folder to move them; files dragged in from Finder are copied.

## Writing

| Syntax | Result |
|---|---|
| `# ` to `###### ` | Headings |
| `*text*`, `**text**`, `~~text~~`, `==text==` | Italic, bold, struck, highlighted |
| `` `code` `` and fenced code blocks with a language | Code, highlighted |
| `H~2~O`, `x^2^` | Subscript, superscript |
| `- `, `1. `, `- [ ] ` | Lists and tasks; click a box to tick it |
| `> `, `> [!TIP] Title` | Quotes and callouts (note, tip, important, warning, caution) |
| `[text](url)`, `[[Note]]`, `[[Note\|label]]` | Links and wikilinks |
| `[^1]` and `[^1]: text` | Footnotes |
| `![alt](path)` on its own line | An image, shown above its line |
| `$x$`, `$$ … $$`, ` ```math ` | Math, rendered with KaTeX |
| ` ```mermaid ` | A diagram, rendered with Mermaid |
| `---` at the top of the note | Front matter; a `title:` there names the note in lists |

Markdown's syntax shows only around the selection: `-` becomes a bullet, `[ ]` a box, and the fences of a code block show only while the insertion point is in it. Turn this off in Settings > Editor to see it everywhere.

- Return continues a list or quote; Return on an empty item ends it. Tab and Shift-Tab indent and outdent list items.
- `/` at the start of a line opens a menu of blocks to insert.
- `[[` completes the names of notes.
- ⌘-click follows a link, a wikilink or a footnote. Hovering over a link shows where it goes, and with ⌘ held the pointer becomes a hand. A wikilink to a missing note creates it beside the current note.
- Hovering over a code block shows a Copy button at its corner.
- A long note scrolls past its end, so its last lines can be read mid-screen. A click in that room puts the insertion point at the end.
- Pasting or dropping an image saves it in an `assets` folder beside the note and links it.

## Finding things

| Shortcut | Action |
|---|---|
| ⌘P | Quick open: any file by fuzzy name |
| ⇧⌘F | Search the text of every note |
| ⇧⌘P | Run any menu command by name |
| ⇧⌘O | Go to a heading of the note |
| ⇧⌘B | Show the notes that link to this one |
| ⌘F | Find and replace in the note |
| ⌘[ and ⌘] | Back and forward in the tab |
| ⌘1 to ⌘9, ⌃Tab | Switch tabs |

The ticks at the right edge of a note are its headings. Hover over them for an outline, then click a heading to jump to it. A note with more headings than fit shows its top levels.

The line under the editor shows how many notes link to this one (click it for the list), where the insertion point is, and how many words the note has. For a file that isn't a note it names the language, or an image's size.

## Saving

Edits are saved 0.6 seconds after you stop typing, when you switch tabs or apps, and when Quill quits. When another app changes an open note that has no unsaved edits, Quill takes in the change. If the note has unsaved edits, Quill's version is written over the other at the next save.

## Settings

Settings (⌘,) holds the theme, the editor font and size, whether syntax hides, spell checking, the line width and the line height. ⌘+ and ⌘- change the font size. Settings are stored in the `dev.sorrycc.quill` user defaults.

## Launch arguments

For trying the app from a script:

| Argument | Effect |
|---|---|
| `-workspace <folder>` | Opens this folder, without remembering it as the last workspace |
| `-open <file>` | Opens this file in a tab |
| `-select <loc,len>` | Selects this range of the open file, in UTF-16 units |
| `-scroll <fraction>` | Scrolls this far down the open file, from 0 to 1 |
| `-type <text>` | Types this text at the selection; `\n` is a line break |
| `-hover <index>` | Moves the pointer over this character; `-command YES` holds ⌘ |
| `-palette files\|search\|commands\|headings\|backlinks` | Opens a panel; `-query <text>` fills it in |
| `-settings YES` | Opens the Settings window, which a snapshot pictures as a panel |
| `-snapshot <png>` | Writes a picture of the window, and of any panel as `<name>-panel.png`, then quits |
| `-timing YES` | Prints how long launching and indexing took |
| `-benchmark <n>` | Types n characters into the open file, prints the time each took, and quits |
| `-theme <id>` | Uses a theme for this run: `system`, `paper`, `github-light`, `solarized-light`, `one-dark`, `nord`, `tokyo-night`, `rose-pine`, `dracula`, `gruvbox-dark` |
