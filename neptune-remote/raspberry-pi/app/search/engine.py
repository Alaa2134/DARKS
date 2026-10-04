"""Ranked, typo-tolerant search over the model library.

Scoring (highest wins):

    exact name match         1000
    name starts with query    800
    name contains query       600
    alias exact / prefix      550 / 450
    tag match                 350
    category match            250
    fuzzy name similarity     up to 500
    transliteration match     300
    token coverage bonus      up to 200
    favourite                 +60
    print count               +up to 40
    recently printed          +up to 30

Nothing here needs a model, a network or a GPU.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set

from .arabic import (
    is_arabic,
    normalize,
    similarity,
    stems,
    tokens,
    token_set_similarity,
    transliterate,
)
from .synonyms import expand_query

FUZZY_THRESHOLD = 0.62
MIN_SCORE = 60.0


@dataclass
class SearchDocument:
    """Everything about one library item that search cares about."""

    id: str
    name_ar: str = ""
    name_en: str = ""
    aliases: List[str] = field(default_factory=list)
    tags: List[str] = field(default_factory=list)
    category: str = ""
    notes: str = ""
    favourite: bool = False
    print_count: int = 0
    last_printed: Optional[float] = None
    material: str = ""
    estimated_seconds: Optional[float] = None
    payload: Dict[str, Any] = field(default_factory=dict)

    # -- derived ------------------------------------------------------------
    def names(self) -> List[str]:
        return [value for value in (self.name_ar, self.name_en) if value]

    def all_terms(self) -> List[str]:
        return self.names() + list(self.aliases) + list(self.tags) + ([self.category] if self.category else [])

    def blob(self) -> str:
        """Normalised text used for cheap substring checks and storage."""
        parts = self.all_terms() + ([self.notes] if self.notes else [])
        normalised = [normalize(part) for part in parts]
        translit = [transliterate(name) for name in self.names()]
        return " ".join(value for value in normalised + translit if value)


@dataclass
class SearchHit:
    document: SearchDocument
    score: float
    reasons: List[str] = field(default_factory=list)


def build_blob(document: SearchDocument) -> str:
    return document.blob()


class SearchEngine:
    """Stateless ranking helper: pass the documents in on every call."""

    def __init__(self, *, fuzzy_threshold: float = FUZZY_THRESHOLD, min_score: float = MIN_SCORE):
        self.fuzzy_threshold = fuzzy_threshold
        self.min_score = min_score

    # ------------------------------------------------------------------ API
    def search(
        self,
        query: str,
        documents: Iterable[SearchDocument],
        *,
        limit: int = 50,
        category: Optional[str] = None,
        favourites_only: bool = False,
    ) -> List[SearchHit]:
        candidates = [
            document for document in documents
            if (category is None or document.category == category)
            and (not favourites_only or document.favourite)
        ]

        normalised_query = normalize(query)
        if not normalised_query:
            # No query: newest/most-used first, still respecting the filters.
            ranked = sorted(
                candidates,
                key=lambda doc: (doc.favourite, doc.print_count, doc.last_printed or 0),
                reverse=True,
            )
            return [SearchHit(document=doc, score=0.0, reasons=["browse"]) for doc in ranked[:limit]]

        query_tokens = tokens(query)
        query_stems = stems(query)
        expansions = expand_query(query)
        query_translit = transliterate(query) if is_arabic(query) else normalised_query

        hits: List[SearchHit] = []
        for document in candidates:
            score, reasons = self._score(
                document,
                normalised_query=normalised_query,
                query_tokens=query_tokens,
                query_stems=query_stems,
                expansions=expansions,
                query_translit=query_translit,
            )
            if score >= self.min_score:
                hits.append(SearchHit(document=document, score=score, reasons=reasons))

        hits.sort(key=lambda hit: (-hit.score, hit.document.name_ar or hit.document.name_en))
        return hits[:limit]

    # -------------------------------------------------------------- scoring
    def _score(
        self,
        document: SearchDocument,
        *,
        normalised_query: str,
        query_tokens: Sequence[str],
        query_stems: Sequence[str],
        expansions: Set[str],
        query_translit: str,
    ) -> tuple[float, List[str]]:
        score = 0.0
        reasons: List[str] = []

        names = [normalize(name) for name in document.names() if name]
        aliases = [normalize(alias) for alias in document.aliases if alias]
        tag_values = [normalize(tag) for tag in document.tags if tag]
        category = normalize(document.category)

        # --- exact / prefix / contains on the names -------------------------
        best_name_score = 0.0
        for name in names:
            if not name:
                continue
            if name == normalised_query:
                best_name_score = max(best_name_score, 1000.0)
                reasons.append("exact")
            elif name.startswith(normalised_query):
                best_name_score = max(best_name_score, 800.0)
                reasons.append("prefix")
            elif normalised_query in name:
                best_name_score = max(best_name_score, 600.0)
                reasons.append("contains")
        score += best_name_score

        # --- aliases --------------------------------------------------------
        for alias in aliases:
            if alias == normalised_query:
                score += 550.0
                reasons.append("alias")
                break
            if alias.startswith(normalised_query) or normalised_query in alias:
                score += 450.0
                reasons.append("alias-partial")
                break

        # --- synonym expansion ---------------------------------------------
        document_terms = set(names) | set(aliases) | set(tag_values) | ({category} if category else set())
        document_words: Set[str] = set()
        for term in document_terms:
            document_words.update(term.split(" "))
        document_words.discard("")

        overlap = expansions & (document_terms | document_words)
        if overlap:
            # A synonym hit is strong but never beats an exact name match.
            score += 420.0 if best_name_score == 0 else 120.0
            reasons.append("synonym")

        # --- tags and category ---------------------------------------------
        if any(normalised_query == tag or normalised_query in tag for tag in tag_values):
            score += 350.0
            reasons.append("tag")
        if category and (normalised_query == category or normalised_query in category):
            score += 250.0
            reasons.append("category")

        # --- fuzzy on names (typo tolerance) --------------------------------
        if best_name_score == 0:
            best_similarity = 0.0
            for name in names:
                best_similarity = max(best_similarity, similarity(normalised_query, name))
                # also compare token-by-token, so "ميدليه ذهبى" finds "ميدالية"
                best_similarity = max(
                    best_similarity,
                    token_set_similarity(query_tokens, tokens(name)),
                )
            if best_similarity >= self.fuzzy_threshold:
                score += 500.0 * best_similarity
                reasons.append(f"fuzzy:{best_similarity:.2f}")

        # --- stem match (definite article removed) --------------------------
        if best_name_score == 0 and query_stems:
            document_stems: Set[str] = set()
            for name in document.all_terms():
                document_stems.update(stems(name))
            if document_stems & set(query_stems):
                score += 220.0
                reasons.append("stem")

        # --- transliteration ------------------------------------------------
        if best_name_score == 0 and query_translit:
            for name in document.names():
                translit = transliterate(name)
                if translit and (
                    translit == query_translit
                    or query_translit in translit
                    or similarity(query_translit, translit) >= 0.78
                ):
                    score += 300.0
                    reasons.append("translit")
                    break

        # --- token coverage -------------------------------------------------
        if query_tokens:
            blob_tokens: Set[str] = set()
            for term in document.all_terms() + [document.notes]:
                blob_tokens.update(tokens(term))
            matched = sum(
                1 for token in query_tokens
                if token in blob_tokens
                or any(token in candidate or candidate in token for candidate in blob_tokens)
            )
            if matched:
                score += 200.0 * (matched / len(query_tokens))
                reasons.append(f"coverage:{matched}/{len(query_tokens)}")

        if score <= 0:
            return 0.0, reasons

        # --- personalisation ------------------------------------------------
        if document.favourite:
            score += 60.0
        score += min(40.0, document.print_count * 8.0)
        if document.last_printed:
            score += 30.0

        return score, reasons


# --------------------------------------------------------------------------- #
# Suggestions
# --------------------------------------------------------------------------- #


def suggestions(prefix: str, documents: Iterable[SearchDocument], limit: int = 8) -> List[str]:
    """Instant suggestions while the user types."""
    normalised = normalize(prefix)
    if not normalised:
        return []

    scored: List[tuple[float, str]] = []
    seen: Set[str] = set()

    for document in documents:
        for raw in document.names() + list(document.aliases):
            if not raw or raw in seen:
                continue
            candidate = normalize(raw)
            if not candidate:
                continue

            words = candidate.split(" ")
            if candidate.startswith(normalised):
                rank = 0.0
            elif any(word.startswith(normalised) for word in words):
                rank = 0.5
            elif normalised in candidate:
                rank = 1.0
            elif similarity(normalised, candidate) >= 0.7:
                rank = 2.0
            elif any(similarity(normalised, word) >= 0.7 for word in words):
                # "ميدلي" should still suggest "ميدالية مفاتيح".
                rank = 2.5
            else:
                continue

            scored.append((rank, raw))
            seen.add(raw)

    scored.sort(key=lambda item: (item[0], len(item[1])))
    return [name for _, name in scored[:limit]]


# --------------------------------------------------------------------------- #
# Idea finder ("فاجئني")
# --------------------------------------------------------------------------- #

ROOM_TAGS: Dict[str, List[str]] = {
    "desk": ["مكتب", "desk", "office", "قلم", "منظم"],
    "car": ["عربية", "سيارة", "car"],
    "kitchen": ["مطبخ", "kitchen"],
    "room": ["منزل", "بيت", "ديكور", "home", "decor"],
    "phone": ["موبايل", "هاتف", "phone", "حامل"],
    "computer": ["كمبيوتر", "pc", "computer", "كابل", "cable"],
    "robotics": ["روبوت", "اردوينو", "راسبيري", "robot", "arduino"],
    "organization": ["منظم", "تنظيم", "علبة", "organizer", "box"],
    "gifts": ["هدية", "هدايا", "ميدالية", "gift", "keychain"],
    "projects": ["مشروع", "project", "prototype"],
    "spare_parts": ["قطع غيار", "spare", "طابعة", "printer"],
}


def find_ideas(
    documents: Iterable[SearchDocument],
    *,
    room: Optional[str] = None,
    max_seconds: Optional[float] = None,
    material: Optional[str] = None,
    exclude_recent_days: float = 14.0,
    now: float = 0.0,
    limit: int = 12,
) -> List[SearchHit]:
    """Deterministic weighted recommendation - no AI, fully explainable."""
    wanted = {normalize(term) for term in ROOM_TAGS.get(room or "", [])}
    normalised_material = normalize(material or "")

    hits: List[SearchHit] = []
    for document in documents:
        score = 10.0
        reasons: List[str] = []

        if wanted:
            document_terms: Set[str] = set()
            for term in document.all_terms():
                document_terms.add(normalize(term))
                document_terms.update(tokens(term))
            if not (document_terms & wanted):
                continue
            score += 120.0
            reasons.append("room")

        if max_seconds is not None:
            if document.estimated_seconds is None:
                score += 5.0
            elif document.estimated_seconds <= max_seconds:
                score += 90.0
                reasons.append("fits-time")
            else:
                continue

        if normalised_material:
            document_material = normalize(document.material)
            if document_material and document_material == normalised_material:
                score += 80.0
                reasons.append("material")
            elif document_material and document_material != normalised_material:
                score -= 40.0

        if document.favourite:
            score += 50.0
            reasons.append("favourite")

        # Prefer things that worked before, but avoid what was just printed.
        if document.last_printed and now:
            age_days = (now - document.last_printed) / 86_400
            if age_days < exclude_recent_days:
                score -= 150.0
                reasons.append("recent")
            elif age_days < 120:
                score += 20.0

        score += min(30.0, document.print_count * 6.0)

        if score > 0:
            hits.append(SearchHit(document=document, score=score, reasons=reasons))

    hits.sort(key=lambda hit: -hit.score)
    return hits[:limit]
