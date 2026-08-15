"""WebSocket fan-out hub."""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any, Dict, List, Set

from fastapi import WebSocket

log = logging.getLogger("neptune.hub")


class EventHub:
    def __init__(self, replay_size: int = 20) -> None:
        self._clients: Set[WebSocket] = set()
        self._lock = asyncio.Lock()
        self._recent: List[Dict[str, Any]] = []
        self._replay_size = replay_size

    @property
    def client_count(self) -> int:
        return len(self._clients)

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self._lock:
            self._clients.add(websocket)

    async def disconnect(self, websocket: WebSocket) -> None:
        async with self._lock:
            self._clients.discard(websocket)

    def recent(self) -> List[Dict[str, Any]]:
        return list(self._recent)

    async def broadcast(self, event_type: str, payload: Dict[str, Any]) -> None:
        message = {"type": event_type, "timestamp": time.time(), "payload": payload}

        if event_type in {"printer", "power", "system"}:
            self._recent = [item for item in self._recent if item["type"] != event_type]
            self._recent.append(message)
            if len(self._recent) > self._replay_size:
                self._recent = self._recent[-self._replay_size :]

        async with self._lock:
            targets = list(self._clients)

        if not targets:
            return

        results = await asyncio.gather(
            *(client.send_json(message) for client in targets), return_exceptions=True
        )
        dead = [client for client, result in zip(targets, results) if isinstance(result, Exception)]
        if dead:
            async with self._lock:
                for client in dead:
                    self._clients.discard(client)
