# G-code safety

**This project never invents, regenerates, rewrites, reorders, optimises or
modifies a toolpath.** There is no function anywhere in it that writes G-code.
`app/gcode/validator.py` reads, measures and reports — that is all it can do.

This exists because a print once came out in the wrong physical location from
G-code produced by a mismatched slicer profile, while a correctly sliced
PrusaSlicer file printed correctly.

## PrusaSlicer is the authority

Slicing runs on the Raspberry Pi with the real PrusaSlicer CLI and a
version-controlled Neptune 3 Plus + Klipper profile. The iPhone app does not
implement a slicer, and never will.

## What the validator checks

* **Every X/Y/Z coordinate** against the live `printer.cfg` limits — resolving
  `G91` relative moves and `G92` origin shifts so neither can hide a move off
  the bed.
* **Positioning mode** — a file that never sets `G90`/`G91` is BLOCKED.
* **Homing** — a file that never homes is BLOCKED. Without `G28`, Klipper prints
  relative to wherever it currently believes the toolhead is, which is exactly
  how a print ends up in the wrong place.
* **Extrusion mode** — missing `M82`/`M83` warns.
* **Motion limits** — `M204`, `M205` and `SET_VELOCITY_LIMIT` against the
  printer's approved profile.
* **Unsupported commands** — `M413`, `G29`, `M900`, `M420`, `M851` and others
  Klipper does not implement, each with the reason.
* **Nozzle** — a file sliced for 0.6 mm on a printer configured for 0.4 mm warns.
* **Provenance** — which slicer, which version, which profile.

## The verdict

**SAFE** · **WARNING** · **BLOCKED**. A validation failure is never silently
ignored.

Geometry errors block. Provenance problems warn — an unverified file may be
perfectly fine, and that is your call, not the app's.

## Golden Slicer Profiles

Once a profile has completed test prints without positional problems, mark it
**GOLDEN**. From then on:

* it is pinned — editing under the same name creates a **new version** beside
  it, and never overwrites it,
* it cannot be deleted while it is Golden,
* G-code declaring that profile is marked verified.

Golden status requires **both** the approved slicer and an approved profile
name. A profile id is only a comment: a file from another slicer cannot inherit
trust by copying the name.

## Before every print

```
Slicer:                PrusaSlicer
Printer Profile:       Neptune 3 Plus Klipper
Profile Status:        GOLDEN
G-code Validation:     PASSED
Build Volume:          PASSED
Unsupported Commands:  NONE
Motion Limits:         PASSED
```

Strict Safety Mode turns warnings into blocks.

## What the app will not do

* It will not "optimise" a sliced file.
* It will not let the AI assistant rewrite `G0`/`G1` coordinates. The assistant
  is advisory: it explains and recommends slicer settings, and requests actions
  through the safety engine like everything else.
* It will not modify a working `printer.cfg` because a G-code file asked for
  incompatible settings. The G-code is rejected instead.

Printer configuration, slicer configuration, G-code and Klipper runtime
overrides are kept separate and never mixed automatically.
