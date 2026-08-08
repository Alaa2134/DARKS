"""Optional shared-secret authentication.

Tailscale is the primary network protection: the backend should never be exposed
to the public internet. When ``server.api_token`` is set, every /api request and
the /ws WebSocket must additionally present the token.
"""

from __future__ import annotations

import hmac
from typing import Optional

from fastapi import Header, HTTPException, Query, WebSocket, status

from .config import AppConfig, get_config

API_KEY_HEADER = "X-API-Key"


def token_matches(config: AppConfig, provided: Optional[str]) -> bool:
    expected = config.server.api_token.strip()
    if not expected:
        return True
    if not provided:
        return False
    return hmac.compare_digest(expected, provided.strip())


async def require_token(
    x_api_key: Optional[str] = Header(default=None, alias=API_KEY_HEADER),
    authorization: Optional[str] = Header(default=None),
    token: Optional[str] = Query(default=None),
) -> None:
    """FastAPI dependency guarding the REST API."""
    config = get_config()
    if not config.server.auth_required:
        return

    provided = x_api_key or token
    if not provided and authorization:
        scheme, _, value = authorization.partition(" ")
        if scheme.lower() == "bearer":
            provided = value

    if not token_matches(config, provided):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API token",
            headers={"WWW-Authenticate": "Bearer"},
        )


async def websocket_authorized(websocket: WebSocket) -> bool:
    config = get_config()
    if not config.server.auth_required:
        return True
    provided = websocket.headers.get(API_KEY_HEADER) or websocket.query_params.get("token")
    if not provided:
        authorization = websocket.headers.get("authorization") or ""
        scheme, _, value = authorization.partition(" ")
        if scheme.lower() == "bearer":
            provided = value
    return token_matches(config, provided)
