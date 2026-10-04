"""Shared FastAPI dependencies."""

from __future__ import annotations

from fastapi import Request, WebSocket

from .state import AppState


def get_state(request: Request) -> AppState:
    state: AppState = request.app.state.services
    return state


def get_state_ws(websocket: WebSocket) -> AppState:
    state: AppState = websocket.app.state.services
    return state
