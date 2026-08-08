# Notifications, widget and Live Activity

All notifications are **local**. Nothing is registered with APNs, no push token
is uploaded, and no server of ours exists. The app watches printer state over
its own socket and posts a `UNNotificationRequest` itself.

The trade-off is honest and worth stating: local notifications need the app to
be running or recently backgrounded. A phone that has been asleep for hours will
show the print-finished notification when the app next wakes, not the instant it
happened. The Live Activity covers the gap for the print you are actually
watching.

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

Klipper errors, print failures and monitor alerts use
`interruptionLevel = .timeSensitive` with the critical sound, so they cut
through a Focus mode. The rest are ordinary.

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
