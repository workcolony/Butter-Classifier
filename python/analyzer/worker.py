"""Persistent analyzer worker.

Imports audio_analyzer (paying the heavy librosa/essentia import cost once),
then processes one file per JSON line on stdin, for the lifetime of the app
session. The analysis itself is delegated to the original, unmodified
process_audio_file, so YAML output is identical to running the script directly.

Protocol (all stdout lines are also streamed to the app's log):
  in:  {"path": "/abs/file.wav", "bpm": 120.0|null, "quick": false, "force": false}
  out: <<<BC_READY>>>                      once imports are done
  out: <<<BC_DONE>>> {"path": ..., "ok": true|false, "error": "..."?}
"""
import sys
import os
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audio_analyzer  # noqa: E402  (heavy: librosa, essentia, numba JIT)

print("<<<BC_READY>>>", flush=True)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    path = "?"
    try:
        req = json.loads(line)
        path = req["path"]
        yaml_path = path + ".yaml"
        if req.get("force") and os.path.exists(yaml_path):
            os.remove(yaml_path)
        if not os.path.exists(yaml_path):
            audio_analyzer.process_audio_file(
                path,
                yaml_path,
                bpm_override=req.get("bpm"),
                quick=bool(req.get("quick", False)),
            )
        result = {"path": path, "ok": os.path.exists(yaml_path)}
    except Exception as e:  # keep the worker alive no matter what
        result = {"path": path, "ok": False, "error": f"{type(e).__name__}: {e}"}
    sys.stdout.flush()
    print("<<<BC_DONE>>> " + json.dumps(result), flush=True)
