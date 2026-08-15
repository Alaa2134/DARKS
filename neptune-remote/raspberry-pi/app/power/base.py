"""PowerProvider abstraction shared by every backend power implementation."""

from __future__ import annotations

import abc
from dataclasses import dataclass, field
from typing import Any, Dict

STATE_ON = "on"
STATE_OFF = "off"
STATE_UNKNOWN = "unknown"
STATE_ERROR = "error"


class PowerError(RuntimeError):
    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


@dataclass
class PowerState:
    state: str = STATE_UNKNOWN
    available: bool = False
    device: str = ""
    message: str = ""
    raw: Dict[str, Any] = field(default_factory=dict)


class PowerProvider(abc.ABC):
    """Every provider maps a physical switch to on/off/unknown."""

    name: str = "base"

    @abc.abstractmethod
    async def status(self) -> PowerState:
        ...

    @abc.abstractmethod
    async def turn_on(self) -> PowerState:
        ...

    @abc.abstractmethod
    async def turn_off(self) -> PowerState:
        ...

    async def aclose(self) -> None:  # pragma: no cover - default no-op
        return None


class NullPowerProvider(PowerProvider):
    """Used when no provider is configured; reports unavailable rather than lying."""

    name = "none"

    def __init__(self, message: str = "No power provider configured") -> None:
        self.message = message

    async def status(self) -> PowerState:
        return PowerState(state=STATE_UNKNOWN, available=False, message=self.message)

    async def turn_on(self) -> PowerState:
        raise PowerError(self.message)

    async def turn_off(self) -> PowerState:
        raise PowerError(self.message)
