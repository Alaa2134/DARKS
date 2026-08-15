# CONTINUE — Neptune 3 Plus Remote

Working state for picking up mid-stream. Read this first, then continue from
**Next step**. Do not re-analyse the project from scratch.

- **Branch:** `claude/neptune-3-plus-remote-jcb1y6` (PR #2 on `Alaa2134/DARKS`)
- **Build:** GitHub Actions `build-ios.yml` — backend tests + iOS unit tests + unsigned IPA
- **Local checks:** `cd neptune-remote && python3 scripts/generate_xcodeproj.py && python3 scripts/verify_project.py`
- **Backend tests:** `cd neptune-remote/raspberry-pi && python3 -m pytest -q`

There is no macOS or Xcode in this environment and no printer attached. Swift is
only ever compiled by CI, so every Swift push must be self-reviewed before it
lands and CI must be checked after.

---

## Done

### Foundation fixes
- **Camera no longer freezes the app.** MJPEG parsing and JPEG decode moved off
  the main thread; scan is linear rather than quadratic; only the newest frame
  in a read is decoded; ImageIO downsamples to the drawn size. Non-multipart
  responses are rejected with a message naming the fix. Stall watchdog,
  backoff reconnect, background suspend. Per-view frame size and rate.
- **Duplicate WebSockets.** `openConnection()`/`open()` replaced `task` without
  cancelling it, and `reconfigure()` (which runs behind *every* settings
  change) called `connect()` each time — one orphaned socket per interaction,
  to both Moonraker and the backend. `connect()` is now idempotent, both paths
  close the outgoing socket, a stale receive loop returns instead of tearing
  down its successor, and a failure counts once.
- **Stale readings.** `PrinterSnapshot.lastUpdate` was written in six places and
  read in none. Now `age`/`isStale`, republished from the poll tick, with a
  strip at the top of every tab.
- **Double sends.** `isBusy` is a depth counter, not a boolean. Pause, resume,
  cancel, the three restarts and `startPrint` refuse a second identical command
  in flight. Emergency stop is deliberately unguarded.
- **Unhomed escape.** `SET_KINEMATIC_POSITION` offered on the jog screen when an
  axis is unhomed and `[force_move]` is enabled; otherwise the two config lines
  are shown. Axes are declared at the *bottom* of travel.

### UX
- `Features/Common/Skeleton.swift` — shimmer, `SkeletonCard/Row/List/Grid`,
  `BusyLine`, `Animation.neptune` / `.neptuneContent`. Applied to Library and
  Files.
- `Features/Common/StartupCard.swift` + `PrinterStore.StartupStage` — the four
  waits (reach Pi → reach Moonraker → Klipper ready → read printer.cfg) ticked
  off on both home screens. The bar tracks the real step, never fills on its own.
- Numbers roll (`.contentTransition(.numericText())`) in `StatTile`/`InfoRow`.

### Model placement (S1)
- `raspberry-pi/app/library/transform.py` — rotate/scale/mirror, drop-to-bed,
  auto-orientation scored over candidate down-directions, binary STL writer with
  recomputed normals, `fits_on_bed`.
- `POST /api/library/{id}/orient` (suggest) and `/transform` (measure only).
  Build volume read from the printer's own `printer.cfg`.
- `SliceRequest.transforms` keyed by model id; `jobs.py` materialises a turned
  copy into the job's temp dir. The library file is never modified.
- iOS: `ModelTransform`, `OrientationReport`, `OrientationSuggestion`,
  `PlacementStore`, `PlacementView`.

### Toolpath preview (S4)
- `raspberry-pi/app/gcode/preview.py` — layer index (cached on disk, keyed by
  name+size), per-layer polylines classified from `;TYPE:` across
  PrusaSlicer/Orca/Cura, bounds from extruding moves only.
- `GET /api/gcodes/local/{name}/preview` and `/preview/{layer}?travel=`.
- iOS: `PreviewStore` (layer cache, 140 ms debounce, neighbour prefetch),
  `ToolpathPreviewView` + `ToolpathCanvas` (one `Path` per feature),
  `FlowRow` legend, colour-change ticks on the scrubber, `Theme.color(for:)`
  using the slicer legend vocabulary.

### Resume / print a piece
- `raspberry-pi/app/gcode/resume.py` — `state_at_layer` replays temps, fan,
  M82/M83, G90/G91, feedrate, position; `assess` decides whether Z can be homed
  by checking `safe_z_home` against the part's own footprint; `build_preamble`
  (bed first *and waited for*, X/Y home only, never a bare `G28`, lift before
  travel, prime, restore modes last); `build_resumed_file` with optional
  `end_layer` and its own closing sequence.
- `GET /api/gcodes/local/{name}/resume/{layer}` (plan) and
  `POST .../resume` (build + upload, never starts the print).
- iOS: `ResumePlan`, `ResumeRequestPayload`, `ResumeResult`, `ResumePrintView`,
  reachable from the preview carrying the on-screen layer through.

---

## Current state

- Backend: **1093 tests passing**.
- iOS: **~300 tests**. Last full CI run (`f931fd3`) compiled the whole app and
  ran 295 tests with **one failure — a wrong assertion in my own test**
  (`[0,0,1,1]` is two points, not one). Fixed, not yet re-run.
- No known Critical or High defects outstanding.

---

## Next step

1. Push the current batch (resume + preview test fix) and confirm CI green.
2. **S2 — mesh repair.** `raspberry-pi/app/library/` has no repair. A broken
   model currently fails at slice time with a slicer message nobody can read.
   Plan: detect non-manifold edges, flipped normals, zero-area triangles,
   disconnected shells; auto-fix only the safe ones; report in Arabic; keep the
   original.
3. **S3 — visual plate arrangement.** `extra_model_ids`/`copies` exist but the
   user cannot see or position anything.
4. **L1 — import from a URL** (Printables first — open API; Thingiverse needs a
   key in `config.yaml` on the Pi only).

---

## Standing constraints

- Secrets (Tuya, ntfy, Telegram, heartbeat) live **only** in `config.yaml` on
  the Pi, git-ignored. The API reports "configured"/"not configured" and nothing
  more. `config.example.yaml` keeps every secret field empty.
- The app **never** writes `printer.cfg` and never calls `SAVE_CONFIG` on its
  own. Applying a config value is a separate, explicitly confirmed step.
- No feature claims to work while half-built. If the macro is missing the button
  does not appear — the config lines to add appear instead.
- Every reply to the user is in Egyptian Arabic.
