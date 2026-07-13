# MuScriptor integration plan

How audio → MIDI transcription could land in Butter Classifier, reusing validated work from the local MuScriptor spike.

Last updated: 2026-07-13

**Reference:** [`MUSCRIPTOR-REFERENCE.md`](MUSCRIPTOR-REFERENCE.md)  
**Validated patches:** [`../midi classifier/docs/LOCAL-PATCHES.md`](../midi%20classifier/docs/LOCAL-PATCHES.md) on branch `local/butter-reference`

---

## Fit with Butter architecture

Butter already uses:

- **Python workers** for heavy audio work (`AnalyzerRunner` → `audio_analyzer.py`)
- **Sidecar files** next to samples (`sample.wav.yaml`, `sample.wav_tags.yaml`, `sample.wav_edits.yaml`)
- **SwiftData** index for fast library queries

Transcription should follow the same pattern — not merge the MuScriptor repo into Butter.

```
sample.wav
  ├── sample.wav.yaml          # existing analysis (machine)
  ├── sample.wav_tags.yaml     # user tags
  ├── sample.wav_edits.yaml    # user edits
  └── sample.wav.mid           # NEW: transcription output (machine)
      and/or sample.wav_notes.yaml   # optional: structured note events for UI
```

---

## What to port from the local spike

| From midi classifier | Port? | Notes |
|---------------------|-------|-------|
| `muscriptor/events.py` decoder fixes | **Yes** | Required for correct note output |
| `tests/test_events.py` new cases | **Yes** | Regression guard in CI |
| `transcription_model.py` / model load | **Via package** | Depend on `muscriptor` PyPI package + patches until upstream merges |
| `web/src/audio.ts` playback | **No** | Reference only; Butter uses `AudioPlayer` |
| `ConditioningPanel` / `INSTRUMENT_IDS` | **Ideas** | Instrument names may inform tag suggestions (#2) |
| Full React piano-roll UI | **Later** | Native SwiftUI canvas is a separate bet |

---

## Phased rollout

### Phase A — Sidecar MIDI (batch, offline)

**Goal:** Transcribe a sample to `.mid` alongside existing analysis.

**Approach:**
1. Add `transcribe_worker.py` (or extend analyzer) that calls `muscriptor` Python API.
2. Vendor patched `events.py` or pin local fork until upstream PR lands.
3. CLI/subprocess from Swift: enqueue like analyze jobs.
4. Write `sample.wav.mid` next to source file.
5. Index in SwiftData: `hasMidiTranscription`, `midiModifiedAt`.

**User flow:** Context menu or detail action — "Transcribe to MIDI" (explicit, slow, GPU/CPU heavy).

**Effort:** ~3–5 days (worker, bundling, HF token UX, error handling).

### Phase B — Persistent transcription worker

**Goal:** Same ergonomics as `AnalyzerRunner` — warm Python process, queue of files.

**Approach:**
1. `TranscriptionRunner` mirroring `AnalyzerRunner` pool pattern.
2. Bundle `muscriptor` + torch in app resources (or optional download pack — weights are large).
3. Progress in status bar; cancel support.
4. Reuse HF token from env or app settings.

**Depends on:** Phase A subprocess path proven.

**Effort:** ~2–3 days on top of A.

### Phase C — Structured note sidecar + UI

**Goal:** Store events for in-app piano roll / note inspection without round-tripping MIDI.

**Approach:**
1. Stream `NoteStartEvent` / `NoteEndEvent` to `sample.wav_notes.yaml` (or JSONL).
2. Swift model `TranscriptionResult` with notes[], instruments[], duration.
3. Detail pane tab or overlay: read-only piano roll (Canvas/SwiftUI).
4. Optional: export MIDI from stored events.

**Reference:** SSE event shape from `muscriptor/server.py` and local web `web/src/pianoroll.ts`.

**Effort:** ~1–2 weeks (UI is the main cost).

### Phase D — Instrument conditioning ↔ tags

**Goal:** Use Butter's tag vocabulary to condition transcription.

**Approach:**
1. Map tag tokens (e.g. `piano`, `808`, `guitar`) → `MT3_FULL_PLUS_GROUP_NAMES` via rules table.
2. Pass `instruments=[...]` to `transcribe()` when user tags are confident enough.
3. Feed transcription instrument output back into tag suggestions (Layer 2 in ROADMAP #2).

**Reference:** `web/src/instruments.ts` (`ALIASES`, `INSTRUMENT_IDS`).

**Effort:** ~3–5 days once Phase A/B exist.

---

## Technical options for Python integration

| Option | Pros | Cons |
|--------|------|------|
| **A. PyPI `muscriptor` + vendored `events.py` patch** | Matches upstream releases | Patch drift on version bumps |
| **B. Git submodule / path dep on local fork** | Full control, includes all fixes | Heavier packaging |
| **C. HTTP to bundled `muscriptor serve`** | Clean IPC, reuse server | Extra process, port management |
| **D. `uvx muscriptor transcribe` subprocess** | Fastest spike | Cold start every file; no warm pool |

**Recommendation:** Spike with **D**, productize with **A + vendored patch** or **B**, long-term move to **A** when upstream merges decoder fixes.

---

## macOS / packaging considerations

- **Model weights:** CC BY-NC, gated on HuggingFace — user must accept license; ~100MB–1GB per variant.
- **PyTorch:** Large; `small` + CPU is realistic for app bundle; `medium`/`large` may be optional download.
- **Intel Macs:** MuScriptor requires Python ≤3.12 for torch wheels on x86_64 (see upstream README).
- **Non-commercial weights:** Align with Butter's distribution model; document in app.

---

## Swift touchpoints (future)

| File | Change |
|------|--------|
| New `TranscriptionRunner.swift` | Worker pool, queue, progress (mirror `AnalyzerRunner`) |
| `Models.swift` / SwiftData | `hasMidiTranscription`, paths, timestamps |
| `DetailPane.swift` | "Transcribe" action, open MIDI in Finder, future piano roll |
| `LibraryScanner.swift` | Discover `*.mid` sidecars, refresh index |
| `tag-token-rules.json` | Optional mapping to MuScriptor instrument ids |

---

## Suggested order relative to ROADMAP

1. Finish near-term ROADMAP items (#12, #8–11) — stable playback/FX baseline.
2. **Phase A** transcription sidecar (this doc) — independent of MIDI keyboard (#14).
3. ROADMAP #2 tag suggestions — synergizes with Phase D conditioning.
4. **Phase C** piano roll UI — optional polish after sidecar exists.
5. ROADMAP #14 MIDI keyboard — orthogonal; can precede or follow transcription.

---

## Open questions

- [ ] Which model variant to bundle default (`small` for CPU app?)?
- [ ] One-shot transcribe vs auto-transcribe on analyze?
- [ ] Store MIDI only, or also `notes.yaml` for native UI?
- [ ] Upstream PR status for `events.py` — track in LOCAL-PATCHES.md
