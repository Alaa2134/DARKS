"""Print modes: one choice, coherent settings, and an honest promise.

A dropdown of profile names is not the feature. The profiles already exist -
fast, standard, quality - and the problem with picking one is that the name
frequently lies:

* ``fast.ini`` asks for 5000 mm/s2 acceleration. The Neptune's printer profile
  caps extruding acceleration at 3000. The slicer emits the higher number,
  Klipper clamps it, and the print is slower than the estimate promised - with
  nothing anywhere saying so.

* ``fast.ini`` asks for 150 mm/s infill. At a 0.28 mm layer and 0.45 mm
  extrusion width that is 18.9 mm3/s of plastic. PETG's profile caps volumetric
  flow at 8 mm3/s, so the slicer quietly drops the speed to about 63 mm/s.
  "Fast" with PETG runs at 42 % of the speed its name implies.

So a mode here is an *intent* - draft, strong, fine detail - resolved against
three real constraints before it becomes numbers:

1. the nozzle (layer height is a ratio of it, not a constant),
2. the material's volumetric limit (the ceiling nobody accounts for),
3. the machine's own acceleration and feedrate limits.

Everything that gets clamped is reported with the reason and both numbers, so
the mode's promise matches what the printer will actually do.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

# PrusaSlicer's usual extrusion width when nothing overrides it.
DEFAULT_WIDTH_RATIO = 1.125
# Sane bounds for a layer height as a fraction of the nozzle. Below the first
# the layer will not bond reliably; above it the nozzle cannot push the plastic
# down flat enough to stick to the layer beneath.
MIN_LAYER_RATIO = 0.25
MAX_LAYER_RATIO = 0.75

# The mode everything else is compared against for the "how much faster" number.
REFERENCE_MODE = "balanced"
# Two modes within this much of each other take, for practical purposes, the
# same time.
EQUIVALENT_TOLERANCE = 0.05


@dataclass(frozen=True)
class ModeSpec:
    """An intent, expressed as ratios rather than absolute numbers.

    Ratios because a 0.2 mm layer means something different on a 0.4 nozzle
    than on a 0.6, and a mode defined in millimetres silently stops making
    sense the moment the nozzle changes.
    """

    id: str
    title_ar: str
    title_en: str
    description_ar: str
    #: Layer height as a fraction of the nozzle diameter.
    layer_ratio: float
    perimeters: int
    infill_percent: int
    infill_pattern: str
    #: Print speed as a fraction of what the base profile asks for.
    speed_scale: float
    #: Acceleration to request, before the machine's own cap is applied.
    acceleration: float
    base_profile: str
    #: Shown so the user knows what they are trading away.
    tradeoff_ar: str


MODES: Dict[str, ModeSpec] = {
    "draft": ModeSpec(
        id="draft",
        title_ar="مسودة",
        title_en="Draft",
        description_ar="أسرع حاجة ممكنة. للتجربة وتأكيد المقاسات قبل الطباعة الحقيقية.",
        layer_ratio=0.70,
        perimeters=2,
        infill_percent=10,
        infill_pattern="grid",
        speed_scale=1.0,
        acceleration=5000,
        base_profile="fast",
        tradeoff_ar="خطوط الطبقات هتبان بوضوح، والقطعة أضعف من العادي.",
    ),
    "fast": ModeSpec(
        id="fast",
        title_ar="سريع",
        title_en="Fast",
        description_ar="أسرع بشكل ملحوظ وشكل مقبول. للقطع اللي مش هتتشاف عن قرب.",
        layer_ratio=0.55,
        perimeters=2,
        infill_percent=15,
        infill_pattern="grid",
        speed_scale=0.9,
        acceleration=4000,
        base_profile="fast",
        tradeoff_ar="السطح أخشن شوية من المتوازن.",
    ),
    "balanced": ModeSpec(
        id="balanced",
        title_ar="متوازن",
        title_en="Balanced",
        description_ar="الوضع الافتراضي. توازن معقول بين الوقت والشكل والمتانة.",
        layer_ratio=0.50,
        perimeters=3,
        infill_percent=20,
        infill_pattern="grid",
        speed_scale=0.75,
        acceleration=3000,
        base_profile="standard",
        tradeoff_ar="مفيش — ده نقطة المقارنة لباقي الأوضاع.",
    ),
    "quality": ModeSpec(
        id="quality",
        title_ar="جودة عالية",
        title_en="Quality",
        description_ar="طبقات رفيعة وسرعة أقل. أنضف سطح ممكن.",
        layer_ratio=0.35,
        perimeters=3,
        infill_percent=20,
        infill_pattern="gyroid",
        speed_scale=0.55,
        acceleration=2000,
        base_profile="quality",
        tradeoff_ar="بتاخد وقت أطول بكتير — احسبها قبل ما تبدأ.",
    ),
    "strong": ModeSpec(
        id="strong",
        title_ar="متين",
        title_en="Strong",
        description_ar="للقطع الوظيفية اللي هتشيل حمل. جدران أكتر وتعبئة أعلى.",
        layer_ratio=0.50,
        perimeters=5,
        infill_percent=45,
        infill_pattern="gyroid",
        speed_scale=0.65,
        acceleration=2500,
        base_profile="standard",
        tradeoff_ar="بتستهلك فيلامنت أكتر بكتير، والوقت أطول.",
    ),
    "miniature": ModeSpec(
        id="miniature",
        title_ar="تفاصيل دقيقة",
        title_en="Fine detail",
        description_ar="للقطع الصغيرة والتماثيل. أرفع طبقة والماكينة بتمشي بالراحة.",
        layer_ratio=0.28,
        perimeters=3,
        infill_percent=15,
        infill_pattern="gyroid",
        speed_scale=0.45,
        acceleration=1500,
        base_profile="quality",
        tradeoff_ar="أبطأ وضع في القايمة، ومش مناسب للقطع الكبيرة.",
    ),
}


@dataclass
class Adjustment:
    """One value the mode asked for and could not have."""

    setting: str
    requested: float
    applied: float
    reason_ar: str
    reason_en: str

    def to_dict(self) -> Dict[str, Any]:
        return {
            "setting": self.setting,
            "requested": round(self.requested, 3),
            "applied": round(self.applied, 3),
            "reason_ar": self.reason_ar,
            "reason_en": self.reason_en,
        }


@dataclass
class ResolvedMode:
    """What the mode actually becomes on this printer with this material."""

    id: str
    title_ar: str
    title_en: str
    description_ar: str
    tradeoff_ar: str
    base_profile: str

    layer_height: float
    first_layer_height: float
    perimeters: int
    infill_percent: int
    infill_pattern: str
    print_speed: float
    acceleration: float

    #: Every value the machine or material would not allow, with both numbers.
    adjustments: List[Adjustment] = field(default_factory=list)
    #: Roughly how long this takes against the balanced mode. 1.0 is the same.
    relative_time: float = 1.0
    #: Flow this mode will actually run at, mm3/s.
    volumetric_flow: float = 0.0
    #: Things worth saying that are not a clamp - chiefly "this mode will not
    #: actually be faster than balanced, and here is why".
    notes_ar: List[str] = field(default_factory=list)

    @property
    def flow_limited(self) -> bool:
        return any(
            item.setting == "print_speed" and "مم³/ث" in item.reason_ar
            for item in self.adjustments
        )

    @property
    def was_clamped(self) -> bool:
        return bool(self.adjustments)

    def overrides(self) -> Dict[str, Any]:
        """The fields to put on a SliceRequest."""
        return {
            "print_profile": self.base_profile,
            "layer_height": round(self.layer_height, 3),
            "first_layer_height": round(self.first_layer_height, 3),
            "perimeters": self.perimeters,
            "infill_percent": self.infill_percent,
            "infill_pattern": self.infill_pattern,
        }

    def speed_overrides(self) -> Dict[str, float]:
        """Speeds and accelerations, already inside every limit."""
        speed = round(self.print_speed, 1)
        return {
            "perimeter_speed": round(speed * 0.6, 1),
            "external_perimeter_speed": round(speed * 0.35, 1),
            "infill_speed": speed,
            "solid_infill_speed": round(speed * 0.8, 1),
            "top_solid_infill_speed": round(speed * 0.35, 1),
            "default_acceleration": round(self.acceleration),
            "perimeter_acceleration": round(self.acceleration),
            "infill_acceleration": round(self.acceleration),
            "travel_acceleration": round(self.acceleration),
        }

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "title_ar": self.title_ar,
            "title_en": self.title_en,
            "description_ar": self.description_ar,
            "tradeoff_ar": self.tradeoff_ar,
            "layer_height": round(self.layer_height, 3),
            "perimeters": self.perimeters,
            "infill_percent": self.infill_percent,
            "print_speed": round(self.print_speed, 1),
            "acceleration": round(self.acceleration),
            "volumetric_flow": round(self.volumetric_flow, 2),
            "relative_time": round(self.relative_time, 2),
            "flow_limited": self.flow_limited,
            "notes_ar": list(self.notes_ar),
            "adjustments": [item.to_dict() for item in self.adjustments],
            "was_clamped": self.was_clamped,
            "overrides": self.overrides(),
            "speed_overrides": self.speed_overrides(),
        }


def _number(values: Dict[str, str], key: str) -> Optional[float]:
    raw = values.get(key)
    if raw is None:
        return None
    try:
        return float(str(raw).strip().rstrip("%"))
    except (TypeError, ValueError):
        return None


def resolve(
    mode_id: str,
    *,
    printer_values: Optional[Dict[str, str]] = None,
    filament_values: Optional[Dict[str, str]] = None,
    print_values: Optional[Dict[str, str]] = None,
    max_accel: Optional[float] = None,
    max_velocity: Optional[float] = None,
) -> Optional[ResolvedMode]:
    """Turn an intent into numbers this printer can actually hit.

    ``max_accel`` and ``max_velocity`` come from the live ``printer.cfg`` when
    it is readable, and take priority over the slicer's printer profile - the
    config is what Klipper actually enforces.
    """
    spec = MODES.get(mode_id)
    if spec is None:
        return None

    printer_values = printer_values or {}
    filament_values = filament_values or {}
    print_values = print_values or {}
    adjustments: List[Adjustment] = []

    nozzle = _number(printer_values, "nozzle_diameter") or 0.4
    width = _number(printer_values, "extrusion_width") or nozzle * DEFAULT_WIDTH_RATIO

    # ---- layer height ------------------------------------------------------
    requested_layer = spec.layer_ratio * nozzle
    layer = requested_layer

    floor = _number(printer_values, "min_layer_height") or nozzle * MIN_LAYER_RATIO
    ceiling = _number(printer_values, "max_layer_height") or nozzle * MAX_LAYER_RATIO
    # A profile that allows more than 75 % of the nozzle is optimistic; the
    # plastic cannot be pressed flat enough to bond at that height.
    ceiling = min(ceiling, nozzle * MAX_LAYER_RATIO)

    if layer > ceiling:
        adjustments.append(
            Adjustment(
                setting="layer_height",
                requested=requested_layer,
                applied=ceiling,
                reason_ar=(
                    f"أقصى ارتفاع طبقة لنوزل {nozzle:.1f} مم هو {ceiling:.2f} مم — "
                    "أعلى من كده الطبقات مش بتلزق في بعض."
                ),
                reason_en=f"Layer height capped at {ceiling:.2f} mm for a {nozzle:.1f} mm nozzle",
            )
        )
        layer = ceiling
    elif layer < floor:
        adjustments.append(
            Adjustment(
                setting="layer_height",
                requested=requested_layer,
                applied=floor,
                reason_ar=f"أقل ارتفاع طبقة تدعمه الطابعة هو {floor:.2f} مم.",
                reason_en=f"Layer height raised to the printer's minimum of {floor:.2f} mm",
            )
        )
        layer = floor

    # ---- speed -------------------------------------------------------------
    base_speed = _number(print_values, "infill_speed") or 80.0
    requested_speed = base_speed * spec.speed_scale
    speed = requested_speed

    # The ceiling nobody accounts for: the hotend can only melt so much plastic
    # per second, and asking for more does not go faster - the slicer silently
    # slows the whole print down instead, so the estimate was never real.
    volumetric_limit = _number(filament_values, "filament_max_volumetric_speed")
    if volumetric_limit and volumetric_limit > 0:
        flow_limited_speed = volumetric_limit / max(layer * width, 1e-6)
        if flow_limited_speed < speed:
            material = filament_values.get("filament_type", "").strip() or "الخامة"
            adjustments.append(
                Adjustment(
                    setting="print_speed",
                    requested=requested_speed,
                    applied=flow_limited_speed,
                    reason_ar=(
                        f"{material} مش بتسيح أسرع من {volumetric_limit:.0f} مم³/ث. "
                        f"عند طبقة {layer:.2f} مم، ده معناه {flow_limited_speed:.0f} مم/ث كحد أقصى — "
                        f"مش {requested_speed:.0f}."
                    ),
                    reason_en=(
                        f"{material} melts at most {volumetric_limit:.0f} mm3/s, "
                        f"which is {flow_limited_speed:.0f} mm/s at this layer height"
                    ),
                )
            )
            speed = flow_limited_speed

    machine_speed = max_velocity or _number(printer_values, "machine_max_feedrate_x")
    if machine_speed and machine_speed > 0 and speed > machine_speed:
        adjustments.append(
            Adjustment(
                setting="print_speed",
                requested=speed,
                applied=machine_speed,
                reason_ar=f"أقصى سرعة للماكينة {machine_speed:.0f} مم/ث.",
                reason_en=f"The machine's maximum velocity is {machine_speed:.0f} mm/s",
            )
        )
        speed = machine_speed

    # ---- acceleration ------------------------------------------------------
    acceleration = spec.acceleration
    machine_accel = max_accel or _number(printer_values, "machine_max_acceleration_extruding")
    if machine_accel and machine_accel > 0 and acceleration > machine_accel:
        adjustments.append(
            Adjustment(
                setting="acceleration",
                requested=spec.acceleration,
                applied=machine_accel,
                reason_ar=(
                    f"الوضع ده بيطلب تسارع {spec.acceleration:.0f}، والماكينة حدها "
                    f"{machine_accel:.0f}. من غير التعديل ده Klipper كان هيقلّلها لوحده "
                    "والوقت المتوقع كان هيطلع غلط."
                ),
                reason_en=(
                    f"Acceleration capped at the machine limit of {machine_accel:.0f} mm/s2"
                ),
            )
        )
        acceleration = machine_accel

    first_layer = min(max(layer, 0.2), ceiling)
    flow = speed * layer * width

    return ResolvedMode(
        id=spec.id,
        title_ar=spec.title_ar,
        title_en=spec.title_en,
        description_ar=spec.description_ar,
        tradeoff_ar=spec.tradeoff_ar,
        base_profile=spec.base_profile,
        layer_height=layer,
        first_layer_height=first_layer,
        perimeters=spec.perimeters,
        infill_percent=spec.infill_percent,
        infill_pattern=spec.infill_pattern,
        print_speed=speed,
        acceleration=acceleration,
        adjustments=adjustments,
        volumetric_flow=flow,
    )


def annotate_comparison(modes: List[ResolvedMode]) -> List[ResolvedMode]:
    """Fill in each mode's time relative to balanced, and the honest notes.

    Separate from :func:`resolve` because a relative time is only meaningful
    against the others - and separate from :func:`resolve_all` because the API
    resolves each mode against its own base profile and would otherwise have to
    duplicate this, which is exactly how two copies of a rule drift apart.

    The relative time is deliberately rough: it assumes time scales with layer
    height times speed, ignoring perimeters, infill density and travel. It is a
    "roughly twice as long" signal, not an estimate, and the UI says so.
    """
    reference = next((item for item in modes if item.id == REFERENCE_MODE), None)
    if reference is None or reference.layer_height <= 0 or reference.print_speed <= 0:
        return modes

    reference_rate = reference.layer_height * reference.print_speed
    for mode in modes:
        rate = mode.layer_height * mode.print_speed
        mode.relative_time = reference_rate / rate if rate > 0 else 1.0

    # The finding that makes this feature worth having.
    #
    # Once two modes are both limited by how fast the plastic melts, they take
    # the same time: a thicker layer at a proportionally lower speed is the
    # same volume per second. So the coarser of the two is pure loss - the same
    # wait for a worse surface.
    #
    # Compared against the next *finer* mode rather than against balanced,
    # because that is where the equivalence actually shows up. On PETG, draft
    # is genuinely quicker than balanced but identical to fast - so "draft
    # saves nothing" is only true, and only useful, next to fast.
    for mode in modes:
        if not mode.flow_limited:
            continue
        finer = [
            other
            for other in modes
            if other is not mode
            and other.layer_height < mode.layer_height
            and other.relative_time <= mode.relative_time * (1 + EQUIVALENT_TOLERANCE)
        ]
        if not finer:
            continue
        best = min(finer, key=lambda item: item.layer_height)
        mode.notes_ar.append(
            f"مش هيكون أسرع من «{best.title_ar}» مع الخامة دي — "
            f"الاتنين واصلين لحد سيحان البلاستيك ({mode.volumetric_flow:.0f} مم³/ث)، "
            f"فالوقت واحد. «{best.title_ar}» هيديك نفس الوقت بسطح أنضف."
        )
    return modes


def resolve_all(**kwargs) -> List[ResolvedMode]:
    """Every mode against one set of profiles, already compared."""
    resolved = [resolve(mode_id, **kwargs) for mode_id in MODES]
    return annotate_comparison([item for item in resolved if item is not None])
