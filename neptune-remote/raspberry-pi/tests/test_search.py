"""Arabic normalisation, fuzzy matching and library search ranking."""

from __future__ import annotations

import pytest

from app.search.arabic import (
    damerau_levenshtein,
    is_arabic,
    normalize,
    similarity,
    stems,
    tokens,
    transliterate,
)
from app.search.engine import SearchDocument, SearchEngine, find_ideas, suggestions
from app.search.synonyms import expand, expand_query


# --------------------------------------------------------------------------- #
# Normalisation
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("أحمد", "احمد"),
        ("إبراهيم", "ابراهيم"),
        ("آلة", "اله"),
        ("مصطفى", "مصطفي"),
        ("ميدالية", "ميداليه"),
        ("مِيدَالِيَّة", "ميداليه"),
        ("حــــامل", "حامل"),
        ("حامل   موبايل", "حامل موبايل"),
        ("Phone Stand!", "phone stand"),
        ("١٢٣", "123"),
        ("حاااامل", "حامل"),
    ],
)
def test_normalisation_rules(raw, expected):
    assert normalize(raw) == expected


def test_normalise_empty_and_punctuation():
    assert normalize("") == ""
    assert normalize("!!!???") == ""
    assert normalize("  ") == ""


def test_hamza_and_taa_marbuta_unify():
    # These three spellings must all collapse to the same token.
    assert normalize("ميدالية") == normalize("ميداليه") == normalize("مِيدالية")


def test_tokens_drop_stopwords():
    assert tokens("حامل من الموبايل") == ["حامل", "الموبايل"]
    assert tokens("stand for the phone") == ["stand", "phone"]


def test_stems_strip_definite_article():
    assert "موبايل" in stems("الموبايل")
    assert "حامل" in stems("حامل")


def test_is_arabic():
    assert is_arabic("حامل")
    assert not is_arabic("stand")


def test_transliteration_is_stable():
    assert transliterate("ميدالية").startswith("m")
    assert transliterate("stand") == "stand"


# --------------------------------------------------------------------------- #
# Edit distance
# --------------------------------------------------------------------------- #


def test_edit_distance_basics():
    assert damerau_levenshtein("cat", "cat") == 0
    assert damerau_levenshtein("cat", "cut") == 1
    assert damerau_levenshtein("cat", "act") == 1          # transposition
    assert damerau_levenshtein("", "abc") == 3


def test_edit_distance_short_circuits():
    assert damerau_levenshtein("a", "abcdefghij", max_distance=2) == 3


def test_similarity_scores():
    assert similarity("ميداليه", "ميداليه") == 1.0
    assert similarity("ميدليه", "ميداليه") > 0.8
    assert similarity("حامل", "طاولة") < 0.5  # well below the 0.62 fuzzy threshold


# --------------------------------------------------------------------------- #
# Synonyms
# --------------------------------------------------------------------------- #


def test_synonyms_link_arabic_and_english():
    group = expand("موبايل")
    assert "phone" in group
    assert "تليفون" in group

    group = expand("keychain")
    assert normalize("ميدالية") in group


def test_expand_query_covers_each_token():
    expanded = expand_query("حامل موبايل")
    assert "phone" in expanded
    assert "stand" in expanded or "holder" in expanded


# --------------------------------------------------------------------------- #
# Ranking
# --------------------------------------------------------------------------- #


@pytest.fixture()
def documents():
    return [
        SearchDocument(
            id="stand", name_ar="حامل موبايل للمكتب", name_en="Desk phone stand",
            tags=["مكتب", "موبايل"], category="stands", print_count=4, favourite=True,
            material="PLA", estimated_seconds=5400,
        ),
        SearchDocument(
            id="keychain", name_ar="ميدالية مفاتيح", name_en="Keychain",
            aliases=["تعليقة مفاتيح"], tags=["هدايا"], category="keychains",
            print_count=12, material="PLA", estimated_seconds=900,
        ),
        SearchDocument(
            id="vase", name_ar="فازة ديكور", name_en="Decorative vase",
            tags=["ديكور", "منزل"], category="decor", material="PETG",
            estimated_seconds=18000,
        ),
        SearchDocument(
            id="bracket", name_ar="مسند رف", name_en="Shelf bracket",
            tags=["منزل"], category="spare_parts", material="PETG", estimated_seconds=3600,
        ),
        SearchDocument(
            id="robot", name_ar="قاعدة روبوت اردوينو", name_en="Arduino robot base",
            tags=["روبوتات", "اردوينو"], category="robotics", material="PLA",
            estimated_seconds=21600,
        ),
    ]


@pytest.fixture()
def engine():
    return SearchEngine()


def test_exact_arabic_name_wins(engine, documents):
    hits = engine.search("حامل موبايل للمكتب", documents)
    assert hits[0].document.id == "stand"
    assert "exact" in hits[0].reasons


def test_partial_arabic_query(engine, documents):
    hits = engine.search("حامل موبايل", documents)
    assert hits[0].document.id == "stand"


def test_english_query_finds_arabic_item(engine, documents):
    hits = engine.search("phone stand", documents)
    assert any(hit.document.id == "stand" for hit in hits)


def test_synonym_query(engine, documents):
    # "ستاند تليفون" shares no literal words with "حامل موبايل".
    hits = engine.search("ستاند تليفون", documents)
    assert any(hit.document.id == "stand" for hit in hits), [h.document.id for h in hits]


def test_typo_tolerance_arabic(engine, documents):
    # The exact case from the specification: "ميدليه" must find "ميدالية".
    hits = engine.search("ميدليه", documents)
    assert hits, "a typo query returned nothing"
    assert hits[0].document.id == "keychain"


def test_typo_tolerance_english(engine, documents):
    hits = engine.search("keychan", documents)
    assert any(hit.document.id == "keychain" for hit in hits)


def test_alias_match(engine, documents):
    hits = engine.search("تعليقة مفاتيح", documents)
    assert hits[0].document.id == "keychain"


def test_taa_marbuta_variants_match(engine, documents):
    for query in ("ميدالية", "ميداليه", "ميدالية مفاتيح"):
        hits = engine.search(query, documents)
        assert hits and hits[0].document.id == "keychain", query


def test_definite_article_is_ignored(engine, documents):
    hits = engine.search("الميدالية", documents)
    assert any(hit.document.id == "keychain" for hit in hits)


def test_category_filter(engine, documents):
    hits = engine.search("", documents, category="decor")
    assert [hit.document.id for hit in hits] == ["vase"]


def test_favourites_filter(engine, documents):
    hits = engine.search("", documents, favourites_only=True)
    assert [hit.document.id for hit in hits] == ["stand"]


def test_empty_query_browses_by_popularity(engine, documents):
    hits = engine.search("", documents)
    # Favourite first, then most printed.
    assert hits[0].document.id == "stand"
    assert hits[1].document.id == "keychain"


def test_nonsense_query_returns_nothing(engine, documents):
    assert engine.search("زققثصضطظ", documents) == []


def test_tag_search(engine, documents):
    hits = engine.search("ديكور", documents)
    assert any(hit.document.id == "vase" for hit in hits)


def test_robotics_synonyms(engine, documents):
    hits = engine.search("اردوينو", documents)
    assert hits[0].document.id == "robot"
    hits = engine.search("arduino", documents)
    assert any(hit.document.id == "robot" for hit in hits)


# --------------------------------------------------------------------------- #
# Suggestions
# --------------------------------------------------------------------------- #


def test_suggestions_prefix(documents):
    result = suggestions("حام", documents)
    assert any("حامل" in name for name in result)


def test_suggestions_typo(documents):
    result = suggestions("ميدلي", documents)
    assert any("ميدالية" in name for name in result)


def test_suggestions_empty_prefix(documents):
    assert suggestions("", documents) == []


# --------------------------------------------------------------------------- #
# Idea finder
# --------------------------------------------------------------------------- #


def test_ideas_filter_by_room(documents):
    hits = find_ideas(documents, room="desk", now=0)
    assert any(hit.document.id == "stand" for hit in hits)


def test_ideas_respect_time_budget(documents):
    hits = find_ideas(documents, max_seconds=1200, now=0)
    ids = [hit.document.id for hit in hits]
    assert "keychain" in ids
    assert "vase" not in ids  # 5 hours does not fit in 20 minutes


def test_ideas_prefer_matching_material(documents):
    hits = find_ideas(documents, material="PETG", now=0)
    assert hits
    assert hits[0].document.material == "PETG"


def test_ideas_avoid_recent_prints():
    import time

    now = time.time()
    recent = SearchDocument(id="a", name_ar="ميدالية", last_printed=now - 3600, print_count=1)
    old = SearchDocument(id="b", name_ar="ميدالية قديمة", last_printed=now - 90 * 86400, print_count=1)
    hits = find_ideas([recent, old], now=now)
    assert hits[0].document.id == "b"


def test_ideas_surprise_me_returns_something(documents):
    assert find_ideas(documents, now=0, limit=3)
