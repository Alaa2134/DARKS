"""Where notifications actually go.

Every channel here is a *push out of the house*. That is the entire point: the
app's own WebSocket only works while the app is open and on screen, which is
exactly not the case when someone is out and the printer needs them. These
channels reach a phone that is in a pocket, locked, and on another network.

A channel never raises into the caller. A dead Telegram bot must not stop ntfy
from delivering the same message, so failures are recorded on the channel and
reported through the API instead.
"""

from __future__ import annotations

import json
import logging
from typing import Any, Dict, List, Optional, Protocol

import httpx

from ..config import NotifyWebhookConfig, NtfyConfig, TelegramConfig
from .messages import Notification, Priority

log = logging.getLogger("neptune.notify")


class Channel(Protocol):
    name: str

    async def send(self, client: httpx.AsyncClient, notification: Notification) -> None: ...


class BaseChannel:
    name = "base"

    def __init__(self) -> None:
        self.last_error: str = ""
        self.last_success_at: float = 0.0
        self.sent_count: int = 0
        self.failed_count: int = 0

    def describe(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "sent": self.sent_count,
            "failed": self.failed_count,
            "last_error": self.last_error,
            "last_success_at": self.last_success_at,
        }


class NtfyChannel(BaseChannel):
    """ntfy.sh - the shortest path from a Raspberry Pi to a locked iPhone.

    No account, no Apple developer programme, no APNs certificate. Which
    matters here: this app is sideloaded unsigned, so it can never receive real
    Apple push notifications. ntfy's own iOS app can, and it will.

    Priority is passed through as ntfy's 1-5 scale. Priority 5 is what lets an
    outage alert make noise through Do Not Disturb.
    """

    name = "ntfy"

    def __init__(self, config: NtfyConfig) -> None:
        super().__init__()
        self.config = config

    @property
    def configured(self) -> bool:
        return bool(self.config.enabled and self.config.topic.strip())

    def _headers(self) -> Dict[str, str]:
        # Titles go in a header, so they must be latin-1 encodable per HTTP
        # rules - Arabic is not. ntfy documents X-Title as UTF-8 but proxies in
        # between are not obliged to agree, so the title is carried in the JSON
        # body instead (see `_payload`) and only ASCII-safe metadata goes here.
        headers: Dict[str, str] = {"Content-Type": "application/json"}
        if self.config.token.strip():
            headers["Authorization"] = f"Bearer {self.config.token.strip()}"
        elif self.config.username and self.config.password:
            import base64

            raw = f"{self.config.username}:{self.config.password}".encode("utf-8")
            headers["Authorization"] = f"Basic {base64.b64encode(raw).decode('ascii')}"
        return headers

    def _payload(self, notification: Notification) -> Dict[str, Any]:
        body = notification.message or notification.title
        return {
            "topic": self.config.topic.strip(),
            "title": notification.title,
            "message": body,
            "priority": int(notification.priority),
            "tags": notification.tags,
        }

    async def send(self, client: httpx.AsyncClient, notification: Notification) -> None:
        server = self.config.server.rstrip("/") or "https://ntfy.sh"
        response = await client.post(
            server,
            headers=self._headers(),
            content=json.dumps(self._payload(notification), ensure_ascii=False).encode("utf-8"),
        )
        response.raise_for_status()


class TelegramChannel(BaseChannel):
    """A Telegram bot message.

    Free, reliable, and it keeps a scrollable history of everything the printer
    has ever told you, which ntfy does not.
    """

    name = "telegram"

    def __init__(self, config: TelegramConfig) -> None:
        super().__init__()
        self.config = config

    @property
    def configured(self) -> bool:
        return bool(
            self.config.enabled and self.config.bot_token.strip() and self.config.chat_id.strip()
        )

    async def send(self, client: httpx.AsyncClient, notification: Notification) -> None:
        text = notification.title
        if notification.message:
            text = f"{text}\n\n{notification.message}"

        response = await client.post(
            f"https://api.telegram.org/bot{self.config.bot_token.strip()}/sendMessage",
            json={
                "chat_id": self.config.chat_id.strip(),
                "text": text,
                # Telegram's own quiet delivery, used for anything below HIGH so
                # a "first layer done" does not buzz a pocket at midnight.
                "disable_notification": notification.priority < Priority.HIGH,
            },
        )
        response.raise_for_status()
        payload = response.json()
        if not payload.get("ok", False):
            raise httpx.HTTPError(str(payload.get("description") or "Telegram rejected the message"))


class WebhookChannel(BaseChannel):
    """Anything else - Home Assistant, Discord, a shell script behind a URL."""

    name = "webhook"

    def __init__(self, config: NotifyWebhookConfig) -> None:
        super().__init__()
        self.config = config

    @property
    def configured(self) -> bool:
        return bool(self.config.enabled and self.config.url.strip())

    def _body(self, notification: Notification) -> Any:
        template = self.config.body_template.strip()
        if not template:
            return notification.to_dict()

        rendered = (
            template.replace("{title}", _escape(notification.title))
            .replace("{message}", _escape(notification.message))
            .replace("{kind}", _escape(notification.kind))
            .replace("{priority}", notification.priority.label)
            .replace("{filename}", _escape(notification.filename))
        )
        try:
            return json.loads(rendered)
        except ValueError:
            # Not JSON - send it as a raw string body.
            return rendered

    async def send(self, client: httpx.AsyncClient, notification: Notification) -> None:
        body = self._body(notification)
        method = (self.config.method or "POST").upper()
        kwargs: Dict[str, Any] = {"headers": self.config.headers or None}
        if isinstance(body, str):
            kwargs["content"] = body.encode("utf-8")
        else:
            kwargs["json"] = body

        response = await client.request(method, self.config.url.strip(), **kwargs)
        response.raise_for_status()


def _escape(value: str) -> str:
    """Make a value safe to paste inside a JSON string template."""
    return json.dumps(value, ensure_ascii=False)[1:-1]


def build_channels(
    ntfy: NtfyConfig,
    telegram: TelegramConfig,
    webhook: NotifyWebhookConfig,
) -> List[BaseChannel]:
    """Only channels that are both enabled and actually filled in."""
    candidates: List[BaseChannel] = [
        NtfyChannel(ntfy),
        TelegramChannel(telegram),
        WebhookChannel(webhook),
    ]
    return [channel for channel in candidates if getattr(channel, "configured", False)]


def missing_configuration(
    ntfy: NtfyConfig,
    telegram: TelegramConfig,
    webhook: NotifyWebhookConfig,
) -> List[str]:
    """Channels switched on but not usable - reported instead of ignored.

    An `enabled: true` with an empty topic is the single most likely way for
    someone to believe they have alerts when they do not.
    """
    problems: List[str] = []
    if ntfy.enabled and not ntfy.topic.strip():
        problems.append("ntfy is enabled but no topic is set")
    if telegram.enabled and not (telegram.bot_token.strip() and telegram.chat_id.strip()):
        problems.append("telegram is enabled but bot_token or chat_id is missing")
    if webhook.enabled and not webhook.url.strip():
        problems.append("webhook is enabled but no url is set")
    return problems


__all__ = [
    "BaseChannel",
    "Channel",
    "NtfyChannel",
    "TelegramChannel",
    "WebhookChannel",
    "build_channels",
    "missing_configuration",
]
