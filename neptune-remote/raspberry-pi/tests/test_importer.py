"""Pasting a link and getting a model - safely."""

from __future__ import annotations

import io
import struct
import zipfile

import httpx
import pytest

from app.library.importer import (
    MAX_ARCHIVE_MODELS,
    MODEL_EXTENSIONS,
    Download,
    ImportError_,
    check_url,
    fetch,
    resolve,
    unpack,
)


def stl_bytes(triangles: int = 2) -> bytes:
    data = bytearray(b"\0" * 80) + struct.pack("<I", triangles)
    for index in range(triangles):
        data += struct.pack("<3f", 0.0, 0.0, 1.0)
        for corner in range(3):
            data += struct.pack("<3f", float(index), float(corner), 0.0)
        data += struct.pack("<H", 0)
    return bytes(data)


def zip_of(names_and_data) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, payload in names_and_data:
            archive.writestr(name, payload)
    return buffer.getvalue()


# --------------------------------------------------------------------------- #
# What may be fetched
# --------------------------------------------------------------------------- #


def test_a_public_https_url_is_allowed():
    assert check_url("https://example.com/part.stl") == "https://example.com/part.stl"


@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1:7125/printer/emergency_stop",
        "http://localhost/admin",
        "http://192.168.1.1/",
        "http://10.0.0.5/thing.stl",
        "http://169.254.169.254/latest/meta-data/",   # cloud metadata
        "http://[::1]/x.stl",
    ],
)
def test_anything_pointing_inward_is_refused(url):
    # A Pi that fetches whatever it is told is a Pi that will POST to its own
    # Moonraker, or read a router's admin page, or a metadata endpoint.
    with pytest.raises(ImportError_):
        check_url(url)


def test_a_non_http_scheme_is_refused():
    for url in ("file:///etc/passwd", "ftp://example.com/x.stl", "gopher://x"):
        with pytest.raises(ImportError_):
            check_url(url)


def test_an_empty_or_hostless_url_is_refused():
    with pytest.raises(ImportError_):
        check_url("")
    with pytest.raises(ImportError_):
        check_url("https:///no-host.stl")


def test_a_name_that_does_not_resolve_is_refused():
    with pytest.raises(ImportError_):
        check_url("https://this-name-does-not-exist.invalid/part.stl")


# --------------------------------------------------------------------------- #
# Working out what a link is
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize("extension", sorted(MODEL_EXTENSIONS) + [".zip"])
def test_a_direct_file_link_needs_no_resolving(extension):
    source = resolve(f"https://example.com/models/part{extension}")

    assert source.download_url.endswith(extension)
    assert source.name == f"part{extension}"
    assert source.needs_key == ""


def test_a_link_with_an_escaped_name_is_read_correctly():
    source = resolve("https://example.com/files/phone%20stand.stl")
    assert source.name == "phone stand.stl"


def test_a_thingiverse_page_without_a_key_says_which_key_is_missing():
    source = resolve("https://www.thingiverse.com/thing:12345")

    # Reported rather than raised: the app can offer to set the key.
    assert source.needs_key == "thingiverse"
    assert source.download_url == ""


def test_a_thingiverse_page_with_a_key_resolves_to_its_archive():
    source = resolve(
        "https://www.thingiverse.com/thing:12345", thingiverse_key="secret"
    )

    assert "thing:12345/zip" in source.download_url
    assert source.page_url.endswith("thing:12345")


def test_a_thingiverse_link_with_no_id_says_so():
    with pytest.raises(ImportError_):
        resolve("https://www.thingiverse.com/search?q=box", thingiverse_key="k")


def test_printables_and_makerworld_explain_themselves_rather_than_guessing():
    # Downloading their HTML and calling it a model would be worse than saying
    # what actually works.
    for url in (
        "https://www.printables.com/model/12345-thing",
        "https://makerworld.com/en/models/999",
    ):
        with pytest.raises(ImportError_) as caught:
            resolve(url)
        assert "نزّل" in str(caught.value) or "الملف" in str(caught.value)


def test_an_unknown_site_is_refused_with_advice():
    with pytest.raises(ImportError_) as caught:
        resolve("https://example.com/some/page")
    assert "STL" in str(caught.value)


# --------------------------------------------------------------------------- #
# Downloading
# --------------------------------------------------------------------------- #


def transport(handler):
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


@pytest.mark.asyncio
async def test_a_file_downloads_with_its_name():
    payload = stl_bytes()

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=payload)

    async with transport(handler) as client:
        result = await fetch("https://example.com/part.stl", client=client)

    assert result.data == payload
    assert result.filename == "part.stl"


@pytest.mark.asyncio
async def test_the_servers_own_filename_wins_over_the_url():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            content=b"solid\n",
            headers={"content-disposition": 'attachment; filename="real name.stl"'},
        )

    async with transport(handler) as client:
        result = await fetch("https://example.com/download?id=7", client=client)

    assert result.filename == "real name.stl"


@pytest.mark.asyncio
async def test_a_redirect_to_a_private_address_is_refused():
    # The whole attack: a public URL that 302s inward. Following redirects in
    # the client rather than by hand would walk straight into it.
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(302, headers={"location": "http://127.0.0.1:7125/x.stl"})

    async with transport(handler) as client:
        with pytest.raises(ImportError_):
            await fetch("https://example.com/part.stl", client=client)


@pytest.mark.asyncio
async def test_a_redirect_loop_gives_up():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(302, headers={"location": "https://example.com/again.stl"})

    async with transport(handler) as client:
        with pytest.raises(ImportError_):
            await fetch("https://example.com/part.stl", client=client)


@pytest.mark.asyncio
async def test_a_declared_size_over_the_limit_is_refused_before_downloading():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, content=b"x", headers={"content-length": str(10 * 1024 * 1024)}
        )

    async with transport(handler) as client:
        with pytest.raises(ImportError_):
            await fetch("https://example.com/big.stl", client=client, max_bytes=1024)


@pytest.mark.asyncio
async def test_a_body_that_lies_about_its_size_is_still_cut_off():
    # No content-length, or a false one. Reading to the end of an endless
    # response is how a card fills up.
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"x" * 5000)

    async with transport(handler) as client:
        with pytest.raises(ImportError_):
            await fetch("https://example.com/big.stl", client=client, max_bytes=1000)


@pytest.mark.asyncio
async def test_common_failures_are_explained_rather_than_reported_as_codes():
    for status, expected in ((404, "مش موجود"), (403, "تسجيل دخول"), (500, "500")):
        def handler(request: httpx.Request, status=status) -> httpx.Response:
            return httpx.Response(status)

        async with transport(handler) as client:
            with pytest.raises(ImportError_) as caught:
                await fetch("https://example.com/part.stl", client=client)
            assert expected in str(caught.value)


# --------------------------------------------------------------------------- #
# Unpacking
# --------------------------------------------------------------------------- #


def test_a_bare_model_becomes_a_one_part_project():
    project = unpack(Download(data=stl_bytes(), filename="bracket.stl"))

    assert project.name == "bracket"
    assert len(project.models) == 1
    assert project.models[0].filename == "bracket.stl"


def test_an_archive_of_parts_becomes_one_project():
    # Splitting it loses the only thing that said they belong together.
    payload = zip_of([
        ("kit/base.stl", stl_bytes()),
        ("kit/lid.stl", stl_bytes()),
        ("kit/pin.stl", stl_bytes()),
    ])
    project = unpack(Download(data=payload, filename="kit.zip"))

    assert project.name == "kit"
    assert len(project.models) == 3
    assert {model.filename for model in project.models} == {"base.stl", "lid.stl", "pin.stl"}
    assert any("مشروع واحد" in note for note in project.notes_ar)


def test_non_model_files_in_an_archive_are_ignored():
    payload = zip_of([
        ("part.stl", stl_bytes()),
        ("readme.txt", b"instructions"),
        ("preview.png", b"\x89PNG"),
    ])
    project = unpack(Download(data=payload, filename="thing.zip"))

    assert [model.filename for model in project.models] == ["part.stl"]


def test_packaging_noise_is_skipped():
    payload = zip_of([
        ("__MACOSX/._part.stl", b"junk"),
        (".hidden/secret.stl", stl_bytes()),
        ("part.stl", stl_bytes()),
    ])
    project = unpack(Download(data=payload, filename="thing.zip"))

    assert [model.filename for model in project.models] == ["part.stl"]


def test_an_archive_member_trying_to_escape_is_skipped():
    payload = zip_of([("../../evil.stl", stl_bytes()), ("good.stl", stl_bytes())])
    project = unpack(Download(data=payload, filename="thing.zip"))

    assert [model.filename for model in project.models] == ["good.stl"]


def test_an_archive_with_no_models_says_so():
    payload = zip_of([("readme.txt", b"nothing here")])

    with pytest.raises(ImportError_) as caught:
        unpack(Download(data=payload, filename="docs.zip"))
    assert "مفيهوش أي موديل" in str(caught.value)


def test_a_corrupt_archive_says_so():
    with pytest.raises(ImportError_) as caught:
        unpack(Download(data=b"PK not really a zip", filename="broken.zip"))
    assert "تالف" in str(caught.value)


def test_a_zip_bomb_is_refused_before_anything_is_written():
    # 40 KB that claims to expand to far more than the limit. Finding this out
    # by running out of disk is the wrong way to find it out.
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("huge.stl", b"\0" * (2 * 1024 * 1024))
    payload = buffer.getvalue()

    from app.library import importer

    original = importer.MAX_ARCHIVE_UNPACKED_BYTES
    importer.MAX_ARCHIVE_UNPACKED_BYTES = 1024
    try:
        with pytest.raises(ImportError_) as caught:
            unpack(Download(data=payload, filename="bomb.zip"))
        assert "أكبر من اللازم" in str(caught.value)
    finally:
        importer.MAX_ARCHIVE_UNPACKED_BYTES = original


def test_an_archive_with_too_many_models_is_capped_and_says_so():
    payload = zip_of([
        (f"part{index}.stl", stl_bytes()) for index in range(MAX_ARCHIVE_MODELS + 5)
    ])
    project = unpack(Download(data=payload, filename="pack.zip"))

    assert len(project.models) == MAX_ARCHIVE_MODELS
    assert any("اتاخد أول" in note for note in project.notes_ar)


def test_an_unsupported_file_type_lists_what_is_supported():
    with pytest.raises(ImportError_) as caught:
        unpack(Download(data=b"%PDF-1.4", filename="manual.pdf"))
    assert ".stl" in str(caught.value)


def test_a_zip_recognised_by_its_bytes_rather_than_its_name():
    # Servers hand out archives named `download` all the time.
    payload = zip_of([("part.stl", stl_bytes())])
    project = unpack(Download(data=payload, filename="download"))

    assert len(project.models) == 1
