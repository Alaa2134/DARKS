"""FastAPI application factory for the Neptune 3 Plus Remote backend."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator, Optional

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .config import AppConfig, get_config, load_config, set_config
from .routers import (
    core,
    files,
    history,
    inventory,
    library,
    media,
    power,
    printer,
    slicing,
    support,
    vision,
    websocket,
)
from .state import AppState
from .version import APP_NAME, VERSION

log = logging.getLogger("neptune")

DESCRIPTION = """
Native backend for the **Neptune 3 Plus Remote** iPhone app.

* proxies and normalises Moonraker / Klipper state
* keeps Tuya (Smart Life) credentials on the Raspberry Pi, never on the phone
* runs a real slicer (PrusaSlicer / OrcaSlicer CLI) for mobile slicing
* keeps a searchable Arabic model library with generated thumbnails
* records prints and renders timelapses with FFmpeg
* runs local print-failure detection - no cloud, no uploads
* tracks filament, cost, products and maintenance
* stores print history in SQLite
* streams everything over `/ws`

Protect this service with Tailscale. Do not expose it to the public internet.
"""


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )


def create_app(config: Optional[AppConfig] = None) -> FastAPI:
    if config is None:
        config = get_config()
    else:
        set_config(config)

    configure_logging(config.server.log_level)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        services = AppState(config)
        app.state.services = services
        await services.start()
        try:
            yield
        finally:
            await services.stop()

    app = FastAPI(
        title=APP_NAME,
        version=VERSION,
        description=DESCRIPTION,
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=config.server.cors_origins or ["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.include_router(core.router, prefix="/api", tags=["core"])
    app.include_router(printer.router, prefix="/api", tags=["printer"])
    app.include_router(power.router, prefix="/api", tags=["power"])
    app.include_router(files.router, prefix="/api", tags=["files"])
    app.include_router(slicing.router, prefix="/api", tags=["slicing"])
    app.include_router(history.router, prefix="/api", tags=["history"])
    app.include_router(library.router, prefix="/api", tags=["library"])
    app.include_router(media.router, prefix="/api", tags=["camera"])
    # Loopback-tolerant: the Klipper timelapse macro, and nothing else.
    app.include_router(media.local_router, prefix="/api", tags=["camera"])
    app.include_router(vision.router, prefix="/api", tags=["vision"])
    app.include_router(inventory.router, prefix="/api", tags=["inventory"])
    app.include_router(support.router, prefix="/api", tags=["support"])
    app.include_router(websocket.router, tags=["realtime"])

    @app.get("/", include_in_schema=False)
    async def root() -> dict:
        return {
            "name": APP_NAME,
            "version": VERSION,
            "docs": "/docs",
            "websocket": "/ws",
            "health": "/api/health",
        }

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
        log.exception("Unhandled error on %s %s", request.method, request.url.path)
        return JSONResponse(
            status_code=500,
            content={"detail": f"Internal backend error: {exc.__class__.__name__}: {exc}"},
        )

    return app


app = create_app(load_config())


def main() -> None:  # pragma: no cover - console entry point
    import uvicorn

    config = get_config()
    uvicorn.run(
        app,
        host=config.server.host,
        port=config.server.port,
        log_level=config.server.log_level,
    )


if __name__ == "__main__":  # pragma: no cover
    main()
