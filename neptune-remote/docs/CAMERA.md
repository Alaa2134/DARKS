# Camera, recording and timelapse

## What the app needs

The app is happy with either of these:

1. **An MJPEG stream** — crowsnest, ustreamer or mjpg-streamer, which most
   Klipper installs already have. Set the URL in the app
   (Settings → Camera → `http://<pi>/webcam/?action=stream`). The phone connects
   directly, so the stream never round-trips through the backend.
2. **A `/dev/video*` device** — the backend grabs single frames with FFmpeg.
   Slower, but it works with nothing else installed.

If neither is present, every camera surface in the app says
"No camera detected" rather than showing a blank rectangle.

## Backend configuration

```yaml
camera:
  stream_url: "http://127.0.0.1:8080/?action=stream"
  snapshot_url: "http://127.0.0.1:8080/?action=snapshot"
  device: "/dev/video0"     # used when the URLs are empty or fail
  width: 1280
  height: 720
  fps: 15
  ffmpeg_binary: "ffmpeg"
```

The backend tries `snapshot_url`, then a frame from `stream_url`, then the
device — and reports the **first real error**, not a generic one, so a broken
stream URL does not get misreported as "no camera configured".

`GET /api/camera/devices` enumerates `/dev/video*` with `v4l2-ctl` and lists the
modes each device supports.

## Recording

Real FFmpeg MP4 output — no frame stitching, no fakery. `recording.mode`:

| Mode | Behaviour |
| --- | --- |
| `off` | Never records |
| `manual` (default) | You start and stop it |
| `full` | Records the whole print automatically |
| `first_layer` | Records only the first layer |
| `last_layer` | Records only the final layer |

Files land in `~/printer_data/neptune_remote/videos/YYYY/MM/DD/`.

Stopping sends `q` on FFmpeg's stdin so the MP4 is finalised properly, and only
escalates to SIGTERM if that is ignored. A recording that ends badly is stored
with its error text attached, not silently dropped.

Without FFmpeg the recording buttons are disabled and the app explains why.

## Timelapse

`timelapse.mode`:

* `interval` — a frame every `interval_seconds`.
* `layer` — a frame per layer, which needs a macro in `printer.cfg`.

**Neptune Remote never edits `printer.cfg`.** `GET /api/timelapse/macro` returns
the snippet, and the app shows it with a *Copy macro* button. Adding it is your
deliberate action.

```ini
[gcode_macro TIMELAPSE_TAKE_FRAME]
gcode:
    {action_call_remote_method("timelapse_frame")}
```

Rendering happens when you tap *Render timelapse* (or at print end in automatic
modes). Fewer than `min_frames` frames produces an explicit "not enough frames"
error rather than a one-second video.

## Storage

`recording.retention_policy`:

| Policy | Behaviour |
| --- | --- |
| `never` | Keep everything |
| `max_size` (default) | Delete oldest beyond `retention_max_gb` |
| `keep_last` | Keep the newest `retention_keep_last` files |

The app's Videos screen shows used and free space and can apply the policy on
demand.

## Privacy

* The MJPEG stream goes phone → Pi directly over Tailscale.
* Snapshots, recordings and timelapses are written to the Pi's disk only.
* The print-failure monitor analyses frames in-process. Nothing is uploaded.
