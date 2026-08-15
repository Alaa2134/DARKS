# Notifications, widget and Live Activity

There are **two** notification paths, and the difference between them is the
difference between finding out and not finding out.

| | In-app (local) | Out-of-house (push from the Pi) |
| --- | --- | --- |
| Needs the app running | yes | **no** |
| Works with the phone locked, elsewhere | no | **yes** |
| Needs an Apple Developer account | no | no |
| Configured in | Settings → Alerts | `config.yaml` on the Pi |

The app is installed unsigned, so it can never receive real Apple push
notifications — there is no APNs key, no push token and no server of ours.
Local notifications are posted by the app itself and therefore need it to be
running or recently backgrounded. A phone asleep for hours shows the
print-finished notification when the app next wakes, not when it happened.

That is fine for a print you are watching and useless for one you are not. So
the Raspberry Pi also pushes, on its own, to a service your phone already
subscribes to. See **[Alerts that arrive when the app is closed](#alerts-that-arrive-when-the-app-is-closed)**.

## Kinds

| Event | Default | Setting |
| --- | --- | --- |
| Print started / paused / resumed | on | `notifyPrintStateChanges` |
| Print finished | on | `notifyPrintFinished` |
| Print failed | on | `notifyPrintFailed` |
| Klipper error | on | `notifyKlipperError` |
| Disconnected / reconnected | on | `notifyDisconnected` |
| Target temperature reached | off | `notifyTargetReached` |
| Auto power off | always | — |
| Print monitor alert | on | `notifyVisionAlerts` |
| Next queued print ready | on | `notifyQueueReady` |
| Maintenance due | on | `notifyMaintenanceDue` |
| Filament low | on | `notifyFilamentLow` |
| Filament runout | on | `notifyPowerAndRunout` |
| Power lost / restored | on | `notifyPowerAndRunout` |
| Print interrupted | on | `notifyPowerAndRunout` |
| First layer done / halfway | off | `notifyProgressMilestones` |
| Safety block, AI pause failure | always | — |

Klipper errors, print failures, monitor alerts, power loss, runout and an
interrupted print use `interruptionLevel = .timeSensitive` with the critical
sound, so they cut through a Focus mode. The rest are ordinary — deliberately.
Handing `.timeSensitive` to "print reached 50 %" is how people end up silencing
the whole category, and then the one alert that mattered arrives silently too.

Duplicates are suppressed by identifier — a repeated `summary` frame describing
the same detection does not re-alert. Maintenance and filament alerts are
edge-triggered: they fire on the transition into the condition and stay quiet
until it clears.

## Live Activity and Dynamic Island

While a print runs, the lock screen shows the model picture, progress, layer and
a live countdown; the Dynamic Island shows the same compactly.

* Updates are throttled: a push only happens when progress moves ~1 %, the state
  changes, or the monitor raises a warning. ActivityKit drops updates that
  arrive too fast, and a dropped update looks like a frozen activity.
* If the user has Live Activities disabled, `LiveActivityController` records
  `unavailableReason` and does nothing else. It never reports an activity it
  did not manage to start.
* An activity that survives an app restart is re-adopted at launch.
* The activity ends when the print stops, and lingers two minutes so the finish
  is visible.

The title uses the **model name**. The G-code filename only appears when there
is no linked model — the same rule the printing screen follows.

## Widget

`SharedStore` holds the last snapshot in the App Group; the widget reads it and
never makes a network request itself. Families: small, medium, and the accessory
(lock screen) circular, rectangular and inline shapes.

The refresh cadence is 5 minutes while printing and 15 minutes when idle, and a
snapshot older than 30 minutes is drawn as stale rather than presented as
current. Without the App Group capability the widget shows placeholder data —
visibly a placeholder, not invented numbers.

## Permissions

The app asks once, on first launch, when notifications are enabled in settings.
Declining is fine: every feature keeps working, and the app does not ask again.
Settings → Notifications shows the current authorisation status and links to the
system settings.

---

# Alerts that arrive when the app is closed

## Why the Pi has to be the one that pushes

Everything above runs on the phone. The moment the app is not running, none of
it happens. That is exactly the situation the feature exists for: you are out,
the printer has been running for six hours, and something goes wrong.

Apple's answer to this is APNs, which needs a paid Developer account and a
signed app. This app is sideloaded unsigned, so that route is closed. The route
that is open: the Raspberry Pi is already awake, already watching Klipper, and
already has internet. It pushes to a service your phone subscribes to.

## ntfy — the short version

[ntfy.sh](https://ntfy.sh) is free, needs no account, and has an iOS app.

1. Install **ntfy** from the App Store.
2. Pick a long random topic — `neptune-a7f3c1d9e2`, not `printer`. **The topic
   name is the password**: anyone who guesses it reads your notifications.
3. Subscribe the app to that topic.
4. On the Pi, in `config.yaml`:
   ```yaml
   notifications:
     ntfy:
       enabled: true
       topic: "neptune-a7f3c1d9e2"
   ```
5. `sudo systemctl restart neptune-remote`
6. In the app: Settings → Alerts → **Send a test message**. Your phone should
   buzz within a second.

Telegram works too (`notifications.telegram` with a @BotFather token and your
chat id) and keeps a scrollable history, which ntfy does not. Both can run at
once; a failure in one never blocks the other.

Credentials live in `config.yaml` on the Pi. `config.yaml` is git-ignored and
the API never returns a token — the app is only ever told *whether* a channel
is configured.

## What gets through, and what does not

An alerting system nobody trusts is worse than none, so messages are filtered:

* **Deduplicated** — the same message inside `dedupe_seconds` is sent once. A
  printer in shutdown reports it on every poll; forty identical alerts are not
  forty times more useful than one.
* **Rate limited** — `max_per_hour`.
* **Quiet hours** — optional, and they wrap past midnight.

A short, explicit list ignores all three: `power_lost`, `print_interrupted`,
`klipper_error`, `filament_runout`, `vision_alert`, `ai_pause_failed`,
`print_failed`. These are the ones that mean a human has to do something, and
they must not be lost to a filter by accident. You can still turn one off
deliberately in Settings → Alerts.

`GET /api/alerts/history` returns recent notifications **including suppressed
ones with the reason**, which is the only way to tell "the printer never said
anything" apart from "quiet hours ate it".

## Power loss

### Telling a cut apart from a crash

Moonraker reports `klippy_state: shutdown` for a thermal runaway, a failed
homing move and a power cut alike. Treating them the same would cry wolf.

The signal that separates them on a USB printer is the serial device:

```ini
[mcu]
serial: /dev/serial/by-id/usb-1a86_USB_Serial-if00-port0
```

udev creates that symlink when the printer's USB interface enumerates. Kill
mains and the interface disappears, so the symlink is gone within a second or
two. A Klipper firmware error unplugs nothing, so the device is still there.

The path is read from **your** `printer.cfg`, not assumed. On a printer whose
MCU is not on USB — CAN bus, network — there is no device to watch, and the
backend says so rather than reporting every shutdown as a power cut.

### When the outage takes the Pi too

Then nothing local is left to report anything. Two answers, and you want both:

**1. The in-flight print is mirrored to disk.** While a print runs, its
filename, layer, height and progress are written to
`~/printer_data/neptune_remote/state/inflight-print.json` — atomically, with
`fsync`, so a cut mid-write leaves either the old file or the new one. A clean
shutdown deletes it. So if it is there on the next boot, something interrupted
a running print, and the backend can say exactly what died and at which layer.
Comparing the file's timestamp against `/proc/uptime` also tells a *reboot*
apart from a mere `systemctl restart`.

**2. A heartbeat.** The Pi pings an outside URL on a schedule; that service
raises the alarm when the pings stop. [healthchecks.io](https://healthchecks.io)
is free and this is its entire product.

```yaml
notifications:
  heartbeat:
    enabled: true
    url: "https://hc-ping.com/your-uuid-here"
    interval_seconds: 300
```

Set the check's period slightly above `interval_seconds` and give it a grace
period. The heartbeat says **"the Pi is alive"** and nothing else — not that
the printer is fine. Conflating the two would make it useless for its one job.

### There is no resume, and the app does not offer one

Klipper has no power-loss recovery. `M413` is Marlin; the G-code validator
rejects it and says why.

Worse, on this printer specifically:

```ini
[stepper_z]
endstop_pin: probe:z_virtual_endstop
[safe_z_home]
home_xy_position: 160,160
```

After a cut the position is unknown, so any resume must `G28` first — which
drives the nozzle down at X160 Y160, the middle of the bed, into the part still
stuck there. Community "resume after power loss" macros do exactly this. The
outage card therefore has no resume button and its advice is always: **clear
the bed before any movement command.**

### Hardware that actually helps

| | Saves the print | Saves the SD card | Cost |
| --- | --- | --- | --- |
| UPS on the Pi only | no | **yes** | low |
| UPS on everything | yes, briefly | yes | high (the bed alone draws ~300 W) |
| Nothing | no | no | — |

A small 5 V pass-through power bank on the Pi is the high-value option: it does
not save the print, but it stops the abrupt cut from corrupting the SD card —
which is what turns a lost print into a reflash — and it lets the heartbeat and
the outage notification actually go out.

If a smart plug controls the printer, set its **power-on behaviour to Off**, so
mains returning does not power the printer up unattended. And put the Pi on a
separate always-on outlet: on the same plug, the first remote power-off kills
the backend that would have turned it back on.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/alerts/status` | channels, heartbeat, and whether anything reaches you |
| GET/PUT | `/api/alerts/preferences` | which events notify, quiet hours |
| POST | `/api/alerts/test` | real message through every channel, bypassing all filters |
| POST | `/api/alerts/heartbeat/test` | ping now |
| GET | `/api/alerts/history` | recent notifications, including suppressed ones |
| GET | `/api/alerts/outage` | interruption log and what is being tracked |
| POST | `/api/alerts/outage/{id}/acknowledge` | dismiss the card |

The test endpoint bypasses every filter on purpose. A test that quiet hours
could swallow would report success for a message nobody received.
