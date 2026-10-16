# Performance

Measured on an Apple silicon Mac with `go test`.

| Scenario | Result |
|---|---|
| Typing in the middle of a 300 KB note | 0.74 ms median, 0.93 ms p95 per keystroke, including layout and drawing the frame (`TestTypingSpeed`) |
| Parsing a 777 KB note | 19 ms to open; 0.8 ms per edit (`TestLargeDocumentTiming`) |
| Workspace index | file names first, then the notes read on up to 8 goroutines |

## Measuring

```sh
go test -run 'TypingSpeed|LargeDocumentTiming' -v ./internal/...
DECKLE_SNAPSHOT=shot.png go run ./cmd/deckle ~/Notes   # a picture of the window once it settles
```
