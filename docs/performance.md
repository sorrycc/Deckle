# Performance

Measured on the development machine with a release build.

| Scenario | Result |
|---|---|
| Typing in the middle of a 300 KB note | 1.4 ms median, 6 ms worst per keystroke, including layout and drawing |
| Window shown after launch | About 360 ms warm. Over a second on the first launch after a build, while macOS verifies the new binary |
| 50,000-note workspace | File list ready in 0.4 s, full index in 2.1 s, both on background threads |

## Measuring

```sh
build/Deckle.app/Contents/MacOS/Deckle -timing YES      # launch and indexing times
build/Deckle.app/Contents/MacOS/Deckle -benchmark 300   # per-keystroke times for 300 characters
```

See [Launch arguments](usage.md#launch-arguments) for the other options, including `-scrollBenchmark`.
