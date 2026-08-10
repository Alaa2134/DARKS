"""Pan and tilt for an IP camera, over the vendor's HTTP control API.

Only Dahua's CGI is implemented, and that is a deliberate limit rather than a
gap waiting to be filled: every vendor spells this differently, and a path
written from documentation and never run against the hardware is a feature that
looks present and fails in the user's hands. Anything else is refused by name.

Movement is momentary. `start` begins a move and `stop` ends it - the camera
keeps turning until told otherwise, so a button that only sent `start` would
leave the lens pointing at a wall the first time a tap was missed.

Credentials come from the RTSP URL that is already configured. The camera has
one username and password; asking for them twice is two chances to get them
wrong and a second place for them to leak.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Optional
from urllib.parse import quote, urlsplit, unquote

import httpx

from ..config import CameraConfig

log = logging.getLogger("neptune.camera.ptz")

#: What the app may ask for, mapped to Dahua's own direction codes.
DAHUA_DIRECTIONS = {
    "up": "Up",
    "down": "Down",
    "left": "Left",
    "right": "Right",
    "up_left": "LeftUp",
    "up_right": "RightUp",
    "down_left": "LeftDown",
    "down_right": "RightDown",
    # Optical zoom, on the models that have the motor for it. Most indoor
    # pan-and-tilt cameras do not, and answer with an error - which is
    # reported rather than swallowed, because "nothing happened" is the one
    # response that leaves somebody pressing a button forever.
    "zoom_in": "ZoomTele",
    "zoom_out": "ZoomWide",
}

SUPPORTED_VENDORS = {"dahua"}


class PTZError(Exception):
    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


@dataclass
class PTZTarget:
    base_url: str
    username: str
    password: str

    @property
    def configured(self) -> bool:
        return bool(self.base_url)


def target_from(config: CameraConfig) -> PTZTarget:
    """Where to send control commands, derived from what is already set up.

    `ptz_url` wins when set - some installations put the camera's web interface
    on a different host or port from its RTSP service. Otherwise the host and
    credentials are taken from `rtsp_url`, which is the common case and needs
    no extra configuration at all.
    """
    explicit = (config.ptz_url or "").strip()
    if explicit:
        parts = urlsplit(explicit)
        return PTZTarget(
            base_url=f"{parts.scheme or 'http'}://{parts.hostname or ''}"
                     + (f":{parts.port}" if parts.port else ""),
            username=unquote(parts.username or ""),
            password=unquote(parts.password or ""),
        )

    rtsp = (config.rtsp_url or "").strip()
    if not rtsp:
        return PTZTarget(base_url="", username="", password="")

    parts = urlsplit(rtsp)
    if not parts.hostname:
        return PTZTarget(base_url="", username="", password="")
    # The camera's web interface is on HTTP, not on the RTSP port.
    return PTZTarget(
        base_url=f"http://{parts.hostname}",
        username=unquote(parts.username or ""),
        password=unquote(parts.password or ""),
    )


class PTZController:
    def __init__(self, config: CameraConfig) -> None:
        self.config = config
        self._client: Optional[httpx.AsyncClient] = None

    async def aclose(self) -> None:
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
            self._client = None

    @property
    def available(self) -> bool:
        return bool(self.config.ptz_enabled) and target_from(self.config).configured

    @property
    def vendor(self) -> str:
        return (self.config.ptz_vendor or "dahua").strip().lower()

    def status(self) -> dict:
        target = target_from(self.config)
        return {
            "available": self.available,
            "vendor": self.vendor,
            # The host, never the credentials.
            "host": urlsplit(target.base_url).hostname or "",
            "directions": sorted(DAHUA_DIRECTIONS),
        }

    async def move(self, direction: str, *, action: str = "start", speed: int = 4) -> None:
        """Start or stop a movement. Raises PTZError with the camera's own words."""
        if not self.config.ptz_enabled:
            raise PTZError("PTZ is switched off in config.yaml (camera.ptz_enabled)")
        if self.vendor not in SUPPORTED_VENDORS:
            raise PTZError(
                f"PTZ vendor '{self.vendor}' is not implemented. "
                f"Only {', '.join(sorted(SUPPORTED_VENDORS))} is."
            )

        code = DAHUA_DIRECTIONS.get(direction.strip().lower())
        if code is None:
            raise PTZError(f"unknown direction '{direction}'")
        if action not in {"start", "stop"}:
            raise PTZError(f"unknown action '{action}'")

        target = target_from(self.config)
        if not target.configured:
            raise PTZError("no camera address: set camera.rtsp_url or camera.ptz_url")

        step = max(1, min(int(speed), 8))
        url = (
            f"{target.base_url}/cgi-bin/ptz.cgi"
            f"?action={action}&channel=0&code={quote(code)}"
            f"&arg1=0&arg2={step}&arg3=0"
        )

        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(timeout=httpx.Timeout(6.0))

        try:
            response = await self._client.get(
                url, auth=httpx.DigestAuth(target.username, target.password)
            )
        except httpx.HTTPError as exc:
            raise PTZError(f"could not reach the camera: {type(exc).__name__}") from exc

        if response.status_code == 401:
            raise PTZError("the camera rejected the username or password")
        if response.status_code >= 400:
            body = response.text.strip()[:200]
            raise PTZError(f"camera returned HTTP {response.status_code}: {body}")

        # Dahua answers 200 with a plain "OK". Anything else is worth
        # surfacing: a model without a zoom motor answers 200 with an error
        # body, and reporting that is the difference between "your camera
        # cannot do this" and a button that silently does nothing.
        text = response.text.strip()
        if text and "ok" not in text.lower():
            raise PTZError(text[:200])
