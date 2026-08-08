# Neptune 3 Plus Remote

Remote control, mobile slicing and a print-monitoring ecosystem for an
**Elegoo Neptune 3 Plus** running Klipper / Moonraker / Mainsail on a
**Raspberry Pi 5**, reachable from anywhere over **Tailscale**.

Two halves, both real:

* **iOS app** — native SwiftUI, iOS 17+, MVVM, async/await. No WebView wrapper,
  no third-party dependencies. Arabic and English with full RTL.
* **Raspberry Pi backend** — Python 3 / FastAPI. Does the things a phone cannot:
  runs a real slicer, holds the Tuya secret, renders model previews, records
  video, and watches for print failures locally.

---

## What it does

### Fix My Printer
* One guided diagnostic that inspects the Pi, Moonraker, Klipper, the MCU, the
  live `printer.cfg`, heaters, thermistors, fans, endstops, the probe, the
  filament sensor, homed axes, travel limits, bed mesh, Z offset and the recent
  Klipper log — and explains what it found in plain language.
* Each finding carries a severity, the likely cause, the affected subsystem, and
  either a one-tap fix or the manual steps written out.
* Diagnosis is read-only. It never moves the printer.

### You never have to remember a command
Guided wizards for homing, Z offset, bed screws, bed mesh, full bed calibration,
axis health and input shaping. No `G28`, `PROBE_CALIBRATE`, `TESTZ`,
`SCREWS_TILT_CALCULATE`, `BED_MESH_CALIBRATE` or `SAVE_CONFIG` to memorise.

* **Every command goes through a Safety Command Engine.** `G28 Z` is blocked when
  the probe is already triggered; moves are clamped to the *live* config; `TESTZ`
  steps and total travel are capped; `SAVE_CONFIG` always backs up first.
* Bed screws are shown on a diagram of the bed, with an arrow per knob and the
  fraction of a turn — Klipper's `00:21` reads as "about 0.35 of a turn".
* A later calibration stage never runs after an earlier safety check failed.

### The known-good configuration is protected
Versioned `printer.cfg` history with naming ("Golden Config", "Before ADXL"), a
section-aware diff that separates `SAVE_CONFIG`'s own writes from your edits,
one-tap rollback, and which config was active for successful prints. Golden
versions cannot be deleted or overwritten.

### G-code is validated, never rewritten
**This app never invents, regenerates, reorders or optimises a toolpath.** The
inspector reads a sliced file and reports: extents against the live config,
`G90`/`G91`, `M82`/`M83`, missing `G28`, `M204`/`M205`/`SET_VELOCITY_LIMIT`
against the printer's limits, unsupported Marlin commands like `M413`, and which
slicer and profile produced it. Files not from the approved PrusaSlicer profile
are marked **UNVERIFIED G-CODE**.

### Printing
* Live printer state over Moonraker REST + WebSocket.
* Jog, home, extrude, temperatures with presets, speed/flow/fan factors,
  velocity limits, and a full G-code terminal (Advanced Mode).
* Safety checklist before a remote print starts.
* Emergency stop, always one tap away.

### The model comes first
* **You always see a picture of what is printing** — never a G-code filename
  standing in for one. If the print did not come from the library, the app says
  "Unknown model" rather than filling the space with a filename.
* Automatic preview + hero image generation for STL / 3MF / OBJ, rendered on the
  Pi with a numpy z-buffer rasteriser (no GPU, no X server).
* Native 3D viewer, and G-code thumbnail extraction.

### Library and Arabic search
* Model library with Arabic names, aliases, tags, categories and collections.
* **Deterministic Arabic search with no AI**: NFKC normalisation, diacritic
  stripping, letter unification, synonym groups, Damerau-Levenshtein fuzzy
  matching, transliteration and ranked results with a reason label.
  `ميدليه` finds `ميدالية مفاتيح`; `ستاند تليفون` finds `حامل موبايل`.
* Idea finder ("فاجئني") that ranks what you already own by room, time and
  material.

### One-tap print
Material, quality, infill, supports. The app maps those four choices onto
profiles the backend actually reports — it never sends a profile id it invented.

### Print queue
Nothing ever starts by itself. The next job needs an explicit
"I removed the last print" confirmation, and the backend consumes that
confirmation on every start so it cannot carry over.

### Camera, video, timelapse
* MJPEG live view, straight from the Pi to the phone.
* Real FFmpeg MP4 recording (manual / full print / first layer / last layer).
* Interval and layer timelapse. The layer macro is **shown for you to copy** —
  `printer.cfg` is never modified by this app.
* Retention policies and a storage screen.

### Local print-failure monitor
* Runs entirely on the Pi. **No frame is ever uploaded.** No cloud, no account.
* Built-in image heuristic by default; optional ONNX model you supply yourself.
* Modes: off / watch only / warn / pause the print.
* Sampling never faster than 5 s, temporal confirmation before acting, backs off
  when the Pi is hot or busy.
* **It can pause a print. It can never switch mains power** — the code path does
  not exist, and a test asserts it.

### Running a small business on it
Filament inventory with real colours, cost calculator (filament, electricity,
machine time, labour, failure allowance, margin), products with SKUs and
margins, print history with photos, reprint, and print-quality memory.

### Keeping it alive
Maintenance reminders driven by real print hours and counts, bed mesh heat map,
offline Arabic troubleshooting decision trees, a Klipper error translator that
always keeps the original text, a one-tap system check, and backups with secrets
redacted.

### On the phone
Live Activity and Dynamic Island, a home-screen and lock-screen widget,
Siri / App Intents, a Share Extension for STL / 3MF / OBJ, local notifications,
Simple and Advanced modes, dark/light, and a complete demo mode with no printer
attached.

---

## Install

### Raspberry Pi

```bash
git clone <this-repo> neptune-remote
cd neptune-remote/raspberry-pi
./install.sh
```

Idempotent — safe to re-run. It installs system packages (including FFmpeg and
`v4l-utils` unless `SKIP_MEDIA=1`), creates a virtualenv, detects your camera,
looks for a CLI slicer, and installs a systemd unit. **It never touches
`printer.cfg`, Klipper or Moonraker.**

```bash
sudo nano /opt/neptune-remote/config.yaml     # power provider, Tuya, API token
sudo systemctl restart neptune-remote
curl -s http://127.0.0.1:8710/api/health
```

Optional, for a trained failure-detection model:

```bash
./scripts/install_vision.sh
```

### iOS

```bash
# On a Mac with Xcode:
open ios/NeptuneRemote.xcodeproj
# or
./scripts/build_unsigned_ipa.sh    # -> dist/NeptuneRemote-unsigned.ipa
```

The project is checked in and regenerable with
`python3 scripts/generate_xcodeproj.py`. Targets are configured for **no code
signing**, so you can sign the IPA yourself.

Compiling needs macOS. On Linux the build script exits with a clear message
rather than producing a fake `.ipa`.

---

## Security

* **Tuya Access Secret never appears in Swift.** It lives only in the Pi's
  `config.yaml`, which is git-ignored, and the backend signs the API request.
* **Moonraker is never exposed to the internet.** Tailscale is the perimeter.
* **Tokens live in the iOS Keychain** — not UserDefaults, not the App Group, and
  not in the Share Extension. The extension stages files; the app uploads them.
* **Optional API token** on `/api` and `/ws` as defence in depth.
* `config.yaml` and `.env` are git-ignored; `config.example.yaml` and
  `.env.example` are committed with every secret field empty.
* Diagnostic reports and backups have secrets redacted before they are written.
* `scripts/verify_project.py` fails the build if a Tuya-looking credential ever
  appears in the tree.

---

## Documentation

| Document | Covers |
| --- | --- |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the pieces fit and where each safety rule lives |
| [TAILSCALE.md](docs/TAILSCALE.md) | Private networking, ports, API token |
| [TUYA_SETUP.md](docs/TUYA_SETUP.md) | Smart plug setup and the power safety rules |
| [SLICER.md](docs/SLICER.md) | PrusaSlicer / OrcaSlicer, profiles, overrides |
| [CAMERA.md](docs/CAMERA.md) | Camera, recording, timelapse, storage |
| [AI.md](docs/AI.md) | The local failure monitor, in detail |
| [NOTIFICATIONS.md](docs/NOTIFICATIONS.md) | Notifications, widget, Live Activity |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptom → cause tables |
| [SAFETY.md](docs/SAFETY.md) | The Safety Command Engine, the wizards, and the three Z numbers |
| [GCODE_SAFETY.md](docs/GCODE_SAFETY.md) | Why toolpaths are never rewritten, and what is validated |
| [BUILD_IPA.md](docs/BUILD_IPA.md) | Unsigned IPA, signing it yourself, CI |
| [UX_REVIEW.md](docs/UX_REVIEW.md) | Twelve scenarios walked end to end, and what changed |
| [FINAL_REPORT.md](docs/FINAL_REPORT.md) | Every requirement, its status, and the remaining limits |

---

## Tests

```bash
cd raspberry-pi && python3 -m pytest -q          # 548 passing
python3 scripts/verify_project.py                # 51 project-wide checks
```

The backend suite covers the happy paths and, deliberately, the failure paths:
no slicer installed, no FFmpeg, no camera, no ONNX runtime, Tuya returning an
error, a corrupt STL, a directory-escape attempt, an unauthorised request. In
each case the assertion is that the system **reports the failure** rather than
faking success.

`verify_project.py` additionally checks that every Swift file is in the project,
that Arabic and English have identical key sets with matching format specifiers,
that every localisation key used in code exists, and that no credential is
committed.

iOS unit tests live in `ios/NeptuneRemoteTests` and run from Xcode.

---

## Hardware this was built for

| | |
| --- | --- |
| Printer | Elegoo Neptune 3 Plus — 320 × 320 × 400 mm, direct drive |
| Nozzles | 0.4 default; 0.2, 0.6, 0.8 profiles included |
| Host | Raspberry Pi 5, Klipper + Moonraker + Mainsail |
| Network | Tailscale (default address `100.78.2.66`, editable in the app) |
| Phone | iPhone, iOS 17 or newer |
