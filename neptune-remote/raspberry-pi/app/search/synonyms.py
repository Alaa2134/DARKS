"""Arabic/English synonym groups for the model library search.

Each group is a set of words that mean the same thing to a user standing in
front of a 3D printer. When a query token matches any member of a group, every
other member is added to the query - so "phone stand" finds "حامل موبايل" and
"ستاند تليفون" without any AI.

Everything here is normalised with ``arabic.normalize`` at import time, so the
tables can be written naturally.
"""

from __future__ import annotations

from typing import Dict, List, Set

from .arabic import normalize

RAW_GROUPS: List[List[str]] = [
    # --- phone / mobile -----------------------------------------------------
    ["موبايل", "محمول", "هاتف", "تليفون", "تلفون", "جوال", "phone", "mobile", "smartphone", "cell"],
    ["حامل", "ستاند", "قاعدة", "قاعده", "مسند", "stand", "holder", "mount", "dock", "cradle"],
    ["حامل موبايل", "ستاند موبايل", "حامل هاتف", "حامل تليفون", "phone stand", "phone holder",
     "mobile stand", "phone dock"],
    # --- keychain -----------------------------------------------------------
    ["ميدالية", "ميداليه", "ميداليات", "تعليقة مفاتيح", "تعليقه مفاتيح", "سلسلة مفاتيح",
     "keychain", "key chain", "keyring", "key ring", "fob"],
    # --- organisers ---------------------------------------------------------
    ["منظم", "منظمة", "منظمه", "منظمات", "ترتيب", "تنظيم", "organizer", "organiser", "tidy", "caddy"],
    ["علبة", "علبه", "صندوق", "بوكس", "حافظة", "box", "case", "container", "bin", "tray", "drawer"],
    # --- desk / office ------------------------------------------------------
    ["مكتب", "شغل", "اوفيس", "desk", "office", "workspace"],
    ["قلم", "اقلام", "pen", "pencil", "pens"],
    ["كوب", "مج", "كوباية", "cup", "mug", "tumbler"],
    # --- kitchen ------------------------------------------------------------
    ["مطبخ", "kitchen"],
    ["شوكة", "معلقة", "ملعقة", "سكينة", "cutlery", "spoon", "fork", "knife"],
    # --- home / decor -------------------------------------------------------
    ["منزل", "بيت", "home", "house"],
    ["ديكور", "زينة", "زينه", "decor", "decoration", "ornament"],
    ["فازة", "فازه", "مزهرية", "vase", "planter", "pot"],
    ["اطار", "برواز", "frame", "picture frame"],
    ["ساعة", "ساعه", "clock", "watch"],
    ["مصباح", "لمبة", "لمبه", "اباجورة", "lamp", "light", "lampshade"],
    # --- toys / games -------------------------------------------------------
    ["لعبة", "لعبه", "العاب", "toy", "toys", "game", "puzzle"],
    ["شطرنج", "chess"],
    ["ديناصور", "dinosaur", "dino"],
    # --- robotics / electronics ---------------------------------------------
    ["روبوت", "روبوتات", "ربوت", "robot", "robotics"],
    ["اردوينو", "أردوينو", "arduino"],
    ["راسبيري", "راسبري", "raspberry", "raspberry pi", "rpi", "pi"],
    ["الكترونيات", "إلكترونيات", "electronics", "pcb", "circuit"],
    ["محرك", "موتور", "motor", "servo", "stepper"],
    ["كابل", "سلك", "وصلة", "cable", "wire", "cable clip", "clip"],
    ["شاحن", "شحن", "charger", "charging"],
    # --- printer parts ------------------------------------------------------
    ["طابعة", "طابعه", "برنتر", "printer", "3d printer"],
    ["نوزل", "فوهة", "nozzle", "hotend"],
    ["بكرة", "بكره", "رول", "spool", "filament spool"],
    ["خامة", "خامه", "فلامنت", "filament", "material"],
    ["قطعة غيار", "قطع غيار", "spare", "spare part", "replacement", "upgrade", "mod"],
    # --- car ----------------------------------------------------------------
    ["عربية", "عربيه", "سيارة", "سياره", "car", "vehicle", "auto"],
    # --- gifts / products ---------------------------------------------------
    ["هدية", "هديه", "هدايا", "gift", "present"],
    ["منتج", "منتجات", "بيع", "product", "products", "sale", "shop"],
    # --- tools --------------------------------------------------------------
    ["اداة", "أداة", "عدة", "tool", "tools", "jig", "gauge"],
    ["خطاف", "علاقة", "علاقه", "شماعة", "hook", "hanger", "hanger hook"],
    ["مسطرة", "مسطره", "ruler", "measure"],
    # --- fittings -----------------------------------------------------------
    ["غطاء", "غطا", "كفر", "cover", "cap", "lid"],
    ["مفصلة", "مفصله", "hinge"],
    ["مسمار", "برغي", "screw", "bolt", "nut"],
    ["حلقة", "حلقه", "ring", "washer"],
    ["ادابتر", "محول", "adapter", "adaptor"],
    # --- quality words used in search ---------------------------------------
    ["سريع", "سريعة", "quick", "fast", "speedy"],
    ["صغير", "صغيرة", "small", "mini", "tiny"],
    ["كبير", "كبيرة", "big", "large"],
    ["مرن", "مرنة", "flexible", "flex", "tpu"],
]


def _build() -> Dict[str, Set[str]]:
    table: Dict[str, Set[str]] = {}
    for group in RAW_GROUPS:
        normalised = {normalize(term) for term in group}
        normalised.discard("")
        # Index by every single-word member and by the full phrase.
        for term in normalised:
            table.setdefault(term, set()).update(normalised)
            for word in term.split(" "):
                if len(word) >= 3:
                    table.setdefault(word, set()).update(normalised)
    return table


SYNONYMS: Dict[str, Set[str]] = _build()


def expand(term: str) -> Set[str]:
    """Return the term plus every synonym known for it (all normalised)."""
    key = normalize(term)
    if not key:
        return set()
    result = {key}
    result.update(SYNONYMS.get(key, set()))
    for word in key.split(" "):
        result.update(SYNONYMS.get(word, set()))
    return result


def expand_query(query: str) -> Set[str]:
    """Expand a whole query: the phrase itself plus each token's synonyms."""
    key = normalize(query)
    if not key:
        return set()
    result: Set[str] = {key}
    result.update(SYNONYMS.get(key, set()))
    for token in key.split(" "):
        if len(token) >= 2:
            result.add(token)
            result.update(SYNONYMS.get(token, set()))
    return result
