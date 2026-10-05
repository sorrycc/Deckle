# Using Deckle

## Workspaces

A workspace is a folder. Open one with File > Open… (⌘O), from File > Open Recent, by dropping a folder on the app or the Welcome window, or from the switcher at the bottom of the sidebar. A file opened the same ways, or with Finder's Open With, opens in a new tab of the workspace window, even when it lives outside the workspace, and leaves the workspace as it is. With no workspace open, Deckle opens the last one, or else the file's own folder without adding it to the recent workspaces. Deckle reopens the last workspace, its tabs and where you were in each note at launch; when there is none, a Welcome window (⇧⌘1) offers a folder to open and the workspaces opened before, which a right-click or Delete takes off the list. Closing the workspace window brings the Welcome window back, and the Dock icon's menu lists recent workspaces. Hidden files and `node_modules` folders are left out.

Selecting a folder in the tree lists its notes, including those in folders under it, newest first or by title (the button at the top of the list). The workspace's own row, at the top of the tree, lists every note. Clicking empty space in the tree, ⌘-clicking the selected row or pressing Escape goes back to it. Titles sort as a person reads them, so "Note 2" comes before "Note 10". Each row shows the note's title, when it was last changed, the first two lines of its text and its first image. Selecting a note opens it in the current tab. ⌘-click or double-click opens it in a new tab.

Image files open in a tab of their own, fitted to the pane, and pinch or ⌘-scroll zooms them. Other text files open with their code highlighted.

Right-click in the tree to create notes and folders, rename, star, reveal in Finder or move to the Trash. Drag files onto a folder to move them; files dragged in from Finder are copied. Notes can be dragged out of the list too, onto a folder, into a note as a link, or to another app. ⌘⌫ moves the selected note to the Trash, and Edit > Undo brings it back.

The arrow keys move through the tree and the list without taking the keyboard away from them; Return hands it to the editor, and Go > Note List (⌥⌘L) and Go > Editor (⌥⌘E) move it either way. Tabs have a menu on right-click, with Close Other Tabs, Close Tabs to the Right, Reveal in Finder, Copy Path and Open in Default App, and ⇧⌘T brings back the tab closed last.

## Writing

| Syntax | Result |
|---|---|
| `# ` to `###### ` | Headings |
| `*text*`, `**text**`, `~~text~~`, `==text==` | Italic, bold, struck, highlighted |
| `` `code` `` and fenced code blocks with a language | Code, highlighted |
| `H~2~O`, `x^2^` | Subscript, superscript |
| `- `, `1. `, `- [ ] ` | Lists and tasks; click a box or press ⌘↩ to tick it |
| `> `, `> [!TIP] Title` | Quotes and callouts (note, tip, important, warning, caution) |
| `[text](url)`, `[[Note]]`, `[[Note\|label]]` | Links and wikilinks |
| `[^1]` and `[^1]: text` | Footnotes, shown as raised numbers |
| `![alt](path)` on its own line | An image, shown above its line |
| `$x$`, `$$ … $$`, ` ```math ` | Math, rendered with KaTeX |
| ` ```mermaid ` | A diagram, rendered with Mermaid in the theme's colors |
| `---` at the top of the note | Front matter; a `title:` there names the note in lists |

Markdown's syntax shows only around the selection: `-` becomes a bullet, `[ ]` a box, and the fences of a code block show only while the insertion point is in it. Turn this off in Settings > Editor to see it everywhere.

- Return continues a list or quote; Return on an empty item ends it. Tab and Shift-Tab, or ⌥⌘] and ⌥⌘[, indent and outdent list items.
- The Format menu toggles bold, italic, strikethrough, highlights, code, links, headings, bulleted, numbered and task lists, quotes and code blocks, and shows what the insertion point is in.
- ⌘↩ (Format > Toggle Done) steps a list item to an open task, a done one and back. Over several lines it ticks every task, or clears them all when all are done.
- Escape puts the find bar away or collapses the selection.
- `/` at the start of a line opens a menu of blocks to insert.
- `[[` completes the names of notes.
- ⌘-click follows a link, a wikilink or a footnote. Hovering over a link shows where it goes, and with ⌘ held the pointer becomes a hand and the link underlines. A wikilink to a missing note creates it beside the current note.
- Edit > Paste and Match Style pastes plain text, and the Edit menu's Spelling, Substitutions, Transformations and Speech submenus are the system's own.
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

Help > Deckle Help opens this guide in a tab, and the Help menu's search field finds any command.

## Printing

File > Print… (⌥⌘P) prints the note as it is drawn, with its images, tables, math and diagrams, and File > Export as PDF… writes the same pages to a file.

## Saving

Edits are saved 0.6 seconds after you stop typing, when you switch tabs or apps, and when Deckle quits. When another app changes an open note that has no unsaved edits, Deckle takes in the change. If the note has unsaved edits, Deckle's version is written over the other at the next save.

A file that isn't UTF-8 is saved in the encoding it was read in, so an old note keeps its bytes apart from what you change. If a note can't be saved, because its file is locked or its disk is gone, Deckle says so once and keeps trying; closing the note, the window or the app then asks whether to save a copy elsewhere or discard the edits.

Each note has its own undo history. With nothing left to undo in the note, ⌘Z undoes the last change to files, such as a move to the Trash.

## Settings

Settings (⌘,) holds the theme, the editor font and size, whether syntax hides, spell checking, the line width and the line height. ⌘+ and ⌘- change the font size. A theme colors the whole window, the panels, the diagrams and the selection, not only the page. Settings are stored in the `dev.sorrycc.deckle` user defaults.

## Launch arguments

For trying the app from a script:

| Argument | Effect |
|---|---|
| `-workspace <folder>` | Opens this folder, without remembering it as the last workspace |
| `-open <file>` | Opens this file in a tab |
| `-select <loc,len>` | Selects this range of the open file, in UTF-16 units |
| `-scroll <fraction>` | Scrolls this far down the open file, from 0 to 1 |
| `-type <text>` | Types this text at the selection; `\n` is a line break |
| `-run <command>` | Runs the menu command with this title, such as `Find…` or `Toggle Done`, after the typing |
| `-hover <index>` | Moves the pointer over this character; `-command YES` holds ⌘ |
| `-palette files\|search\|commands\|headings\|backlinks` | Opens a panel; `-query <text>` fills it in |
| `-welcome YES` | Opens the Welcome window, pictured as a panel |
| `-settings YES` | Opens the Settings window, which a snapshot pictures as a panel; `-settingsTab 1` picks a tab |
| `-exportPDF <path>` | Writes the open note as a PDF there |
| `-snapshot <png>` | Writes a picture of the window, and of any panel as `<name>-panel.png`, then quits |
| `-timing YES` | Prints how long launching and indexing took |
| `-benchmark <n>` | Types n characters into the open file, prints the time each took, and quits |
| `-scrollBenchmark <n>` | Pages n times down the open file, prints the time each page took to draw, and quits |
| `-theme <id>` | Uses a theme for this run: `system`, `paper`, `github-light`, `solarized-light`, `one-dark`, `nord`, `tokyo-night`, `rose-pine`, `dracula`, `gruvbox-dark` |
