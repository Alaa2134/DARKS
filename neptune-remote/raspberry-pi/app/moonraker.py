"""Async Moonraker HTTP client.

Only documented Moonraker endpoints are used:
https://moonraker.readthedocs.io/en/latest/web_api/
"""

from __future__ import annotations

import asyncio

import logging
from typing import Any, Dict, Iterable, List, Optional

import httpx

from .config import MoonrakerConfig

log = logging.getLogger("neptune.moonraker")

# Objects the dashboard needs. Keys map to the field list Moonraker expects
# (None == "give me every field of this object").
DEFAULT_OBJECTS: Dict[str, Optional[List[str]]] = {
    "print_stats": None,
    "display_status": None,
    "virtual_sdcard": None,
    "toolhead": None,
    "extruder": None,
    "heater_bed": None,
    "fan": None,
    "gcode_move": None,
    "idle_timeout": None,
    "webhooks": None,
}


class MoonrakerError(RuntimeError):
    """Raised when Moonraker answers with an error payload or is unreachable."""

    def __init__(self, message: str, status_code: Optional[int] = None) -> None:
        super().__init__(message)
        self.message = message
        self.status_code = status_code


class MoonrakerClient:
    def __init__(self, config: MoonrakerConfig) -> None:
        self.config = config
        self._client: Optional[httpx.AsyncClient] = None

    # ----------------------------------------------------------------- setup
    @property
    def base_url(self) -> str:
        return self.config.base_url

    def _headers(self) -> Dict[str, str]:
        headers = {"Accept": "application/json"}
        if self.config.api_key:
            headers["X-Api-Key"] = self.config.api_key
        return headers

    async def client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                base_url=self.base_url,
                timeout=httpx.Timeout(self.config.timeout_seconds),
                headers=self._headers(),
                follow_redirects=True,
            )
        return self._client

    async def aclose(self) -> None:
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
        self._client = None

    # --------------------------------------------------------------- request
    async def request(
        self,
        method: str,
        path: str,
        *,
        params: Optional[Dict[str, Any]] = None,
        json_body: Optional[Any] = None,
        content: Optional[bytes] = None,
        files: Optional[Any] = None,
        data: Optional[Dict[str, Any]] = None,
        timeout: Optional[float] = None,
    ) -> Any:
        client = await self.client()
        try:
            response = await client.request(
                method,
                path,
                params=params,
                json=json_body,
                content=content,
                files=files,
                data=data,
                timeout=timeout or self.config.timeout_seconds,
            )
        except httpx.HTTPError as exc:  # connection refused, DNS, timeout ...
            raise MoonrakerError(f"Moonraker unreachable at {self.base_url}: {exc}") from exc

        payload: Any
        if response.headers.get("content-type", "").startswith("application/json"):
            try:
                payload = response.json()
            except ValueError:
                payload = None
        else:
            payload = None

        if response.status_code >= 400:
            message = f"HTTP {response.status_code}"
            if isinstance(payload, dict):
                err = payload.get("error")
                if isinstance(err, dict):
                    message = str(err.get("message") or err)
                elif err:
                    message = str(err)
                elif "message" in payload:
                    message = str(payload["message"])
            raise MoonrakerError(message, response.status_code)

        if isinstance(payload, dict) and "result" in payload:
            return payload["result"]
        if payload is None:
            return response.content
        return payload

    # ------------------------------------------------------------- read APIs
    async def server_info(self) -> Dict[str, Any]:
        return await self.request("GET", "/server/info")

    async def printer_info(self) -> Dict[str, Any]:
        return await self.request("GET", "/printer/info")

    async def list_objects(self) -> List[str]:
        result = await self.request("GET", "/printer/objects/list")
        return list(result.get("objects", [])) if isinstance(result, dict) else []

    async def query_objects(
        self, objects: Optional[Dict[str, Optional[List[str]]]] = None
    ) -> Dict[str, Any]:
        """POST /printer/objects/query - returns the ``status`` mapping."""
        payload = {"objects": objects if objects is not None else DEFAULT_OBJECTS}
        result = await self.request("POST", "/printer/objects/query", json_body=payload)
        if isinstance(result, dict):
            return result.get("status", {})
        return {}

    async def query_status(self) -> Dict[str, Any]:
        return await self.query_objects(DEFAULT_OBJECTS)

    # ---------------------------------------------------------- print control
    async def run_gcode(self, script: str) -> Any:
        return await self.request("POST", "/printer/gcode/script", params={"script": script})

    async def start_print(self, filename: str) -> Any:
        return await self.request("POST", "/printer/print/start", params={"filename": filename})

    async def pause_print(self) -> Any:
        return await self.request("POST", "/printer/print/pause")

    async def resume_print(self) -> Any:
        return await self.request("POST", "/printer/print/resume")

    async def cancel_print(self) -> Any:
        return await self.request("POST", "/printer/print/cancel")

    async def emergency_stop(self) -> Any:
        return await self.request("POST", "/printer/emergency_stop")

    async def restart_klipper(self) -> Any:
        return await self.request("POST", "/printer/restart")

    async def restart_firmware(self) -> Any:
        return await self.request("POST", "/printer/firmware_restart")

    async def restart_service(self, service: str) -> Any:
        return await self.request("POST", "/machine/services/restart", params={"service": service})

    async def host_action(self, action: str) -> Any:
        """action is one of: shutdown, reboot."""
        if action not in {"shutdown", "reboot"}:
            raise MoonrakerError(f"Unsupported host action: {action}")
        return await self.request("POST", f"/machine/{action}")

    # ------------------------------------------------------- config & logs
    async def read_config_file(self, name: str = "printer.cfg") -> str:
        """Fetch a file from Moonraker's ``config`` root.

        This is the live config Klipper is actually running, which is the only
        thing the safety engine is allowed to trust for travel limits.
        """
        data = await self.download_file(f"config/{name}")
        return data.decode("utf-8", errors="replace")

    async def write_config_file(self, name: str, text: str) -> Any:
        """Upload a config file. Callers must have taken a backup first - the
        safety engine and the config router both enforce that."""
        client = await self.client()
        files = {"file": (name, text.encode("utf-8"), "text/plain")}
        response = await client.post(
            "/server/files/upload",
            files=files,
            data={"root": "config", "path": ""},
            headers=self._headers(),
        )
        if response.status_code >= 400:
            raise MoonrakerError(
                f"Could not write {name}: {response.text[:200]}", response.status_code
            )
        return response.json().get("result", {})

    async def config_files(self) -> List[Dict[str, Any]]:
        result = await self.request("GET", "/server/files/list", params={"root": "config"})
        return result if isinstance(result, list) else []

    async def download_file(self, relative_path: str) -> bytes:
        client = await self.client()
        response = await client.get(f"/server/files/{relative_path}", headers=self._headers())
        if response.status_code >= 400:
            raise MoonrakerError(
                f"Could not read {relative_path}", response.status_code
            )
        return response.content

    async def klipper_log_tail(self, lines: int = 200) -> List[str]:
        """Last lines of klippy.log. Returns [] when the log is unavailable
        rather than raising - a missing log must not break a diagnosis."""
        return await self._log_tail("klippy.log", lines)

    async def moonraker_log_tail(self, lines: int = 200) -> List[str]:
        return await self._log_tail("moonraker.log", lines)

    async def _log_tail(self, name: str, lines: int) -> List[str]:
        try:
            data = await self.download_file(f"logs/{name}")
        except (MoonrakerError, httpx.HTTPError):
            return []
        text = data.decode("utf-8", errors="replace")
        return text.splitlines()[-lines:]

    # ------------------------------------------------------ gcode responses
    async def gcode_help(self) -> Dict[str, str]:
        result = await self.request("GET", "/printer/gcode/help")
        return result if isinstance(result, dict) else {}

    async def gcode_store(self, count: int = 100) -> List[Dict[str, Any]]:
        """Moonraker's rolling buffer of console output.

        This is how the app reads the *result* of a command such as
        SCREWS_TILT_CALCULATE or QUERY_PROBE: the REST call that runs the
        command returns only "ok", and the answer arrives as console text.
        """
        result = await self.request(
            "GET", "/server/gcode_store", params={"count": count}
        )
        if isinstance(result, dict):
            store = result.get("gcode_store", [])
            return store if isinstance(store, list) else []
        return []

    async def run_gcode_and_collect(
        self,
        script: str,
        *,
        settle: float = 0.35,
        count: int = 60,
    ) -> str:
        """Run ``script`` and return the console output it produced.

        Works by noting where the console buffer ends, running the command, then
        reading the lines that appeared after that point. ``settle`` gives
        Klipper a moment to finish writing before the buffer is read; long
        operations should poll :meth:`gcode_store` themselves instead.
        """
        before = await self.gcode_store(count=count)
        marker = before[-1].get("time") if before else None

        await self.run_gcode(script)
        await asyncio.sleep(settle)

        after = await self.gcode_store(count=count)
        fresh: List[str] = []
        for entry in after:
            if marker is not None and entry.get("time", 0) <= marker:
                continue
            message = entry.get("message", "")
            if message:
                fresh.append(message)
        return "\n".join(fresh)

    # ----------------------------------------------------------------- files
    async def list_gcodes(self, root: str = "gcodes") -> List[Dict[str, Any]]:
        result = await self.request("GET", "/server/files/list", params={"root": root})
        return result if isinstance(result, list) else []

    async def metadata(self, filename: str) -> Dict[str, Any]:
        return await self.request("GET", "/server/files/metadata", params={"filename": filename})

    async def delete_gcode(self, path: str) -> Any:
        clean = path.lstrip("/")
        return await self.request("DELETE", f"/server/files/gcodes/{clean}")

    async def upload_gcode(
        self,
        filename: str,
        content: bytes,
        *,
        root: str = "gcodes",
        path: str = "",
        start_print: bool = False,
    ) -> Dict[str, Any]:
        files = {"file": (filename, content, "application/octet-stream")}
        data: Dict[str, Any] = {"root": root, "print": "true" if start_print else "false"}
        if path:
            data["path"] = path
        result = await self.request(
            "POST", "/server/files/upload", files=files, data=data, timeout=300.0
        )
        return result if isinstance(result, dict) else {}

    async def download_gcode(self, path: str) -> bytes:
        client = await self.client()
        clean = path.lstrip("/")
        try:
            response = await client.get(f"/server/files/gcodes/{clean}", timeout=300.0)
        except httpx.HTTPError as exc:
            raise MoonrakerError(f"Moonraker unreachable: {exc}") from exc
        if response.status_code >= 400:
            raise MoonrakerError(f"HTTP {response.status_code}", response.status_code)
        return response.content

    async def thumbnail(self, relative_path: str) -> bytes:
        """Thumbnails are served from the gcodes root at the path reported in metadata."""
        return await self.download_gcode(relative_path)

    # ---------------------------------------------------------- power devices
    async def power_devices(self) -> List[Dict[str, Any]]:
        result = await self.request("GET", "/machine/device_power/devices")
        if isinstance(result, dict):
            return list(result.get("devices", []))
        return []

    async def power_device_status(self, device: str) -> Optional[str]:
        result = await self.request(
            "GET", "/machine/device_power/device", params={"device": device}
        )
        if isinstance(result, dict):
            value = result.get(device)
            return str(value) if value is not None else None
        return None

    async def set_power_device(self, device: str, action: str) -> Optional[str]:
        if action not in {"on", "off", "toggle"}:
            raise MoonrakerError(f"Unsupported power action: {action}")
        result = await self.request(
            "POST", "/machine/device_power/device", params={"device": device, "action": action}
        )
        if isinstance(result, dict):
            value = result.get(device)
            return str(value) if value is not None else None
        return None

    # ------------------------------------------------------------ convenience
    async def is_reachable(self) -> bool:
        try:
            await self.server_info()
            return True
        except MoonrakerError:
            return False


def flatten_temperatures(status: Dict[str, Any]) -> Dict[str, float]:
    """Pull the four temperature numbers out of a printer objects status blob."""
    extruder = status.get("extruder") or {}
    bed = status.get("heater_bed") or {}
    return {
        "nozzle_actual": float(extruder.get("temperature") or 0.0),
        "nozzle_target": float(extruder.get("target") or 0.0),
        "bed_actual": float(bed.get("temperature") or 0.0),
        "bed_target": float(bed.get("target") or 0.0),
    }


def progress_from_status(status: Dict[str, Any]) -> float:
    """Progress 0..1 preferring display_status, falling back to virtual_sdcard."""
    display = status.get("display_status") or {}
    if isinstance(display.get("progress"), (int, float)):
        return max(0.0, min(1.0, float(display["progress"])))
    sdcard = status.get("virtual_sdcard") or {}
    if isinstance(sdcard.get("progress"), (int, float)):
        return max(0.0, min(1.0, float(sdcard["progress"])))
    return 0.0


def object_names(objects: Iterable[str], prefix: str) -> List[str]:
    return [name for name in objects if name == prefix or name.startswith(prefix + " ")]
