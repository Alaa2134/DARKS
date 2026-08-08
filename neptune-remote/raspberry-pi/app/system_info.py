"""Raspberry Pi system metrics.

``psutil`` is used when installed; every value degrades gracefully to a /proc
based reading (or 0) so the endpoint never fails.
"""

from __future__ import annotations

import json
import os
import platform
import re
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import List, Optional

from .schemas import SystemResponse, TailscaleStatus

try:  # optional dependency
    import psutil  # type: ignore
except Exception:  # pragma: no cover - psutil missing
    psutil = None  # type: ignore

THERMAL_PATHS = (
    "/sys/class/thermal/thermal_zone0/temp",
    "/sys/devices/virtual/thermal/thermal_zone0/temp",
)


def cpu_temperature() -> Optional[float]:
    for path in THERMAL_PATHS:
        try:
            raw = Path(path).read_text(encoding="utf-8").strip()
            value = float(raw)
            return value / 1000.0 if value > 200 else value
        except (OSError, ValueError):
            continue
    if psutil is not None:
        try:
            temps = psutil.sensors_temperatures()  # type: ignore[attr-defined]
            for entries in temps.values():
                for entry in entries:
                    if entry.current:
                        return float(entry.current)
        except Exception:
            pass
    return None


def pi_model() -> str:
    try:
        return Path("/proc/device-tree/model").read_text(encoding="utf-8").strip("\x00").strip()
    except OSError:
        return ""


def uptime_seconds() -> float:
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as handle:
            return float(handle.readline().split()[0])
    except (OSError, ValueError, IndexError):
        if psutil is not None:
            try:
                return time.time() - psutil.boot_time()
            except Exception:
                pass
        return 0.0


def load_average() -> List[float]:
    try:
        return [round(value, 2) for value in os.getloadavg()]
    except (OSError, AttributeError):
        return []


def memory() -> tuple[float, float, float]:
    if psutil is not None:
        try:
            mem = psutil.virtual_memory()
            return (
                mem.total / 1048576.0,
                (mem.total - mem.available) / 1048576.0,
                float(mem.percent),
            )
        except Exception:
            pass
    try:
        values = {}
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            key, _, rest = line.partition(":")
            values[key.strip()] = float(rest.strip().split()[0]) / 1024.0  # MB
        total = values.get("MemTotal", 0.0)
        available = values.get("MemAvailable", values.get("MemFree", 0.0))
        used = max(0.0, total - available)
        percent = (used / total * 100.0) if total else 0.0
        return total, used, percent
    except (OSError, ValueError, IndexError):
        return 0.0, 0.0, 0.0


def disk(path: str = "/") -> tuple[float, float, float]:
    try:
        usage = shutil.disk_usage(path)
        total = usage.total / 1073741824.0
        used = usage.used / 1073741824.0
        percent = (usage.used / usage.total * 100.0) if usage.total else 0.0
        return total, used, percent
    except OSError:
        return 0.0, 0.0, 0.0


def cpu_percent() -> float:
    if psutil is not None:
        try:
            return float(psutil.cpu_percent(interval=None))
        except Exception:
            pass
    loads = load_average()
    if loads:
        cores = os.cpu_count() or 1
        return min(100.0, loads[0] / cores * 100.0)
    return 0.0


def ip_addresses() -> List[str]:
    addresses: List[str] = []
    if psutil is not None:
        try:
            for name, entries in psutil.net_if_addrs().items():
                for entry in entries:
                    if entry.family == socket.AF_INET and not entry.address.startswith("127."):
                        addresses.append(f"{name}: {entry.address}")
        except Exception:
            pass
    if not addresses:
        try:
            output = subprocess.run(
                ["hostname", "-I"], capture_output=True, text=True, timeout=5
            ).stdout
            addresses = [addr for addr in output.split() if addr]
        except (OSError, subprocess.SubprocessError):
            pass
    return addresses


def throttled_state() -> Optional[str]:
    """``vcgencmd get_throttled`` decodes under-voltage / thermal throttling."""
    binary = shutil.which("vcgencmd")
    if binary is None:
        return None
    try:
        output = subprocess.run(
            [binary, "get_throttled"], capture_output=True, text=True, timeout=5
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"0x([0-9a-fA-F]+)", output)
    if not match:
        return None
    value = int(match.group(1), 16)
    if value == 0:
        return "ok"
    flags = []
    if value & 0x1:
        flags.append("under-voltage now")
    if value & 0x4:
        flags.append("throttled now")
    if value & 0x8:
        flags.append("soft temp limit now")
    if value & 0x10000:
        flags.append("under-voltage occurred")
    if value & 0x40000:
        flags.append("throttling occurred")
    return ", ".join(flags) or hex(value)


def tailscale_status() -> TailscaleStatus:
    binary = shutil.which("tailscale")
    if binary is None:
        return TailscaleStatus(installed=False)
    try:
        result = subprocess.run(
            [binary, "status", "--json"], capture_output=True, text=True, timeout=8
        )
    except (OSError, subprocess.SubprocessError):
        return TailscaleStatus(installed=True, running=False)

    if result.returncode != 0 or not result.stdout.strip():
        return TailscaleStatus(installed=True, running=False, backend_state="Stopped")

    try:
        data = json.loads(result.stdout)
    except ValueError:
        return TailscaleStatus(installed=True, running=False)

    self_node = data.get("Self") or {}
    backend_state = str(data.get("BackendState") or "")
    return TailscaleStatus(
        installed=True,
        running=backend_state == "Running",
        hostname=str(self_node.get("HostName") or ""),
        ips=[str(ip) for ip in (self_node.get("TailscaleIPs") or [])],
        backend_state=backend_state,
    )


def collect() -> SystemResponse:
    total_mem, used_mem, mem_percent = memory()
    total_disk, used_disk, disk_percent = disk()
    return SystemResponse(
        hostname=socket.gethostname(),
        platform=f"{platform.system()} {platform.release()} ({platform.machine()})",
        model=pi_model(),
        cpu_percent=round(cpu_percent(), 1),
        cpu_temp_c=cpu_temperature(),
        load_average=load_average(),
        memory_total_mb=round(total_mem, 1),
        memory_used_mb=round(used_mem, 1),
        memory_percent=round(mem_percent, 1),
        disk_total_gb=round(total_disk, 2),
        disk_used_gb=round(used_disk, 2),
        disk_percent=round(disk_percent, 1),
        uptime_seconds=uptime_seconds(),
        ip_addresses=ip_addresses(),
        tailscale=tailscale_status(),
        throttled=throttled_state(),
    )
