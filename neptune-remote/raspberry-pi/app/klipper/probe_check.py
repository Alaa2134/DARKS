"""Find out why a probe is not working, instead of guessing at it.

"The probe doesn't work" is four different faults with four different fixes, and
they are told apart by two facts: what the probe reads when nothing is touching
it, and what it reads when something is. Everything below is built on that pair.

    at rest    pressed    what it is
    -------    -------    ----------------------------------------------
    open       triggered  working
    triggered  triggered  never releases - stuck, or the pin needs `!`
    open       open       never fires - unplugged, dead, or wrong pin
    triggered  open       wired inverted - the `!` on the pin is wrong

Klipper cannot tell these apart on its own: a probe that reads triggered at rest
fails ``G28`` with "Probe triggered prior to movement", and one that never fires
drives the nozzle into the bed. Both come out as "homing failed".

The third test is repeatability, which is a different question - the probe fires
but not in the same place twice. ``PROBE_ACCURACY`` measures it, and its range is
what ``samples_tolerance`` has to be able to live with. Recommending a tolerance
from a measurement is the point: a number picked without measuring is how this
printer ended up unable to home at all.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

#: How much slack a tolerance needs over the measured spread.
#:
#: samples_tolerance is the most a set of readings may disagree by before
#: Klipper retries. Set it exactly at the measured range and roughly half of all
#: probes fail - the range is what happened *once*, not a ceiling. Doubling it
#: leaves room for the run that is a little worse than the one measured.
TOLERANCE_HEADROOM = 2.0

#: Below this, the probe is good enough that the tolerance is not the problem.
GOOD_RANGE_MM = 0.025

#: Above this, no tolerance value rescues it - the probe or the mount is loose,
#: and a tolerance wide enough to pass would also be wide enough to be useless.
HOPELESS_RANGE_MM = 0.15

_ACCURACY_RESULT = re.compile(
    r"maximum\s+([\d.-]+).*?minimum\s+([\d.-]+).*?range\s+([\d.-]+)"
    r".*?average\s+([\d.-]+).*?median\s+([\d.-]+).*?standard deviation\s+([\d.-]+)",
    re.I | re.S,
)


def read_probe_state(output: str) -> Optional[bool]:
    """True triggered, False open, None when the answer is not in the text."""
    lowered = (output or "").lower()
    if "probe: triggered" in lowered:
        return True
    if "probe: open" in lowered:
        return False
    return None


@dataclass
class ProbeAccuracy:
    """What PROBE_ACCURACY measured, and what it means for the config."""

    maximum: float
    minimum: float
    range: float
    average: float
    median: float
    deviation: float

    @property
    def recommended_tolerance(self) -> float:
        """A samples_tolerance this probe can actually meet.

        Rounded up to the nearest 5 microns - a recommendation carrying six
        decimal places would be pretending to a precision the measurement does
        not have.
        """
        value = max(self.range * TOLERANCE_HEADROOM, 0.01)
        return round(value + 0.0049, 3)

    @property
    def verdict(self) -> str:
        if self.range <= GOOD_RANGE_MM:
            return "good"
        if self.range >= HOPELESS_RANGE_MM:
            return "mechanical"
        return "loose"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "maximum": self.maximum,
            "minimum": self.minimum,
            "range": self.range,
            "average": self.average,
            "median": self.median,
            "deviation": self.deviation,
            "verdict": self.verdict,
            "recommended_tolerance": self.recommended_tolerance,
        }


def parse_probe_accuracy(output: str) -> Optional[ProbeAccuracy]:
    """Read Klipper's PROBE_ACCURACY summary line. None when it is not there."""
    match = _ACCURACY_RESULT.search(output or "")
    if match is None:
        return None
    try:
        values = [float(group) for group in match.groups()]
    except ValueError:
        return None
    return ProbeAccuracy(
        maximum=values[0],
        minimum=values[1],
        range=values[2],
        average=values[3],
        median=values[4],
        deviation=values[5],
    )


@dataclass
class ProbeDiagnosis:
    """What the probe is doing, why, and what to change."""

    #: working | stuck | dead | inverted | unreadable | unrepeatable
    fault: str
    title_ar: str
    detail_ar: str
    fixes_ar: List[str] = field(default_factory=list)
    at_rest: Optional[bool] = None
    pressed: Optional[bool] = None
    accuracy: Optional[ProbeAccuracy] = None
    #: A config change to make, as ``section -> {option: value}``. Never
    #: applied here - printer.cfg is not written by this app without an
    #: explicit, separate confirmation.
    suggested_config: Dict[str, Dict[str, str]] = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return self.fault == "working"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "fault": self.fault,
            "ok": self.ok,
            "title_ar": self.title_ar,
            "detail_ar": self.detail_ar,
            "fixes_ar": self.fixes_ar,
            "at_rest": self.at_rest,
            "pressed": self.pressed,
            "accuracy": self.accuracy.to_dict() if self.accuracy else None,
            "suggested_config": self.suggested_config,
        }


def diagnose_wiring(
    at_rest: Optional[bool], pressed: Optional[bool], *, probe_pin: str = ""
) -> ProbeDiagnosis:
    """The four-way answer from the two readings.

    `pressed` is None when that half of the test has not been done yet, which is
    a real state and not an error: the first reading alone already rules things
    in and out, and the app shows that before asking anyone to touch anything.
    """
    inverted_pin = _inverted(probe_pin)

    if at_rest is None:
        return ProbeDiagnosis(
            fault="unreadable",
            title_ar="مش قادر أقرا البروب",
            detail_ar=(
                "أمر QUERY_PROBE مردّش بحاجة مفهومة. غالبًا Klipper مش شغال، "
                "أو مفيش قسم [probe] في الملف أصلاً."
            ),
            fixes_ar=[
                "اتأكد إن Klipper حالته ready من شاشة التشخيص.",
                "اتأكد إن فيه قسم [probe] في printer.cfg.",
            ],
            at_rest=at_rest,
            pressed=pressed,
        )

    if at_rest is True and pressed is not False:
        # Triggered with nothing touching it. G28 dies immediately with "Probe
        # triggered prior to movement" and never moves an axis.
        return ProbeDiagnosis(
            fault="stuck",
            title_ar="البروب بيقول «مضغوط» وهو مش بيلمس حاجة",
            detail_ar=(
                "دي بالظبط اللي بتخلي G28 يفشل فورًا برسالة "
                "«Probe triggered prior to movement» من غير ما أي محور يتحرك. "
                "يا إما الحساس متعلّق ميكانيكيًا، يا إما قطبية الپن في الملف مقلوبة."
            ),
            fixes_ar=[
                "بصّ على الحساس نفسه: لو فيه ذراع أو مسمار متعلّق، حرّره بإيدك.",
                (
                    f"لو الحساس سليم، اقلب قطبية الپن في [probe]: "
                    f"{probe_pin or '^PA8'} تبقى {inverted_pin}."
                ),
                "اعمل FIRMWARE_RESTART بعد أي تعديل، وبعدين اختبر تاني.",
            ],
            at_rest=at_rest,
            pressed=pressed,
            suggested_config={"probe": {"pin": inverted_pin}} if probe_pin else {},
        )

    if at_rest is False and pressed is None:
        return ProbeDiagnosis(
            fault="working",
            title_ar="البروب مفتوح وهو مستريح - كده تمام لحد دلوقتي",
            detail_ar=(
                "القراءة الأولى سليمة. فاضل نتأكد إنه بيحسّ فعلاً: قرّب إيدك أو "
                "لوح معدن من الحساس واضغط «اقرأ تاني»."
            ),
            at_rest=at_rest,
            pressed=pressed,
        )

    if at_rest is False and pressed is False:
        # Never fires. This is the dangerous one: Klipper keeps driving Z down
        # looking for a trigger that is not coming.
        return ProbeDiagnosis(
            fault="dead",
            title_ar="البروب مش بيحسّ خالص",
            detail_ar=(
                "فضل «مفتوح» حتى وانت بتلمسه. يعني وقت الـ homing، Klipper هيفضل "
                "ينزّل الـ Z وهو مستني إشارة مش جاية - والفوهة بتخبط في السرير. "
                "متعملش G28 قبل ما تحل دي."
            ),
            fixes_ar=[
                "اتأكد من كابل الحساس على البورد وعلى الرأس - أكتر سبب هو كابل نص فايت.",
                "لو الحساس استقرائي (inductive)، هو بيحسّ المعدن بس - جرّب بلوح معدن مش بصباعك.",
                f"اتأكد إن رقم الپن في [probe] ({probe_pin or 'مش مكتوب'}) هو بتاع لوحتك فعلاً.",
                "لو اللمبة اللي على الحساس نفسه مش بتنوّر خالص، الحساس أو تغذيته عطلانة.",
            ],
            at_rest=at_rest,
            pressed=pressed,
        )

    if at_rest is True and pressed is False:
        return ProbeDiagnosis(
            fault="inverted",
            title_ar="قراءة البروب مقلوبة",
            detail_ar=(
                "بيقول «مضغوط» وهو مستريح، و«مفتوح» وانت بتلمسه - بالظبط بالعكس. "
                "الحساس شغال كويس، بس Klipper بيقرا الإشارة مقلوبة."
            ),
            fixes_ar=[
                f"غيّر پن [probe] من {probe_pin or '^PA8'} لـ {inverted_pin}.",
                "FIRMWARE_RESTART، وبعدين اختبر تاني.",
            ],
            at_rest=at_rest,
            pressed=pressed,
            suggested_config={"probe": {"pin": inverted_pin}} if probe_pin else {},
        )

    return ProbeDiagnosis(
        fault="working",
        title_ar="البروب شغال صح",
        detail_ar="مفتوح وهو مستريح، وبيضرب وانت بتلمسه. التوصيل والقطبية سليمين.",
        at_rest=at_rest,
        pressed=pressed,
    )


def _inverted(pin: str) -> str:
    """Flip the `!` on a Klipper pin name, keeping `^` and the pin itself.

    Klipper's prefixes are order-sensitive and independent: `^` is a pull-up and
    `!` inverts the reading. Flipping polarity must not silently drop the
    pull-up, which is what naive string surgery does.
    """
    name = (pin or "").strip()
    if not name:
        return "!^PA8"
    prefix = ""
    while name and name[0] in "^!~":
        prefix += name[0]
        name = name[1:]
    pullup = "^" in prefix
    inverted = "!" in prefix
    result = ""
    if not inverted:
        result += "!"
    if pullup:
        result += "^"
    return result + name


def diagnose_accuracy(accuracy: Optional[ProbeAccuracy], configured: Optional[float]) -> ProbeDiagnosis:
    """Whether the probe repeats well enough for the configured tolerance."""
    if accuracy is None:
        return ProbeDiagnosis(
            fault="unreadable",
            title_ar="مش قادر أقرا نتيجة PROBE_ACCURACY",
            detail_ar="الأمر اشتغل بس مطلعش ملخص. جرّب تاني، والطابعة لازم تكون homed.",
        )

    recommended = accuracy.recommended_tolerance

    if accuracy.verdict == "mechanical":
        return ProbeDiagnosis(
            fault="unrepeatable",
            title_ar="البروب بيقيس مكان مختلف كل مرة",
            detail_ar=(
                f"الفرق بين أعلى وأقل قراءة {accuracy.range:.3f} مم. ده كبير أوي "
                f"لدرجة إن مفيش قيمة samples_tolerance هتنفع: أي قيمة واسعة كفاية "
                f"إنها تعدّي، واسعة كفاية إنها تخلي المعايرة نفسها بلا معنى. "
                f"المشكلة ميكانيكية مش في الإعدادات."
            ),
            fixes_ar=[
                "شدّ مسامير تثبيت الحساس على الرأس - أشهر سبب إنه بيتهز.",
                "اتأكد إن العجل (eccentric nuts) بتاع محور Z مظبوط ومفيش خلخلة.",
                "اتأكد إن الكابل مش بيتشد على الحساس مع حركة الرأس.",
                "جرّب تقيس والسرير سخن على درجة الطباعة - المعدن بيتمدد.",
            ],
            accuracy=accuracy,
        )

    if configured is not None and configured < accuracy.range:
        return ProbeDiagnosis(
            fault="unrepeatable",
            title_ar="الـ samples_tolerance أضيق من قدرة البروب",
            detail_ar=(
                f"البروب بيتفاوت {accuracy.range:.3f} مم بين القراءات، "
                f"وanت طالب منه يتفق في حدود {configured:.3f} مم. Klipper بيعيد "
                f"القياس وبعدين بيفشل بـ «Probe samples exceed samples_tolerance»، "
                f"والفشل ده بيفشل G28، والطابعة غير الـ homed بترفض أي حركة."
            ),
            fixes_ar=[
                f"غيّر samples_tolerance في [probe] لـ {recommended:.3f}.",
                "FIRMWARE_RESTART بعد التعديل.",
            ],
            accuracy=accuracy,
            suggested_config={"probe": {"samples_tolerance": f"{recommended:.3f}"}},
        )

    return ProbeDiagnosis(
        fault="working",
        title_ar="تكرارية البروب كويسة",
        detail_ar=(
            f"الفرق بين أعلى وأقل قراءة {accuracy.range:.3f} مم "
            f"(الانحراف المعياري {accuracy.deviation:.4f}). "
            f"القيمة المناسبة لـ samples_tolerance هي {recommended:.3f} أو أوسع."
        ),
        accuracy=accuracy,
        suggested_config={"probe": {"samples_tolerance": f"{recommended:.3f}"}},
    )
