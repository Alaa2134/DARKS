# The safety layer

Everything in this project that can move the printer goes through one place.

## The Safety Command Engine

`raspberry-pi/app/safety/engine.py`. Nothing else sends a movement command to
Klipper — not the routers, not the calibration wizards, not the AI assistant,
not the app. They all call `evaluate()` or `execute()`, which:

1. classifies the command,
2. checks the preconditions that class needs,
3. clamps coordinates to the **live `printer.cfg`**, never to hardcoded printer
   dimensions,
4. refuses, with a reason the UI can show.

When the engine cannot establish that a command is safe, it refuses. It never
assumes.

### The rules

| Command | What is checked |
| --- | --- |
| `G28 Z` | **BLOCKED** when the probe is already triggered. WARNS when the probe state has not been read — unknown is never treated as fine |
| `G0/G1` | Axis must be homed; coordinates clamped to `position_min`/`position_max`; feedrate capped for diagnostic moves; refused while printing |
| `PROBE`, `PROBE_CALIBRATE` | Probe must exist, must not be triggered, printer must be homed |
| `TESTZ` | Only inside a calibration session; single step capped at 1 mm; cumulative downward travel capped at 12 mm per session |
| `ACCEPT` / `ABORT` | Only inside a calibration session |
| `BED_MESH_CALIBRATE` | `[bed_mesh]` must exist; printer must be homed |
| `SCREWS_TILT_CALCULATE` | `[screws_tilt_adjust]` must exist; printer must be homed |
| `SAVE_CONFIG` | Always takes a `printer.cfg` backup first |
| `SHAPER_CALIBRATE`, `TEST_RESONANCES` | Blocked without a configured accelerometer |
| `M104/M140` | Absurd targets refused (>300 °C hotend, >130 °C bed) |
| `M112` | Never gated on anything |

`force` acknowledges a **warning**. It can never override a **block** — the
engine raises regardless, and nothing reaches the printer.

A sequence stops at the first refusal, which is what stops a later calibration
stage running after an earlier safety check failed.

### The audit log

Every decision is recorded — command, verdict, adjustments, whether it ran.
`GET /api/doctor/command/audit`.

## Why the live config, not the printer model

The Neptune 3 Plus profile in `app/klipper/validator.py` exists to *advise*: it
says "X position_max is 220 mm, but a Neptune 3 Plus is about 320 mm — is this
config from a different printer?" It never overrides what the config says.

Clamping always uses the live `printer.cfg`. If you have modified your machine,
the app follows your machine.

## Guided workflows

`app/doctor/workflows.py`. Seven procedures, each a state machine the phone
drives one step at a time:

| Workflow | Replaces remembering |
| --- | --- |
| Home safely | `QUERY_PROBE` → `G28 X Y` → `G28 Z` |
| Z Offset wizard | `PROBE_CALIBRATE` → `TESTZ` → `ACCEPT` → `SAVE_CONFIG` |
| Bed screw adjustment | `SCREWS_TILT_CALCULATE`, repeated |
| Bed mesh | `BED_MESH_CALIBRATE` → `SAVE_CONFIG` |
| Full bed calibration | screws → Z offset → mesh, in that order |
| Axis health test | conservative sweeps, then re-home and compare |
| Input shaper | `ACCELEROMETER_QUERY` → `SHAPER_CALIBRATE` → `SAVE_CONFIG` |

Full bed calibration levels the screws **before** meshing, because a mesh cannot
compensate for a badly tilted bed.

## The three Z numbers

These get confused constantly, so the app keeps them apart and labels each:

* **Current Z coordinate** — where Klipper believes the nozzle is right now.
* **TESTZ nudges** — temporary, relative, and normally negative as you step down.
* **probe `z_offset`** — what `SAVE_CONFIG` stores. For an inductive or BLTouch
  probe this is normally **positive**: it is how far below the trigger point the
  nozzle sits.

A negative temporary nudge does not mean the saved offset will be negative. The
app shows the calculated value and asks before writing it.

## Screw clock notation

Klipper's `SCREWS_TILT_CALCULATE` reports one full turn per hour, so `00:21` is
21/60 = **0.35 of a turn**, and `01:12` is **1.2 turns**. The app states the
fraction rather than the clock alone, with a direction and a severity per screw,
and identifies the base screw as the one never to turn.

## Lost position

Standard steppers are open loop. Klipper assumes a commanded move happened, and
nothing in the machine reports otherwise. **The app never pretends there is
position feedback.**

The Axis Health Test gathers indirect evidence: it moves each axis across its
travel at a conservative speed, re-homes, and compares. It reports "possible
skipped Y steps", never "Y lost 3.2 mm". Detecting it for certain needs hardware
that is not installed — see `docs/HARDWARE.md`.
