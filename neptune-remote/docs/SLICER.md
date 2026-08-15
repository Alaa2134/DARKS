# Slicing on the Raspberry Pi

Slicing runs on the Pi with a **real** slicer binary. The app does not implement
its own slicer, and it does not pretend to slice when no binary is installed —
`/api/slicer/info` reports `available: false` and the UI says so.

## PrusaSlicer (recommended)

```bash
sudo apt install prusa-slicer
prusa-slicer --help | head -1
```

If your distribution has no package, use the official AppImage:

```bash
wget -O ~/PrusaSlicer.AppImage \
  https://github.com/prusa3d/PrusaSlicer/releases/latest/download/PrusaSlicer-Linux-aarch64.AppImage
chmod +x ~/PrusaSlicer.AppImage
~/PrusaSlicer.AppImage --appimage-extract          # avoids needing FUSE
sudo ln -sf ~/squashfs-root/AppRun /usr/local/bin/prusa-slicer
```

Then point the config at it:

```yaml
slicer:
  engine: "prusaslicer"
  prusaslicer_bin: "prusa-slicer"
  timeout_seconds: 1800
  max_concurrent_jobs: 1
```

## How settings reach the slicer

Rather than guessing at CLI flag names (which differ between PrusaSlicer
versions), the backend writes an `overrides.ini` and loads it **last**:

```
prusa-slicer --export-gcode \
    --load profiles/printer/neptune3plus_0.4.ini \
    --load profiles/filament/pla.ini \
    --load profiles/print/standard.ini \
    --load /tmp/<job>/overrides.ini \
    --output out.gcode model.stl
```

`--load` order decides precedence, so the per-job overrides always win. Any
setting PrusaSlicer understands can go in `custom_overrides` without the backend
needing to know about it.

## OrcaSlicer

```yaml
slicer:
  engine: "orcaslicer"
  orcaslicer_bin: "orca-slicer"
```

Orca uses JSON profiles instead of INI. The backend merges the machine, filament
and process JSON plus the job overrides into one temporary JSON and passes it
with `--load-settings`. Orca is optional; PrusaSlicer is the tested path.

## Bundled profiles

`raspberry-pi/profiles/`:

* **printer** — `neptune3plus_0.4` (default), plus `0.2`, `0.6` and `0.8`
  nozzle variants. Bed 320 × 320, height 400 mm, origin centred, bed shape and
  Klipper-friendly start/end G-code included.
* **filament** — PLA, PLA+, PETG, TPU, ABS with sane temperatures, fan curves
  and retraction for a direct-drive Neptune 3 Plus.
* **print** — draft (0.28), standard (0.2), fine (0.16), ultra (0.12), plus
  speed-oriented variants.

## One-tap print

The app's simple flow (material / quality / infill / supports) never sends a
profile id it invented. `SliceProfileMapper` matches your choice against the
profiles `/api/profiles` actually reported, falling back through progressively
looser matches and finally to a profile that definitely exists.

## Progress

`/api/slice` returns a job id immediately. Progress arrives two ways:

* the `/ws` socket pushes `slice` frames as PrusaSlicer prints its stages,
* `GET /api/slice/{id}` polls, so a dropped socket does not freeze the UI.

Stages are mapped to Arabic localisation keys — "بيجهز الطبقات",
"بيكتب الـ G-code" — rather than showing raw slicer output, though the full log
tail is available in Advanced Mode.

## When slicing fails

The job status becomes `failed`, `error` carries the slicer's own message, and
`log_tail` carries the last lines of stderr. Nothing partial is uploaded to
Moonraker, and no G-code file is left behind pretending to be complete.
