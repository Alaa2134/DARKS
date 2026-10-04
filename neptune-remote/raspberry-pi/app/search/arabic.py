"""Deterministic Arabic text normalisation.

No machine learning, no network, no model files: pure string processing that
makes Arabic search behave the way an Egyptian user expects.

    normalize("مِيداليّة")   -> "ميداليه"
    normalize("حامل الموبايل") -> "حامل الموبايل"
    tokens("حامل موبايل")     -> ["حامل", "موبايل"]
"""

from __future__ import annotations

import re
import unicodedata
from typing import Iterable, List, Set

# Harakat (fatha, damma, kasra, shadda, sukun, tanween ...) and tatweel.
DIACRITICS = re.compile(
    "["
    "ؐ-ؚ"   # Quranic annotation signs
    "ً-ْ"   # tanween + harakat + shadda + sukun
    "ٓ-ٕ"   # maddah / hamza above & below
    "ٖ-ٟ"   # extended marks
    "ٰ"          # superscript alef
    "ۖ-ۭ"   # more Quranic marks
    "ـ"          # tatweel
    "]"
)

# Letters that users type interchangeably.
LETTER_MAP = {
    "أ": "ا",  # أ -> ا
    "إ": "ا",  # إ -> ا
    "آ": "ا",  # آ -> ا
    "ٱ": "ا",  # ٱ -> ا
    "ى": "ي",  # ى -> ي
    "ئ": "ي",  # ئ -> ي
    "ؤ": "و",  # ؤ -> و
    "ة": "ه",  # ة -> ه
    "ک": "ك",  # ک (Persian kaf) -> ك
    "ی": "ي",  # ی (Persian yeh) -> ي
    "ھ": "ه",  # ﮪ -> ه
}

ARABIC_INDIC_DIGITS = {
    "٠": "0", "١": "1", "٢": "2", "٣": "3", "٤": "4",
    "٥": "5", "٦": "6", "٧": "7", "٨": "8", "٩": "9",
    "۰": "0", "۱": "1", "۲": "2", "۳": "3", "۴": "4",
    "۵": "5", "۶": "6", "۷": "7", "۸": "8", "۹": "9",
}

PUNCTUATION = re.compile(r"[^\w؀-ۿ]+", re.UNICODE)
WHITESPACE = re.compile(r"\s+")

# Very common Arabic prefixes worth stripping for matching purposes.
PREFIXES = ("ال", "لل", "بال", "وال", "فال", "كال")

STOPWORDS: Set[str] = {
    "من", "الى", "الي", "على", "علي", "في", "عن", "مع", "او", "أو", "و",
    "the", "a", "an", "of", "for", "to", "with", "and",
}


def strip_diacritics(text: str) -> str:
    return DIACRITICS.sub("", text)


def unify_letters(text: str) -> str:
    return "".join(LETTER_MAP.get(char, char) for char in text)


def unify_digits(text: str) -> str:
    return "".join(ARABIC_INDIC_DIGITS.get(char, char) for char in text)


def collapse_repeats(text: str) -> str:
    """"حاااامل" -> "حامل" (three or more of the same letter become one)."""
    return re.sub(r"(.)\1{2,}", r"\1", text)


def normalize(text: str) -> str:
    """Full normalisation pipeline. Safe to call on English text too."""
    if not text:
        return ""
    text = unicodedata.normalize("NFKC", text)
    text = strip_diacritics(text)
    text = unify_letters(text)
    text = unify_digits(text)
    text = text.lower()
    text = PUNCTUATION.sub(" ", text)
    text = collapse_repeats(text)
    return WHITESPACE.sub(" ", text).strip()


def strip_prefix(token: str) -> str:
    """Remove a leading definite article when a real stem remains."""
    for prefix in PREFIXES:
        if token.startswith(prefix) and len(token) - len(prefix) >= 3:
            return token[len(prefix):]
    return token


def tokens(text: str, *, drop_stopwords: bool = True) -> List[str]:
    normalised = normalize(text)
    if not normalised:
        return []
    result = []
    for token in normalised.split(" "):
        if not token:
            continue
        if drop_stopwords and token in STOPWORDS:
            continue
        result.append(token)
    return result


def stems(text: str) -> List[str]:
    """Tokens with definite articles removed - used for loose matching."""
    return [strip_prefix(token) for token in tokens(text)]


# --------------------------------------------------------------------------- #
# Transliteration (Arabic <-> Latin), for "keychain" vs "كيتشين"
# --------------------------------------------------------------------------- #

AR_TO_LATIN = {
    "ا": "a", "ب": "b", "ت": "t", "ث": "th", "ج": "g", "ح": "h", "خ": "kh",
    "د": "d", "ذ": "z", "ر": "r", "ز": "z", "س": "s", "ش": "sh", "ص": "s",
    "ض": "d", "ط": "t", "ظ": "z", "ع": "a", "غ": "gh", "ف": "f", "ق": "k",
    "ك": "k", "ل": "l", "م": "m", "ن": "n", "ه": "h", "و": "w", "ي": "y",
    "ء": "", "چ": "ch", "ڤ": "v", "پ": "p", "گ": "g",
}


def transliterate(text: str) -> str:
    """Rough Arabic -> Latin transliteration used only for fuzzy matching."""
    normalised = normalize(text)
    out: List[str] = []
    for char in normalised:
        if char in AR_TO_LATIN:
            out.append(AR_TO_LATIN[char])
        elif char.isascii():
            out.append(char)
        elif char == " ":
            out.append(" ")
    return WHITESPACE.sub(" ", "".join(out)).strip()


def is_arabic(text: str) -> bool:
    return any("؀" <= char <= "ۿ" for char in text)


# --------------------------------------------------------------------------- #
# Edit distance
# --------------------------------------------------------------------------- #


def damerau_levenshtein(left: str, right: str, *, max_distance: int = 4) -> int:
    """Optimal string alignment distance (handles adjacent transpositions).

    Returns ``max_distance + 1`` as soon as the distance provably exceeds the
    limit, so long strings stay cheap.
    """
    if left == right:
        return 0
    if abs(len(left) - len(right)) > max_distance:
        return max_distance + 1
    if not left:
        return len(right)
    if not right:
        return len(left)

    previous_previous: List[int] = []
    previous = list(range(len(right) + 1))

    for i, left_char in enumerate(left, start=1):
        current = [i] + [0] * len(right)
        best = current[0]
        for j, right_char in enumerate(right, start=1):
            cost = 0 if left_char == right_char else 1
            value = min(
                previous[j] + 1,        # deletion
                current[j - 1] + 1,     # insertion
                previous[j - 1] + cost  # substitution
            )
            if (
                i > 1 and j > 1
                and left_char == right[j - 2]
                and left[i - 2] == right_char
            ):
                value = min(value, previous_previous[j - 2] + 1)  # transposition
            current[j] = value
            best = min(best, value)
        if best > max_distance:
            return max_distance + 1
        previous_previous = previous
        previous = current

    return previous[-1]


def similarity(left: str, right: str) -> float:
    """0.0 - 1.0 similarity based on edit distance."""
    if not left and not right:
        return 1.0
    if not left or not right:
        return 0.0
    longest = max(len(left), len(right))
    distance = damerau_levenshtein(left, right, max_distance=longest)
    return max(0.0, 1.0 - distance / longest)


def token_set_similarity(left: Iterable[str], right: Iterable[str]) -> float:
    """Best-match similarity between two token lists."""
    left_list = [token for token in left if token]
    right_list = [token for token in right if token]
    if not left_list or not right_list:
        return 0.0
    total = 0.0
    for token in left_list:
        total += max(similarity(token, other) for other in right_list)
    return total / len(left_list)
