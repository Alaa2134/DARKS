"""The dead man's switch.

The heartbeat exists for exactly one failure mode - the Pi loses power, so
nothing on the Pi can tell anyone - which means the properties worth testing
are that it never raises, and that it does not conflate "the printer is fine"
with "this machine is alive".
"""

from __future__ import annotations

import httpx
import pytest

from app.config import HeartbeatConfig
from app.notify.heartbeat import HeartbeatPinger


def pinger(**overrides) -> HeartbeatPinger:
    defaults = {"enabled": True, "url": "https://hc.example.invalid/abc123"}
    defaults.update(overrides)
    return HeartbeatPinger(HeartbeatConfig(**defaults))


def install(beat: HeartbeatPinger, handler) -> None:
    beat._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))


class TestConfiguration:
    def test_disabled_without_a_url(self):
        assert not pinger(url="").enabled

    def test_disabled_when_switched_off(self):
        assert not pinger(enabled=False).enabled

    def test_the_interval_has_a_floor(self):
        """A ping every five seconds is traffic, not monitoring."""
        assert pinger(interval_seconds=5).interval == 60.0

    def test_a_longer_interval_is_respected(self):
        assert pinger(interval_seconds=900).interval == 900.0


class TestPinging:
    @pytest.mark.asyncio
    async def test_a_successful_ping_is_recorded(self):
        beat = pinger()
        install(beat, lambda request: httpx.Response(200, text="OK"))
        assert await beat.ping() is True
        assert beat.success_count == 1
        assert beat.last_ping_at > 0

    @pytest.mark.asyncio
    async def test_a_failed_ping_never_raises(self):
        """A minute without internet must not take the backend down with it."""
        beat = pinger()

        def handler(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("no route to host")

        install(beat, handler)
        assert await beat.ping() is False
        assert beat.failure_count == 1
        assert "ConnectError" in beat.last_error

    @pytest.mark.asyncio
    async def test_an_http_error_counts_as_a_failure(self):
        beat = pinger()
        install(beat, lambda request: httpx.Response(500))
        assert await beat.ping() is False

    @pytest.mark.asyncio
    async def test_a_disabled_pinger_does_nothing(self):
        beat = pinger(enabled=False)
        assert await beat.ping() is False
        assert beat.success_count == 0

    @pytest.mark.asyncio
    async def test_the_failure_signal_hits_a_different_url(self):
        """healthchecks.io wants /fail to raise the alarm immediately rather
        than waiting out the grace period."""
        seen = []
        beat = pinger()
        install(beat, lambda request: (seen.append(str(request.url)), httpx.Response(200))[1])

        await beat.ping()
        await beat.ping(failing=True)

        assert seen[0].endswith("/abc123")
        assert seen[1].endswith("/abc123/fail")

    @pytest.mark.asyncio
    async def test_no_fail_suffix_means_the_same_url(self):
        seen = []
        beat = pinger(fail_suffix="")
        install(beat, lambda request: (seen.append(str(request.url)), httpx.Response(200))[1])
        await beat.ping(failing=True)
        assert seen[0].endswith("/abc123")

    @pytest.mark.asyncio
    async def test_a_body_is_only_sent_on_methods_that_take_one(self):
        seen = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["method"] = request.method
            seen["body"] = request.content
            return httpx.Response(200)

        beat = pinger(method="POST")
        install(beat, handler)
        await beat.ping(body="printer lost power")
        assert seen["body"] == b"printer lost power"

        get_beat = pinger(method="GET")
        install(get_beat, handler)
        await get_beat.ping(body="ignored")
        assert seen["body"] == b""


class TestStatus:
    def test_status_before_any_ping(self):
        status = pinger().status()
        assert status["enabled"] is True
        assert status["last_ping_at"] is None

    @pytest.mark.asyncio
    async def test_status_after_a_ping(self):
        beat = pinger()
        install(beat, lambda request: httpx.Response(200))
        await beat.ping()
        status = beat.status()
        assert status["successes"] == 1
        assert status["seconds_since_last_ping"] is not None
