# Pumice

A native iPadOS PDF annotation utility for local-first PKM users.

Pumice edits PDF files directly inside your vault — no sidecar files, no cloud
lock-in, no proprietary formats. Highlight and scribble with Apple Pencil; pan
with your finger; extract annotations to reconcilable Markdown that drops
straight into Obsidian, Logseq, or any other plain-text knowledge graph.

## Status

Early development. The product requirements document lives in the author's
private Obsidian vault and is intentionally not duplicated in this repo.

## Requirements

- iPadOS 18.0 or later
- Apple Pencil (any generation) recommended
- Xcode 16+ (for development)

## Building

The Xcode project is generated from `project.yml` via
[xcodegen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open Pumice.xcodeproj
```

## License

MIT — see [`LICENSE`](LICENSE).
