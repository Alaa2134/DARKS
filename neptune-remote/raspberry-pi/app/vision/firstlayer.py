"""Reading a first-layer test patch and turning it into a Z number.

Most prints that fail, fail on the first layer, and the first layer is set by
one number that everyone eyeballs. This measures it instead.

**The physics that makes a number possible.** Extrusion is volume-conserving:
for a given feed rate and travel speed, the plastic laid down per millimetre is
fixed. Squash it into a smaller gap and it spreads wider; lift the nozzle and it
draws narrower. So for a commanded first-layer height ``h0`` and a real gap
``h0 + d``:

    w * (h0 + d) = w0 * h0        =>        d = h0 * (w0 / w - 1)

where ``w0`` is the extrusion width the pattern was generated with and ``w`` is
the width actually printed. Measure ``w`` and the Z error falls out.

**How ``w`` is measured without knowing anything about the camera.** The patch
is parallel lines at a *known* spacing. Whatever the lens, the distance, or the
resolution, the peak-to-peak spacing in pixels corresponds to that known
spacing in millimetres - so the image supplies its own scale bar. Line width in
pixels then converts straight to millimetres. Spacing is set to *three times* the
extrusion width rather than twice. Twice would put a correct layer at exactly
50 % duty - and at 50 % the lines and the gaps are the same size, so nothing in
a greyscale profile can say which of the two is plastic. At a third, the lines
are unambiguously the narrower of the two runs for any error worth correcting.

**What it refuses to do.** Every step above assumes the patch is in focus,
roughly square-on, and visible against the bed. When it is not - too few lines
found, not enough contrast, spacing that varies across the frame because the
camera is at an angle - it returns ``unreadable`` and says which check failed.
It does not produce a smaller number with lower confidence, because a Z offset
applied from a bad measurement drives the nozzle into the bed.

The correction is also capped. An apparent error beyond a tenth of a millimetre
is the measurement being wrong, not the Z being that far out.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, List, Optional, Sequence

try:  # pragma: no cover - exercised by the availability test
    import numpy as np
except Exception:  # pragma: no cover
    np = None  # type: ignore

from .providers import crop_roi, decode_frame

# Working resolution. Large enough to resolve ~1 mm lines across a 40 mm patch,
# small enough to stay cheap on a Raspberry Pi.
WORK_SIZE = (640, 480)

#: Lines needed before the spacing measurement means anything.
MIN_LINES = 5
#: Contrast between line and gap, 0..1. Below this the filament is not
#: distinguishable from the bed - dark grey PLA on a black sheet, or a frame
#: that is simply out of focus.
MIN_CONTRAST = 0.10
#: How much the spacing may drift from one end of the patch to the other. A
#: camera at an angle makes near lines sit further apart than far ones, which
#: breaks the pixels-to-millimetres scale the whole measurement rests on.
MAX_SPACING_DRIFT = 0.15
#: Beyond this the measurement is wrong, not the printer.
MAX_CORRECTION_MM = 0.10
#: Duty cycle above which lines and gaps are too alike to tell apart. The
#: pattern is drawn at a third, so anything approaching a half means the image
#: is not showing what the generator drew.
AMBIGUOUS_DUTY = 0.45
#: Inside this the first layer is as good as it needs to be.
GOOD_ENOUGH_MM = 0.012


class Verdict(str, Enum):
    GOOD = "good"
    TOO_LOW = "too_low"      # nozzle too close: lines squashed wide, no gaps
    TOO_HIGH = "too_high"    # nozzle too far: thin lines, gaps between them
    UNREADABLE = "unreadable"


VERDICT_AR: Dict[str, str] = {
    Verdict.GOOD: "الطبقة الأولى مظبوطة",
    Verdict.TOO_LOW: "النوزل قريب من السرير",
    Verdict.TOO_HIGH: "النوزل بعيد عن السرير",
    Verdict.UNREADABLE: "مش شايف الباترن كويس",
}


@dataclass
class FirstLayerResult:
    verdict: Verdict
    #: Millimetres to add to the Z offset. Positive raises the nozzle.
    z_adjust_mm: Optional[float] = None
    #: 0..1, and only ever set when the verdict is not `unreadable`.
    confidence: float = 0.0
    #: Every number the verdict was computed from.
    measurements: Dict[str, float] = field(default_factory=dict)
    #: Why it could not read the patch, when it could not.
    blockers: List[str] = field(default_factory=list)

    @property
    def readable(self) -> bool:
        return self.verdict is not Verdict.UNREADABLE

    @property
    def command(self) -> Optional[str]:
        """The Klipper command that applies the correction, if there is one."""
        if self.z_adjust_mm is None or abs(self.z_adjust_mm) < GOOD_ENOUGH_MM:
            return None
        return f"SET_GCODE_OFFSET Z_ADJUST={self.z_adjust_mm:+.3f} MOVE=1"

    @property
    def detail_ar(self) -> str:
        if not self.readable:
            return (
                "مقدرتش أقيس الباترن من الصورة. "
                + " ".join(self.blockers)
                + " الرقم الغلط هنا معناه النوزل يتحفر في السرير، فمش هخمّن."
            )
        if self.verdict is Verdict.GOOD:
            return (
                f"عرض الخط المقاس {self.measurements.get('line_width_mm', 0):.3f} مم "
                f"مقابل {self.measurements.get('expected_width_mm', 0):.3f} مم متوقعة — "
                "الفرق أصغر من إنه يستاهل تعديل."
            )
        direction = "بعيد" if self.verdict is Verdict.TOO_HIGH else "قريب"
        return (
            f"الخطوط طلعت بعرض {self.measurements.get('line_width_mm', 0):.3f} مم "
            f"والمفروض {self.measurements.get('expected_width_mm', 0):.3f} مم. "
            f"يعني النوزل {direction} بحوالي "
            f"{abs(self.z_adjust_mm or 0):.3f} مم."
        )

    def to_dict(self) -> Dict[str, Any]:
        return {
            "verdict": self.verdict.value,
            "verdict_ar": VERDICT_AR[self.verdict],
            "readable": self.readable,
            "z_adjust_mm": (
                round(self.z_adjust_mm, 4) if self.z_adjust_mm is not None else None
            ),
            "command": self.command,
            "confidence": round(self.confidence, 2),
            "measurements": {k: round(v, 4) for k, v in self.measurements.items()},
            "blockers": list(self.blockers),
            "detail_ar": self.detail_ar,
        }


def _unreadable(*blockers: str) -> FirstLayerResult:
    return FirstLayerResult(verdict=Verdict.UNREADABLE, blockers=list(blockers))


def _runs(mask: "np.ndarray") -> List[int]:
    """Lengths of consecutive True runs."""
    lengths: List[int] = []
    count = 0
    for value in mask:
        if value:
            count += 1
        elif count:
            lengths.append(count)
            count = 0
    if count:
        lengths.append(count)
    return lengths


def analyse(
    frame: bytes,
    *,
    expected_spacing_mm: float,
    expected_width_mm: float,
    first_layer_height_mm: float,
    roi: Optional[Sequence[float]] = None,
    horizontal_lines: bool = True,
) -> FirstLayerResult:
    """Measure a first-layer patch. Never guesses."""
    if np is None:
        return _unreadable("numpy مش متثبت على الراسبيري.")
    if expected_spacing_mm <= 0 or expected_width_mm <= 0 or first_layer_height_mm <= 0:
        return _unreadable("قيم الباترن مش صحيحة.")

    gray = decode_frame(frame, WORK_SIZE)
    if gray is None:
        return _unreadable("الصورة مش مقروءة.")

    patch = crop_roi(gray, roi)
    if patch.size == 0 or min(patch.shape) < 32:
        return _unreadable("منطقة الباترن صغيرة أوي في الصورة.")

    # Average along the lines to collapse to a one-dimensional profile across
    # them. Averaging is what makes this robust to a bit of noise and to the
    # texture of the print sheet.
    profile = patch.mean(axis=1 if horizontal_lines else 0)
    if profile.size < 32:
        return _unreadable("منطقة الباترن صغيرة أوي في الصورة.")

    # A three-tap smoothing, enough to kill single-pixel noise without blurring
    # a 1 mm line.
    kernel = np.ones(3, dtype=np.float32) / 3.0
    profile = np.convolve(profile, kernel, mode="valid")

    low, high = float(profile.min()), float(profile.max())
    contrast = high - low
    if contrast < MIN_CONTRAST:
        return _unreadable(
            f"الفرق بين الخطوط والسرير ضعيف جدًا ({contrast:.2f}). "
            "جرّب إضاءة أحسن أو فيلامنت لونه مختلف عن السرير."
        )

    midpoint = (high + low) / 2.0
    # Whichever side is the plastic depends on the filament and the sheet, so
    # take the runs of both and let the geometry decide which is which.
    bright = profile > midpoint
    bright_runs = _runs(bright)
    dark_runs = _runs(~bright)

    if len(bright_runs) < MIN_LINES or len(dark_runs) < MIN_LINES - 1:
        return _unreadable(
            f"لقيت {len(bright_runs)} خط بس، والمفروض على الأقل {MIN_LINES}. "
            "قرّب الكاميرا من الباترن أو ظبّط منطقة الاهتمام."
        )

    # Drop the first and last of each - they are cut off by the crop and would
    # drag the average down.
    bright_runs = bright_runs[1:-1] or bright_runs
    dark_runs = dark_runs[1:-1] or dark_runs

    period_px = float(np.mean(bright_runs) + np.mean(dark_runs))
    if period_px <= 0:
        return _unreadable("مقدرتش أقيس المسافة بين الخطوط.")

    # Perspective check.
    #
    # Measured as spacing *drift* from one end of the patch to the other, not
    # as spread around the mean. A camera at an angle makes near lines sit
    # further apart than far ones - a systematic gradient - and it is that
    # gradient which breaks the single pixels-to-millimetres scale the whole
    # measurement rests on. Spread would also be inflated by ordinary noise,
    # which does not break the scale at all.
    periods = [bright + dark for bright, dark in zip(bright_runs, dark_runs)]
    if len(periods) >= 4:
        midpoint_index = len(periods) // 2
        near = float(np.mean(periods[:midpoint_index]))
        far = float(np.mean(periods[midpoint_index:]))
        drift = abs(far - near) / max((far + near) / 2, 1e-6)
    else:
        drift = 0.0

    if drift > MAX_SPACING_DRIFT:
        return _unreadable(
            f"المسافة بين الخطوط بتتغير {drift * 100:.0f}٪ من أول الصورة لآخرها. "
            "الكاميرا غالبًا بزاوية مايلة على الباترن — صوّرها من فوق قدر الإمكان."
        )

    mm_per_pixel = expected_spacing_mm / period_px

    # Which of the two run sets is the plastic.
    #
    # The filament may be lighter or darker than the sheet, so brightness alone
    # cannot say. Geometry can: the pattern is drawn at three times the
    # extrusion width, so a correct first layer covers a third of it and the
    # lines are always the *narrower* set. Comparing each mean against half the
    # period would not work - the two runs sum to the period, so they are
    # always equidistant from half, and the test is vacuous.
    bright_mean = float(np.mean(bright_runs))
    dark_mean = float(np.mean(dark_runs))
    line_px = min(bright_mean, dark_mean)

    duty = line_px / period_px
    if duty > AMBIGUOUS_DUTY:
        return _unreadable(
            f"الخطوط والفراغات بينهم تقريبًا نفس العرض ({duty * 100:.0f}٪)، "
            "فمش قادر أفرق البلاستيك عن السرير. غالبًا الباترن اتطبع بإعدادات "
            "مختلفة، أو التدفق بعيد جدًا عن المضبوط."
        )

    line_width_mm = line_px * mm_per_pixel

    # Volume conservation: a wider line means the gap was smaller.
    correction = first_layer_height_mm * (expected_width_mm / line_width_mm - 1.0)

    measurements = {
        "line_width_mm": line_width_mm,
        "expected_width_mm": expected_width_mm,
        "spacing_mm": expected_spacing_mm,
        "period_px": period_px,
        "mm_per_pixel": mm_per_pixel,
        "contrast": contrast,
        "spacing_drift": drift,
        "lines_found": float(len(bright_runs)),
        "raw_correction_mm": correction,
    }

    if abs(correction) > MAX_CORRECTION_MM:
        return FirstLayerResult(
            verdict=Verdict.UNREADABLE,
            measurements=measurements,
            blockers=[
                f"الحساب طلع فرق {correction:+.2f} مم، وده أكبر من إن يكون Z offset — "
                "غالبًا الباترن مش ظاهر صح أو التدفق نفسه محتاج معايرة. "
                "اعمل معايرة التدفق (Flow) الأول."
            ],
        )

    if abs(correction) < GOOD_ENOUGH_MM:
        verdict = Verdict.GOOD
    elif correction > 0:
        # Lines came out narrower than expected -> the gap was larger.
        verdict = Verdict.TOO_HIGH
    else:
        verdict = Verdict.TOO_LOW

    # Confidence from the two things that actually make the reading solid: how
    # separable the lines are, and how many were measured.
    confidence = min(
        0.95,
        0.4
        + min(contrast / 0.4, 1.0) * 0.35
        + min(len(bright_runs) / 20.0, 1.0) * 0.2,
    )

    return FirstLayerResult(
        verdict=verdict,
        z_adjust_mm=round(correction, 4),
        confidence=confidence,
        measurements=measurements,
    )
