# Performance

Measured on an Apple silicon Mac with `go test`.

| Scenario | Result |
|---|---|
| Typing in the middle of a 300 KB note | 0.74 ms median, 0.93 ms p95 per keystroke, including layout and drawing the frame (`TestTypingSpeed`) |
| Parsing a 777 KB note | 19 ms to open; 0.8 ms per edit (`TestLargeDocumentTiming`) |
| Workspace index | file names first, then the notes read on up to 8 goroutines |
| A frame of the whole window, with 4,000 notes and a note open | 0.33 ms median, drawn on the CPU (`TestWindowFrameTime`) |
| A frame with 3,000 notes in one folder, each a row of the tree | 0.13 ms median; the tree builds only the rows in view (`TestFlatFolderFrameTime`) |
| Idle | no frames once the caret stops blinking, 30 seconds after the last change |

## Measuring

```sh
go test -run 'TypingSpeed|LargeDocumentTiming|WindowFrameTime' -v ./...
DECKLE_SNAPSHOT=shot.png go run ./cmd/deckle ~/Notes   # a picture of the window once it settles
```
