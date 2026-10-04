"""What actually works on this printer, according to this printer.

Every setting recommendation in every slicer is somebody else's average. This
one is not: it is a count of what happened on this machine, with this filament,
at this layer height. That makes it far narrower than general advice and far
more likely to be right - and it makes honesty about sample size essential,
because "PETG fails half the time" from two prints is not a finding, it is
noise wearing a percentage sign.

So nothing is claimed below a minimum count, and what is claimed always carries
the count next to it.

The one inference worth making beyond counting: **when** a print failed. A
cancelled print whose duration is a small fraction of the slicer's estimate
died near the start, and the start is the first layer. A cluster of early
failures on one material is an adhesion problem, which is a completely
different fix from a cluster of late ones.
"""

from __future__ import annotations

import statistics
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence

# Below this, a percentage is noise. Chosen so one bad print cannot produce a
# "this combination fails" headline.
MIN_SAMPLES = 4
# A failure this early in the estimated time is a first-layer failure.
EARLY_FAILURE_FRACTION = 0.20
# Share of failures that must be early before adhesion is named as the cause.
EARLY_CLUSTER_SHARE = 0.6
# Success rate below which a combination is called out.
POOR_SUCCESS_RATE = 0.7


@dataclass
class Outcome:
    """One finished print, reduced to what matters for learning."""

    result: str
    duration: Optional[float] = None
    estimated_seconds: Optional[float] = None
    filament_type: Optional[str] = None
    print_profile: Optional[str] = None
    layer_height: Optional[float] = None

    @property
    def succeeded(self) -> bool:
        return self.result == "completed"

    @property
    def counts(self) -> bool:
        """Interrupted prints say nothing about the settings.

        A power cut is not the profile's fault, and counting it would teach the
        app that whatever was loaded that day is unreliable.
        """
        return self.result in {"completed", "cancelled", "error"}

    @property
    def failed_early(self) -> Optional[bool]:
        """Did this die near the start? None when there is nothing to compare."""
        if self.succeeded or not self.duration or not self.estimated_seconds:
            return None
        if self.estimated_seconds <= 0:
            return None
        return (self.duration / self.estimated_seconds) < EARLY_FAILURE_FRACTION


@dataclass
class Combination:
    """One material-and-settings pairing, and how it has gone."""

    filament_type: str
    print_profile: str
    layer_height: Optional[float]

    total: int = 0
    succeeded: int = 0
    early_failures: int = 0
    late_failures: int = 0

    @property
    def failed(self) -> int:
        return self.total - self.succeeded

    @property
    def success_rate(self) -> Optional[float]:
        if self.total < MIN_SAMPLES:
            return None
        return self.succeeded / self.total

    @property
    def is_conclusive(self) -> bool:
        return self.total >= MIN_SAMPLES

    @property
    def key(self) -> str:
        layer = f"{self.layer_height:.2f}" if self.layer_height else "?"
        return f"{self.filament_type}|{self.print_profile}|{layer}"

    @property
    def label_ar(self) -> str:
        parts = [self.filament_type or "خامة غير معروفة"]
        if self.print_profile:
            parts.append(self.print_profile)
        if self.layer_height:
            parts.append(f"طبقة {self.layer_height:.2f} مم")
        return " · ".join(parts)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "key": self.key,
            "filament_type": self.filament_type,
            "print_profile": self.print_profile,
            "layer_height": self.layer_height,
            "label_ar": self.label_ar,
            "total": self.total,
            "succeeded": self.succeeded,
            "failed": self.failed,
            "early_failures": self.early_failures,
            "late_failures": self.late_failures,
            "success_rate": (
                round(self.success_rate, 3) if self.success_rate is not None else None
            ),
            "conclusive": self.is_conclusive,
        }


@dataclass
class Insight:
    """Something the history says, with the count that says it."""

    id: str
    title_ar: str
    detail_ar: str
    suggestion_ar: str = ""
    #: The combination it is about, when it is about one.
    combination: Optional[str] = None
    samples: int = 0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "title_ar": self.title_ar,
            "detail_ar": self.detail_ar,
            "suggestion_ar": self.suggestion_ar,
            "combination": self.combination,
            "samples": self.samples,
        }


def summarise(outcomes: Sequence[Outcome]) -> List[Combination]:
    """Group finished prints by material and settings."""
    groups: Dict[str, Combination] = {}

    for outcome in outcomes:
        if not outcome.counts:
            continue
        combination = Combination(
            filament_type=(outcome.filament_type or "").strip() or "غير معروف",
            print_profile=(outcome.print_profile or "").strip() or "غير معروف",
            layer_height=round(outcome.layer_height, 2) if outcome.layer_height else None,
        )
        existing = groups.setdefault(combination.key, combination)
        existing.total += 1
        if outcome.succeeded:
            existing.succeeded += 1
        else:
            early = outcome.failed_early
            if early is True:
                existing.early_failures += 1
            elif early is False:
                existing.late_failures += 1

    return sorted(groups.values(), key=lambda item: (-item.total, item.key))


def _material_totals(combinations: Sequence[Combination]) -> Dict[str, Combination]:
    """Roll up per material, so a material used across several profiles still
    accumulates enough samples to say something."""
    totals: Dict[str, Combination] = {}
    for item in combinations:
        rolled = totals.setdefault(
            item.filament_type,
            Combination(filament_type=item.filament_type, print_profile="", layer_height=None),
        )
        rolled.total += item.total
        rolled.succeeded += item.succeeded
        rolled.early_failures += item.early_failures
        rolled.late_failures += item.late_failures
    return totals


def insights(combinations: Sequence[Combination]) -> List[Insight]:
    """Everything the counts support saying. Nothing they do not."""
    found: List[Insight] = []

    # ---- the best combination, when there is enough to pick one ------------
    conclusive = [item for item in combinations if item.is_conclusive]
    reliable = [item for item in conclusive if (item.success_rate or 0) >= 0.9]
    if reliable:
        best = max(reliable, key=lambda item: (item.success_rate or 0, item.total))
        found.append(
            Insight(
                id="best_combination",
                title_ar="أكثر تركيبة نجحت معاك",
                detail_ar=(
                    f"«{best.label_ar}» نجحت {best.succeeded} من {best.total} مرة "
                    f"({(best.success_rate or 0) * 100:.0f}٪)."
                ),
                suggestion_ar="لو مش متأكد من إعدادات طبعة مهمة، ابدأ من دي.",
                combination=best.key,
                samples=best.total,
            )
        )

    # ---- combinations that keep failing ------------------------------------
    for item in conclusive:
        rate = item.success_rate or 0
        if rate >= POOR_SUCCESS_RATE:
            continue

        early_share = item.early_failures / item.failed if item.failed else 0
        if early_share >= EARLY_CLUSTER_SHARE and item.early_failures >= 2:
            # Early failures cluster at the first layer, which is an adhesion
            # problem - a completely different fix from failing at layer 200.
            detail = (
                f"«{item.label_ar}» نجحت {item.succeeded} من {item.total} بس، "
                f"و{item.early_failures} من الفشل حصل في أول ٢٠٪ من الطباعة — "
                "يعني الطبقة الأولى مش بتلزق."
            )
            suggestion = (
                "جرّب: ارفع حرارة السرير ٥ درجات، بطّئ الطبقة الأولى، "
                "ونضّف السرير بالكحول. ولو المشكلة مستمرة اعمل معايرة Z offset."
            )
            insight_id = "early_failures"
        else:
            detail = (
                f"«{item.label_ar}» نجحت {item.succeeded} من {item.total} بس "
                f"({rate * 100:.0f}٪)، والفشل مش مركّز في أول الطباعة."
            )
            suggestion = (
                "الفشل المتأخر عادة بيكون التصاق طبقات أو انسداد. "
                "جرّب برج الحرارة من صفحة المعايرة."
            )
            insight_id = "poor_combination"

        found.append(
            Insight(
                id=insight_id,
                title_ar="تركيبة بتفشل كتير",
                detail_ar=detail,
                suggestion_ar=suggestion,
                combination=item.key,
                samples=item.total,
            )
        )

    # ---- a material that struggles across every profile --------------------
    for material, rolled in _material_totals(combinations).items():
        if material == "غير معروف" or not rolled.is_conclusive:
            continue
        rate = rolled.succeeded / rolled.total
        if rate >= POOR_SUCCESS_RATE:
            continue
        # Only worth saying separately when no single combination already
        # explained it - otherwise it is the same finding twice.
        if any(
            item.filament_type == material and item.is_conclusive and (item.success_rate or 1) < POOR_SUCCESS_RATE
            for item in combinations
        ):
            continue
        found.append(
            Insight(
                id="material_struggles",
                title_ar=f"{material} بتتعبك",
                detail_ar=(
                    f"{material} نجحت {rolled.succeeded} من {rolled.total} على كل "
                    "الإعدادات اللي جربتها — يعني المشكلة في الخامة أو تخزينها، "
                    "مش في بروفايل معين."
                ),
                suggestion_ar=(
                    "الخامات اللي بتشرب رطوبة (PETG وNylon وTPU) بتفشل كده لما "
                    "تكون متبلّلة. جفّفها ٤-٦ ساعات وجرّب تاني."
                ),
                samples=rolled.total,
            )
        )

    # ---- nothing to say yet, said plainly ---------------------------------
    if not found:
        total = sum(item.total for item in combinations)
        needed = max(0, MIN_SAMPLES - max((item.total for item in combinations), default=0))
        found.append(
            Insight(
                id="not_enough_data",
                title_ar="لسه مفيش بيانات كفاية",
                detail_ar=(
                    f"عندك {total} طبعة مسجّلة. محتاج على الأقل {MIN_SAMPLES} طبعات "
                    "بنفس الخامة والإعدادات قبل ما أقدر أقول حاجة مش تخمين."
                    + (f" ناقص {needed}." if needed else "")
                ),
                samples=total,
            )
        )

    return found


def duration_accuracy(outcomes: Sequence[Outcome]) -> Optional[Dict[str, float]]:
    """How far off the slicer's estimates run, per material.

    Separate from the global calibration the time estimator learns, because
    materials differ: PETG prints at a lower volumetric ceiling, so its prints
    overrun the slicer by more than PLA's do.
    """
    ratios: Dict[str, List[float]] = {}
    for outcome in outcomes:
        if not outcome.succeeded or not outcome.duration or not outcome.estimated_seconds:
            continue
        if outcome.estimated_seconds <= 0:
            continue
        material = (outcome.filament_type or "").strip() or "غير معروف"
        ratios.setdefault(material, []).append(outcome.duration / outcome.estimated_seconds)

    result = {
        material: round(statistics.median(values), 3)
        for material, values in ratios.items()
        if len(values) >= 3
    }
    return result or None


def report(outcomes: Sequence[Outcome]) -> Dict[str, Any]:
    combinations = summarise(outcomes)
    return {
        "combinations": [item.to_dict() for item in combinations],
        "insights": [item.to_dict() for item in insights(combinations)],
        "duration_accuracy": duration_accuracy(outcomes),
        "min_samples": MIN_SAMPLES,
        "total_prints": sum(item.total for item in combinations),
    }
