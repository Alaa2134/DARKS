# Final report

What was asked for, what exists, and where the honest limits are.

---

## 1. Simple Mode and Advanced Mode

**Done.** Simple Mode is the default: four tabs, one obvious action per printer
state. Advanced Mode adds the Control and Slice tabs and the terminal. Nothing
is removed in Simple Mode — every screen stays reachable under *More* — and the
switch is one toggle in two places.

## 2. State-driven Home

**Done.** `PrinterPhase.resolve(snapshot:power:)` maps the printer to OFF /
STARTING / READY / PRINTING / COMPLETE / ERROR, with error taking precedence
over everything and an unknown power state never being reported as "off". Six
unit tests cover the transitions.

## 3. The model image is always visually obvious

**Done.** `ModelImage` is used on every surface that identifies a print: home,
library, detail, printing screen, videos, Live Activity. It shows the rendered
preview, or a category-symbol placeholder built from the model's own name. The
G-code filename never occupies the picture position.

## 4. Automatic thumbnail and hero generation

**Done.** STL, 3MF and OBJ are parsed on the Pi and rendered by a numpy z-buffer
rasteriser with flat Lambert shading — no GPU, no X server, no headless browser.
A file that fails to render gets a clearly-labelled placeholder card and an
error, not a blank.

## 5. Native 3D viewer and G-code preview

**Done.** SceneKit viewer with the 320 × 320 × 400 build plate drawn to scale,
fed by an in-app STL/OBJ/3MF loader (including a raw-DEFLATE reader for 3MF).
G-code thumbnails are extracted from the slicer's embedded base64 blocks.

## 6. One-tap print

**Done.** Material, quality, infill, supports, copies. `SliceProfileMapper`
resolves those onto profile ids the backend actually reported, through
progressively looser matches, and finally onto one that provably exists — it
cannot send an invented profile. Verified by unit tests.

## 7. Model library

**Done.** Arabic and English names, aliases, tags, thirteen categories,
collections, favourites, print counts, notes, photos, per-item G-code history,
and a remembered "successful profile" per model.

## 8. Deterministic Arabic smart search, no AI

**Done.** NFKC normalisation, diacritic stripping, alef/ya/ta-marbuta
unification, tatweel removal, synonym groups, Damerau-Levenshtein fuzzy
matching, transliteration, token-coverage scoring, and suggestions. The exact
cases from the brief are asserted: `ميدليه` → `ميدالية مفاتيح`,
`ستاند تليفون` → `حامل موبايل`. Identical input always gives identical output.

## 9. Idea finder

**Done.** Ranks the user's own library by room, available time and material.
"فاجئني" returns one pick. It never invents models it does not have.

## 10. Print queue that never auto-starts

**Done.** The next job requires an explicit bed-clear confirmation, which the
backend consumes on every start so it cannot carry over to a second job. The
Siri intent refuses with the same rule. The app names the blocker rather than
showing a dead button.

## 11. Filament inventory and colours

**Done.** Spools with brand, material, colour (rendered as the real colour),
weight, price and remaining grams. Consumption is deducted from real filament
usage. The pre-print check reports "enough" / "only just" / "not enough" — and
deliberately does **not** block when no spool is configured, because then the
app simply does not know.

## 12. Print cost calculator

**Done.** Filament, electricity, machine time, labour, packaging, other, and a
failure allowance, producing a per-unit cost and a suggested price with a
configurable margin and rounding. Currency is shown as a code, never as a
guessed symbol.

## 13. Product management

**Done.** Products linked to library models, with SKU, colours, print cost,
selling price, margin, stock and made-to-order.

## 14. Visual print history, reprint and quality memory

**Done.** History carries the model thumbnail and result. A rating
(excellent / good / problem) stores the profile that produced it, so the app can
offer the settings that worked last time.

## 15. Bed mesh visualisation

**Done.** The saved mesh is drawn as a heat map with the front row at the
bottom, each cell labelled, plus range and a plain-language verdict. Running a
fresh probe is refused while printing.

## 16. Maintenance reminders

**Done.** Driven by real print hours, print counts and elapsed days, with
progress bars and a due badge that surfaces on Home.

## 17. Offline Arabic troubleshooting

**Done.** Decision trees answered entirely on the Pi, with yes/no navigation,
per-leaf advice and quick fixes. No internet, no service.

## 18. Klipper error translator

**Done.** Arabic title, explanation, likely causes and what to check — and the
**original text is always kept and displayed**. An unmatched message returns
`matched: false` and says so rather than inventing an explanation.

## 19. Notifications

**Done.** Eleven kinds, individually switchable, all local. Failures and monitor
alerts are time-sensitive so they cut through Focus. Duplicates are suppressed
by identifier; maintenance and filament alerts are edge-triggered.

**Honest limit:** local notifications need the app running or recently
backgrounded. There is no push server, because adding one would mean sending
printer state to a third party. `docs/NOTIFICATIONS.md` states this plainly.

## 20. Live Activity and Dynamic Island

**Done.** Lock screen and Dynamic Island show the model picture, progress, layer
and a live countdown, plus a warning line when the monitor flags something.
Updates are throttled to ~1 % progress movement or a state change, because
ActivityKit drops updates that arrive too fast. If the user has Live Activities
off, the controller records why and does nothing — it never reports an activity
it did not start.

## 21. Widget, Siri, Share Extension

**Done.** Widget in five families reading the App Group snapshot (stale after 30
minutes is drawn as stale). Ten App Shortcuts — Apple's limit — in one provider,
including "what is printing", which answers with the model name. Share Extension
accepts STL/3MF/OBJ.

**Design decision:** the Share Extension stages files in the App Group and the
app uploads them. Giving the extension the backend token would mean storing it
somewhere outside the Keychain, which the brief forbids.

## 22. Real video recording and timelapse

**Done.** FFmpeg MP4 recording (manual / full / first layer / last layer),
finalised by sending `q` on stdin and only escalating to SIGTERM. Interval and
layer timelapse, output under `videos/YYYY/MM/DD/`, with retention policies.

The layer macro is **returned as text to copy**. `printer.cfg` is never written
to. During this work the macro was found to embed the API token in the curl
command — printer.cfg is exactly the file people paste into forum posts — so the
frame endpoint now accepts loopback callers without a token and the macro
carries no credential at all. Tests assert both halves.

## 23. Local AI print-failure detection

**Done, with its limits stated everywhere it appears.**

* Runs entirely on the Pi. No frame is uploaded; no cloud service is contacted.
* Built-in image heuristic by default; ONNX only with a model the user supplies.
  **This project ships no model** — one you did not choose is a black box making
  decisions about your printer.
* Every heuristic detection is tagged `[heuristic]` in the UI.
* Sampling never faster than 5 s, temporal confirmation before acting, cooldown
  after acting, and automatic back-off when the Pi is hot or busy.
* Modes off / monitor / warn / auto_pause, defaulting to warn.
* **It can pause a print. It can never switch mains power.**
  `app/vision/detector.py` imports no power code, and a test greps the module
  source to keep it that way.

## 24. Tests, verification and the build

**Backend: 362 tests passing.** Alongside the happy paths, the suite explicitly
covers no slicer, no FFmpeg, no camera, no ONNX runtime, Tuya errors, a corrupt
STL, a directory-escape attempt, an unauthorised request, and the new
loopback-exemption boundary. In each case the assertion is that the system
reports the failure rather than faking success.

**Project checks: 51 passing.** Every Swift file referenced by the project,
identical Arabic/English key sets with matching format specifiers, every
localisation key used in code defined, and no committed credential.

**iOS: compiles and its tests run on macOS CI.** The first real compile found
four things — an exclusivity violation in `HTTPClient`, a main-actor isolation
error in the Share Extension, a deprecated locale API, and a test that asserted
`JSONEncoder` writes nulls for nil optionals when it omits them. All fixed.

**The IPA is real or it does not exist.** `scripts/build_unsigned_ipa.sh` refuses
to run anywhere but macOS, refuses to package an app bundle with no executable,
and prints the SHA-256 of what it produced. No placeholder file is ever written.

---

## What is not done

* **The IPA in this repository's artifacts is built by CI, not by hand here.**
  There is no Swift toolchain on Linux, so the macOS runner is the first and only
  compile.
* **The App Group must exist in your developer account** or be removed from the
  three entitlement files. Without it the app still runs — the widget shows a
  placeholder and the Share Extension says the shared container is unavailable —
  but that is a degraded mode, not the intended one.
* **No trained failure-detection model is included**, by choice. The heuristic
  works out of the box and says how rough it is.
* **A Watch app was listed as optional and is not built.** The complications
  surface through the accessory widget families instead.

---

# Phase 3 — control, safety, diagnosis and recovery

Status of the second specification, added after phase 2.

## Done

**1. Fix My Printer.** `app/doctor/engine.py` inspects the Pi, Moonraker,
Klipper, the MCU, the live `printer.cfg`, heaters, thermistors, fans, endstops,
the probe, the filament sensor, homed axes, travel limits, bed mesh, Z offset,
saved config values and the recent Klipper log. Every finding carries severity,
likely cause, subsystem, recommendation, and either a one-tap fix or written-out
manual steps. Diagnosis is read-only — it never moves the printer. A check that
could not run reports *unknown*, never a pass.

**2. Safe Command Engine.** `app/safety/engine.py`. Nothing in the project sends
a movement command to Klipper directly. See `docs/SAFETY.md` for the full rule
table. `G28 Z` is blocked on a triggered probe and warns on an unread one;
moves clamp to the live config; `TESTZ` is session-gated and capped per step and
per session; `SAVE_CONFIG` always backs up first; `force` never overrides a
block; a sequence stops at the first refusal. Emergency Stop is pinned to the
bottom of every calibration screen and is never gated on anything.

**3. Known-good config / versioning.** Automatic backup before every change,
timestamped versions, naming ("Golden Config", "Before ADXL"), a section-aware
diff that separates `SAVE_CONFIG`'s own writes from your edits, one-tap
rollback, "restore last working configuration", and per-version proven-print
counts. Golden versions cannot be deleted or pruned. Suspicious values are
detected against a Neptune 3 Plus profile that advises but never overrides.

**4. Z Offset wizard.** The documented procedure end to end, with ±1.0 … ±0.01
controls, guarded step sizes, and the three numbers kept explicitly separate:
the live Z coordinate, the temporary `TESTZ` nudges, and the probe `z_offset`
Klipper saves — which is normally positive even though the nudges are negative.

**5. Screws tilt / bed level wizard.** All six Neptune 3 Plus positions on a
diagram of the bed, an arrow and severity per screw, and the fraction of a turn.
Klipper's clock is one full turn per hour, so `00:21` reads as "about 0.35 of a
turn". Measure-and-turn loops back rather than advancing.

**6. Bed mesh.** `BED_MESH_CALIBRATE` through the workflow, plus the existing
heat-map view. Full Bed Calibration levels the screws **before** meshing and
stops at the first failed safety check.

**7. Axis health test.** Conservative sweeps across the configured travel,
re-home, compare. It reports "possible skipped Y steps" and never claims
certainty — see the limits below.

**12. Pre-print safety check.** Printer health plus G-code analysis produce
READY / WARNING / BLOCKED, with Strict Safety Mode turning warnings into blocks.
The pre-print banner shows slicer, profile, profile status, validation, build
volume, unsupported commands and motion limits.

**14. Printer health page.** One card per subsystem: green, yellow, red or
unknown, with status, detail and recommended action.

**15. Maintenance.** The checklist now covers V wheels, eccentric nuts, belts, Z
lead screws, nozzle, hotend, fans, bed screws, wiring and the filament sensor,
each with English and Arabic guidance. **The lubrication task names the Z lead
screws specifically and says not to lubricate the POM V wheels or the aluminium
V-slot** — a test enforces that lubrication and a wheel never appear together
without a prohibition.

**16. Printer profile.** Neptune 3 Plus geometry is used to *validate* the live
config, not to replace it. Clamping and bounds checks always use `printer.cfg`.

**19-20. Error translation and config validation.** The existing translator
keeps the original Klipper text; the config validator detects duplicate
sections, inverted limits, endstops outside travel, missing required fields and
suspicious probe offsets, and runs before any save.

**G-code safety (the critical requirement).** `app/gcode/validator.py` reads and
reports; there is no function in this project that writes G-code. It resolves
`G91` and `G92` so neither can hide a move off the bed, checks bounds against
the live config, flags missing `G28`/`G90`, catches `M413` and other Marlin
commands, and marks anything not from the approved PrusaSlicer profile as
UNVERIFIED. Golden profiles are pinned: editing creates a new version and never
overwrites, and Golden status requires both the approved slicer and an approved
profile name.

## Verified

- **548 backend tests**, including the safety engine's refusals, the workflow
  stop-on-refusal invariant, and every G-code failure shape.
- **51 project checks** — no committed credentials, complete AR/EN key sets.
- **The iOS app compiles.** The macOS CI job built a real unsigned IPA
  (3.3 MB) with the app, widget and Share Extension embedded.

## Not done yet

* **AI assistant (§10).** The context it would read is all in place — health
  report, config, logs, print history, G-code analysis — and the Safety Command
  Engine is exactly the gate it would have to request actions through. The
  assistant itself is not built.
* **Hardware mods registry (§9, §22).** Dual 5015 wiring guidance, the ADXL345
  setup flow and the fan test steps are specified but not implemented. The
  accelerometer is already detected and resonance tests already refuse without
  one.
* **Smart print recovery (§13).** Reconnect and pause handling exist from
  phase 1; the explicit "do not resume after suspected lost position" logic is
  not built.
* **Axis health interpretation.** The workflow runs and collects endstop and
  position output; turning that into a per-axis pass/fail verdict is not
  finished.

## Honest limits

* **Standard steppers are open loop.** Nothing in the machine reports actual
  position. The app gathers indirect evidence and says "possible skipped steps";
  it will not pretend otherwise. Detecting it for certain needs hardware that is
  not installed.
* **The heuristic print monitor is rough**, and says so on every detection.
* **No accelerometer is installed**, so input shaping is offered but reports
  "Not installed" rather than faking a result.
