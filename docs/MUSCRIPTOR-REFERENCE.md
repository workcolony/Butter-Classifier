# MuScriptor reference

Reference material for a possible **audio → multi-instrument MIDI transcription** feature in Butter Classifier, based on [MuScriptor](https://github.com/muscriptor/muscriptor).

Last updated: 2026-07-13

---

## What MuScriptor is

MuScriptor is an open multi-instrument music transcription model (Kyutai + Mirelo). It transcribes polyphonic audio into a stream of note onsets/offsets with instrument labels, or into a MIDI file.

| Resource | URL |
|----------|-----|
| Repository | https://github.com/muscriptor/muscriptor |
| Paper | https://arxiv.org/abs/2607.08168v1 |
| Online demo | https://muscriptor.kyutai.org |
| Models (gated) | https://huggingface.co/MuScriptor |
| License (code) | MIT |
| License (weights) | CC BY-NC 4.0 |

## Local validated fork

We maintain a local spike with important decoder and demo fixes:

| Item | Location |
|------|----------|
| Repo path | `../midi classifier` |
| Branch | `local/butter-reference` |
| Patch manifest | [`../midi classifier/docs/LOCAL-PATCHES.md`](../midi%20classifier/docs/LOCAL-PATCHES.md) |
| Upstream base | `muscriptor/muscriptor` `main` @ `836d32c` |

**Must carry into Butter:** decoder patches in `muscriptor/events.py` (+ tests). Without them, first notes at chunk boundaries and tie-prologue openings are dropped.

**Web-only (reference):** `web/src/audio.ts` playback fixes — useful design notes if Butter adds MIDI preview, but not portable as-is (Swift `AudioPlayer` is separate).

---

## API surface Butter cares about

### Python library

```python
from muscriptor import TranscriptionModel

model = TranscriptionModel.load_model()  # "small" | "medium" | "large"

for event in model.transcribe("audio.wav", instruments=["acoustic_piano", "drums"]):
    # NoteStartEvent | NoteEndEvent | ProgressEvent
    ...

midi_bytes = model.transcribe_to_midi("audio.wav")
```

Key modules:

| Module | Role |
|--------|------|
| `muscriptor/transcription_model.py` | Model load, chunked inference, event streaming |
| `muscriptor/events.py` | Token stream → `NoteStartEvent` / `NoteEndEvent` (**patched locally**) |
| `muscriptor/tokenizer/notes.py` | Note encoding/decoding vocabulary |
| `muscriptor/tokenizer/mt3.py` | `MT3_FULL_PLUS_GROUP_NAMES` — canonical instrument ids |
| `muscriptor/server.py` | FastAPI: `POST /transcribe` (SSE), `GET /instruments` |

### Event contract

- Audio processed in **5-second chunks**; events stream in temporal order.
- Every `NoteStartEvent` is followed by exactly one matching `NoteEndEvent` (same `index`).
- Drum hits: start + end at nearly the same time.
- **No velocity** in output — timing, pitch, and instrument group only.
- Optional **instrument conditioning**: pass exact group names to bias detection.

### Instrument groups (35)

Canonical list in upstream `muscriptor/tokenizer/mt3.py` as `MT3_FULL_PLUS_GROUP_NAMES`. Also exported in the local web UI as `INSTRUMENT_IDS` in `web/src/instruments.ts`.

Examples: `acoustic_piano`, `distorted_electric_guitar`, `string_ensemble`, `drums`, `voice`, …

Run `muscriptor list-instruments` or `GET /instruments` on the server for the full list.

### HTTP server (optional embedding)

```bash
uv run muscriptor serve --model small --host 127.0.0.1 --port 8222
```

- `POST /transcribe` — multipart audio upload; response is SSE of JSON note events
- `GET /instruments` — instrument group names
- Bundled React UI in `web/` (reference implementation)

---

## Model variants

| Variant | Params | Typical use |
|---------|--------|-------------|
| `small` | 103M | CPU-friendly |
| `medium` | 307M | Default speed/accuracy |
| `large` | 1.4B | Best accuracy; wants GPU |

Weights download on first use (~100MB–1GB depending on variant) and require HuggingFace login + license acceptance.

---

## Known quirks (handled in local patches)

1. **Omitted `velocity=1` after chunk boundaries** — model often skips redundant velocity token on first onset; decoder must default to onset velocity or notes are dropped.
2. **Tie prologue + offset-only body** — model lists opening notes in tie section and only emits offsets in chunk body; decoder must mint missing onsets at `seek_time`.
3. **Chunk boundaries every 5 s** — instrument debuts often land at boundaries, which is why missing-first-note bugs show up per instrument.

See [`LOCAL-PATCHES.md`](../midi%20classifier/docs/LOCAL-PATCHES.md) for file-level detail.

---

## Relationship to Butter ROADMAP

- **[ROADMAP #14](ROADMAP.md#14-midi-integration)** — MIDI *keyboard/controller* input for playback and workflow. Different feature.
- **[ROADMAP #17](ROADMAP.md#17-audio--midi-transcription-muscriptor)** — audio → MIDI transcription via MuScriptor.

Implementation plan: [`MUSCRIPTOR-INTEGRATION-PLAN.md`](MUSCRIPTOR-INTEGRATION-PLAN.md).
