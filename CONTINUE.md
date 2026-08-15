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

### Mesh repair (S2)
- `raspberry-pi/app/library/repair.py` — welds loose STL corners into shared
  vertices first (without it every edge looks open), then counts degenerate
  triangles, open edges, edges shared by 3+ faces, shells, and faces whose
  winding disagrees. Signed volume catches a mesh that is *consistently*
  inside-out, which a neighbour-agreement check cannot see. Repairs only what
  has one right answer; holes are reported, never filled.
- `GET /api/library/{id}/health`, `POST /api/library/{id}/repair` (writes a new
  library item, never replaces the original).
- iOS: `MeshHealth`, `MeshRepairResult`, health card on `PlacementView`.

### Library backup (L4)
- `raspberry-pi/app/library/backup.py` — `.tar.gz` of the database (through
  SQLite's own backup API, because a WAL database's newest commits are not in
  the `.db` file), the models and the thumbnails, plus a manifest so a restore
  can refuse a newer format. G-code and videos excluded on purpose. Tar members
  are filtered against path escape and links before extraction. Restore merges
  by default; replacing the database moves the old one aside.
- `GET/POST /api/library/backups`, `/backups/{name}/download`,
  `POST /backups/restore`, `DELETE /backups/{name}`.
- Two bugs the API tests caught: the routes were declared after
  `/library/{item_id}` and were being swallowed by it, and two backups in the
  same second landed on the same filename — a backup feature deleting a backup.

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

- Backend: **1144 tests passing**.
- iOS: **~300 tests**. Last full CI run (`f931fd3`) compiled the whole app and
  ran 295 tests with **one failure — a wrong assertion in my own test**
  (`[0,0,1,1]` is two points, not one). Fixed, not yet re-run.
- No known Critical or High defects outstanding.

---

## Next step

1. Confirm CI green for the resume + mesh-repair batch.
2. **S3 — visual plate arrangement.** `extra_model_ids`/`copies` exist in
   `SliceRequest` but the user cannot see the bed or position anything. Needs:
   bed drawn from `printer.cfg` limits, drag to place, overlap and out-of-bounds
   warnings, simple bin-packing as a starting arrangement, offsets passed to the
   engine with `--dont-arrange`.
3. **L1 — import from a URL** (Printables first — open API; Thingiverse needs a
   key in `config.yaml` on the Pi only). A ZIP of several STLs should become one
   project, not several entries.
4. **iOS screen for backup/restore.** The backend and API are done; there is no
   UI for it yet. Belongs in Settings or More → System.

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
