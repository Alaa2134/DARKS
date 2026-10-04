# Local print-failure detection

Everything on this page runs on your Raspberry Pi. No frame is uploaded
anywhere, no cloud service is contacted, and there is no account to create.

## What it actually is

Two providers, selected by `vision.provider` in `config.yaml`:

| Provider | Needs | What it does |
| --- | --- | --- |
| `heuristic` (default) | nothing | Rule-based image analysis: edge-density growth, frame-change fraction, frozen-frame detection |
| `onnx` | `onnxruntime` + a model file you supply | Runs your model on each sampled frame |
| `disabled` | — | Off entirely |

The heuristic is deliberately unsophisticated and says so: every detection it
produces is tagged `[heuristic]` in the app, and the UI shows
"No trained model installed - detections are rough."

**This project ships no model.** A failure-detection model you did not choose
is a black box making decisions about your printer. `scripts/install_vision.sh`
installs ONNX Runtime and, if you pass `MODEL_URL=...`, fetches a model you
picked yourself.

## Modes

`vision.mode`, changeable from the app:

| Mode | Behaviour |
| --- | --- |
| `off` | Nothing is analysed |
| `monitor` | Detections are recorded, no alerts |
| `warn` (default) | Push notification when a detection is confirmed |
| `auto_pause` | Pauses the print after repeated confirmations |

### The hard limit

**The detector can pause a print. It can never switch mains power.**

This is structural, not a policy note: `app/vision/detector.py` does not import
the power layer at all, and a test asserts that the module source contains
neither `PowerProvider` nor `build_power_provider`. There is no code path from a
detection to the smart plug.

## Why it does not fire on every frame

* Sampling is never faster than 5 s (`interval_seconds`, floor enforced in code).
* A detection must repeat `confirmations` times inside `window_seconds` before
  it counts. One odd frame does nothing.
* After acting, `cooldown_seconds` must pass before the same kind fires again.
* If the Pi's CPU is above `throttle_cpu_percent` or its temperature above
  `throttle_temp_c`, sampling backs off. Klipper always keeps its CPU.
* `only_while_printing: true` means an idle printer is not analysed at all.

## Region of interest

Drawing a box around the print (app → Print monitor → Watched area) stores a
normalised `[x0, y0, x1, y1]` rectangle. Everything outside it is ignored, which
removes most false positives from a busy workshop background.

"First layer looks fine" resets the detector's baseline, so the normal texture
of *this* print stops being read as a change.

## Bringing your own ONNX model

```bash
MODEL_URL=https://example.com/failure.onnx ./scripts/install_vision.sh
```

Then in `config.yaml`:

```yaml
vision:
  provider: "onnx"
  model_path: "~/printer_data/neptune_remote/models_ai/failure.onnx"
  input_size: 320
  labels: ["ok", "spaghetti"]
  fallback_to_heuristic: true
```

Expected input is a single RGB image tensor; expected output is one failure
probability or a small set of class scores. If the shape does not match, the
backend reports the error in `/api/vision/status` (and therefore in the app) and
falls back to the heuristic when `fallback_to_heuristic` is set. It does not
guess, and it does not silently report "healthy".

## When it cannot run

`/api/vision/status` always tells the truth about why:

| `reason` | Meaning |
| --- | --- |
| no camera | Nothing at `camera.stream_url` / `camera.device` |
| onnxruntime not installed | Run `scripts/install_vision.sh` |
| model file missing | `model_path` does not exist |
| model shape mismatch | Your model's input/output does not match |

The app surfaces each of these instead of showing a monitor that appears to be
watching when it is not.
