"""Deciding what is worth waking someone up for, and getting it there.

The filtering here exists because an alerting system nobody trusts is worse
than none: if the printer sends forty messages an hour, the one that says the
power went out while a nine-hour print was running arrives in a pile nobody
reads. So messages are deduplicated, rate limited and silenced at night - and
a short, explicit list of kinds is exempt from all three, because those are the
ones that mean a human has to do something.

Preferences split in two on purpose:

* channels and secrets live in ``config.yaml`` on the Pi, which is git-ignored
  and never leaves the machine;
* which events notify, and quiet hours, live in the database and are editable
  from the phone, because those are choices you change at 1am from bed.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, List, Optional, Sequence

import httpx

from ..config import NotificationsConfig
from .channels import BaseChannel, build_channels, missing_configuration
from .messages import (
    Notification,
    Priority,
    all_event_kinds,
    critical_kinds,
    default_event_kinds,
    render,
)

log = logging.getLogger("neptune.notify")

STATE_KEY_PREFERENCES = "notifications.preferences"


@dataclass
class Preferences:
    """The half of the settings the phone is allowed to change."""

    enabled: bool = True
    events: List[str] = field(default_factory=default_event_kinds)
    min_priority: Priority = Priority.LOW
    quiet_hours_enabled: bool = False
    quiet_start_hour: int = 23
    quiet_end_hour: int = 8

    def to_dict(self) -> Dict[str, Any]:
        return {
            "enabled": self.enabled,
            "events": sorted(self.events),
            "min_priority": self.min_priority.label,
            "quiet_hours_enabled": self.quiet_hours_enabled,
            "quiet_start_hour": self.quiet_start_hour,
            "quiet_end_hour": self.quiet_end_hour,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any], fallback: "Preferences") -> "Preferences":
        known = set(all_event_kinds())
        raw_events = data.get("events")
        if isinstance(raw_events, list):
            # Unknown kinds are dropped rather than stored: they would silently
            # accumulate every time an event name is renamed.
            events = [str(kind) for kind in raw_events if str(kind) in known]
        else:
            events = list(fallback.events)

        return cls(
            enabled=bool(data.get("enabled", fallback.enabled)),
            events=events,
            min_priority=Priority.parse(data.get("min_priority"), fallback.min_priority),
            quiet_hours_enabled=bool(
                data.get("quiet_hours_enabled", fallback.quiet_hours_enabled)
            ),
            quiet_start_hour=_hour(data.get("quiet_start_hour"), fallback.quiet_start_hour),
            quiet_end_hour=_hour(data.get("quiet_end_hour"), fallback.quiet_end_hour),
        )


def _hour(value: Any, fallback: int) -> int:
    try:
        hour = int(value)
    except (TypeError, ValueError):
        return fallback
    return hour % 24


@dataclass
class Decision:
    """Why a notification was or was not sent - surfaced in the API."""

    send: bool
    reason: str = ""

    def __bool__(self) -> bool:  # pragma: no cover - convenience only
        return self.send


def in_quiet_hours(now: datetime, start_hour: int, end_hour: int) -> bool:
    """Quiet hours that wrap past midnight, which is the normal case."""
    if start_hour == end_hour:
        return False
    hour = now.hour
    if start_hour < end_hour:
        return start_hour <= hour < end_hour
    return hour >= start_hour or hour < end_hour


class NotificationService:
    """Routes printer events to every configured out-of-house channel."""

    def __init__(
        self,
        config: NotificationsConfig,
        *,
        db: Any = None,
        clock=time.time,
    ) -> None:
        self.config = config
        self._db = db
        self._clock = clock
        self.channels: List[BaseChannel] = build_channels(
            config.ntfy, config.telegram, config.webhook
        )
        self.warnings: List[str] = missing_configuration(
            config.ntfy, config.telegram, config.webhook
        )
        self._client: Optional[httpx.AsyncClient] = None
        self._lock = asyncio.Lock()
        # (kind, message) -> last sent timestamp
        self._recent: Dict[tuple, float] = {}
        self._sent_times: List[float] = []
        self.history: List[Dict[str, Any]] = []
        self.last_decision: str = ""

        self.preferences = self._load_preferences()

    # ------------------------------------------------------------ preferences
    def _load_preferences(self) -> Preferences:
        base = Preferences(
            enabled=self.config.enabled,
            events=list(self.config.events) or default_event_kinds(),
            min_priority=Priority.parse(self.config.min_priority, Priority.LOW),
            quiet_hours_enabled=self.config.quiet_hours.enabled,
            quiet_start_hour=self.config.quiet_hours.start_hour,
            quiet_end_hour=self.config.quiet_hours.end_hour,
        )
        # `muted` is a config-level veto; it is applied on every read so a
        # phone cannot re-enable something the Pi's owner turned off.
        base.events = [kind for kind in base.events if kind not in set(self.config.muted)]

        if self._db is None:
            return base
        stored = self._db.get_state(STATE_KEY_PREFERENCES, None)
        if not isinstance(stored, dict):
            return base
        merged = Preferences.from_dict(stored, base)
        merged.events = [kind for kind in merged.events if kind not in set(self.config.muted)]
        return merged

    def update_preferences(self, data: Dict[str, Any]) -> Preferences:
        self.preferences = Preferences.from_dict(data, self.preferences)
        self.preferences.events = [
            kind for kind in self.preferences.events if kind not in set(self.config.muted)
        ]
        if self._db is not None:
            self._db.set_state(STATE_KEY_PREFERENCES, self.preferences.to_dict())
        return self.preferences

    # -------------------------------------------------------------- decisions
    @property
    def available(self) -> bool:
        return bool(self.channels)

    def evaluate(self, notification: Notification, now: Optional[float] = None) -> Decision:
        """Everything that can stop a message, in the order it should apply."""
        moment = now if now is not None else self._clock()

        if not self.preferences.enabled:
            return Decision(False, "notifications are switched off")
        if not self.channels:
            return Decision(False, "no notification channel is configured")

        if notification.kind not in set(self.preferences.events):
            return Decision(False, f"'{notification.kind}' is not in the enabled events")

        # Critical kinds skip priority, quiet hours and the rate limit. They
        # still respect the event list above, so it stays possible to turn one
        # off deliberately - but not to lose it by accident.
        if not notification.critical:
            if notification.priority < self.preferences.min_priority:
                return Decision(
                    False,
                    f"priority {notification.priority.label} is below the minimum "
                    f"{self.preferences.min_priority.label}",
                )

            if self.preferences.quiet_hours_enabled and in_quiet_hours(
                datetime.fromtimestamp(moment),
                self.preferences.quiet_start_hour,
                self.preferences.quiet_end_hour,
            ):
                return Decision(False, "quiet hours")

            window_start = moment - 3600
            recent_count = len([t for t in self._sent_times if t >= window_start])
            if self.config.max_per_hour > 0 and recent_count >= self.config.max_per_hour:
                return Decision(False, f"rate limit of {self.config.max_per_hour}/hour reached")

        # Deduplication applies to everything, including critical events: a
        # printer that lost power reports it on every poll, and forty identical
        # alerts is not forty times more useful than one.
        key = (notification.kind, notification.title, notification.message)
        last = self._recent.get(key)
        if last is not None and moment - last < self.config.dedupe_seconds:
            return Decision(False, "duplicate of a message just sent")

        return Decision(True)

    # ------------------------------------------------------------- delivering
    async def _http(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(timeout=self.config.timeout_seconds)
        return self._client

    async def notify(self, notification: Notification, *, force: bool = False) -> Dict[str, Any]:
        """Send if the rules allow. Never raises."""
        now = self._clock()
        if notification.timestamp == 0.0:
            notification.timestamp = now

        decision = Decision(True) if force else self.evaluate(notification, now)
        self.last_decision = decision.reason

        record: Dict[str, Any] = {
            **notification.to_dict(),
            "sent": False,
            "reason": decision.reason,
            "channels": [],
        }

        if not decision.send:
            self._remember(record)
            return record

        async with self._lock:
            self._recent[(notification.kind, notification.title, notification.message)] = now
            self._sent_times = [t for t in self._sent_times if t >= now - 3600]
            self._sent_times.append(now)
            # Bounded so a long-running Pi cannot accumulate keys forever.
            if len(self._recent) > 200:
                for key in sorted(self._recent, key=self._recent.get)[:100]:
                    self._recent.pop(key, None)

        results = await asyncio.gather(
            *(self._deliver(channel, notification) for channel in self.channels),
            return_exceptions=False,
        )
        record["channels"] = results
        record["sent"] = any(item["ok"] for item in results)
        self._remember(record)
        return record

    async def _deliver(self, channel: BaseChannel, notification: Notification) -> Dict[str, Any]:
        client = await self._http()
        attempts = max(1, self.config.retries + 1)
        last_error = ""

        for attempt in range(attempts):
            try:
                await channel.send(client, notification)
                channel.sent_count += 1
                channel.last_error = ""
                channel.last_success_at = self._clock()
                return {"channel": channel.name, "ok": True, "error": ""}
            except Exception as exc:  # noqa: BLE001 - a channel must never propagate
                last_error = f"{type(exc).__name__}: {exc}"
                if attempt + 1 < attempts:
                    await asyncio.sleep(min(2 ** attempt, 8))

        channel.failed_count += 1
        channel.last_error = last_error
        log.warning("notification via %s failed: %s", channel.name, last_error)
        return {"channel": channel.name, "ok": False, "error": last_error}

    def _remember(self, record: Dict[str, Any]) -> None:
        self.history.append(record)
        if len(self.history) > 100:
            del self.history[: len(self.history) - 100]

    # ------------------------------------------------------------- public API
    async def dispatch_event(
        self,
        kind: str,
        *,
        title: str = "",
        message: str = "",
        filename: str = "",
        priority: Optional[Priority] = None,
        timestamp: float = 0.0,
    ) -> Dict[str, Any]:
        notification = render(
            kind,
            language=self.config.language,
            fallback_title=title,
            message=message,
            filename=filename,
            timestamp=timestamp or self._clock(),
            priority=priority,
        )
        return await self.notify(notification)

    async def send_test(self) -> Dict[str, Any]:
        """Forced through every filter - the point is to prove delivery works."""
        notification = render(
            "test",
            language=self.config.language,
            message=(
                "لو وصلتك الرسالة دي، الإشعارات شغالة."
                if self.config.language.startswith("ar")
                else "If you can read this, notifications are working."
            ),
            timestamp=self._clock(),
        )
        return await self.notify(notification, force=True)

    def status(self) -> Dict[str, Any]:
        return {
            "enabled": self.preferences.enabled,
            "language": self.config.language,
            "channels": [channel.describe() for channel in self.channels],
            "configured": self.available,
            "warnings": list(self.warnings),
            "preferences": self.preferences.to_dict(),
            "available_events": all_event_kinds(),
            "critical_events": critical_kinds(),
            "default_events": default_event_kinds(),
            "last_decision": self.last_decision,
        }

    def recent(self, limit: int = 25) -> List[Dict[str, Any]]:
        return self.history[-limit:][::-1]

    async def aclose(self) -> None:
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()


def kinds_from(sequence: Sequence[str]) -> List[str]:
    known = set(all_event_kinds())
    return [kind for kind in sequence if kind in known]
