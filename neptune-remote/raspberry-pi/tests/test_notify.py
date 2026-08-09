"""Notification routing.

The point of these tests is the *filtering*. Delivering a message is the easy
half; the hard half is that the system stays worth listening to, which means
the chatty events can be silenced and the urgent ones cannot be silenced by
accident.
"""

from __future__ import annotations

import httpx
import pytest

from app.config import (
    NotificationsConfig,
    NotifyWebhookConfig,
    NtfyConfig,
    TelegramConfig,
)
from app.notify.channels import NtfyChannel, TelegramChannel, WebhookChannel, missing_configuration
from app.notify.messages import Priority, all_event_kinds, critical_kinds, render
from app.notify.service import NotificationService, in_quiet_hours


class FakeClock:
    def __init__(self, now: float = 1_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class RecordingChannel:
    """Stands in for a real channel; remembers what it was asked to send."""

    def __init__(self, name: str = "recording", fail_times: int = 0) -> None:
        self.name = name
        self.sent = []
        self.sent_count = 0
        self.failed_count = 0
        self.last_error = ""
        self.last_success_at = 0.0
        self._fail_times = fail_times
        self.attempts = 0

    async def send(self, client, notification) -> None:
        self.attempts += 1
        if self.attempts <= self._fail_times:
            raise httpx.ConnectError("boom")
        self.sent.append(notification)
        self.sent_count += 1

    def describe(self):
        return {"name": self.name, "sent": self.sent_count}


def build_service(**overrides) -> tuple[NotificationService, RecordingChannel, FakeClock]:
    config = NotificationsConfig(**overrides)
    clock = FakeClock()
    service = NotificationService(config, clock=clock)
    channel = RecordingChannel()
    service.channels = [channel]
    return service, channel, clock


# --------------------------------------------------------------------------- #
# The catalogue
# --------------------------------------------------------------------------- #


class TestMessages:
    def test_arabic_is_the_default_language(self):
        notification = render("print_finished")
        assert notification.title == "الطباعة خلصت"

    def test_english_is_available(self):
        assert render("print_finished", language="en").title == "Print finished"

    def test_an_unknown_kind_is_still_delivered(self):
        """A missing translation must not become a missing alert."""
        notification = render("something_new", fallback_title="Something happened")
        assert notification.title == "Something happened"
        assert notification.priority == Priority.DEFAULT

    def test_power_loss_outranks_a_progress_update(self):
        assert render("power_lost").priority > render("print_halfway").priority

    def test_the_urgent_ones_are_marked_critical(self):
        for kind in ("power_lost", "filament_runout", "klipper_error", "print_interrupted"):
            assert render(kind).critical, f"{kind} should bypass quiet hours"

    def test_progress_chatter_is_not_on_by_default(self):
        from app.notify.messages import default_event_kinds

        assert "print_halfway" not in default_event_kinds()
        assert "print_finished" in default_event_kinds()

    def test_the_filename_lands_in_the_title(self):
        assert "benchy.gcode" in render("print_started", filename="benchy.gcode").title


# --------------------------------------------------------------------------- #
# Deciding whether to send
# --------------------------------------------------------------------------- #


class TestFiltering:
    @pytest.mark.asyncio
    async def test_a_normal_event_is_sent(self):
        service, channel, _ = build_service()
        result = await service.dispatch_event("print_finished", filename="a.gcode")
        assert result["sent"] is True
        assert len(channel.sent) == 1

    @pytest.mark.asyncio
    async def test_a_disabled_event_is_not_sent(self):
        service, channel, _ = build_service(events=["power_lost"])
        result = await service.dispatch_event("print_finished")
        assert result["sent"] is False
        assert "not in the enabled events" in result["reason"]
        assert channel.sent == []

    @pytest.mark.asyncio
    async def test_the_same_message_twice_is_sent_once(self):
        service, channel, clock = build_service()
        await service.dispatch_event("print_finished", filename="a.gcode")
        await service.dispatch_event("print_finished", filename="a.gcode")
        assert len(channel.sent) == 1

        clock.advance(service.config.dedupe_seconds + 1)
        await service.dispatch_event("print_finished", filename="a.gcode")
        assert len(channel.sent) == 2

    @pytest.mark.asyncio
    async def test_a_repeated_outage_does_not_repeat_forever(self):
        """The printer reports a shutdown on every poll - once is enough."""
        service, channel, _ = build_service()
        for _ in range(10):
            await service.dispatch_event("power_lost", message="same")
        assert len(channel.sent) == 1

    @pytest.mark.asyncio
    async def test_quiet_hours_hold_back_an_ordinary_event(self):
        service, channel, clock = build_service()
        service.preferences.quiet_hours_enabled = True
        service.preferences.quiet_start_hour = 0
        service.preferences.quiet_end_hour = 23
        result = await service.dispatch_event("print_finished")
        assert result["sent"] is False
        assert result["reason"] == "quiet hours"

    @pytest.mark.asyncio
    async def test_quiet_hours_do_not_hold_back_a_power_cut(self):
        service, channel, _ = build_service()
        service.preferences.quiet_hours_enabled = True
        service.preferences.quiet_start_hour = 0
        service.preferences.quiet_end_hour = 23
        result = await service.dispatch_event("power_lost")
        assert result["sent"] is True

    @pytest.mark.asyncio
    async def test_the_rate_limit_does_not_hold_back_a_power_cut(self):
        service, channel, _ = build_service(max_per_hour=1)
        await service.dispatch_event("print_started", filename="one.gcode")
        blocked = await service.dispatch_event("print_started", filename="two.gcode")
        assert blocked["sent"] is False
        assert "rate limit" in blocked["reason"]

        urgent = await service.dispatch_event("power_lost")
        assert urgent["sent"] is True

    @pytest.mark.asyncio
    async def test_min_priority_filters_the_quiet_ones(self):
        service, _, _ = build_service(
            min_priority="high", events=all_event_kinds()
        )
        low = await service.dispatch_event("first_layer_complete")
        assert low["sent"] is False
        assert "below the minimum" in low["reason"]

        high = await service.dispatch_event("print_finished")
        assert high["sent"] is True

    @pytest.mark.asyncio
    async def test_switching_notifications_off_stops_everything(self):
        service, channel, _ = build_service()
        service.preferences.enabled = False
        assert (await service.dispatch_event("power_lost"))["sent"] is False
        assert channel.sent == []

    @pytest.mark.asyncio
    async def test_no_channel_means_no_send_but_no_crash(self):
        config = NotificationsConfig()
        service = NotificationService(config, clock=FakeClock())
        result = await service.dispatch_event("power_lost")
        assert result["sent"] is False
        assert "no notification channel" in result["reason"]

    @pytest.mark.asyncio
    async def test_a_muted_kind_cannot_be_re_enabled_from_the_phone(self):
        """`muted` is the Pi owner's veto, applied after the phone's list."""
        service, _, _ = build_service(muted=["print_halfway"])
        service.update_preferences({"events": all_event_kinds()})
        assert "print_halfway" not in service.preferences.events

    def test_quiet_hours_wrap_past_midnight(self):
        from datetime import datetime

        assert in_quiet_hours(datetime(2026, 1, 1, 23, 30), 23, 8)
        assert in_quiet_hours(datetime(2026, 1, 1, 3, 0), 23, 8)
        assert not in_quiet_hours(datetime(2026, 1, 1, 12, 0), 23, 8)

    def test_identical_start_and_end_means_no_quiet_hours(self):
        from datetime import datetime

        assert not in_quiet_hours(datetime(2026, 1, 1, 5, 0), 8, 8)


# --------------------------------------------------------------------------- #
# Delivery
# --------------------------------------------------------------------------- #


class TestDelivery:
    @pytest.mark.asyncio
    async def test_a_failing_channel_is_retried(self):
        service, _, _ = build_service(retries=2)
        flaky = RecordingChannel(fail_times=1)
        service.channels = [flaky]
        result = await service.dispatch_event("print_finished")
        assert result["sent"] is True
        assert flaky.attempts == 2

    @pytest.mark.asyncio
    async def test_one_dead_channel_does_not_stop_the_others(self):
        service, _, _ = build_service(retries=0)
        dead = RecordingChannel(name="dead", fail_times=99)
        alive = RecordingChannel(name="alive")
        service.channels = [dead, alive]

        result = await service.dispatch_event("power_lost")
        assert result["sent"] is True
        assert len(alive.sent) == 1
        assert any(entry["channel"] == "dead" and not entry["ok"] for entry in result["channels"])

    @pytest.mark.asyncio
    async def test_the_test_message_ignores_every_filter(self):
        """Otherwise a green test would prove nothing about a silenced setup."""
        service, channel, _ = build_service(events=[])
        service.preferences.enabled = False
        service.preferences.quiet_hours_enabled = True
        service.preferences.quiet_start_hour = 0
        service.preferences.quiet_end_hour = 23

        result = await service.send_test()
        assert result["sent"] is True
        assert len(channel.sent) == 1

    @pytest.mark.asyncio
    async def test_suppressed_messages_are_still_recorded_with_a_reason(self):
        service, _, _ = build_service(events=["power_lost"])
        await service.dispatch_event("print_finished")
        recent = service.recent()
        assert recent[0]["sent"] is False
        assert recent[0]["reason"]


# --------------------------------------------------------------------------- #
# Channels
# --------------------------------------------------------------------------- #


class TestChannels:
    def test_ntfy_needs_a_topic(self):
        assert not NtfyChannel(NtfyConfig(enabled=True)).configured
        assert NtfyChannel(NtfyConfig(enabled=True, topic="abc")).configured

    def test_telegram_needs_both_halves(self):
        assert not TelegramChannel(TelegramConfig(enabled=True, bot_token="t")).configured
        assert TelegramChannel(TelegramConfig(enabled=True, bot_token="t", chat_id="1")).configured

    def test_enabled_but_unconfigured_is_reported_not_ignored(self):
        """The likeliest way to believe you have alerts when you do not."""
        problems = missing_configuration(
            NtfyConfig(enabled=True),
            TelegramConfig(enabled=True),
            NotifyWebhookConfig(enabled=True),
        )
        assert len(problems) == 3

    @pytest.mark.asyncio
    async def test_ntfy_sends_arabic_in_the_body_not_a_header(self):
        """HTTP headers are latin-1; an Arabic title in one is a 500 or mojibake."""
        seen = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["headers"] = dict(request.headers)
            seen["body"] = request.content.decode("utf-8")
            return httpx.Response(200, json={"id": "1"})

        channel = NtfyChannel(NtfyConfig(enabled=True, topic="printer", server="https://ntfy.sh"))
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            await channel.send(client, render("power_lost"))

        assert "انقطعت الكهرباء عن الطابعة" in seen["body"]
        for value in seen["headers"].values():
            value.encode("latin-1")  # would raise if Arabic leaked into a header

    @pytest.mark.asyncio
    async def test_ntfy_passes_the_priority_through(self):
        captured = {}

        def handler(request: httpx.Request) -> httpx.Response:
            import json

            captured.update(json.loads(request.content))
            return httpx.Response(200, json={"id": "1"})

        channel = NtfyChannel(NtfyConfig(enabled=True, topic="printer"))
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            await channel.send(client, render("power_lost"))

        assert captured["priority"] == 5

    @pytest.mark.asyncio
    async def test_telegram_stays_silent_for_low_priority(self):
        captured = {}

        def handler(request: httpx.Request) -> httpx.Response:
            import json

            captured.update(json.loads(request.content))
            return httpx.Response(200, json={"ok": True})

        channel = TelegramChannel(TelegramConfig(enabled=True, bot_token="t", chat_id="1"))
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            await channel.send(client, render("first_layer_complete"))
        assert captured["disable_notification"] is True

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            await channel.send(client, render("power_lost"))
        assert captured["disable_notification"] is False

    @pytest.mark.asyncio
    async def test_telegram_ok_false_is_an_error_not_a_success(self):
        def handler(request: httpx.Request) -> httpx.Response:
            # Telegram answers 200 with ok:false for a bad chat_id.
            return httpx.Response(200, json={"ok": False, "description": "chat not found"})

        channel = TelegramChannel(TelegramConfig(enabled=True, bot_token="t", chat_id="1"))
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            with pytest.raises(httpx.HTTPError):
                await channel.send(client, render("test"))

    @pytest.mark.asyncio
    async def test_a_webhook_template_survives_a_quote_in_the_text(self):
        captured = {}

        def handler(request: httpx.Request) -> httpx.Response:
            import json

            captured.update(json.loads(request.content))
            return httpx.Response(200, json={})

        channel = WebhookChannel(
            NotifyWebhookConfig(
                enabled=True, url="https://example.invalid/hook", body_template='{"text": "{title}"}'
            )
        )
        notification = render("test", fallback_title="")
        notification.title = 'a "quoted" title'
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            await channel.send(client, notification)

        assert captured["text"] == 'a "quoted" title'


# --------------------------------------------------------------------------- #
# Preferences
# --------------------------------------------------------------------------- #


class TestPreferences:
    def test_unknown_event_kinds_are_dropped_on_the_way_in(self):
        service, _, _ = build_service()
        service.update_preferences({"events": ["print_finished", "not_a_real_event"]})
        assert service.preferences.events == ["print_finished"]

    def test_an_omitted_field_keeps_its_current_value(self):
        service, _, _ = build_service()
        before = list(service.preferences.events)
        service.update_preferences({"quiet_hours_enabled": True})
        assert service.preferences.events == before
        assert service.preferences.quiet_hours_enabled is True

    def test_an_out_of_range_hour_wraps_instead_of_crashing(self):
        service, _, _ = build_service()
        service.update_preferences({"quiet_start_hour": 25})
        assert service.preferences.quiet_start_hour == 1

    def test_critical_kinds_are_reported_so_the_ui_can_mark_them(self):
        assert "power_lost" in critical_kinds()
        assert "print_halfway" not in critical_kinds()
