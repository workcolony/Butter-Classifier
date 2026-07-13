# LUP → Butter Classifier Adaptation Plan

Adapted from [lup.tomandandy.com](https://lup.tomandandy.com/) and the `lofi-glitch` room (PROC, Library/crate finder, waveform modes, Tag Zones).

## Sidecar architecture

| File | Owner | Purpose |
|------|-------|---------|
| `sample.wav.yaml` | Analyzer (machine) | Full feature dump; re-analyze overwrites |
| `sample.wav_tags.yaml` | User/classifier | Tag list (`tags: [snare, top, …]`) |
| `sample.wav_edits.yaml` | User *(Phase 4)* | Loop points, manual onsets, BPM/key overrides |
| `~/Library/Application Support/ButterClassifier/tagzone-presets.json` | App | Global Tag Zone presets |

## Phase 1 — Tags + Tag Zones *(done)*

## Phase 2 — Library finder *(done)*

## Phase 3 — Waveform display modes *(done)*

## Phase 4 — Classification editor *(done)*

Draggable onsets, loop braces, scalar overrides in `*_edits.yaml`. Indexed in SwiftData for table/library display.

## Phase 5 — PROC shell (no AU) *(done)*

Routine picker, monospaced script editor, preset chains, preview → commit, recents.
Routines: gain, normalize, crop, lpf/hpf, reverse. Starter presets: Pulverize, Reverse Bloom, Mangle, Stutter Prep.

## Phase 6 — Full PROC catalog *(done)*

35 Swift routines across 11 groups including a Cecilia-inspired tier (degrade, phaser, freq shift, waveshape, param EQ, state variable, granulator, vocoder, harmonizer, spectral gate/delay/shift, resonators, particle).
20 bundled preset chains spanning LUP starters and Cecilia-style examples.
Still open: pygmu/CDP port, Monaco syntax highlighting.

## LUP PROC reference (Phase 6 target)

**Groups:** basics, filter, dynamics, space, modulate, time, spectral, distort, grain/walk, combine

**Preset chains:** Pulverize, Reverse Bloom, Ring Mod, Stutter, Spectral Smear, Mangle, Granular Dust, Glitch Walk, Ghost Layer, Telephone, Dub Echo

## Phase 7+ — Roadmap

See **[`ROADMAP.md`](ROADMAP.md)** for the full backlog (17 items as of 2026-07-13): zero-crossing snap, tag suggestions, Library LUP feel, PROC script editor, pygmu/CDP, tempo/key + FX coupling, spectrogram mode, stereo overlay waveform, Get Info inspector, MIDI keyboard integration, MuScriptor audio→MIDI transcription, and more.

MuScriptor reference: [`MUSCRIPTOR-REFERENCE.md`](MUSCRIPTOR-REFERENCE.md), [`MUSCRIPTOR-INTEGRATION-PLAN.md`](MUSCRIPTOR-INTEGRATION-PLAN.md).

## Deferred (larger bets)

- AU plugin chain
- Live collaborative rooms
- PUBS tab
