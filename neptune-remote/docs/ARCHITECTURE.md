# Architecture

```
┌──────────────────────┐        Tailscale (WireGuard)        ┌──────────────────────┐
│  iPhone              │ ──────────────────────────────────► │  Raspberry Pi 5      │
│                      │                                     │                      │
│  SwiftUI app         │  REST  /api/*        ───────────────►  FastAPI backend     │
│  ├ stores (MVVM)     │  WS    /ws           ◄──────────────┤  :8710               │
│  ├ widget            │                                     │   │                  │
│  ├ Live Activity     │  MJPEG (direct)      ◄──────────────┤   ├ Moonraker client │
│  └ Share Extension   │                                     │   ├ slicer (CLI)     │
└──────────────────────┘                                     │   ├ library + search │
                                                             │   ├ camera / FFmpeg  │
                                                             │   ├ vision (local)   │
                                                             │   └ SQLite           │
                                                             │          │           │
                                                             │   Moonraker :7125    │
                                                             │          │           │
                                                             │   Klipper ─► printer │
                                                             └──────────────────────┘
```

## Why there is a backend at all

The phone could talk to Moonraker directly — and for temperatures and jogging it
does. The backend exists for the things a phone cannot or should not do:

* **Slicing.** A real slicer binary, on a machine that is already running.
* **Secrets.** The Tuya Access Secret signs API requests; it stays on the Pi.
* **Rendering.** STL/3MF/OBJ → PNG previews via a numpy rasteriser.
* **Long-running work.** FFmpeg recording, timelapse, frame analysis.
* **State that outlives the app.** Library, history, filament, queue.

## Backend layout

```
raspberry-pi/app/
├── main.py           FastAPI app, lifespan, router registration
├── config.py         defaults → config.yaml → environment
├── state.py          AppState: the one object that wires everything together
├── security.py       X-API-Key / ?token= gate for /api and /ws
├── paths.py          StorageLayout, rooted at ~/printer_data/neptune_remote
├── db.py             single SQLite file, WAL, CREATE TABLE IF NOT EXISTS
├── moonraker.py      REST + JSON-RPC-over-WebSocket client
├── power/            tuya | moonraker | webhook | demo, behind one protocol
├── slicer/           engines (PrusaSlicer, Orca), job manager, profiles
├── library/          mesh parsing, thumbnail rasteriser, item store
├── search/           Arabic normalisation, synonyms, fuzzy ranking
├── camera/           snapshot + device enumeration
├── recording/        FFmpeg MP4 recording
├── timelapse/        interval + layer frame collection and render
├── vision/           local failure detection (heuristic | ONNX)
├── filament/ cost/ products/ maintenance/ printqueue/
├── backup/           config + database archive with secret redaction
├── knowledge.py      offline troubleshooting trees, Klipper error dictionary
└── routers/          core, library, media, vision, inventory, support, websocket
```

`AppState` is the seam. Routers hold no logic of their own: they validate input,
call into `AppState`, and return. That is what makes the 350+ backend tests
possible without spinning up a printer.

## The `summary` frame

Home needs printer state, the current model, power, camera, recording,
timelapse, vision, queue, filament, library counters and totals. Fetching that
as ten requests would be slow and racy, so `AppState.status_summary()` builds it
once and the `/ws` socket pushes it as a single `summary` frame.

On the iOS side one callback fans it out:

```
BackendSocket ──► PrinterStore.onSummary ──► AppEnvironment.apply(summary)
                                                ├─► MediaStore.apply
                                                ├─► InventoryStore.apply
                                                ├─► notifications (edge-triggered)
                                                └─► LiveActivityController.sync
```

## iOS layout

```
ios/NeptuneRemote/
├── App/              entry point, AppEnvironment, RootView
├── Core/
│   ├── Networking/   HTTPClient, APIError
│   ├── Moonraker/    client, socket, PrinterSnapshot
│   ├── Backend/      client + endpoint extensions, typed models
│   ├── Power/        PowerProviding, safety rules
│   ├── Storage/      AppSettings, Keychain
│   ├── Notifications/ local notifications, Live Activity controller
│   └── *Store.swift  Printer, Files, Slice, History, System,
│                     Library, Media, Inventory, Support
├── Features/         one folder per screen area
├── Intents/          App Intents / Siri
├── Shared/           compiled into the app AND the extensions
├── NeptuneRemoteWidget/   widget + Live Activity UI
└── NeptuneRemoteShare/    Share Extension
```

Stores are `@MainActor final class … : ObservableObject`. Network clients are
`actor`s. Views hold no networking code.

## Safety invariants, and where they live

| Invariant | Enforced in |
| --- | --- |
| Power off refused while printing / hot | `app/power/safety.py` **and** `Core/Power/PowerSafety.swift` |
| The monitor cannot cut power | `app/vision/detector.py` imports no power code; asserted by a test |
| Queue never auto-starts | `app/printqueue/store.py` consumes a `bed_clear` flag on every start |
| `printer.cfg` is never modified | No write path exists; the macro is returned as text |
| Secrets never reach the phone | Tuya credentials only in `config.yaml`; app holds only its own token, in the Keychain |
| Share Extension holds no credentials | It writes to the App Group; the app uploads |

Duplicating the power rules on both sides is deliberate: the app can refuse
before making a request, and the backend refuses even if something else asks.
