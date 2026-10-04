from __future__ import annotations

import hashlib
import hmac

import httpx
import pytest

from app.config import AppConfig, PowerSafetyConfig, TuyaConfig, WebhookPowerConfig
from app.moonraker import MoonrakerClient
from app.power import (
    DemoPowerProvider,
    MoonrakerPowerProvider,
    NullPowerProvider,
    PowerError,
    TuyaClient,
    TuyaPowerProvider,
    WebhookPowerProvider,
    build_power_provider,
    evaluate_power_off,
)
from app.power.providers import dig
from app.schemas import PrinterStatusResponse, TemperatureBlock


# --------------------------------------------------------------------------- #
# Safety
# --------------------------------------------------------------------------- #


def status(*, state="standby", nozzle=25.0, bed=22.0, online=True) -> PrinterStatusResponse:
    return PrinterStatusResponse(
        online=online,
        state=state,
        nozzle=TemperatureBlock(actual=nozzle, target=0.0),
        bed=TemperatureBlock(actual=bed, target=0.0),
    )


def test_cold_idle_printer_is_safe_to_power_off():
    report = evaluate_power_off(status(), PowerSafetyConfig())
    assert report.safe is True
    assert report.blockers == []


def test_hot_nozzle_blocks_power_off():
    report = evaluate_power_off(status(nozzle=180.0), PowerSafetyConfig())
    assert report.safe is False
    assert any("Nozzle" in blocker for blocker in report.blockers)


def test_hot_bed_blocks_power_off():
    report = evaluate_power_off(status(bed=60.0), PowerSafetyConfig())
    assert report.safe is False
    assert any("Bed" in blocker for blocker in report.blockers)


def test_printing_blocks_power_off():
    report = evaluate_power_off(status(state="printing"), PowerSafetyConfig())
    assert report.safe is False
    assert any("print" in blocker.lower() for blocker in report.blockers)


def test_paused_also_blocks_power_off():
    report = evaluate_power_off(status(state="paused"), PowerSafetyConfig())
    assert report.safe is False


def test_configurable_thresholds_are_respected():
    lenient = PowerSafetyConfig(max_nozzle_temp=200, max_bed_temp=100)
    assert evaluate_power_off(status(nozzle=180.0, bed=60.0), lenient).safe is True


def test_offline_printer_warns_but_does_not_block():
    report = evaluate_power_off(status(online=False), PowerSafetyConfig())
    assert report.safe is True
    assert report.warnings


def test_disabled_safety_always_allows():
    report = evaluate_power_off(
        status(state="printing", nozzle=250.0), PowerSafetyConfig(enabled=False)
    )
    assert report.safe is True


def test_active_targets_produce_a_warning():
    hot_target = PrinterStatusResponse(
        online=True,
        state="standby",
        nozzle=TemperatureBlock(actual=30.0, target=200.0),
        bed=TemperatureBlock(actual=25.0, target=0.0),
    )
    report = evaluate_power_off(hot_target, PowerSafetyConfig())
    assert report.safe is True
    assert any("target" in warning.lower() for warning in report.warnings)


# --------------------------------------------------------------------------- #
# Providers
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_demo_provider_round_trip():
    provider = DemoPowerProvider(initial=False)
    assert (await provider.status()).state == "off"
    assert (await provider.turn_on()).state == "on"
    assert (await provider.status()).state == "on"
    assert (await provider.turn_off()).state == "off"


@pytest.mark.asyncio
async def test_null_provider_reports_unavailable_and_refuses():
    provider = NullPowerProvider()
    state = await provider.status()
    assert state.available is False
    assert state.state == "unknown"
    with pytest.raises(PowerError):
        await provider.turn_on()


@pytest.mark.asyncio
async def test_moonraker_power_provider_reads_and_sets():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/machine/device_power/devices":
            return httpx.Response(
                200, json={"result": {"devices": [{"device": "printer", "status": "on"}]}}
            )
        return httpx.Response(200, json={"result": {"printer": "off"}})

    client = MoonrakerClient(AppConfig().moonraker)
    client._client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), base_url="http://testserver"
    )
    provider = MoonrakerPowerProvider(client, "printer")
    assert (await provider.status()).state == "on"
    assert (await provider.turn_off()).state == "off"
    await client.aclose()


@pytest.mark.asyncio
async def test_moonraker_power_provider_reports_missing_device():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"result": {"devices": []}})

    client = MoonrakerClient(AppConfig().moonraker)
    client._client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), base_url="http://testserver"
    )
    state = await MoonrakerPowerProvider(client, "printer").status()
    assert state.available is False
    assert "no [power printer]" in state.message
    await client.aclose()


@pytest.mark.asyncio
async def test_webhook_provider_parses_nested_json_state():
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(f"{request.method} {request.url}")
        if "status" in str(request.url):
            return httpx.Response(200, json={"data": {"relay": "ON"}})
        return httpx.Response(200, json={"ok": True})

    config = WebhookPowerConfig(
        on_url="http://plug/on",
        off_url="http://plug/off",
        status_url="http://plug/status",
        status_json_path="data.relay",
        on_value="on",
    )
    provider = WebhookPowerProvider(
        config, client=httpx.AsyncClient(transport=httpx.MockTransport(handler))
    )
    assert (await provider.status()).state == "on"
    assert (await provider.turn_off()).state == "off"
    assert any("/off" in call for call in calls)


def test_dig_walks_dotted_paths():
    assert dig({"a": {"b": [1, 2, 3]}}, "a.b.1") == 2
    assert dig({"a": 1}, "a.b") is None
    assert dig({"a": 1}, "") == {"a": 1}


# --------------------------------------------------------------------------- #
# Tuya
# --------------------------------------------------------------------------- #


TUYA = TuyaConfig(
    enabled=True,
    access_id="test-id",
    access_secret="test-secret",
    device_id="dev123",
    endpoint="https://openapi.tuyaeu.com",
    switch_code="switch_1",
)


def expected_sign(payload: str) -> str:
    return hmac.new(b"test-secret", payload.encode(), hashlib.sha256).hexdigest().upper()


def test_tuya_signature_follows_the_documented_algorithm():
    client = TuyaClient(TUYA)
    headers = client._sign("GET", "/v1.0/token?grant_type=1", "")
    empty_hash = hashlib.sha256(b"").hexdigest()
    string_to_sign = "\n".join(["GET", empty_hash, "", "/v1.0/token?grant_type=1"])
    payload = "test-id" + headers["t"] + headers["nonce"] + string_to_sign
    assert headers["sign"] == expected_sign(payload)
    assert headers["sign_method"] == "HMAC-SHA256"
    assert headers["client_id"] == "test-id"
    assert "access_token" not in headers


def test_tuya_business_signature_includes_the_token():
    client = TuyaClient(TUYA)
    headers = client._sign("POST", "/v1.0/iot-03/devices/dev123/commands", '{"a":1}', "tok")
    body_hash = hashlib.sha256(b'{"a":1}').hexdigest()
    string_to_sign = "\n".join(
        ["POST", body_hash, "", "/v1.0/iot-03/devices/dev123/commands"]
    )
    payload = "test-id" + "tok" + headers["t"] + headers["nonce"] + string_to_sign
    assert headers["sign"] == expected_sign(payload)
    assert headers["access_token"] == "tok"


def test_tuya_query_parameters_are_sorted():
    assert TuyaClient._url_path("/v1.0/x", {"b": 2, "a": 1}) == "/v1.0/x?a=1&b=2"
    assert TuyaClient._url_path("/v1.0/x", None) == "/v1.0/x"


@pytest.mark.asyncio
async def test_tuya_provider_status_and_commands():
    sent: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1.0/token":
            return httpx.Response(
                200,
                json={"success": True, "result": {"access_token": "tok", "expire_time": 7200}},
            )
        if request.url.path.endswith("/status"):
            return httpx.Response(
                200,
                json={
                    "success": True,
                    "result": [
                        {"code": "switch_1", "value": True},
                        {"code": "countdown_1", "value": 0},
                    ],
                },
            )
        if request.url.path.endswith("/commands"):
            import json as _json

            sent.append(_json.loads(request.content.decode()))
            return httpx.Response(200, json={"success": True, "result": True})
        return httpx.Response(404, json={"success": False, "msg": "not found"})

    tuya_client = TuyaClient(
        TUYA, client=httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url=TUYA.endpoint)
    )
    provider = TuyaPowerProvider(TUYA, client=tuya_client)

    state = await provider.status()
    assert state.state == "on"
    assert state.available is True

    off = await provider.turn_off()
    assert off.state == "off"
    assert sent == [{"commands": [{"code": "switch_1", "value": False}]}]


@pytest.mark.asyncio
async def test_tuya_api_error_is_surfaced():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"success": False, "code": 1106, "msg": "permission deny"})

    tuya_client = TuyaClient(
        TUYA, client=httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url=TUYA.endpoint)
    )
    provider = TuyaPowerProvider(TUYA, client=tuya_client)
    with pytest.raises(PowerError) as excinfo:
        await provider.status()
    assert "1106" in str(excinfo.value)


@pytest.mark.asyncio
async def test_tuya_missing_credentials_are_reported_clearly():
    provider = TuyaPowerProvider(TuyaConfig(enabled=True))
    with pytest.raises(PowerError) as excinfo:
        await provider.status()
    assert "access_id" in str(excinfo.value)


@pytest.mark.asyncio
async def test_tuya_unknown_switch_code_is_explained():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1.0/token":
            return httpx.Response(
                200, json={"success": True, "result": {"access_token": "t", "expire_time": 100}}
            )
        return httpx.Response(
            200, json={"success": True, "result": [{"code": "cur_power", "value": 12}]}
        )

    tuya_client = TuyaClient(
        TUYA, client=httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url=TUYA.endpoint)
    )
    state = await TuyaPowerProvider(TUYA, client=tuya_client).status()
    assert state.state == "unknown"
    assert "switch_code" in state.message


# --------------------------------------------------------------------------- #
# Factory
# --------------------------------------------------------------------------- #


def test_factory_selects_providers():
    cfg = AppConfig()
    moonraker = MoonrakerClient(cfg.moonraker)

    cfg.power.provider = "demo"
    assert build_power_provider(cfg, moonraker).name == "demo"

    cfg.power.provider = "moonraker"
    assert build_power_provider(cfg, moonraker).name == "moonraker"

    cfg.power.provider = "webhook"
    assert build_power_provider(cfg, moonraker).name == "webhook"

    cfg.power.provider = "none"
    assert build_power_provider(cfg, moonraker).name == "none"

    cfg.power.provider = "nonsense"
    assert build_power_provider(cfg, moonraker).name == "none"


def test_tuya_provider_requires_enabled_flag():
    cfg = AppConfig()
    cfg.power.provider = "tuya"
    cfg.tuya.enabled = False
    provider = build_power_provider(cfg, MoonrakerClient(cfg.moonraker))
    assert provider.name == "none"

    cfg.tuya.enabled = True
    assert build_power_provider(cfg, MoonrakerClient(cfg.moonraker)).name == "tuya"
