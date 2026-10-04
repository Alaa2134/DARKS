"""Realtime WebSocket endpoint.

Messages are JSON objects: ``{"type": ..., "timestamp": ..., "payload": {...}}``

Types pushed by the server:
    hello      - handshake with backend capabilities
    summary    - one-shot snapshot of every subsystem, sent on connect
    printer    - full PrinterStatusResponse (+ the model being printed), ~1 Hz
    power      - power provider state, on change
    slice      - slicing job progress
    event      - discrete printer events (print finished, klipper error, ...)
    system     - Raspberry Pi metrics, every 20 s
    recording  - video recording status
    timelapse  - timelapse session status
    vision     - confirmed print-failure detections
    pong       - reply to a client ``{"type": "ping"}``
"""

from __future__ import annotations

import asyncio
import logging
import time

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from .. import system_info
from ..deps import get_state_ws
from ..security import websocket_authorized
from ..state import _power_payload
from ..version import VERSION

log = logging.getLogger("neptune.ws")

router = APIRouter()

SYSTEM_PUSH_SECONDS = 20.0


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    if not await websocket_authorized(websocket):
        await websocket.close(code=4401, reason="Invalid or missing API token")
        return

    state = get_state_ws(websocket)
    await state.hub.connect(websocket)

    try:
        await websocket.send_json(
            {
                "type": "hello",
                "timestamp": time.time(),
                "payload": {
                    "version": VERSION,
                    "power_provider": state.power.name,
                    "slicer_engine": state.engine.name,
                    "slicer_available": state.engine.available,
                    "moonraker_url": state.config.moonraker.base_url,
                    "camera_available": state.camera.status(probe_devices=False).available,
                    "recording_available": state.camera.ffmpeg is not None,
                    "vision_provider": state.vision.provider.name,
                    "vision_available": state.vision.provider.available,
                    "vision_mode": state.vision.mode,
                    "storage_root": str(state.layout.root),
                },
            }
        )

        # Immediate snapshot so the client can render without waiting a tick.
        await websocket.send_json(
            {"type": "summary", "timestamp": time.time(), "payload": state.status_summary()}
        )
        printer_payload = state.last_status.model_dump()
        printer_payload["item"] = state.status_summary().get("item")
        await websocket.send_json(
            {"type": "printer", "timestamp": time.time(), "payload": printer_payload}
        )
        await websocket.send_json(
            {
                "type": "power",
                "timestamp": time.time(),
                "payload": _power_payload(state.power.name, state.last_power),
            }
        )

        system_task = asyncio.create_task(_system_pusher(websocket))
        try:
            while True:
                message = await websocket.receive_json()
                kind = str(message.get("type") or "")
                if kind == "ping":
                    await websocket.send_json({"type": "pong", "timestamp": time.time(), "payload": {}})
                elif kind == "system":
                    await websocket.send_json(
                        {
                            "type": "system",
                            "timestamp": time.time(),
                            "payload": system_info.collect().model_dump(),
                        }
                    )
                elif kind == "summary":
                    await websocket.send_json(
                        {
                            "type": "summary",
                            "timestamp": time.time(),
                            "payload": state.status_summary(),
                        }
                    )
        finally:
            system_task.cancel()
    except WebSocketDisconnect:
        pass
    except Exception:
        log.debug("WebSocket closed with an error", exc_info=True)
    finally:
        await state.hub.disconnect(websocket)


async def _system_pusher(websocket: WebSocket) -> None:
    try:
        while True:
            await asyncio.sleep(SYSTEM_PUSH_SECONDS)
            await websocket.send_json(
                {
                    "type": "system",
                    "timestamp": time.time(),
                    "payload": system_info.collect().model_dump(),
                }
            )
    except asyncio.CancelledError:
        raise
    except Exception:
        return
