"""Moonraker, webhook and demo power providers + the provider factory."""

from __future__ import annotations

import logging
import time
from typing import Any, Dict, Optional

import httpx

from ..config import AppConfig, WebhookPowerConfig
from ..moonraker import MoonrakerClient, MoonrakerError
from .base import (
    STATE_ERROR,
    STATE_OFF,
    STATE_ON,
    STATE_UNKNOWN,
    NullPowerProvider,
    PowerError,
    PowerProvider,
    PowerState,
)
from .tuya import TuyaPowerProvider

log = logging.getLogger("neptune.power")


# --------------------------------------------------------------------------- #
# Moonraker [power ...] device
# --------------------------------------------------------------------------- #


class MoonrakerPowerProvider(PowerProvider):
    name = "moonraker"

    def __init__(self, client: MoonrakerClient, device: str) -> None:
        self.client = client
        self.device = device

    @staticmethod
    def _map(value: Optional[str]) -> str:
        if value is None:
            return STATE_UNKNOWN
        lowered = value.lower()
        if lowered == "on":
            return STATE_ON
        if lowered == "off":
            return STATE_OFF
        if lowered == "error":
            return STATE_ERROR
        return STATE_UNKNOWN

    async def status(self) -> PowerState:
        try:
            devices = await self.client.power_devices()
        except MoonrakerError as exc:
            raise PowerError(exc.message) from exc

        names = [str(d.get("device")) for d in devices]
        if self.device not in names:
            return PowerState(
                state=STATE_UNKNOWN,
                available=False,
                device=self.device,
                message=(
                    f"Moonraker has no [power {self.device}] section. "
                    f"Available devices: {', '.join(names) if names else 'none'}"
                ),
                raw={"devices": devices},
            )
        entry = next((d for d in devices if str(d.get("device")) == self.device), {})
        return PowerState(
            state=self._map(entry.get("status")),
            available=True,
            device=self.device,
            raw={"device": entry},
        )

    async def _set(self, action: str) -> PowerState:
        try:
            value = await self.client.set_power_device(self.device, action)
        except MoonrakerError as exc:
            raise PowerError(exc.message) from exc
        return PowerState(state=self._map(value), available=True, device=self.device)

    async def turn_on(self) -> PowerState:
        return await self._set("on")

    async def turn_off(self) -> PowerState:
        return await self._set("off")


# --------------------------------------------------------------------------- #
# Generic HTTP webhook
# --------------------------------------------------------------------------- #


def dig(data: Any, dotted: str) -> Any:
    node = data
    if not dotted:
        return node
    for part in dotted.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
            node = node[int(part)]
        else:
            return None
    return node


class WebhookPowerProvider(PowerProvider):
    """Calls user-supplied URLs. Works with Home Assistant, Shelly, Tasmota, ..."""

    name = "webhook"

    def __init__(self, config: WebhookPowerConfig, *, client: Optional[httpx.AsyncClient] = None) -> None:
        self.config = config
        self._client = client
        self._owns_client = client is None

    async def _http(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(timeout=httpx.Timeout(15.0), follow_redirects=True)
            self._owns_client = True
        return self._client

    async def aclose(self) -> None:
        if self._owns_client and self._client is not None and not self._client.is_closed:
            await self._client.aclose()
        self._client = None

    async def _call(self, url: str, body: str, method: Optional[str] = None) -> httpx.Response:
        if not url:
            raise PowerError("Webhook URL is not configured")
        http = await self._http()
        try:
            return await http.request(
                (method or self.config.method or "POST").upper(),
                url,
                headers=self.config.headers or None,
                content=body.encode("utf-8") if body else None,
            )
        except httpx.HTTPError as exc:
            raise PowerError(f"Webhook request failed: {exc}") from exc

    async def status(self) -> PowerState:
        if not self.config.status_url:
            return PowerState(
                state=STATE_UNKNOWN,
                available=bool(self.config.on_url and self.config.off_url),
                message="No status URL configured for the webhook provider",
            )
        response = await self._call(self.config.status_url, "", method="GET")
        if response.status_code >= 400:
            raise PowerError(f"Webhook status returned HTTP {response.status_code}")

        raw: Dict[str, Any]
        try:
            parsed = response.json()
            raw = parsed if isinstance(parsed, dict) else {"value": parsed}
            value = dig(parsed, self.config.status_json_path)
        except ValueError:
            text = response.text.strip()
            raw = {"text": text}
            value = text

        if isinstance(value, bool):
            state = STATE_ON if value else STATE_OFF
        elif value is None:
            state = STATE_UNKNOWN
        else:
            state = STATE_ON if str(value).strip().lower() == self.config.on_value.lower() else STATE_OFF
        return PowerState(state=state, available=True, device="webhook", raw=raw)

    async def turn_on(self) -> PowerState:
        response = await self._call(self.config.on_url, self.config.on_body)
        if response.status_code >= 400:
            raise PowerError(f"Webhook ON returned HTTP {response.status_code}")
        return PowerState(state=STATE_ON, available=True, device="webhook")

    async def turn_off(self) -> PowerState:
        response = await self._call(self.config.off_url, self.config.off_body)
        if response.status_code >= 400:
            raise PowerError(f"Webhook OFF returned HTTP {response.status_code}")
        return PowerState(state=STATE_OFF, available=True, device="webhook")


# --------------------------------------------------------------------------- #
# Demo
# --------------------------------------------------------------------------- #


class DemoPowerProvider(PowerProvider):
    """In-memory switch so the whole stack can be exercised without hardware."""

    name = "demo"

    def __init__(self, initial: bool = True) -> None:
        self._on = initial
        self.last_change = time.time()

    async def status(self) -> PowerState:
        return PowerState(
            state=STATE_ON if self._on else STATE_OFF,
            available=True,
            device="demo-switch",
            raw={"last_change": self.last_change},
        )

    async def turn_on(self) -> PowerState:
        self._on = True
        self.last_change = time.time()
        return await self.status()

    async def turn_off(self) -> PowerState:
        self._on = False
        self.last_change = time.time()
        return await self.status()


# --------------------------------------------------------------------------- #
# Factory
# --------------------------------------------------------------------------- #


def build_power_provider(config: AppConfig, moonraker: MoonrakerClient) -> PowerProvider:
    provider = (config.power.provider or "none").strip().lower()

    if provider == "tuya":
        if not config.tuya.enabled:
            return NullPowerProvider(
                "power.provider is 'tuya' but tuya.enabled is false in config.yaml"
            )
        return TuyaPowerProvider(config.tuya)

    if provider == "moonraker":
        return MoonrakerPowerProvider(moonraker, config.power.moonraker_device)

    if provider == "webhook":
        return WebhookPowerProvider(config.power.webhook)

    if provider == "demo":
        return DemoPowerProvider()

    if provider in {"none", ""}:
        return NullPowerProvider()

    log.warning("Unknown power provider %r, falling back to none", provider)
    return NullPowerProvider(f"Unknown power provider: {provider}")
