"""What is actually calibrated on this printer, read from its own config.

The app has had a Z offset wizard, a bed screw wizard and a mesh wizard for a
while. None of them answered the question a person actually has, which is not
"how do I calibrate" but **"is my printer calibrated?"** - and the answer was
three screens deep behind a menu.

Everything here is read from the live ``printer.cfg``. The distinction that
carries most of the weight is between a value someone typed and a value Klipper
wrote: ``SAVE_CONFIG`` appends below ``#*# <---------------------- SAVE_CONFIG``,
so a ``z_offset`` that appears *only* in the hand-written ``[probe]`` section is
the number the printer shipped with, not one anybody measured. Reporting that as
"calibrated" would be the single most misleading thing this file could do, and it
is the state a printer that has never had a good first layer is usually in.

Bed screws are the exception: nothing in printer.cfg records whether the knobs
were ever turned, so the last measurement is remembered instead, and when there
is none the honest answer is "unknown", not "fine".
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from .model import ParsedConfig

#: Past this, a bed screw measurement is old enough that the answer is really
#: "measure again". Beds move: filament tension, a knocked knob, a cold night.
SCREWS_STALE_SECONDS = 30 * 24 * 3600


@dataclass
class CalibrationItem:
    """One thing that either is or is not calibrated, and what to do about it."""

    #: Matches the workflow kind, so the app can open the right wizard without
    #: a second mapping table that would drift out of step with this one.
    id: str
    #: done | missing | unknown | not_applicable
    #:
    #: "unknown" is its own state on purpose. A bed whose screws have never been
    #: measured is not level and is not un-level; saying either would be making
    #: something up.
    state: str
    title_ar: str
    detail_ar: str
    #: What is wrong beyond the headline - a saved mesh nothing loads, a value
    #: that came from the factory rather than from a measurement.
    warnings_ar: List[str] = field(default_factory=list)
    #: The measured value, when there is one worth showing.
    value: Optional[float] = None
    measured_at: Optional[float] = None

    @property
    def ok(self) -> bool:
        return self.state in {"done", "not_applicable"}

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "state": self.state,
            "ok": self.ok,
            "title_ar": self.title_ar,
            "detail_ar": self.detail_ar,
            "warnings_ar": self.warnings_ar,
            "value": self.value,
            "measured_at": self.measured_at,
        }


def _z_offset_item(config: ParsedConfig) -> CalibrationItem:
    if not config.has_probe:
        return CalibrationItem(
            id="z_offset",
            state="not_applicable",
            title_ar="مسافة الفوهة عن السرير (Z offset)",
            detail_ar="الطابعة دي مفيهاش بروب، فالـ Z بيتظبط من المسمار الميكانيكي.",
        )

    saved = config.saved_probe_z_offset
    written = config.probe_z_offset

    if saved is not None:
        return CalibrationItem(
            id="z_offset",
            state="done",
            title_ar="مسافة الفوهة عن السرير (Z offset)",
            detail_ar=f"معايَرة ومحفوظة: {saved:.3f} مم.",
            value=saved,
        )

    if written is not None:
        # The number is *there*, and Klipper will use it, which is exactly why
        # this is worth saying out loud rather than showing a green tick.
        return CalibrationItem(
            id="z_offset",
            state="missing",
            title_ar="مسافة الفوهة عن السرير (Z offset)",
            detail_ar=(
                f"القيمة الموجودة ({written:.3f} مم) مكتوبة بالإيد في الملف، "
                f"مش ناتجة عن معايرة. دي رقم افتراضي بيتقاس منه، والطبقة الأولى "
                f"بتطلع غلط لحد ما تعايره فعلاً."
            ),
            value=written,
        )

    return CalibrationItem(
        id="z_offset",
        state="missing",
        title_ar="مسافة الفوهة عن السرير (Z offset)",
        detail_ar="مفيش z_offset في الملف خالص. الطابعة مش عارفة الفوهة بعيدة قد إيه عن السرير.",
    )


def _screws_item(config: ParsedConfig, last: Optional[Dict[str, Any]]) -> CalibrationItem:
    title = "استواء السرير من المسامير"

    if not config.has_screws_tilt:
        return CalibrationItem(
            id="screws_tilt",
            state="not_applicable",
            title_ar=title,
            detail_ar="مفيش قسم [screws_tilt_adjust] في الملف، فمفيش قياس أوتوماتيك للمسامير.",
        )

    if not last:
        # printer.cfg records nothing about the knobs, so there is genuinely
        # nothing to read here. "Unknown" is the truthful answer.
        return CalibrationItem(
            id="screws_tilt",
            state="unknown",
            title_ar=title,
            detail_ar=(
                "لسه ماتقاسش من التطبيق. الملف مش بيسجّل حالة المسامير، "
                "فالطريقة الوحيدة إنك تقيس."
            ),
        )

    measured_at = last.get("measured_at")
    level = bool(last.get("level"))
    worst = last.get("worst") or ""
    age = time.time() - float(measured_at) if measured_at else None
    stale = age is not None and age > SCREWS_STALE_SECONDS

    warnings: List[str] = []
    if stale:
        days = int(age / 86400)
        warnings.append(f"آخر قياس بقاله {days} يوم. السرير بيتحرك، يستحسن تقيس تاني.")

    if level:
        return CalibrationItem(
            id="screws_tilt",
            state="done" if not stale else "unknown",
            title_ar=title,
            detail_ar="آخر قياس طلع السرير مستوي في حدود السماحية.",
            warnings_ar=warnings,
            measured_at=measured_at,
        )

    return CalibrationItem(
        id="screws_tilt",
        state="missing",
        title_ar=title,
        detail_ar=(
            f"آخر قياس لقى مسامير محتاجة لف{': ' + worst if worst else ''}. "
            f"الميش مش بيعوّض سرير مايل، فده أول حاجة تتظبط."
        ),
        warnings_ar=warnings,
        measured_at=measured_at,
    )


def _mesh_item(config: ParsedConfig) -> CalibrationItem:
    title = "خريطة السرير (Bed mesh)"

    if not config.has_bed_mesh:
        return CalibrationItem(
            id="bed_mesh",
            state="not_applicable",
            title_ar=title,
            detail_ar="مفيش قسم [bed_mesh] في الملف.",
        )

    profiles = config.saved_mesh_profiles
    if not profiles:
        return CalibrationItem(
            id="bed_mesh",
            state="missing",
            title_ar=title,
            detail_ar="مفيش خريطة محفوظة. السرير مش مستوي تمامًا في أي طابعة، والميش هو اللي بيعوّض الباقي.",
        )

    warnings: List[str] = []
    # A saved mesh that nothing loads is not applied to a single print. This is
    # the quietest failure in the whole bed story: everything looks calibrated
    # and none of it reaches the nozzle.
    if not _print_start_loads_mesh(config):
        warnings.append(
            "الخريطة محفوظة بس مفيش حاجة بتحمّلها. من غير BED_MESH_PROFILE LOAD "
            "في PRINT_START، الميش اللي عايرته مش بيتطبق على أي طبعة."
        )

    return CalibrationItem(
        id="bed_mesh",
        state="done",
        title_ar=title,
        detail_ar="محفوظة: " + "، ".join(profiles) + ".",
        warnings_ar=warnings,
    )


def _print_start_loads_mesh(config: ParsedConfig) -> bool:
    """Whether anything in PRINT_START actually applies the saved mesh.

    Read from the macro body rather than assumed, and matched loosely - people
    call it from a wrapper, or load a named profile, or call BED_MESH_CALIBRATE
    every print instead of loading. All three count as "the mesh reaches the
    print"; only silence does not.
    """
    for section in config.sections_of_kind("gcode_macro"):
        if section.label.upper() != "PRINT_START":
            continue
        # The raw block, not the parsed option: a macro body is a dozen
        # indented lines and the option parser keeps one line per key, so
        # `gcode` reads back as an empty string.
        body = config.section_body(section).upper()
        return "BED_MESH_PROFILE" in body or "BED_MESH_CALIBRATE" in body
    return False


def build_status(
    config: ParsedConfig, last_screws: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """The three bed calibrations, in the order they have to be done.

    Screws before mesh before Z offset is not alphabetical and not arbitrary: a
    mesh measured over a tilted bed encodes the tilt, and re-levelling
    afterwards invalidates it. The order is the answer to "where do I start".
    """
    items = [
        _screws_item(config, last_screws),
        _z_offset_item(config),
        _mesh_item(config),
    ]

    outstanding = [item for item in items if not item.ok]
    return {
        "items": [item.to_dict() for item in items],
        "all_done": not outstanding,
        # What to do first, when something is outstanding. One answer, not a
        # list: a person who is not sure whether their printer is calibrated is
        # not helped by being handed three choices.
        "next_id": outstanding[0].id if outstanding else None,
        "next_title_ar": outstanding[0].title_ar if outstanding else "",
    }
