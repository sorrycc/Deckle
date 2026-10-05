# Performance

Measured on the development machine with a release build.

| Scenario | Result |
|---|---|
| Typing in the middle of a 300 KB note | 1.4 ms median, 6 ms worst per keystroke, including layout and drawing |
| Typing inside a code block of 4,000 lines | 3 ms median, 8 ms worst per keystroke: only the line typed in is styled again |
| Window shown after launch | About 360 ms warm. Over a second on the first launch after a build, while macOS verifies the new binary |
| 50,000-note workspace | File list ready in 0.4 s, full index in 2.1 s, both on background threads |
| Window shown with a 20,000-note workspace, 6,000 of them in one folder | About 390 ms |

## Measuring

```sh
build/Deckle.app/Contents/MacOS/Deckle -timing YES      # launch and indexing times
build/Deckle.app/Contents/MacOS/Deckle -benchmark 300   # per-keystroke times for 300 characters
```

See [Launch arguments](usage.md#launch-arguments) for the other options, including `-scrollBenchmark`.
