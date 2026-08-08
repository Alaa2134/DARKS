# Tuya / Smart Life power control

The smart plug that feeds the printer is switched through the Tuya Cloud API.

**The Tuya Access Secret never goes into the iOS app.** It lives only in
`config.yaml` on the Raspberry Pi, which is git-ignored. The app calls
`POST /api/power/on` on your own backend; the backend signs the Tuya request.

## 1. Create a Tuya IoT project

1. Sign up at <https://iot.tuya.com> (free tier is enough).
2. **Cloud → Development → Create Cloud Project**.
   * Development Method: *Smart Home*
   * Data Centre: the one matching your Smart Life account region
     (Central Europe, Western America, China, India…). Picking the wrong one is
     the single most common cause of `1106 permission deny`.
3. Open the project → **Devices → Link App Account** → *Add App Account*, and
   scan the QR code from the Smart Life / Tuya Smart app.
   Your plug should now appear under **Devices → All Devices**.
4. **Service API → Go to Authorize** and enable at least:
   * *IoT Core*
   * *Authorization Token Management*
   * *Smart Home Scene Linkage* (optional)

## 2. Collect three values

| Value | Where |
| --- | --- |
| Access ID | Project → Overview → *Access ID/Client ID* |
| Access Secret | Project → Overview → *Access Secret/Client Secret* |
| Device ID | Devices → All Devices → your plug → *Device ID* |

## 3. Put them on the Pi only

```yaml
# /opt/neptune-remote/config.yaml   (git-ignored)
power:
  provider: "tuya"
  tuya:
    endpoint: "https://openapi.tuyaeu.com"   # match your data centre
    access_id: "..."
    access_secret: "..."
    device_id: "..."
    switch_code: "switch_1"                  # some plugs use "switch"
```

Or through the environment, if you prefer `.env`:

```bash
NEPTUNE_TUYA_ACCESS_ID=...
NEPTUNE_TUYA_ACCESS_SECRET=...
NEPTUNE_TUYA_DEVICE_ID=...
```

Endpoints by region:

| Region | Endpoint |
| --- | --- |
| Central Europe | `https://openapi.tuyaeu.com` |
| Western America | `https://openapi.tuyaus.com` |
| China | `https://openapi.tuyacn.com` |
| India | `https://openapi.tuyain.com` |

Then:

```bash
sudo systemctl restart neptune-remote
curl -s http://127.0.0.1:8710/api/power/status
```

## 4. Safety rules the backend enforces

Power **off** is refused when:

* a print is running or paused,
* the nozzle is above 50 °C,
* the bed is above 45 °C.

The app shows exactly which rule blocked it. A forced power-off exists, but only
behind an explicit confirmation dialog that names the blockers.

Power **on** never starts a print. After AC returns, the printer boots into
standby and waits for you — including when a queued job is sitting there.

## Alternatives to Tuya

`power.provider` also accepts:

* `moonraker` — a `[power printer]` section in `moonraker.conf` (Tasmota, Shelly,
  GPIO, klipper-power). Nothing else to configure beyond `moonraker_device`.
* `webhook` — any URL you can hit; useful for Home Assistant or Node-RED.
* `demo` — an in-memory switch for trying the app out.
* `none` — power control hidden entirely.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `1106 permission deny` | Wrong data centre, or the app account is not linked |
| `1004 sign invalid` | Access Secret wrong, or the Pi's clock is off — run `timedatectl` |
| `device not found` | Device ID belongs to a different project |
| Status says `unknown` | The plug reports a status code other than `switch_code` |

The backend never reports "on" when the API call failed. If Tuya is unreachable,
the state is `unknown` and the reason is passed through to the app verbatim.
