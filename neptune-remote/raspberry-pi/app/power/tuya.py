"""Tuya / Smart Life Cloud power provider.

Implements Tuya's OpenAPI v2.0 HMAC-SHA256 request signing so no third-party
Tuya SDK is required. Credentials come from ``config.yaml`` / environment and
never leave the Raspberry Pi -- the iOS app only talks to this backend.

Signing rules (Tuya "Cloud Development -> API reference -> Request signature"):

    stringToSign = METHOD \n
                   SHA256(body) \n
                   <signature headers, usually empty> \n
                   /path?sorted&query

    token request    sign = HMAC-SHA256(client_id + t + nonce + stringToSign)
    business request sign = HMAC-SHA256(client_id + access_token + t + nonce + stringToSign)

    sign is uppercase hex.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import time
import uuid
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlencode

import httpx

from ..config import TuyaConfig
from .base import STATE_OFF, STATE_ON, STATE_UNKNOWN, PowerError, PowerProvider, PowerState

log = logging.getLogger("neptune.power.tuya")

EMPTY_BODY_SHA256 = hashlib.sha256(b"").hexdigest()

# Codes that commonly represent the main relay on a Tuya smart plug.
SWITCH_CODE_CANDIDATES = ("switch_1", "switch", "switch_led", "Power")


class TuyaClient:
    """Minimal signed HTTP client for the Tuya OpenAPI."""

    def __init__(self, config: TuyaConfig, *, client: Optional[httpx.AsyncClient] = None) -> None:
        self.config = config
        self._client = client
        self._owns_client = client is None
        self._token: Optional[str] = None
        self._token_expires_at: float = 0.0

    async def _http(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                base_url=self.config.endpoint.rstrip("/"),
                timeout=httpx.Timeout(15.0),
            )
            self._owns_client = True
        return self._client

    async def aclose(self) -> None:
        if self._owns_client and self._client is not None and not self._client.is_closed:
            await self._client.aclose()
        self._client = None

    # ------------------------------------------------------------- signing
    def _sign(self, method: str, url_path: str, body: str, access_token: str = "") -> Dict[str, str]:
        t = str(int(time.time() * 1000))
        nonce = uuid.uuid4().hex
        content_hash = hashlib.sha256(body.encode("utf-8")).hexdigest() if body else EMPTY_BODY_SHA256
        string_to_sign = "\n".join([method.upper(), content_hash, "", url_path])
        payload = self.config.access_id + access_token + t + nonce + string_to_sign
        signature = hmac.new(
            self.config.access_secret.encode("utf-8"),
            payload.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest().upper()

        headers = {
            "client_id": self.config.access_id,
            "sign": signature,
            "t": t,
            "sign_method": "HMAC-SHA256",
            "nonce": nonce,
            "Content-Type": "application/json",
        }
        if access_token:
            headers["access_token"] = access_token
        return headers

    @staticmethod
    def _url_path(path: str, params: Optional[Dict[str, Any]] = None) -> str:
        if not params:
            return path
        ordered = sorted((str(k), str(v)) for k, v in params.items())
        return f"{path}?{urlencode(ordered)}"

    # ------------------------------------------------------------- requests
    async def _raw_request(
        self,
        method: str,
        path: str,
        *,
        params: Optional[Dict[str, Any]] = None,
        body: Optional[Any] = None,
        access_token: str = "",
    ) -> Dict[str, Any]:
        body_str = json.dumps(body, separators=(",", ":"), ensure_ascii=False) if body is not None else ""
        url_path = self._url_path(path, params)
        headers = self._sign(method, url_path, body_str, access_token)

        http = await self._http()
        try:
            response = await http.request(
                method.upper(),
                url_path,
                headers=headers,
                content=body_str.encode("utf-8") if body_str else None,
            )
        except httpx.HTTPError as exc:
            raise PowerError(f"Tuya cloud unreachable: {exc}") from exc

        try:
            data = response.json()
        except ValueError as exc:
            raise PowerError(f"Tuya returned a non-JSON response (HTTP {response.status_code})") from exc

        if not isinstance(data, dict):
            raise PowerError("Unexpected Tuya response format")

        if not data.get("success", False):
            code = data.get("code")
            msg = data.get("msg") or "unknown error"
            raise PowerError(f"Tuya API error {code}: {msg}")

        return data

    async def _access_token(self, force: bool = False) -> str:
        now = time.time()
        if not force and self._token and now < self._token_expires_at - 60:
            return self._token

        data = await self._raw_request("GET", "/v1.0/token", params={"grant_type": 1})
        result = data.get("result") or {}
        token = result.get("access_token")
        if not token:
            raise PowerError("Tuya did not return an access token")
        self._token = str(token)
        self._token_expires_at = now + float(result.get("expire_time") or 7200)
        return self._token

    async def request(
        self,
        method: str,
        path: str,
        *,
        params: Optional[Dict[str, Any]] = None,
        body: Optional[Any] = None,
    ) -> Dict[str, Any]:
        token = await self._access_token()
        try:
            return await self._raw_request(method, path, params=params, body=body, access_token=token)
        except PowerError as exc:
            # 1010 / 1011 -> token invalid or expired: refresh once and retry.
            if "1010" in str(exc) or "1011" in str(exc) or "token" in str(exc).lower():
                token = await self._access_token(force=True)
                return await self._raw_request(
                    method, path, params=params, body=body, access_token=token
                )
            raise

    # --------------------------------------------------------------- device
    async def device_status(self, device_id: str) -> List[Dict[str, Any]]:
        data = await self.request("GET", f"/v1.0/iot-03/devices/{device_id}/status")
        result = data.get("result")
        return result if isinstance(result, list) else []

    async def device_info(self, device_id: str) -> Dict[str, Any]:
        data = await self.request("GET", f"/v1.0/iot-03/devices/{device_id}")
        result = data.get("result")
        return result if isinstance(result, dict) else {}

    async def send_commands(self, device_id: str, commands: List[Dict[str, Any]]) -> bool:
        data = await self.request(
            "POST",
            f"/v1.0/iot-03/devices/{device_id}/commands",
            body={"commands": commands},
        )
        return bool(data.get("result", True))


class TuyaPowerProvider(PowerProvider):
    name = "tuya"

    def __init__(self, config: TuyaConfig, *, client: Optional[TuyaClient] = None) -> None:
        self.config = config
        self.client = client or TuyaClient(config)
        self._resolved_code: Optional[str] = None

    def _validate(self) -> None:
        missing = [
            field
            for field in ("access_id", "access_secret", "device_id", "endpoint")
            if not getattr(self.config, field)
        ]
        if missing:
            raise PowerError(
                "Tuya is enabled but these values are missing from config.yaml: "
                + ", ".join(missing)
            )

    def _pick_switch(self, statuses: List[Dict[str, Any]]) -> Tuple[Optional[str], Optional[bool]]:
        by_code = {str(item.get("code")): item.get("value") for item in statuses if "code" in item}
        preferred = self.config.switch_code
        if preferred and preferred in by_code:
            value = by_code[preferred]
            return preferred, bool(value) if isinstance(value, bool) else None
        for candidate in SWITCH_CODE_CANDIDATES:
            if candidate in by_code:
                value = by_code[candidate]
                return candidate, bool(value) if isinstance(value, bool) else None
        # last resort: first boolean DP whose code starts with "switch"
        for code, value in by_code.items():
            if code.startswith("switch") and isinstance(value, bool):
                return code, value
        return None, None

    async def status(self) -> PowerState:
        self._validate()
        statuses = await self.client.device_status(self.config.device_id)
        code, value = self._pick_switch(statuses)
        if code:
            self._resolved_code = code
        raw = {"status": statuses, "resolved_code": code}
        if value is None:
            return PowerState(
                state=STATE_UNKNOWN,
                available=bool(statuses),
                device=self.config.device_id,
                message=(
                    "Could not find a boolean switch data point on this Tuya device. "
                    "Set tuya.switch_code in config.yaml to one of: "
                    + ", ".join(str(item.get("code")) for item in statuses)
                )
                if statuses
                else "Tuya device returned no status",
                raw=raw,
            )
        return PowerState(
            state=STATE_ON if value else STATE_OFF,
            available=True,
            device=self.config.device_id,
            raw=raw,
        )

    async def _switch(self, on: bool) -> PowerState:
        self._validate()
        code = self._resolved_code or self.config.switch_code or SWITCH_CODE_CANDIDATES[0]
        await self.client.send_commands(self.config.device_id, [{"code": code, "value": on}])
        # Tuya cloud is eventually consistent; report the requested state and let
        # the next status poll confirm it.
        return PowerState(
            state=STATE_ON if on else STATE_OFF,
            available=True,
            device=self.config.device_id,
            message=f"Command sent to Tuya ({code}={'true' if on else 'false'})",
        )

    async def turn_on(self) -> PowerState:
        return await self._switch(True)

    async def turn_off(self) -> PowerState:
        return await self._switch(False)

    async def aclose(self) -> None:
        await self.client.aclose()
