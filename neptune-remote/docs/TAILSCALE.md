# Networking with Tailscale

**Moonraker is never exposed to the public internet.** No port forwarding, no
dynamic DNS, no reverse proxy open to the world. Tailscale gives the phone and
the Pi a private WireGuard network, and everything rides inside it.

## On the Raspberry Pi

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4          # e.g. 100.78.2.66
```

Optional but recommended:

```bash
sudo tailscale up --ssh                       # SSH without opening port 22
sudo tailscale set --auto-update
```

## On the iPhone

Install Tailscale from the App Store, sign in with the same account, leave it
connected. In Neptune Remote → Settings → Raspberry Pi address, enter the
Tailscale IP (or the MagicDNS name, e.g. `pi.tail1234.ts.net`).

## Ports the app uses

| Port | Service | Bound to |
| --- | --- | --- |
| 8710 | Neptune Remote backend | `0.0.0.0` — reachable over Tailscale and LAN |
| 7125 | Moonraker | leave as installed, `127.0.0.1` is fine |
| 80 | Mainsail / nginx | optional |
| 8080 | crowsnest / MJPEG | optional |

The backend talks to Moonraker over loopback, so Moonraker does not need to
listen on any external interface at all.

## Defence in depth

Tailscale is the perimeter, but the backend has its own lock:

```yaml
server:
  api_token: "a-long-random-string"
```

With that set, every `/api` request and the `/ws` socket must present the token
(`X-API-Key` header, or `?token=` for media URLs the system player fetches). The
iOS app stores it in the **Keychain** — never in UserDefaults, never in the App
Group container, and never in the Share Extension.

Generate one with:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

## Checking it works

```bash
# From the Pi
curl -s http://127.0.0.1:8710/api/health

# From the phone's Tailscale IP range
curl -s http://100.78.2.66:8710/api/health
```

The app's **Help → System check** runs the same probes and reports Moonraker,
Klipper, the slicer, the camera, disk space and Tailscale state in one screen.

## If it stops working

| Symptom | Check |
| --- | --- |
| App cannot reach the Pi | `tailscale status` on both ends; the phone's VPN toggle |
| Works on Wi-Fi, not on mobile data | Tailscale is disconnected on the phone |
| `401 Invalid or missing API token` | Token mismatch between `config.yaml` and the app |
| Backend reachable, Moonraker not | `systemctl status moonraker`, then `moonraker.host/port` in `config.yaml` |
