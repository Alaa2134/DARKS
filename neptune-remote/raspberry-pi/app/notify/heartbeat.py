"""A dead man's switch for the Raspberry Pi.

Every other alert in this project has the same blind spot: it runs on the Pi,
so when the Pi loses power it cannot tell anyone. No amount of local cleverness
fixes that - the machine that noticed is the machine that died.

The only way out is to invert the signal. This pings an outside URL on a
schedule; when the pings stop, the outside service raises the alarm. It works
with healthchecks.io (free, and its whole product is this), a self-hosted
Uptime Kuma "push" monitor, or anything that can watch for an absence.

Nothing here needs the printer. The heartbeat keeps beating while Klipper is
down, while a print fails, while Moonraker is restarting - it means one thing
only: *the Pi is alive and the backend is running*. Conflating that with
printer health would make it useless for the one job it has.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any, Dict, Optional

import httpx

from ..config import HeartbeatConfig

log = logging.getLogger("neptune.heartbeat")


class HeartbeatPinger:
    def __init__(self, config: HeartbeatConfig, *, clock=time.time) -> None:
        self.config = config
        self._clock = clock
        self._client: Optional[httpx.AsyncClient] = None
        self.last_ping_at: float = 0.0
        self.last_error: str = ""
        self.success_count: int = 0
        self.failure_count: int = 0

    @property
    def enabled(self) -> bool:
        return bool(self.config.enabled and self.config.url.strip())

    @property
    def interval(self) -> float:
        # A monitor configured with, say, a 10 minute grace period needs pings
        # comfortably inside it. Below a minute is pointless traffic.
        return max(60.0, float(self.config.interval_seconds))

    def _url(self, failing: bool) -> str:
        base = self.config.url.strip().rstrip("/")
        if failing and self.config.fail_suffix:
            return base + self.config.fail_suffix
        return base

    async def _http(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(timeout=self.config.timeout_seconds)
        return self._client

    async def ping(self, *, failing: bool = False, body: str = "") -> bool:
        """One beat. Returns whether it landed; never raises."""
        if not self.enabled:
            return False

        url = self._url(failing)
        method = (self.config.method or "GET").upper()
        try:
            client = await self._http()
            kwargs: Dict[str, Any] = {}
            if body and method != "GET":
                kwargs["content"] = body.encode("utf-8")
            response = await client.request(method, url, **kwargs)
            response.raise_for_status()
            self.last_ping_at = self._clock()
            self.last_error = ""
            self.success_count += 1
            return True
        except Exception as exc:  # noqa: BLE001 - a missed beat is not fatal
            self.last_error = f"{type(exc).__name__}: {exc}"
            self.failure_count += 1
            # Debug, not warning: losing internet for a minute is normal and
            # this would otherwise fill the journal on every hiccup.
            log.debug("heartbeat ping failed: %s", self.last_error)
            return False

    async def run(self) -> None:
        """Beat forever. Cancelled on shutdown."""
        if not self.enabled:
            return
        # An immediate first ping means a restart shows up straight away rather
        # than one interval later.
        await self.ping()
        while True:
            try:
                await asyncio.sleep(self.interval)
                await self.ping()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - the loop outlives any one error
                log.debug("heartbeat loop error", exc_info=True)

    def status(self) -> Dict[str, Any]:
        age = self._clock() - self.last_ping_at if self.last_ping_at else None
        return {
            "enabled": self.enabled,
            "interval_seconds": self.interval if self.enabled else 0,
            "last_ping_at": self.last_ping_at or None,
            "seconds_since_last_ping": age,
            "successes": self.success_count,
            "failures": self.failure_count,
            "last_error": self.last_error,
        }

    async def aclose(self) -> None:
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
