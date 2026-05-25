# Pumice

A native iPadOS PDF annotation utility for local-first PKM users.

Pumice edits PDF files directly inside your vault — no sidecar files, no cloud
lock-in, no proprietary formats. Highlight and scribble with Apple Pencil; pan
with your finger; extract annotations to reconcilable Markdown that drops
straight into Obsidian, Logseq, or any other plain-text knowledge graph.

## Status

Version `0.1.0` — first functional release. Apple Pencil drawing with color and
width selection, real-time eraser, undo/redo via touch and Pencil press, debounced
autosave, and cross-app PDF compatibility (annotations render in Preview, Adobe,
and any standards-conformant viewer) all work on iPadOS hardware. Snap-to-text
highlights and Markdown extraction are scoped for the next release.

The product requirements document lives in the author's private Obsidian vault
and is intentionally not duplicated in this repo.

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
