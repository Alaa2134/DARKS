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

### Plate arrangement (S3)
- `raspberry-pi/app/slicer/arrange.py` — shelf packing on bounding rectangles,
  overlap and bed-edge checks, `bed_size_from_limits`. Stable rather than
  optimal: the same parts always come out the same way, so the plate does not
  reshuffle itself when the screen is reopened.
- `Transform.offset_xy` moves the mesh before the slicer sees it — PrusaSlicer's
  CLI has no per-object placement flag, so that is the only way to say "this one
  goes there". A non-zero offset also makes `engine.py` skip `--arrange`.
- `POST /api/library/arrange`, with `check_only` for the post-drag verdict:
  rearranging there would undo the drag and answer a question nobody asked.
- iOS: `PlatePlacement`, `ArrangeRequestPayload`, `ArrangeResponse`,
  `PlacementStore.setPosition/platePayload`, `PlateView` (bed drawn to real
  proportions, drag to place, live problems), linked from `SliceView` only when
  there is more than one part.

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

### Import from a link (L1)
- `raspberry-pi/app/library/importer.py` — every host is resolved and checked
  against the private ranges **before each request and after every redirect**
  (redirects are followed by hand for exactly that reason: a public URL that
  302s to `127.0.0.1` is the whole attack). Download and unpacked-archive size
  caps; a zip's declared sizes are summed before anything is written. A ZIP of
  eight STLs becomes **one project**, not eight entries.
- Reality check on the plan: **Printables page downloads need a login**, so
  `resolve()` says so and asks for a direct file link instead. MakerWorld has no
  public download API. Thingiverse works, with a key. Direct file links always
  work — that is the path the screen leads with.
- `POST /api/library/import` — one library item per model, plus a collection
  when there is more than one. `library_items` gained `source_url`/`author`/
  `licence` through a new `COLUMN_MIGRATIONS` pass in `app/db.py` (the schema
  is `CREATE TABLE IF NOT EXISTS`, so a new column in it would appear only on a
  fresh database).
- `config.yaml` → `library.thingiverse_key`, Pi-only like every other secret.
- iOS: `ImportRequestPayload`, `ImportResult`, `LibraryItem.sourceURL/author/
  licence`, `LibraryStore.importFromURL`, `ImportLinkView` (link field forced
  LTR so a pasted URL is not reordered), reachable from the library's menu.

### Projects (L2)
- A project is a collection with parts in it, shown as one thing:
  `Features/Library/ProjectView.swift` (parts grid, tallest part, slice the lot,
  open the plate, rename, remove a part), a projects shelf on `LibraryView`, and
  "add to a project" on `ModelDetailView`. `ProjectRoute` is its own navigation
  type - a bare `String` already means "a model".
- `PATCH /api/collections/{id}` renames one. Deleting a project deletes the
  grouping and nothing else; the confirmation says so rather than asking "are
  you sure".

### How many of each part (S5, in the useful direction)
- `copies` multiplies the whole plate, so "four clips and one lid" could not be
  asked for at all. `quantities` is per model, on both `ArrangeRequest` and
  `SliceRequest`; `arrange.expand()` turns it into one **instance** per copy
  (`abc`, `abc#2`, `abc#3` - the first keeps the model's own id, so everything
  that only ever dealt in single parts is untouched).
- The job runner expands instances and writes a placed mesh per copy, so a
  dragged copy keeps its own spot. Capped at 25 on both sides.
- iOS: `PlacementStore.quantity/setQuantity/instances/quantityPayload`, steppers
  on `PlateView`, part count on `SliceView` counted in parts rather than models.
- `tests/test_slice_plate.py` is the first test of `SliceJobManager` at all -
  the expansion sits between the request and the command line and nothing else
  looks at it.

### Notifications that actually arrive
- Two faults, together explaining "الإشعارات مش بتيجي":
  1. **No `UNUserNotificationCenterDelegate`** — iOS shows nothing in the
     foreground unless the app says to, so every alert raised while the user was
     looking at the app was swallowed.
  2. **Nothing awake to raise them.** Events came over a WebSocket that closes
     with the app. `UIBackgroundModes: fetch` was declared and **no task was
     ever registered** — the NotificationManager doc comment described a
     background poller that did not exist.
- `Core/Notifications/BackgroundWatch.swift` — a `BGAppRefreshTask` registered
  through SwiftUI's `.backgroundTask`, depending on no store (iOS may relaunch
  the process for this alone): address from the App Group, token from the
  Keychain, last reading from disk. The app records what it saw on the way to
  the background so a later wake-up does not re-announce it.
- `decide(previous:current:allow:)` is pure and has 16 tests. `postTest()` and
  an honest "iOS decides when" section on the alerts screen, plus a warning when
  Background App Refresh is off.
- Still **not** push: instant delivery with the app terminated needs APNs, a
  push server and a paid developer account. The Pi's own ntfy/Telegram channels
  remain the way to get that today.

### The Pi answers while it works
- Every heavy library operation ran on the event loop: mesh reads, thumbnail
  renders, G-code scans, backups. CPU there means an API that answers nothing —
  and the app polls `/printer/status`, so its own tap made the printer look
  disconnected.
- Now `asyncio.to_thread`: mesh health, repair, upload, thumbnail regeneration,
  arrange (one hop for the whole plate), orient, transform, backup, restore,
  preview index, preview layer, resume plan, resumed-file writing.
- `tests/test_api_responsive.py` measures the stall with a **ticker**, not with
  a second request — the first version used a request as the probe and passed
  on the blocking code, because a request can be served in the gap before the
  slow handler reaches its blocking call. Verified by reverting one endpoint
  and watching the test fail.

### Carrying on after a power cut
- `GET /api/alerts/outage/resume` joins two things that already existed: the Pi
  knew a print died and at which layer, and it could build a file starting from
  a layer. Offers the layer **before** the recorded one (the layer it was on is
  the one that did not finish), carries the file's real layer count, and
  declines plainly for a Moonraker-only file or a file that no longer has that
  layer.
- The offer lives on the outage card itself (Home + alerts screen) — that card
  is the moment the user finds out.

### A queue that runs itself
- `app/printqueue/auto.py` — the decision only, so every branch that ends in the
  toolhead moving is provable without a printer (18 tests).
- The bed-clear confirmation is not removed, it is **earned**: after a
  *completed* print the ejector is armed, the existing `EjectWaiter` fires it
  once the bed is genuinely cold, and a successful sweep sets `bed_clear` and
  starts the next job. No `EJECT_PART` macro → nothing automatic happens at all.
  A cancelled or failed print stops it dead; a failed sweep is never retried.
- `GET/POST /api/queue/auto`, a switch on `QueueView` that shows its blockers
  whether or not it is on, and `queue_started_next` / `queue_auto_blocked`
  notifications — a queue that quietly stops is one you find idle in the morning
  with no idea why.

---

## Current state

- Backend: **1290 tests passing**.
- iOS: **~300 tests**. Last full CI run (`f931fd3`) compiled the whole app and
  ran 295 tests with **one failure — a wrong assertion in my own test**
  (`[0,0,1,1]` is two points, not one). Fixed, not yet re-run.
- No known Critical or High defects outstanding.

---

## Next step

Nothing in the plan is half-built; what remains is either expensive or belongs
to the user's own machine.

**Code, in order of value:**
1. **A project remembers how it was sliced.** `successful_profile` already
   exists per item; a project has nowhere to keep one. The `app_state` key/value
   table would hold it without a migration, and it turns "print the whole thing
   again" into one tap.
2. **Per-object settings** (different infill or supports per part on one plate).
   PrusaSlicer's CLI has no per-object config for STL input at all - it needs a
   3MF project file with per-object modifiers written by us. Real work, and the
   only piece of S5 still missing.
3. **Orca cannot do plates.** `OrcaSlicerEngine` refuses more than one model by
   name rather than guessing a flag. Fine while the engine is PrusaSlicer.

**Known limits, stated rather than hidden:**
- Import works from a direct file link or a ZIP. Printables and MakerWorld pages
  need a login; Thingiverse needs `library.thingiverse_key` in `config.yaml`.
- Background notifications are a safety net on iOS's schedule (15-60 min, never
  in Low Power Mode). Instant delivery with the app terminated needs APNs, a
  push server and a paid developer account. The Pi's ntfy/Telegram channels are
  the way to get that today.

**Waiting on the user's machine (blocks a first successful print):**
1. Install the generated `printer.cfg`, then `FIRMWARE_RESTART`.
2. المعايرة ← فحص البروب - never been run, and the probe has never been tested.
3. Level the bed screws with the numbers that screen gives.
4. A small test print.

## Three mistakes worth not repeating

- I used `BackupInfo`/`deleteBackup` without checking they were free. They were
  not. **grep for a name before using it** — `verify_project.py` does not
  compile Swift, so only CI catches a collision, and that is a 4-minute loop.
- Fixing that, a blanket string replace over a file I had not read renamed the
  *existing* method too, because its signature was textually identical to mine.
  **Never blanket-replace in a file you have not read.**
- `ImportResult` was written with default values and a *synthesised* decoder. A
  synthesised decoder ignores defaults — a missing key throws — so a response
  without `collection_id` failed to decode entirely. **Any Decodable whose
  fields the backend may omit needs `init(from:)` written out with
  `decodeIfPresent`.**

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
