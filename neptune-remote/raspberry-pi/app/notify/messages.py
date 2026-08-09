"""What each printer event actually says on a phone screen.

Two things matter here and neither is cosmetic.

*Priority* decides whether a phone that is face-down, silenced or in Do Not
Disturb makes a sound. "Print reached 50%" waking someone at 3am is how people
end up muting the whole channel, and then the one notification that mattered -
the printer lost power with a print running - arrives silently. So the scale is
used honestly: URGENT is reserved for "a human has to do something now".

*Language*: the phone using this speaks Arabic, so Arabic is the default and
English is the fallback, not the other way round.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum
from typing import Dict, List, Optional


class Priority(IntEnum):
    """Matches ntfy's 1-5 scale so it maps straight through."""

    MIN = 1
    LOW = 2
    DEFAULT = 3
    HIGH = 4
    URGENT = 5

    @classmethod
    def parse(cls, value: object, fallback: "Priority" = None) -> "Priority":
        default = fallback if fallback is not None else cls.DEFAULT
        if isinstance(value, Priority):
            return value
        if isinstance(value, int):
            return cls(min(max(value, 1), 5))
        text = str(value or "").strip().lower()
        return _PRIORITY_NAMES.get(text, default)

    @property
    def label(self) -> str:
        return self.name.lower()


_PRIORITY_NAMES: Dict[str, Priority] = {
    "min": Priority.MIN,
    "low": Priority.LOW,
    "default": Priority.DEFAULT,
    "normal": Priority.DEFAULT,
    "high": Priority.HIGH,
    "urgent": Priority.URGENT,
    "max": Priority.URGENT,
}


@dataclass
class Notification:
    """One message, already rendered, ready for any channel."""

    kind: str
    title: str
    message: str = ""
    priority: Priority = Priority.DEFAULT
    # ntfy renders these as emoji; other channels use them as plain labels.
    tags: List[str] = field(default_factory=list)
    filename: str = ""
    timestamp: float = 0.0
    # Set for events that must never be held back by quiet hours or rate limits.
    critical: bool = False

    def to_dict(self) -> dict:
        return {
            "kind": self.kind,
            "title": self.title,
            "message": self.message,
            "priority": self.priority.label,
            "tags": list(self.tags),
            "filename": self.filename,
            "timestamp": self.timestamp,
            "critical": self.critical,
        }


@dataclass(frozen=True)
class Template:
    ar: str
    en: str
    priority: Priority
    tags: tuple = ()
    # Quiet hours and the hourly rate limit do not apply to these.
    critical: bool = False
    # Off unless the user opts in - true for the chatty progress ones.
    noisy: bool = False


# The catalogue. Adding an event kind anywhere in the backend without adding it
# here is not a bug: it falls through to the event's own English title, which
# is worse but still delivered.
TEMPLATES: Dict[str, Template] = {
    # ---- the ones that mean "go look at the printer" -----------------------
    "power_lost": Template(
        ar="انقطعت الكهرباء عن الطابعة",
        en="Printer lost power",
        priority=Priority.URGENT,
        tags=("rotating_light", "electric_plug"),
        critical=True,
    ),
    "print_interrupted": Template(
        ar="الطباعة اتقطعت",
        en="Print was interrupted",
        priority=Priority.URGENT,
        tags=("rotating_light",),
        critical=True,
    ),
    "power_restored": Template(
        ar="الكهرباء رجعت",
        en="Power is back",
        priority=Priority.HIGH,
        tags=("electric_plug",),
    ),
    "filament_runout": Template(
        ar="الفيلامنت خلص - الطباعة واقفة",
        en="Filament ran out - print paused",
        priority=Priority.URGENT,
        tags=("thread", "warning"),
        critical=True,
    ),
    "klipper_error": Template(
        ar="خطأ في Klipper",
        en="Klipper error",
        priority=Priority.URGENT,
        tags=("rotating_light",),
        critical=True,
    ),
    "vision_alert": Template(
        ar="الكاميرا شافت مشكلة في الطباعة",
        en="The camera spotted a problem",
        priority=Priority.URGENT,
        tags=("camera", "warning"),
        critical=True,
    ),
    "ai_pause_failed": Template(
        ar="حاولت أوقف الطباعة ومقدرتش",
        en="Could not pause the print",
        priority=Priority.URGENT,
        tags=("rotating_light",),
        critical=True,
    ),
    "anomaly": Template(
        ar="الطابعة بتتصرف بشكل غير طبيعي",
        en="The printer is behaving abnormally",
        priority=Priority.HIGH,
        tags=("chart_with_upwards_trend", "warning"),
        critical=True,
    ),
    "safety_blocked": Template(
        ar="أمر اتمنع لأسباب أمان",
        en="A command was blocked for safety",
        priority=Priority.HIGH,
        tags=("shield",),
    ),
    # ---- print lifecycle ---------------------------------------------------
    "print_started": Template(
        ar="بدأت الطباعة",
        en="Print started",
        priority=Priority.DEFAULT,
        tags=("printer",),
    ),
    "print_finished": Template(
        ar="الطباعة خلصت",
        en="Print finished",
        priority=Priority.HIGH,
        tags=("white_check_mark",),
    ),
    "print_failed": Template(
        ar="الطباعة اتلغت",
        en="Print cancelled",
        priority=Priority.HIGH,
        tags=("x",),
        critical=True,
    ),
    "print_paused": Template(
        ar="الطباعة اتوقفت مؤقتاً",
        en="Print paused",
        priority=Priority.HIGH,
        tags=("pause_button",),
    ),
    "print_resumed": Template(
        ar="الطباعة كمّلت",
        en="Print resumed",
        priority=Priority.DEFAULT,
        tags=("arrow_forward",),
    ),
    "first_layer_complete": Template(
        ar="أول طبقة خلصت",
        en="First layer complete",
        priority=Priority.LOW,
        tags=("heavy_check_mark",),
    ),
    "print_halfway": Template(
        ar="الطباعة وصلت نص الطريق",
        en="Print is halfway",
        priority=Priority.LOW,
        tags=("hourglass_flowing_sand",),
        noisy=True,
    ),
    # ---- connectivity ------------------------------------------------------
    "disconnected": Template(
        ar="الطابعة مش متصلة",
        en="Printer disconnected",
        priority=Priority.HIGH,
        tags=("warning",),
    ),
    "connected": Template(
        ar="الطابعة رجعت اتصلت",
        en="Printer reconnected",
        priority=Priority.LOW,
        tags=("link",),
    ),
    # ---- power -------------------------------------------------------------
    "auto_power_off": Template(
        ar="الطابعة اتفصلت أوتوماتيك",
        en="Printer powered off automatically",
        priority=Priority.LOW,
        tags=("electric_plug",),
    ),
    "auto_power_off_failed": Template(
        ar="فشل الفصل الأوتوماتيكي للكهرباء",
        en="Automatic power off failed",
        priority=Priority.HIGH,
        tags=("warning",),
    ),
    # ---- housekeeping ------------------------------------------------------
    "target_reached": Template(
        ar="الحرارة وصلت للمطلوب",
        en="Target temperature reached",
        priority=Priority.MIN,
        tags=("thermometer",),
        noisy=True,
    ),
    "test": Template(
        ar="تجربة إشعارات من الطابعة",
        en="Test notification",
        priority=Priority.DEFAULT,
        tags=("bell",),
    ),
}


def default_event_kinds() -> List[str]:
    """Everything except the chatty ones, which are opt-in."""
    return sorted(kind for kind, template in TEMPLATES.items() if not template.noisy)


def all_event_kinds() -> List[str]:
    return sorted(TEMPLATES)


def critical_kinds() -> List[str]:
    return sorted(kind for kind, template in TEMPLATES.items() if template.critical)


def render(
    kind: str,
    *,
    language: str = "ar",
    fallback_title: str = "",
    message: str = "",
    filename: str = "",
    timestamp: float = 0.0,
    priority: Optional[Priority] = None,
) -> Notification:
    """Turn a raw backend event into something worth reading on a lock screen."""
    template = TEMPLATES.get(kind)

    if template is None:
        # An event kind nobody wrote a template for. Deliver it anyway with its
        # own title rather than swallowing it - a missing translation is a
        # cosmetic problem, a missing alert is not.
        return Notification(
            kind=kind,
            title=fallback_title or kind.replace("_", " "),
            message=message,
            priority=priority or Priority.DEFAULT,
            filename=filename,
            timestamp=timestamp,
        )

    title = template.ar if language.lower().startswith("ar") else template.en
    if filename:
        title = f"{title} - {filename}"

    return Notification(
        kind=kind,
        title=title,
        message=message,
        priority=priority or template.priority,
        tags=list(template.tags),
        filename=filename,
        timestamp=timestamp,
        critical=template.critical,
    )
