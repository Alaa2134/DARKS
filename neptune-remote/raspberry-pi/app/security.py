"""Optional shared-secret authentication.

Tailscale is the primary network protection: the backend should never be exposed
to the public internet. When ``server.api_token`` is set, every /api request and
the /ws WebSocket must additionally present the token.
"""

from __future__ import annotations

import hmac
from typing import Optional

from fastapi import Header, HTTPException, Query, Request, WebSocket, status

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


# Loopback addresses. A caller on one of these is already executing code on the
# Pi, so requiring a token from them buys nothing - and it would force the
# timelapse macro to carry the token inside printer.cfg, which users routinely
# paste into forums when asking for help.
_LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}


def is_loopback(request: Request) -> bool:
    client = request.client
    return client is not None and client.host in _LOOPBACK_HOSTS


async def require_token_or_loopback(
    request: Request,
    x_api_key: Optional[str] = Header(default=None, alias=API_KEY_HEADER),
    authorization: Optional[str] = Header(default=None),
    token: Optional[str] = Query(default=None),
) -> None:
    """Guard for the one endpoint Klipper itself calls, from the same machine.

    Deliberately narrow: it is used only by POST /api/timelapse/frame, which
    captures a frame and returns nothing sensitive. Every other endpoint keeps
    the plain token requirement.
    """
    if is_loopback(request):
        return
    await require_token(x_api_key=x_api_key, authorization=authorization, token=token)


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
