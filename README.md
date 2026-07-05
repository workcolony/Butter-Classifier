# Butter Classifier

A native macOS app for managing, analyzing, and editing audio loops and samples. The analysis engine is the original `audio_analyzer.py` (in `A.Milburn Original Script/`), which extracts tempo, onsets, swing, loudness, spectral features, and more, writing a `.yaml` sidecar next to each audio file.

The built app is fully self-contained: a relocatable Python runtime (with librosa, essentia, scipy, etc.) is bundled inside `ButterClassifier.app`, so end users just launch the app — no Python, Homebrew, or setup required.

## Features

- **Library**: point the app at your sample folders (managed in place, nothing is copied or moved). Browse everything in a sortable, searchable table: duration, BPM, LUFS, kickiness, swing.
- **Analysis**: run the analyzer on a file, folder, or the whole library, with live progress and a full output log. Files that already have a `.yaml` are skipped; re-analyze deletes the stale sidecar first. Optional BPM override.
- **Player**: waveform with analyzed onset markers, click-to-seek, loop playback.
- **Editing** (non-destructive — always writes new files):
  - Trim: drag a selection on the waveform, export it (with anti-click fades).
  - Slice at onsets: cut the file into per-onset WAVs in a `<name>_slices` folder.
  - Normalize: peak-normalize to a target dBFS.

## Building

Requirements (build machine only): Xcode, network access for the first build.

```bash
# 1. Build the self-contained Python runtime into Runtime/ (one-time, ~5 min)
./python/build_runtime.sh

# 2. Build ButterClassifier.app into build/
./scripts/make_app.sh
```

During development you can run the app directly with `swift run` from the repo root; it finds `Runtime/` and `python/analyzer/` relative to the repo automatically (or set `BUTTER_ANALYZER_DIR`).

## Layout

- `A.Milburn Original Script/audio_analyzer.py` — the original, untouched analysis engine
- `python/analyzer/audio_analyzer.py` — the bundled copy (one-line fix: essentia's `BeatsLoudness` in the current PyPI wheel rejects `np.float32` lists, so onsets are cast to plain floats)
- `python/build_runtime.sh` — assembles the relocatable CPython 3.12 runtime + dependencies in `Runtime/` and rewrites any Homebrew dylib references so nothing external is needed
- `Sources/ButterClassifier/` — SwiftUI app (library index via SwiftData, analyzer runner, waveform player, editors)
- `scripts/make_app.sh` — release build + .app assembly + ad-hoc signing
