# Troubleshooting

The app has an offline version of most of this: **Help → Troubleshooting** walks
Arabic decision trees, and **Help → Explain a Klipper error** translates raw
Klipper text while always keeping the original.

## The app cannot reach the Pi

Run **Help → System check** first; it reports each layer separately.

| Check fails | Do |
| --- | --- |
| Tailscale | `tailscale status` on both devices; the phone's VPN toggle |
| Backend | `systemctl status neptune-remote`, `journalctl -u neptune-remote -n 50` |
| Moonraker | `systemctl status moonraker`; confirm `moonraker.host/port` in `config.yaml` |
| Klipper | `systemctl status klipper`; the printer's USB cable |

`401 Invalid or missing API token` means `server.api_token` and the token in the
app's settings disagree.

## Power switching

| Symptom | Cause |
| --- | --- |
| Power off is greyed out | A print is running, or the nozzle/bed are still hot. The app names the blocker |
| `1106 permission deny` | Wrong Tuya data centre, or the Smart Life account is not linked |
| `1004 sign invalid` | Wrong Access Secret, or the Pi's clock is wrong (`timedatectl`) |
| State stuck on `unknown` | The plug reports a code other than `switch_code` |

The printer never starts a print by itself when power returns.

## Slicing

| Symptom | Cause |
| --- | --- |
| "Slicer unavailable" | No `prusa-slicer` binary — see `docs/SLICER.md` |
| Job fails immediately | Unsupported file type; only STL, 3MF and OBJ are accepted |
| Job times out | Raise `slicer.timeout_seconds`; a dense 3MF on a Pi can exceed 30 min |
| G-code exists but will not print | Moonraker upload failed — check the job's `log_tail` |

## Camera

| Symptom | Cause |
| --- | --- |
| "No camera detected" | No `/dev/video*` and no working stream URL |
| Stream works in Mainsail, not here | The URL points at `127.0.0.1`; use the Pi's Tailscale address |
| Snapshot works, stream does not | Camera kind is set to MJPEG but the endpoint is a still-image URL |
| Recording disabled | FFmpeg is not installed (`sudo apt install ffmpeg`) |

## Print monitor

| Symptom | Cause |
| --- | --- |
| "No detection engine is installed" | `provider: onnx` without `onnxruntime`; run `scripts/install_vision.sh` |
| Nothing is ever detected | `mode: off`, or `only_while_printing` with an idle printer |
| Too many false positives | Draw a region of interest, then tap "First layer looks fine" |
| Alerts stop during long prints | The Pi got hot or busy and sampling backed off — expected |

It can pause a print. It cannot switch mains power, ever.

## Library and search

| Symptom | Cause |
| --- | --- |
| A model has no picture | Rendering failed; open it and tap "Regenerate preview" |
| The printing screen says "Unknown model" | That G-code was not sliced from a library item |
| Arabic search misses an obvious model | Add an alias in the model's detail page |

Search is deterministic — normalisation, synonyms and edit distance. No AI, so
identical input always gives identical results.

## Queue

The queue never starts anything on its own. If *Start the next print* is
disabled, one of these is true and the app says which: the queue is empty, a
print is running, or the bed has not been confirmed clear. That confirmation is
consumed by every start, so it can never carry over to a second job.

## Collecting a report

**Help → System check → Share the report** produces plain text with tokens and
secrets removed. It is safe to paste into a forum or an issue.
