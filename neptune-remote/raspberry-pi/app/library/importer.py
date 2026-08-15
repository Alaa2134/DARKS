"""Paste a link, get a model.

The library was an archive: everything in it had to be uploaded from the phone,
which means finding the model on a desktop, downloading it, moving it to the
phone, and then uploading it again. This makes the library a place things arrive
rather than a place they are put.

Three things it has to get right, and only one of them is downloading a file.

**Not fetching whatever it is told to.** A URL from the app is a URL a person
typed, and a Pi that will fetch any address is a Pi that will fetch
`http://localhost:7125/printer/emergency_stop`, or a router's admin page, or a
cloud metadata endpoint. Every host is resolved and checked against the private
ranges before a request is made, and again after any redirect - a public
hostname that resolves to 127.0.0.1 is the oldest trick there is.

**Knowing when to stop.** A download with no limit is a full SD card. A zip with
no limit is a zip bomb: 40 KB that expands to 40 GB. Both are bounded, and the
zip is measured by its declared sizes before anything is written.

**Keeping a project together.** A zip holding eight STLs is one model with eight
parts, not eight models. Splitting it loses the only thing that said they belong
together.
"""

from __future__ import annotations

import ipaddress
import logging
import posixpath
import re
import socket
import zipfile
from dataclasses import dataclass, field
from io import BytesIO
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple
from urllib.parse import unquote, urlparse

import httpx

log = logging.getLogger("neptune.library.importer")

#: Extensions worth keeping out of an archive.
MODEL_EXTENSIONS = {".stl", ".3mf", ".obj", ".amf", ".step", ".stp"}

#: Anything bigger than this is not a model somebody is about to print on a
#: Neptune; it is a mistake, and it would fill the card.
MAX_DOWNLOAD_BYTES = 512 * 1024 * 1024

#: Total uncompressed size allowed out of one archive. A zip bomb is 40 KB that
#: expands to 40 GB, so the declared sizes are added up *before* anything is
#: written.
MAX_ARCHIVE_UNPACKED_BYTES = 1024 * 1024 * 1024

#: Most models in one archive. Past this it is a pack, not a project, and
#: importing it as one item produces something unusable.
MAX_ARCHIVE_MODELS = 64

#: How long to wait for the other end.
REQUEST_TIMEOUT = 60.0

#: Redirect chains are followed by hand so each hop can be checked. Three is
#: enough for every real host and short enough to stop a loop.
MAX_REDIRECTS = 3


class ImportError_(RuntimeError):
    """Named with a trailing underscore: `ImportError` is a builtin."""


# --------------------------------------------------------------------------- #
# Deciding whether a URL may be fetched
# --------------------------------------------------------------------------- #


def _is_private(host: str) -> bool:
    """Whether a hostname resolves anywhere we must not send a request.

    Resolved rather than pattern-matched. `127.0.0.1` is obvious; a hostname
    that resolves to it is the same request and does not look like anything.
    """
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        # A name that does not resolve cannot be fetched anyway, and refusing
        # here gives a clearer message than a connection error later.
        return True

    for info in infos:
        address = info[4][0]
        try:
            parsed = ipaddress.ip_address(address)
        except ValueError:
            return True
        if (
            parsed.is_private
            or parsed.is_loopback
            or parsed.is_link_local
            or parsed.is_reserved
            or parsed.is_multicast
            or parsed.is_unspecified
        ):
            return True
    return False


def check_url(url: str) -> str:
    """The URL, or an error saying why it will not be fetched."""
    raw = (url or "").strip()
    if not raw:
        raise ImportError_("مفيش رابط.")

    parsed = urlparse(raw)
    if parsed.scheme not in ("http", "https"):
        raise ImportError_("الرابط لازم يبدأ بـ http:// أو https://")
    if not parsed.hostname:
        raise ImportError_("الرابط ده مفيهوش اسم موقع.")
    if _is_private(parsed.hostname):
        raise ImportError_(
            "الرابط ده بيشاور على جهاز في الشبكة المحلية أو على الباي نفسها، "
            "والاستيراد بيجيب من الإنترنت بس."
        )
    return raw


# --------------------------------------------------------------------------- #
# Working out what a link points at
# --------------------------------------------------------------------------- #


@dataclass
class ResolvedSource:
    """Where the file actually is, and what to call the thing it becomes."""

    download_url: str
    name: str = ""
    #: Where it came from, kept with the model. Respecting a licence starts
    #: with knowing whose work it is.
    page_url: str = ""
    author: str = ""
    licence: str = ""
    #: Set when the site needs a key this Pi does not have.
    needs_key: str = ""


_PRINTABLES = re.compile(r"printables\.com/", re.I)
_THINGIVERSE = re.compile(r"thingiverse\.com/", re.I)
_MAKERWORLD = re.compile(r"makerworld\.com/", re.I)
_THING_ID = re.compile(r"thing:(\d+)")


def resolve(url: str, *, thingiverse_key: str = "") -> ResolvedSource:
    """Turn a link into something downloadable.

    A direct file link is already one. A model *page* is not, and each site
    needs its own answer - so a site we cannot resolve says so plainly rather
    than downloading its HTML and calling it a model.
    """
    checked = check_url(url)
    path = urlparse(checked).path
    extension = Path(unquote(path)).suffix.lower()

    if extension in MODEL_EXTENSIONS or extension == ".zip":
        return ResolvedSource(
            download_url=checked,
            name=Path(unquote(path)).name,
            page_url=checked,
        )

    if _THINGIVERSE.search(checked):
        match = _THING_ID.search(checked)
        if not match:
            raise ImportError_(
                "مش لاقي رقم الموديل في رابط Thingiverse ده. "
                "استخدم رابط صفحة الموديل نفسه."
            )
        if not thingiverse_key:
            return ResolvedSource(
                download_url="",
                page_url=checked,
                needs_key="thingiverse",
            )
        thing_id = match.group(1)
        return ResolvedSource(
            download_url=(
                f"https://www.thingiverse.com/thing:{thing_id}/zip"
                f"?access_token={thingiverse_key}"
            ),
            name=f"thing-{thing_id}.zip",
            page_url=checked,
        )

    if _PRINTABLES.search(checked):
        raise ImportError_(
            "روابط صفحات Printables محتاجة تسجيل دخول عشان التنزيل. "
            "افتح الصفحة، نزّل الملف، وبعدين الصق رابط الملف المباشر - "
            "أو ارفعه من التطبيق."
        )

    if _MAKERWORLD.search(checked):
        raise ImportError_(
            "MakerWorld مفيهاش API عام للتنزيل، فالرابط ده مش هينفع. "
            "نزّل الملف وارفعه من التطبيق."
        )

    raise ImportError_(
        "مش عارف أجيب موديل من الرابط ده. لو عندك رابط مباشر لملف "
        "STL أو 3MF أو ZIP، استخدمه."
    )


# --------------------------------------------------------------------------- #
# Fetching
# --------------------------------------------------------------------------- #


@dataclass
class Download:
    data: bytes
    filename: str
    content_type: str = ""


async def fetch(
    url: str,
    *,
    client: Optional[httpx.AsyncClient] = None,
    max_bytes: int = MAX_DOWNLOAD_BYTES,
) -> Download:
    """Download a file, following redirects one hop at a time.

    Redirects are followed by hand rather than by the client, because each hop
    is a new host and a new chance to be pointed somewhere private. A public
    URL that 302s to `http://127.0.0.1` is the whole attack.

    The body is read in chunks and abandoned the moment it passes the limit,
    so an endless response costs a few megabytes rather than the card.
    """
    owned = client is None
    session = client or httpx.AsyncClient(timeout=REQUEST_TIMEOUT)
    current = check_url(url)

    try:
        for _ in range(MAX_REDIRECTS + 1):
            async with session.stream("GET", current, follow_redirects=False) as response:
                if response.status_code in (301, 302, 303, 307, 308):
                    location = response.headers.get("location", "")
                    if not location:
                        raise ImportError_("الموقع رجّع تحويلة من غير عنوان.")
                    current = check_url(httpx.URL(current).join(location).__str__())
                    continue

                if response.status_code == 404:
                    raise ImportError_("الملف ده مش موجود على الرابط ده.")
                if response.status_code in (401, 403):
                    raise ImportError_(
                        "الموقع رفض التنزيل — الملف ده غالبًا محتاج تسجيل دخول."
                    )
                if response.status_code >= 400:
                    raise ImportError_(
                        f"الموقع رجّع خطأ {response.status_code}."
                    )

                declared = response.headers.get("content-length")
                if declared and declared.isdigit() and int(declared) > max_bytes:
                    raise ImportError_(
                        f"الملف أكبر من {max_bytes // (1024 * 1024)} ميجا."
                    )

                chunks: List[bytes] = []
                total = 0
                async for chunk in response.aiter_bytes():
                    total += len(chunk)
                    if total > max_bytes:
                        raise ImportError_(
                            f"الملف أكبر من {max_bytes // (1024 * 1024)} ميجا."
                        )
                    chunks.append(chunk)

                return Download(
                    data=b"".join(chunks),
                    filename=_filename_for(current, response.headers),
                    content_type=response.headers.get("content-type", ""),
                )

        raise ImportError_("الرابط بيحوّل لنفسه أكتر من اللازم.")
    except httpx.HTTPError as error:
        raise ImportError_(f"مش قادر أوصل للرابط: {error}") from error
    finally:
        if owned:
            await session.aclose()


def _filename_for(url: str, headers) -> str:
    """The name to save under, from the server's word or the URL's."""
    disposition = headers.get("content-disposition", "")
    match = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)"?', disposition)
    if match:
        candidate = unquote(match.group(1)).strip()
        if candidate:
            return Path(candidate).name

    name = Path(unquote(urlparse(url).path)).name
    return name or "download"


# --------------------------------------------------------------------------- #
# Unpacking
# --------------------------------------------------------------------------- #


@dataclass
class ExtractedModel:
    filename: str
    data: bytes


@dataclass
class ImportedProject:
    """One import: a name, and the model files that came with it."""

    name: str = ""
    models: List[ExtractedModel] = field(default_factory=list)
    source_url: str = ""
    author: str = ""
    licence: str = ""
    notes_ar: List[str] = field(default_factory=list)

    @property
    def is_empty(self) -> bool:
        return not self.models


def _is_safe_member(name: str) -> bool:
    """Whether a zip entry may be extracted.

    A zip can name `../../etc/anything` or an absolute path, and extracting one
    blindly writes wherever it says. Nothing here is written to the path the
    archive chose anyway - only the basename is kept - but a member that tries
    is a member worth skipping outright.
    """
    if not name or name.endswith("/"):
        return False
    if name.startswith("/") or ".." in Path(name).parts:
        return False
    # __MACOSX and dotfiles are packaging noise, not models.
    parts = Path(name).parts
    return not any(part.startswith(("__MACOSX", ".")) for part in parts)


def unpack(download: Download) -> ImportedProject:
    """Turn what was downloaded into a project.

    A zip holding eight STLs is one model with eight parts, not eight models.
    Splitting it loses the only thing that said they belong together.
    """
    stem = Path(download.filename).stem or "model"
    extension = Path(download.filename).suffix.lower()

    if extension in MODEL_EXTENSIONS:
        return ImportedProject(
            name=stem,
            models=[ExtractedModel(filename=download.filename, data=download.data)],
        )

    if extension != ".zip" and not download.data[:2] == b"PK":
        raise ImportError_(
            f"نوع الملف «{extension or 'مش معروف'}» مش مدعوم. "
            "المدعوم: " + "، ".join(sorted(MODEL_EXTENSIONS)) + " و ZIP."
        )

    project = ImportedProject(name=stem)
    try:
        with zipfile.ZipFile(BytesIO(download.data)) as archive:
            members = [
                info for info in archive.infolist()
                if _is_safe_member(info.filename)
                and Path(info.filename).suffix.lower() in MODEL_EXTENSIONS
            ]

            if not members:
                raise ImportError_(
                    "الملف المضغوط ده مفيهوش أي موديل. "
                    "المدعوم: " + "، ".join(sorted(MODEL_EXTENSIONS)) + "."
                )

            # Declared sizes are added up before a single byte is written: a
            # zip bomb is 40 KB that expands to 40 GB, and finding that out by
            # running out of disk is the wrong way to find it out.
            declared = sum(info.file_size for info in members)
            if declared > MAX_ARCHIVE_UNPACKED_BYTES:
                raise ImportError_(
                    "الملف المضغوط بيفك لحجم أكبر من اللازم — غالبًا مش موديل."
                )

            if len(members) > MAX_ARCHIVE_MODELS:
                project.notes_ar.append(
                    f"الأرشيف فيه {len(members)} موديل، اتاخد أول "
                    f"{MAX_ARCHIVE_MODELS} بس."
                )
                members = members[:MAX_ARCHIVE_MODELS]

            for info in members:
                with archive.open(info) as handle:
                    data = handle.read(MAX_ARCHIVE_UNPACKED_BYTES + 1)
                if len(data) > MAX_ARCHIVE_UNPACKED_BYTES:
                    raise ImportError_("ملف جوه الأرشيف أكبر من اللازم.")
                project.models.append(
                    ExtractedModel(filename=Path(info.filename).name, data=data)
                )
    except zipfile.BadZipFile as error:
        raise ImportError_("الملف المضغوط ده تالف.") from error

    if len(project.models) > 1:
        project.notes_ar.append(
            f"الأرشيف فيه {len(project.models)} قطعة، واتحفظوا كمشروع واحد."
        )
    return project
