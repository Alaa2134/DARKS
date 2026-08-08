"""End-to-end proof that an STL can actually be uploaded.

Written while chasing a report of "the app will not take my STL". Both
endpoints answered 200 here, which is what ruled the backend out and moved the
search to the phone - so these stay as a regression test, and as the fastest
way to answer that question again next time.

The mesh is a tetrahedron rather than a single triangle on purpose: it has real
volume, so thumbnail rendering has a bounding box to work with.
"""

from pathlib import Path

from tests.test_api import client  # noqa: F401  (reuses the app fixture)

TETRAHEDRON_STL = """solid test
facet normal 0 0 -1
  outer loop
    vertex 0 0 0
    vertex 5 10 0
    vertex 10 0 0
  endloop
endfacet
facet normal 0 -1 0.5
  outer loop
    vertex 0 0 0
    vertex 10 0 0
    vertex 5 5 10
  endloop
endfacet
facet normal 1 0.5 0.5
  outer loop
    vertex 10 0 0
    vertex 5 10 0
    vertex 5 5 10
  endloop
endfacet
facet normal -1 0.5 0.5
  outer loop
    vertex 5 10 0
    vertex 0 0 0
    vertex 5 5 10
  endloop
endfacet
endsolid test
"""


def _stl(tmp_path: Path) -> Path:
    path = tmp_path / "tetra.stl"
    path.write_text(TETRAHEDRON_STL)
    return path


def test_model_upload_accepts_stl(client, tmp_path):  # noqa: F811
    """The slicer path: POST /api/models/upload."""
    with _stl(tmp_path).open("rb") as handle:
        response = client.post(
            "/api/models/upload", files={"file": ("tetra.stl", handle, "model/stl")}
        )

    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["ok"] is True
    assert payload["filename"] == "tetra.stl"
    assert payload["size"] > 0


def test_library_upload_accepts_stl_and_renders_a_thumbnail(client, tmp_path):  # noqa: F811
    """The library path: POST /api/library/upload, which also renders a preview."""
    with _stl(tmp_path).open("rb") as handle:
        response = client.post(
            "/api/library/upload",
            files={"file": ("tetra.stl", handle, "model/stl")},
            data={"category": "other"},
        )

    assert response.status_code == 200, response.text
    item = response.json()
    assert item["id"]
    # The name falls back to the filename stem when none is supplied.
    assert item["name_en"] == "tetra"
    assert item["thumbnail"], "a thumbnail should have been generated"


def test_unsupported_extension_is_refused_with_a_readable_reason(client, tmp_path):  # noqa: F811
    bogus = tmp_path / "notes.txt"
    bogus.write_text("not a mesh")

    with bogus.open("rb") as handle:
        response = client.post(
            "/api/models/upload", files={"file": ("notes.txt", handle, "text/plain")}
        )

    assert response.status_code == 400
    detail = response.json()["detail"]
    assert ".txt" in detail
    # The message names what *is* accepted, so the caller can act on it.
    assert ".stl" in detail
