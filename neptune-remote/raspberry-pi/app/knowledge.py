"""Offline knowledge base: Klipper error translation + troubleshooting trees.

Everything here is static data and plain pattern matching. It works with no
network, no AI and no cloud, and the original error text is always preserved so
an advanced user can see exactly what Klipper said.
"""

from __future__ import annotations

import re
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class TranslatedError(BaseModel):
    matched: bool = False
    code: str = "unknown"
    title_ar: str = ""
    title_en: str = ""
    explanation_ar: str = ""
    explanation_en: str = ""
    causes_ar: List[str] = Field(default_factory=list)
    checks_ar: List[str] = Field(default_factory=list)
    severity: str = "error"          # info | warning | error | critical
    original: str = ""               # never hidden


# --------------------------------------------------------------------------- #
# Klipper / Moonraker errors
# --------------------------------------------------------------------------- #

ERROR_RULES: List[Dict[str, Any]] = [
    {
        "code": "mcu_shutdown_timer_too_close",
        "pattern": r"timer too close",
        "severity": "critical",
        "title_ar": "توقف المتحكم: التوقيت ضيق جداً",
        "title_en": "MCU shutdown: timer too close",
        "explanation_ar": "لوحة التحكم لم تستطع تنفيذ الأوامر في الوقت المطلوب فأوقفت نفسها لحماية الطابعة.",
        "explanation_en": "The mainboard could not keep up with the command timing and shut itself down.",
        "causes_ar": [
            "سرعة أو تسارع أعلى من قدرة اللوحة",
            "كابل USB أو سلك تغذية غير مستقر",
            "ضغط عالي على الراسبيري باي أثناء الطباعة",
        ],
        "checks_ar": [
            "أعد تشغيل الفيرموير من التطبيق",
            "قلّل السرعة والتسارع من صفحة السرعة",
            "غيّر كابل USB بين الراسبيري باي واللوحة",
            "تأكد أن مصدر كهرباء الراسبيري باي 5V/5A أصلي",
        ],
    },
    {
        "code": "mcu_shutdown_lost_communication",
        "pattern": r"lost communication with mcu|mcu '\w+' shutdown: communication",
        "severity": "critical",
        "title_ar": "انقطع الاتصال بلوحة التحكم",
        "title_en": "Lost communication with the MCU",
        "explanation_ar": "الراسبيري باي فقد الاتصال بلوحة الطابعة أثناء التشغيل.",
        "explanation_en": "The Pi lost its serial link to the printer mainboard.",
        "causes_ar": [
            "كابل USB تالف أو غير مثبت",
            "انقطاع كهرباء الطابعة (المفتاح الذكي)",
            "تداخل كهربائي من السخانات",
        ],
        "checks_ar": [
            "تأكد أن كهرباء الطابعة شغالة",
            "افحص كابل USB وجرّب منفذ آخر",
            "أعد تشغيل الفيرموير ثم كليبر",
        ],
    },
    {
        "code": "heater_not_heating",
        "pattern": r"heater \w+ not heating at expected rate",
        "severity": "critical",
        "title_ar": "السخان لا يسخن بالمعدل المتوقع",
        "title_en": "Heater not heating at the expected rate",
        "explanation_ar": "كليبر أوقف الطابعة لأن درجة الحرارة لم ترتفع كما يجب — وهذه حماية من الحريق.",
        "explanation_en": "Klipper stopped the printer because the temperature did not rise as expected.",
        "causes_ar": [
            "ثيرمستور مفكوك أو خارج مكانه",
            "سلك السخان مقطوع أو مفكوك",
            "تيار هواء قوي على الهوت إند",
            "الطباعة بمروحة 100% على درجات عالية",
        ],
        "checks_ar": [
            "افحص أسلاك السخان والثيرمستور وهي باردة",
            "تأكد أن الثيرمستور داخل مكانه بإحكام",
            "امنع تيار الهواء المباشر على النوزل",
            "بعد الإصلاح: إعادة تشغيل الفيرموير",
        ],
    },
    {
        "code": "thermistor_shorted",
        "pattern": r"adc out of range|thermistor",
        "severity": "critical",
        "title_ar": "قراءة حرارة غير منطقية",
        "title_en": "Temperature sensor out of range",
        "explanation_ar": "قراءة حساس الحرارة خارج المدى المسموح، فأوقف كليبر التشغيل.",
        "explanation_en": "The temperature sensor reading is outside the allowed range.",
        "causes_ar": ["ثيرمستور مقطوع", "سلك مفكوك أو ملامس", "حساس تالف"],
        "checks_ar": [
            "افحص سلك الثيرمستور من الطرفين",
            "تأكد من عدم وجود تلامس في الأسلاك",
            "استبدل الحساس إذا استمرت المشكلة",
        ],
    },
    {
        "code": "probe_failed",
        "pattern": r"probe triggered prior to movement|probe failed|bltouch",
        "severity": "error",
        "title_ar": "مشكلة في حساس المستوى (البروب)",
        "title_en": "Bed probe error",
        "explanation_ar": "حساس مستوى السرير أعطى إشارة قبل أو أثناء الحركة بشكل غير متوقع.",
        "explanation_en": "The bed probe triggered unexpectedly.",
        "causes_ar": [
            "النوزل متسخ ببقايا خامة",
            "الحساس قريب جداً من السرير",
            "سلك الحساس مفكوك",
        ],
        "checks_ar": [
            "نظّف النوزل جيداً وهو دافئ",
            "تأكد من تركيب الحساس وارتفاعه",
            "أعد عمل خريطة السرير BED_MESH_CALIBRATE",
        ],
    },
    {
        "code": "must_home_first",
        "pattern": r"must home axis first|printer not homed",
        "severity": "warning",
        "title_ar": "لازم تعمل هومنج أولاً",
        "title_en": "Home the axes first",
        "explanation_ar": "الطابعة لا تعرف موقعها الحالي، فلا يمكن تحريكها قبل المعايرة.",
        "explanation_en": "The printer does not know where it is; home the axes before moving.",
        "causes_ar": ["بعد تشغيل الطابعة", "بعد M84 أو إيقاف طوارئ"],
        "checks_ar": ["اضغط معايرة الكل (G28) من صفحة التحريك"],
    },
    {
        "code": "extrude_below_min_temp",
        "pattern": r"extrude below minimum temp|cannot extrude",
        "severity": "warning",
        "title_ar": "لا يمكن دفع الخامة والنوزل بارد",
        "title_en": "Cannot extrude below the minimum temperature",
        "explanation_ar": "كليبر يمنع دفع الخامة قبل تسخين النوزل لحماية الترس والخامة.",
        "explanation_en": "Klipper refuses to extrude before the nozzle is hot enough.",
        "causes_ar": ["النوزل أقل من الحد الأدنى (170° افتراضياً)"],
        "checks_ar": ["سخّن النوزل أولاً من صفحة الحرارة ثم أعد المحاولة"],
    },
    {
        "code": "move_out_of_range",
        "pattern": r"move out of range",
        "severity": "error",
        "title_ar": "حركة خارج حدود الطابعة",
        "title_en": "Move out of range",
        "explanation_ar": "الأمر يطلب حركة خارج مساحة الطباعة المسموحة.",
        "explanation_en": "The requested move is outside the machine limits.",
        "causes_ar": [
            "الموديل أكبر من مساحة الطباعة",
            "إزاحة في إعدادات السلايسر",
            "الطابعة غير معايرة",
        ],
        "checks_ar": [
            "اعمل معايرة الكل ثم أعد المحاولة",
            "تأكد أن الموديل داخل 320×320×400 مم",
        ],
    },
    {
        "code": "klipper_config_error",
        "pattern": r"option '.*' in section|unable to parse|config error|invalid printer\.cfg",
        "severity": "error",
        "title_ar": "خطأ في ملف الإعدادات printer.cfg",
        "title_en": "printer.cfg configuration error",
        "explanation_ar": "كليبر لم يستطع قراءة ملف الإعدادات، فلن يعمل حتى يتم إصلاحه.",
        "explanation_en": "Klipper could not parse printer.cfg.",
        "causes_ar": ["تعديل يدوي في الملف", "خيار غير موجود في نسخة كليبر الحالية"],
        "checks_ar": [
            "افتح Mainsail وراجع رسالة الخطأ الكاملة",
            "ارجع لنسخة احتياطية من الإعدادات",
            "هذا التطبيق لا يعدّل printer.cfg نهائياً",
        ],
    },
    {
        "code": "klipper_not_ready",
        "pattern": r"klipper is not ready|klippy is not connected|printer is shutdown",
        "severity": "error",
        "title_ar": "كليبر غير جاهز",
        "title_en": "Klipper is not ready",
        "explanation_ar": "خدمة كليبر متوقفة أو في حالة إيقاف بعد خطأ.",
        "explanation_en": "The Klipper service is stopped or shut down after an error.",
        "causes_ar": ["إيقاف طوارئ", "خطأ سابق لم يتم مسحه", "كهرباء الطابعة مفصولة"],
        "checks_ar": [
            "تأكد أن كهرباء الطابعة شغالة",
            "اضغط إعادة تشغيل الفيرموير",
            "لو استمرت المشكلة: إعادة تشغيل كليبر",
        ],
    },
    {
        "code": "shutdown_by_user",
        "pattern": r"shutdown due to webhooks request|emergency stop",
        "severity": "warning",
        "title_ar": "تم إيقاف الطابعة يدوياً (إيقاف طوارئ)",
        "title_en": "Printer stopped by an emergency stop",
        "explanation_ar": "تم طلب إيقاف طوارئ. لازم إعادة تشغيل الفيرموير قبل الطباعة مرة أخرى.",
        "explanation_en": "An emergency stop was requested; a firmware restart is required.",
        "causes_ar": ["ضغط زر إيقاف الطوارئ"],
        "checks_ar": ["تأكد أن الطابعة آمنة", "اضغط إعادة تشغيل الفيرموير"],
    },
    {
        "code": "file_not_found",
        "pattern": r"file not found|unable to open file",
        "severity": "error",
        "title_ar": "ملف الطباعة غير موجود",
        "title_en": "Print file not found",
        "explanation_ar": "الملف المطلوب غير موجود على الراسبيري باي.",
        "explanation_en": "The requested G-code file is not on the Pi.",
        "causes_ar": ["الملف تم حذفه", "اسم مختلف بعد التقطيع"],
        "checks_ar": ["افتح الملفات وتأكد من وجود الملف", "أعد التقطيع أو الرفع"],
    },
    {
        "code": "no_space_left",
        "pattern": r"no space left on device|disk full",
        "severity": "critical",
        "title_ar": "مساحة التخزين ممتلئة",
        "title_en": "Storage is full",
        "explanation_ar": "لا توجد مساحة كافية على كارت الراسبيري باي.",
        "explanation_en": "The Raspberry Pi has run out of disk space.",
        "causes_ar": ["تسجيلات فيديو كثيرة", "ملفات جي كود قديمة"],
        "checks_ar": [
            "احذف تسجيلات الفيديو القديمة من التطبيق",
            "فعّل الحذف التلقائي في إعدادات التسجيل",
            "احذف ملفات الجي كود غير المستخدمة",
        ],
    },
]

COMPILED_RULES = [
    (re.compile(rule["pattern"], re.IGNORECASE), rule) for rule in ERROR_RULES
]


def translate_error(raw: str) -> TranslatedError:
    """Match a raw Klipper/Moonraker message against the known patterns."""
    text = (raw or "").strip()
    if not text:
        return TranslatedError(original="")

    for pattern, rule in COMPILED_RULES:
        if pattern.search(text):
            return TranslatedError(
                matched=True,
                code=rule["code"],
                title_ar=rule["title_ar"],
                title_en=rule["title_en"],
                explanation_ar=rule["explanation_ar"],
                explanation_en=rule["explanation_en"],
                causes_ar=list(rule["causes_ar"]),
                checks_ar=list(rule["checks_ar"]),
                severity=rule["severity"],
                original=text,
            )

    return TranslatedError(
        matched=False,
        code="unknown",
        title_ar="خطأ من الطابعة",
        title_en="Printer error",
        explanation_ar="لم يتم التعرف على هذا الخطأ تلقائياً. النص الأصلي معروض بالأسفل.",
        explanation_en="This message is not in the offline knowledge base; the original text is shown below.",
        severity="error",
        original=text,
    )


# --------------------------------------------------------------------------- #
# Troubleshooting decision trees
# --------------------------------------------------------------------------- #


class TroubleshootingStep(BaseModel):
    id: str
    question_ar: str
    question_en: str = ""
    yes_next: Optional[str] = None
    no_next: Optional[str] = None
    advice_ar: str = ""
    advice_en: str = ""


class TroubleshootingTopic(BaseModel):
    id: str
    title_ar: str
    title_en: str
    icon: str = "wrench.and.screwdriver"
    summary_ar: str = ""
    first_step: str = ""
    steps: List[TroubleshootingStep] = Field(default_factory=list)
    quick_fixes_ar: List[str] = Field(default_factory=list)


TOPICS: List[TroubleshootingTopic] = [
    TroubleshootingTopic(
        id="adhesion",
        title_ar="الطباعة لا تلتصق بالسرير",
        title_en="Print does not stick to the bed",
        icon="square.stack.3d.down.right",
        summary_ar="أكثر مشكلة شائعة، وغالباً سببها المسافة بين النوزل والسرير أو نظافة السطح.",
        first_step="adhesion_clean",
        quick_fixes_ar=[
            "نظّف السرير بكحول إيزوبروبيل 90%",
            "ارفع حرارة السرير 5 درجات",
            "فعّل البريم (Brim) في إعدادات التقطيع",
            "قلّل سرعة الطبقة الأولى",
        ],
        steps=[
            TroubleshootingStep(
                id="adhesion_clean",
                question_ar="هل السرير نظيف ومغسول بالكحول؟",
                question_en="Is the bed clean and wiped with alcohol?",
                yes_next="adhesion_zoffset",
                no_next="adhesion_clean_advice",
            ),
            TroubleshootingStep(
                id="adhesion_clean_advice",
                question_ar="",
                advice_ar="نظّف السرير بكحول إيزوبروبيل واتركه يجف تماماً، ثم جرّب الطباعة مرة أخرى. "
                          "الدهون من اليد أكثر سبب لعدم الالتصاق.",
                advice_en="Clean the bed with isopropyl alcohol and let it dry, then retry.",
            ),
            TroubleshootingStep(
                id="adhesion_zoffset",
                question_ar="هل الطبقة الأولى تبدو مضغوطة على السرير (وليست خيوط مدورة)؟",
                question_en="Does the first layer look squished, not round strings?",
                yes_next="adhesion_temp",
                no_next="adhesion_zoffset_advice",
            ),
            TroubleshootingStep(
                id="adhesion_zoffset_advice",
                question_ar="",
                advice_ar="النوزل بعيد عن السرير. اعمل خريطة سرير جديدة (BED_MESH_CALIBRATE) ثم اضبط "
                          "Z-offset بمقدار 0.02 مم في كل مرة حتى تصبح الطبقة الأولى مضغوطة قليلاً.",
                advice_en="Lower the Z offset in 0.02 mm steps until the first layer is slightly squished.",
            ),
            TroubleshootingStep(
                id="adhesion_temp",
                question_ar="هل حرارة السرير مناسبة للخامة؟ (PLA 60° / PETG 75-80° / ABS 100°)",
                yes_next="adhesion_speed",
                no_next="adhesion_temp_advice",
            ),
            TroubleshootingStep(
                id="adhesion_temp_advice",
                question_ar="",
                advice_ar="اضبط حرارة السرير حسب الخامة من صفحة الحرارة، وارفعها 5 درجات إضافية "
                          "للطبقة الأولى فقط.",
            ),
            TroubleshootingStep(
                id="adhesion_speed",
                question_ar="هل سرعة الطبقة الأولى أقل من 30 مم/ث؟",
                yes_next="adhesion_final",
                no_next="adhesion_speed_advice",
            ),
            TroubleshootingStep(
                id="adhesion_speed_advice",
                question_ar="",
                advice_ar="قلّل سرعة الطبقة الأولى إلى 20-25 مم/ث من إعدادات التقطيع المتقدمة.",
            ),
            TroubleshootingStep(
                id="adhesion_final",
                question_ar="",
                advice_ar="جرّب إضافة Brim أو Raft، وتأكد أن المروحة مطفية في الطبقة الأولى. "
                          "لو المشكلة مستمرة مع PETG فقط، قلّل حرارة السرير قليلاً — PETG يلتصق أكثر من اللازم أحياناً.",
            ),
        ],
    ),
    TroubleshootingTopic(
        id="stringing",
        title_ar="خيوط رفيعة بين الأجزاء (Stringing)",
        title_en="Stringing",
        icon="scribble",
        summary_ar="خيوط شعرية بين أجزاء الموديل، سببها غالباً الرطوبة أو الحرارة أو الريتراكشن.",
        first_step="stringing_material",
        quick_fixes_ar=[
            "قلّل حرارة النوزل 5-10 درجات",
            "زوّد الريتراكشن 0.2 مم",
            "جفّف الخامة خصوصاً PETG و TPU",
            "زوّد سرعة الحركة (Travel)",
        ],
        steps=[
            TroubleshootingStep(
                id="stringing_material",
                question_ar="هل الخامة PETG أو TPU أو مفتوحة من فترة طويلة؟",
                yes_next="stringing_dry",
                no_next="stringing_temp",
            ),
            TroubleshootingStep(
                id="stringing_dry",
                question_ar="",
                advice_ar="الخامة على الأغلب امتصت رطوبة. جفّفها 4-6 ساعات على 55° (PETG) أو 50° (TPU) "
                          "في فرن أو مجفف خامات، ثم أعد الطباعة.",
            ),
            TroubleshootingStep(
                id="stringing_temp",
                question_ar="هل جرّبت تقليل حرارة النوزل 10 درجات؟",
                yes_next="stringing_retract",
                no_next="stringing_temp_advice",
            ),
            TroubleshootingStep(
                id="stringing_temp_advice",
                question_ar="",
                advice_ar="قلّل حرارة النوزل 5 درجات كل مرة واطبع قطعة اختبار حتى تختفي الخيوط.",
            ),
            TroubleshootingStep(
                id="stringing_retract",
                question_ar="هل الريتراكشن مفعّل بقيمة 1 مم على الأقل؟",
                yes_next="stringing_final",
                no_next="stringing_retract_advice",
            ),
            TroubleshootingStep(
                id="stringing_retract_advice",
                question_ar="",
                advice_ar="زوّد الريتراكشن إلى 1-1.5 مم للـ Direct Drive، وسرعة السحب 35-45 مم/ث "
                          "من إعدادات التقطيع المتقدمة.",
            ),
            TroubleshootingStep(
                id="stringing_final",
                question_ar="",
                advice_ar="فعّل خيار المشي فوق الفراغات (Avoid crossing perimeters) وزوّد سرعة الحركة "
                          "إلى 200 مم/ث. الخيوط الخفيفة جداً طبيعية ويمكن إزالتها بمسدس حرارة.",
            ),
        ],
    ),
    TroubleshootingTopic(
        id="warping",
        title_ar="القطعة ترفع من الأطراف (Warping)",
        title_en="Warping",
        icon="arrow.up.right.and.arrow.down.left",
        summary_ar="أطراف القطعة ترفع لأعلى وتنفصل عن السرير، غالباً بسبب تبريد سريع.",
        first_step="warping_material",
        quick_fixes_ar=[
            "أغلق تيار الهواء حول الطابعة",
            "استخدم Brim عريض",
            "ارفع حرارة السرير",
            "قلّل المروحة في الطبقات الأولى",
        ],
        steps=[
            TroubleshootingStep(
                id="warping_material",
                question_ar="هل الخامة ABS أو ASA؟",
                yes_next="warping_enclosure",
                no_next="warping_draft",
            ),
            TroubleshootingStep(
                id="warping_enclosure",
                question_ar="",
                advice_ar="ABS و ASA يحتاجان حيّز مغلق. اصنع غطاء بسيط حول الطابعة، ارفع حرارة السرير "
                          "إلى 100-110°، وأطفئ مروحة التبريد تماماً تقريباً.",
            ),
            TroubleshootingStep(
                id="warping_draft",
                question_ar="هل الطابعة في مكان به تيار هواء (شباك/مكيف/مروحة)؟",
                yes_next="warping_draft_advice",
                no_next="warping_brim",
            ),
            TroubleshootingStep(
                id="warping_draft_advice",
                question_ar="",
                advice_ar="انقل الطابعة بعيداً عن التيار أو اعمل حاجز بسيط. التبريد غير المتساوي هو "
                          "السبب الأول للتقوس.",
            ),
            TroubleshootingStep(
                id="warping_brim",
                question_ar="",
                advice_ar="فعّل Brim بعرض 8 مم على الأقل، وارفع حرارة السرير 5 درجات، وقلّل المروحة "
                          "إلى 30% في أول 5 طبقات.",
            ),
        ],
    ),
    TroubleshootingTopic(
        id="layer_shift",
        title_ar="إزاحة في الطبقات (Layer Shift)",
        title_en="Layer shift",
        icon="rectangle.offgrid",
        summary_ar="الطبقات تنزاح فجأة في اتجاه واحد، وغالباً السبب ميكانيكي أو سرعة عالية.",
        first_step="shift_collision",
        quick_fixes_ar=[
            "قلّل السرعة والتسارع",
            "افحص شد السيور",
            "تأكد أن القطعة لا تصطدم بالنوزل",
        ],
        steps=[
            TroubleshootingStep(
                id="shift_collision",
                question_ar="هل النوزل اصطدم بقطعة مرتفعة أثناء الطباعة؟",
                yes_next="shift_collision_advice",
                no_next="shift_belts",
            ),
            TroubleshootingStep(
                id="shift_collision_advice",
                question_ar="",
                advice_ar="فعّل خيار Z-hop (رفع المحور Z عند الحركة) بمقدار 0.2-0.4 مم في إعدادات التقطيع.",
            ),
            TroubleshootingStep(
                id="shift_belts",
                question_ar="هل السيور مشدودة (تصدر رنة عند اللمس وليست مرتخية)؟",
                yes_next="shift_speed",
                no_next="shift_belts_advice",
            ),
            TroubleshootingStep(
                id="shift_belts_advice",
                question_ar="",
                advice_ar="اشدّ سيور X و Y حتى تصبح مشدودة بدون مبالغة، وافحص أن البكرات ليست مرتخية. "
                          "ستجد هذه المهمة في صفحة الصيانة.",
            ),
            TroubleshootingStep(
                id="shift_speed",
                question_ar="هل السرعة أعلى من 100 مم/ث أو التسارع أعلى من 5000؟",
                yes_next="shift_speed_advice",
                no_next="shift_final",
            ),
            TroubleshootingStep(
                id="shift_speed_advice",
                question_ar="",
                advice_ar="قلّل السرعة والتسارع من صفحة السرعة. Neptune 3 Plus سرير متحرك، والسرعات "
                          "العالية تحتاج ضبط Input Shaper أولاً.",
            ),
            TroubleshootingStep(
                id="shift_final",
                question_ar="",
                advice_ar="افحص أن الموتورات لا تسخن أكثر من اللازم، وأن العجلات تتحرك بسلاسة على القضبان.",
            ),
        ],
    ),
    TroubleshootingTopic(
        id="clog",
        title_ar="انسداد النوزل",
        title_en="Nozzle clog",
        icon="flame",
        summary_ar="الخامة لا تخرج أو تخرج بشكل متقطع.",
        first_step="clog_partial",
        quick_fixes_ar=["اعمل Cold Pull", "نظّف النوزل بإبرة 0.4", "استبدل النوزل"],
        steps=[
            TroubleshootingStep(
                id="clog_partial",
                question_ar="هل الخامة تخرج ببطء أو متقطعة (وليس توقف كامل)؟",
                yes_next="clog_partial_advice",
                no_next="clog_full",
            ),
            TroubleshootingStep(
                id="clog_partial_advice",
                question_ar="",
                advice_ar="غالباً انسداد جزئي. سخّن النوزل إلى 240° وادفع الخامة يدوياً، ثم اعمل "
                          "Cold Pull: سخّن 240°، ادفع خامة، برّد إلى 90°، ثم اسحب الخامة بقوة.",
            ),
            TroubleshootingStep(
                id="clog_full",
                question_ar="هل ترس التغذية يصدر صوت طقطقة؟",
                yes_next="clog_extruder",
                no_next="clog_replace",
            ),
            TroubleshootingStep(
                id="clog_extruder",
                question_ar="",
                advice_ar="الترس لا يستطيع دفع الخامة. تأكد من ضغط الترس، ونظّف أسنانه من البرادة، "
                          "وارفع حرارة النوزل 10 درجات.",
            ),
            TroubleshootingStep(
                id="clog_replace",
                question_ar="",
                advice_ar="استبدل النوزل — أرخص وأسرع من محاولات التنظيف المتكررة. غيّر النوزل والطابعة "
                          "ساخنة بحرص.",
            ),
        ],
    ),
    TroubleshootingTopic(
        id="under_extrusion",
        title_ar="نقص في كمية الخامة (Under Extrusion)",
        title_en="Under extrusion",
        icon="drop.triangle",
        summary_ar="فراغات بين الخطوط وطبقات ضعيفة.",
        first_step="under_temp",
        quick_fixes_ar=["ارفع الحرارة 5-10 درجات", "ارفع التدفق إلى 105%", "قلّل السرعة"],
        steps=[
            TroubleshootingStep(
                id="under_temp",
                question_ar="هل الطباعة بسرعة عالية (أكثر من 80 مم/ث)؟",
                yes_next="under_speed_advice",
                no_next="under_flow",
            ),
            TroubleshootingStep(
                id="under_speed_advice",
                question_ar="",
                advice_ar="قلّل السرعة أو ارفع حرارة النوزل 10 درجات — النوزل 0.4 له حد أقصى للتدفق.",
            ),
            TroubleshootingStep(
                id="under_flow",
                question_ar="هل جرّبت رفع التدفق (Flow) إلى 105%؟",
                yes_next="under_mechanical",
                no_next="under_flow_advice",
            ),
            TroubleshootingStep(
                id="under_flow_advice",
                question_ar="",
                advice_ar="ارفع التدفق من صفحة السرعة إلى 103-107% وراقب النتيجة.",
            ),
            TroubleshootingStep(
                id="under_mechanical",
                question_ar="",
                advice_ar="افحص قطر الخامة (يجب 1.75 مم)، ونظافة الترس، وأن البكرة تدور بحرية بدون شد.",
            ),
        ],
    ),
    TroubleshootingTopic(
        id="tpu",
        title_ar="مشاكل طباعة TPU المرن",
        title_en="TPU printing problems",
        icon="waveform.path",
        summary_ar="الخامة المرنة تحتاج إعدادات محافظة جداً.",
        first_step="tpu_speed",
        quick_fixes_ar=[
            "سرعة 15-25 مم/ث",
            "ريتراكشن 0.4 مم فقط",
            "تدفق حجمي أقصى 1.8 مم³/ث",
            "أطفئ التجفيف السريع وجفّف الخامة",
        ],
        steps=[
            TroubleshootingStep(
                id="tpu_speed",
                question_ar="هل السرعة أقل من 25 مم/ث؟",
                yes_next="tpu_retract",
                no_next="tpu_speed_advice",
            ),
            TroubleshootingStep(
                id="tpu_speed_advice",
                question_ar="",
                advice_ar="اختر بروفايل TPU من التطبيق — الحد الأقصى للتدفق فيه 1.8 مم³/ث وهو يبطئ "
                          "الطباعة تلقائياً بشكل آمن.",
            ),
            TroubleshootingStep(
                id="tpu_retract",
                question_ar="هل الريتراكشن أقل من 0.6 مم؟",
                yes_next="tpu_path",
                no_next="tpu_retract_advice",
            ),
            TroubleshootingStep(
                id="tpu_retract_advice",
                question_ar="",
                advice_ar="قلّل الريتراكشن إلى 0.4 مم — الخامة المرنة تنضغط داخل الأنبوب ولا تُسحب مثل PLA.",
            ),
            TroubleshootingStep(
                id="tpu_path",
                question_ar="",
                advice_ar="تأكد أن مسار الخامة من البكرة للترس قصير وبدون احتكاك، وأن البكرة تدور بسهولة جداً.",
            ),
        ],
    ),
    TroubleshootingTopic(
        id="printer_offline",
        title_ar="الطابعة غير متصلة",
        title_en="Printer offline",
        icon="wifi.slash",
        summary_ar="التطبيق لا يستطيع الوصول للطابعة.",
        first_step="offline_power",
        quick_fixes_ar=[
            "تأكد أن كهرباء الطابعة شغالة",
            "تأكد أن Tailscale شغال على الموبايل",
            "افتح فحص النظام من الإعدادات",
        ],
        steps=[
            TroubleshootingStep(
                id="offline_power",
                question_ar="هل كهرباء الطابعة شغالة؟",
                yes_next="offline_tailscale",
                no_next="offline_power_advice",
            ),
            TroubleshootingStep(
                id="offline_power_advice",
                question_ar="",
                advice_ar="شغّل الكهرباء من زر (تشغيل الطابعة) في الصفحة الرئيسية، وانتظر 30 ثانية "
                          "حتى يبدأ كليبر.",
            ),
            TroubleshootingStep(
                id="offline_tailscale",
                question_ar="هل تطبيق Tailscale شغال ومتصل على الموبايل؟",
                yes_next="offline_backend",
                no_next="offline_tailscale_advice",
            ),
            TroubleshootingStep(
                id="offline_tailscale_advice",
                question_ar="",
                advice_ar="افتح تطبيق Tailscale وتأكد أنه متصل بنفس الحساب. بدون Tailscale لن يعمل "
                          "التطبيق خارج المنزل.",
            ),
            TroubleshootingStep(
                id="offline_backend",
                question_ar="",
                advice_ar="افتح الإعدادات ← فحص النظام. هي ستخبرك بالضبط أي جزء لا يعمل: الراسبيري باي، "
                          "الخادم، مونريكر أو كليبر.",
            ),
        ],
    ),
]


def topics() -> List[TroubleshootingTopic]:
    return TOPICS


def topic(topic_id: str) -> Optional[TroubleshootingTopic]:
    return next((item for item in TOPICS if item.id == topic_id), None)
