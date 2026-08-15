#!/usr/bin/env python3
"""Static checks that can run without macOS/Xcode.

    python3 scripts/verify_project.py

Checks:
  1. project.pbxproj is structurally sound and every referenced object exists.
  2. Every Swift file on disk is a member of a target.
  3. Swift files are bracket-balanced (catches truncated/garbled files).
  4. en/ar localisations have identical key sets and format specifiers.
  5. Every localisation key used in Swift exists in the strings files.
  6. No secrets are committed.
  7. Python backend imports cleanly and shell scripts parse.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / "ios"
PBXPROJ = IOS / "NeptuneRemote.xcodeproj" / "project.pbxproj"
BACKEND = ROOT / "raspberry-pi"

failures: list[str] = []
warnings: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}" + (f" - {detail}" if detail else ""))
        failures.append(name)


def warn(name: str, detail: str) -> None:
    print(f"  warn  {name} - {detail}")
    warnings.append(name)


# --------------------------------------------------------------------------- #
# 1 + 2. Xcode project
# --------------------------------------------------------------------------- #


def check_project() -> None:
    print("\nXcode project")
    if not PBXPROJ.is_file():
        check("project.pbxproj exists", False)
        return
    text = PBXPROJ.read_text(encoding="utf-8")

    check("braces balanced", text.count("{") == text.count("}"),
          f"{text.count('{')} open vs {text.count('}')} close")
    check("parentheses balanced", text.count("(") == text.count(")"))
    check("root object declared", "rootObject = " in text)

    defined = set(re.findall(r"^\t\t([0-9A-F]{24}) /\*", text, re.MULTILINE))
    referenced = set(re.findall(r"\b([0-9A-F]{24})\b", text))
    dangling = sorted(referenced - defined)
    check("all object references resolve", not dangling,
          f"{len(dangling)} dangling: {dangling[:3]}")

    isas = re.findall(r"isa = (\w+);", text)
    for required in (
        "PBXProject", "PBXNativeTarget", "PBXSourcesBuildPhase",
        "PBXResourcesBuildPhase", "PBXFileReference", "PBXBuildFile",
        "XCBuildConfiguration", "XCConfigurationList", "PBXVariantGroup",
        "PBXTargetDependency", "PBXCopyFilesBuildPhase",
    ):
        check(f"contains {required}", required in isas)

    # app + widget extension + share extension + unit tests
    check("four native targets", isas.count("PBXNativeTarget") == 4,
          f"found {isas.count('PBXNativeTarget')}")

    # Every Swift file on disk must be referenced.
    swift_files = sorted(
        p.name for p in IOS.rglob("*.swift") if ".xcodeproj" not in str(p)
    )
    missing = [name for name in swift_files if f"/* {name} */" not in text]
    check(f"all {len(swift_files)} Swift files referenced", not missing, str(missing[:5]))

    # Every Swift file must be compiled by at least one target.
    not_compiled = [name for name in swift_files if f"/* {name} in Sources */" not in text]
    check("all Swift files in a Sources phase", not not_compiled, str(not_compiled[:5]))

    for resource in ("Assets.xcassets", "Localizable.strings", "Info.plist"):
        check(f"{resource} referenced", f"/* {resource} */" in text)

    scheme = IOS / "NeptuneRemote.xcodeproj" / "xcshareddata" / "xcschemes" / "NeptuneRemote.xcscheme"
    check("shared scheme present", scheme.is_file())


# --------------------------------------------------------------------------- #
# 3. Swift bracket balance
# --------------------------------------------------------------------------- #


def strip_swift(source: str) -> str:
    """Remove comments and string literals so bracket counting is meaningful."""
    out: list[str] = []
    index = 0
    length = len(source)
    while index < length:
        char = source[index]
        pair = source[index:index + 2]

        if pair == "//":
            end = source.find("\n", index)
            index = length if end == -1 else end
            continue
        if pair == "/*":
            depth = 1
            index += 2
            while index < length and depth:
                if source[index:index + 2] == "/*":
                    depth += 1
                    index += 2
                elif source[index:index + 2] == "*/":
                    depth -= 1
                    index += 2
                else:
                    index += 1
            continue
        if source[index:index + 3] == '"""':
            end = source.find('"""', index + 3)
            index = length if end == -1 else end + 3
            continue
        if char == '"':
            index += 1
            while index < length:
                if source[index] == "\\":
                    index += 2
                    continue
                if source[index] == '"':
                    index += 1
                    break
                # keep interpolation brackets balanced by copying them through
                if source[index - 1] == "\\" and source[index] == "(":
                    depth = 1
                    index += 1
                    while index < length and depth:
                        if source[index] == "(":
                            depth += 1
                        elif source[index] == ")":
                            depth -= 1
                        index += 1
                    continue
                index += 1
            continue
        out.append(char)
        index += 1
    return "".join(out)


def check_swift_syntax() -> None:
    print("\nSwift files")
    files = sorted(p for p in IOS.rglob("*.swift") if ".xcodeproj" not in str(p))
    bad: list[str] = []
    for path in files:
        cleaned = strip_swift(path.read_text(encoding="utf-8"))
        for open_char, close_char in (("{", "}"), ("(", ")"), ("[", "]")):
            if cleaned.count(open_char) != cleaned.count(close_char):
                bad.append(f"{path.relative_to(ROOT)} ({open_char}{close_char})")
                break
    check(f"{len(files)} Swift files bracket-balanced", not bad, str(bad[:5]))

    # Every file that uses SwiftUI types must import SwiftUI.
    missing_import = []
    for path in files:
        text = path.read_text(encoding="utf-8")
        if re.search(r"\b(some View|@State|@EnvironmentObject|View \{)", text):
            if "import SwiftUI" not in text and "import WidgetKit" not in text:
                missing_import.append(str(path.relative_to(ROOT)))
    check("SwiftUI imports present", not missing_import, str(missing_import[:5]))

    # No leftover placeholders.
    banned = re.compile(r"\b(TODO|FIXME|implement later|your code here)\b", re.IGNORECASE)
    offenders = []
    for path in list(files) + sorted(BACKEND.rglob("*.py")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if banned.search(line):
                offenders.append(f"{path.relative_to(ROOT)}:{number}")
    check("no TODO/FIXME placeholders", not offenders, str(offenders[:5]))


# --------------------------------------------------------------------------- #
# 4 + 5. Localisation
# --------------------------------------------------------------------------- #

STRING_LINE = re.compile(r'^"([^"]+)"\s*=\s*"(.*)";\s*$')


STRINGS_ENTRY = re.compile(r'^\s*"(?:[^"\\]|\\.)*"\s*=\s*"(?:[^"\\]|\\.)*"\s*;\s*$')


def malformed_strings_lines(path: Path) -> list[tuple[int, str]]:
    """Lines that are neither a comment nor a complete "key" = "value"; entry.

    Xcode parses the whole file, so one stray fragment fails the build. Block
    comments are tracked across lines because the headers in these files span
    several.
    """
    problems: list[tuple[int, str]] = []
    in_block_comment = False

    for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
        stripped = line.strip()

        if in_block_comment:
            if "*/" in stripped:
                in_block_comment = False
            continue
        if not stripped or stripped.startswith("//"):
            continue
        if stripped.startswith("/*"):
            if "*/" not in stripped[2:]:
                in_block_comment = True
            continue
        if not STRINGS_ENTRY.match(line):
            problems.append((number, stripped[:80]))

    if in_block_comment:
        problems.append((0, "unterminated block comment"))
    return problems


def parse_strings(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("/*") or line.startswith("//"):
            continue
        match = STRING_LINE.match(line)
        if match:
            result[match.group(1)] = match.group(2)
    return result


def check_screens_are_reachable() -> None:
    """Every screen must be constructed from somewhere other than itself.

    A View nobody navigates to compiles, ships, and is invisible - which is
    exactly how a release went out where three finished screens could not be
    opened at all. The user's report was "the app looks no different", and
    nothing in the build caught it.

    A screen here is a View whose name ends in `View` and which sets a
    navigation title, since that is what distinguishes a destination from a
    card or a row.
    """
    print("\nScreen reachability")
    files = sorted(p for p in IOS.rglob("*.swift") if ".xcodeproj" not in str(p))
    sources = {path: path.read_text(encoding="utf-8") for path in files}

    destinations: dict[str, pathlib.Path] = {}
    for path, text in sources.items():
        for name in re.findall(r"struct (\w+View)\s*:\s*View", text):
            # A navigation title is what makes it a place rather than a piece.
            body = text.split(f"struct {name}", 1)[1]
            if ".navigationTitle(" in body:
                destinations[name] = path

    unreachable = []
    for name, owner in destinations.items():
        # `Name(`, `Name()` and `Name { ... }` are all construction - the last
        # one is a trailing closure and has no parentheses at all.
        pattern = re.compile(rf"\b{name}\s*[({{]")
        referenced = False
        for path, text in sources.items():
            for line in text.splitlines():
                # Skip the declaration itself; a screen declared beside its
                # parent in one file is still perfectly reachable.
                if re.search(rf"struct\s+{name}\s*:", line):
                    continue
                if pattern.search(line):
                    referenced = True
                    break
            if referenced:
                break
        # The root screens are presented by the tab bar / app entry point,
        # which some builds do by value rather than by construction.
        if not referenced and name not in ROOT_SCREENS:
            unreachable.append(name)

    check(
        f"all {len(destinations)} screens reachable",
        not unreachable,
        "no navigation to: " + ", ".join(sorted(unreachable)),
    )


#: Screens the app shell owns; they need no inbound navigation.
ROOT_SCREENS = {"RootView", "HomeView", "FilesView", "LibraryView", "SliceView"}


def check_localization() -> None:
    print("\nLocalisation")
    resources = IOS / "NeptuneRemote" / "Resources"
    english_path = resources / "en.lproj" / "Localizable.strings"
    arabic_path = resources / "ar.lproj" / "Localizable.strings"

    if not english_path.is_file() or not arabic_path.is_file():
        check("both .strings files exist", False)
        return

    # Syntax first. parse_strings() reads line by line and simply skips
    # anything it does not recognise, so a file with a stray fragment in it
    # still yields a full, matching key set - which is exactly how a broken
    # .strings file passed every check here and then failed the build with
    # "Couldn't parse property list because the input data was in an invalid
    # format". Xcode reads the whole file; so must this.
    for path in (english_path, arabic_path):
        malformed = malformed_strings_lines(path)
        check(
            f"{path.parent.name}/Localizable.strings is well formed",
            not malformed,
            "; ".join(f"line {number}: {text}" for number, text in malformed[:3]),
        )

    english = parse_strings(english_path)
    arabic = parse_strings(arabic_path)

    check(f"English has {len(english)} keys", len(english) > 300)
    check("identical key sets", set(english) == set(arabic),
          f"only-en={sorted(set(english) - set(arabic))[:3]} "
          f"only-ar={sorted(set(arabic) - set(english))[:3]}")

    specifier = re.compile(r"%[0-9.]*[@dfs]")
    mismatched = [
        key for key in english
        if key in arabic and specifier.findall(english[key]) != specifier.findall(arabic[key])
    ]
    check("format specifiers match", not mismatched, str(mismatched[:5]))

    empty = [key for key, value in {**english, **arabic}.items() if not value.strip()]
    check("no empty translations", not empty, str(empty[:5]))

    # Keys used in Swift must exist.
    used: set[str] = set()
    patterns = [
        r'L\.t\("([a-zA-Z0-9_.]+)"',
        r'Text\(localized: "([a-zA-Z0-9_.]+)"',
        r'SectionHeader\("([a-zA-Z0-9_.]+)"',
        r'(?:titleKey|messageKey|retryTitleKey|actionTitleKey): "([a-zA-Z0-9_.]+)"',
        r'NSLocalizedString\("([a-zA-Z0-9_.]+)"',
    ]
    for path in IOS.rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for pattern in patterns:
            used.update(re.findall(pattern, text))

    missing = sorted(key for key in used if key not in english)
    check(f"all {len(used)} used keys are defined", not missing, str(missing[:8]))

    # Dynamic key families must be complete.
    families = {
        "printer.state.": ["standby", "printing", "paused", "complete", "cancelled", "error", "unknown"],
        "klippy.state.": ["ready", "startup", "shutdown", "error", "disconnected", "unknown"],
        "power.state.": ["on", "off", "unknown", "error"],
        "power.provider.": ["backend", "moonraker", "webhook", "demo", "none"],
        "camera.kind.": ["mjpeg", "snapshot", "webrtc", "mainsail"],
        "settings.appearance.": ["system", "light", "dark"],
        "history.result.": ["completed", "cancelled", "error", "in_progress"],
        "notification.": [
            "print_started.title", "print_paused.title", "print_resumed.title",
            "print_finished.title", "print_failed.title", "klipper_error.title",
            "disconnected.title", "connected.title", "target_reached.title",
            "auto_power_off.title", "vision_alert.title", "queue_ready.title",
            "maintenance_due.title", "filament_low.title",
        ],
        "vision.mode.": ["off", "monitor", "warn", "auto_pause"],
        "vision.kind.": ["spaghetti", "detached", "no_motion", "blocked", "unknown"],
        "vision.provider.": ["heuristic", "onnx", "disabled"],
        "cost.line.": [
            "filament", "electricity", "machine", "labour",
            "packaging", "failure", "other",
        ],
        "print.quality.": ["draft", "normal", "fine", "ultra"],
        "video.kind.": ["recording", "timelapse"],
        "timelapse.mode.": ["interval", "layer"],
        "bedmesh.verdict.": ["good", "fair", "poor"],
        "diagnostics.overall.": ["ok", "warning", "error"],
        "filament.check.": ["enough", "tight", "not_enough", "no_spool"],
        "home.state.": ["off", "starting", "ready", "printing", "complete", "error"],
        "search.reason.": ["exact", "alias", "synonym", "tag", "fuzzy", "category"],
        "subsystem.": [
            "connection", "moonraker", "klipper", "mcu", "config", "x_axis",
            "y_axis", "z_axis", "probe", "bed", "hotend", "part_cooling",
            "filament_sensor", "bed_mesh", "z_offset", "motion_limits",
            "accelerometer", "camera", "host", "storage",
        ],
        "workflow.": [
            "safe_home", "z_offset", "screws_tilt", "bed_mesh",
            "full_bed_calibration", "axis_health", "input_shaper",
            "safe_home.description", "z_offset.description",
            "screws_tilt.description", "bed_mesh.description",
            "full_bed_calibration.description", "axis_health.description",
            "input_shaper.description",
        ],
        "workflow.state.": [
            "idle", "running", "waiting_for_user", "done", "failed", "cancelled",
        ],
        "screws.verdict.": ["level", "adjust", "poor", "unknown"],
        "screw.": [
            "left_front", "left_middle", "left_rear",
            "right_front", "right_middle", "right_rear",
        ],
        "config.verdict.": ["ok", "warning", "blocked"],
        "config.reason.": [
            "manual", "pre_save_config", "pre_edit", "pre_restore", "imported", "auto",
        ],
        "gcode.verdict.": ["safe", "warning", "blocked"],
        "gcode.profile.": ["golden", "known", "unverified"],
        "preflight.verdict.": ["ready", "warning", "blocked"],
    }
    incomplete = [
        prefix + suffix
        for prefix, suffixes in families.items()
        for suffix in suffixes
        if prefix + suffix not in english
    ]
    check("dynamic key families complete", not incomplete, str(incomplete[:5]))


# --------------------------------------------------------------------------- #
# 6. Secrets
# --------------------------------------------------------------------------- #


def check_secrets() -> None:
    print("\nSecrets")
    tracked_config = ROOT / "raspberry-pi" / "config.yaml"
    check("config.yaml not committed", not tracked_config.exists())
    check(".env not committed", not (ROOT / "raspberry-pi" / ".env").exists())
    check("config.example.yaml present", (ROOT / "raspberry-pi" / "config.example.yaml").is_file())
    check(".env.example present", (ROOT / "raspberry-pi" / ".env.example").is_file())

    example = (ROOT / "raspberry-pi" / "config.example.yaml").read_text(encoding="utf-8")
    for field in ("access_id", "access_secret", "device_id", "api_token"):
        line = next((l for l in example.splitlines() if l.strip().startswith(field)), "")
        value = line.split(":", 1)[1].strip().strip('"') if ":" in line else "?"
        check(f"{field} is empty in the example", value == "", f"got {value!r}")

    # No Tuya-looking credentials anywhere in the tree.
    suspicious = []
    pattern = re.compile(r'(access_secret|access_id)\s*[:=]\s*["\']([A-Za-z0-9]{16,})["\']')
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix not in {".py", ".swift", ".yaml", ".yml", ".sh", ".json"}:
            continue
        if "/tests/" in str(path) or path.name.startswith("test_"):
            continue
        for match in pattern.finditer(path.read_text(encoding="utf-8", errors="replace")):
            suspicious.append(f"{path.relative_to(ROOT)}: {match.group(1)}")
    check("no hardcoded Tuya credentials", not suspicious, str(suspicious[:3]))


# --------------------------------------------------------------------------- #
# 7. Backend + shell
# --------------------------------------------------------------------------- #


def check_backend() -> None:
    print("\nBackend")
    result = subprocess.run(
        [sys.executable, "-m", "compileall", "-q", str(BACKEND / "app")],
        capture_output=True, text=True,
    )
    check("python sources compile", result.returncode == 0, result.stdout + result.stderr)

    scripts = sorted(ROOT.rglob("*.sh"))
    for script in scripts:
        result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
        check(f"{script.relative_to(ROOT)} syntax", result.returncode == 0, result.stderr.strip())

    # A script committed without its executable bit extracts from a GitHub
    # archive as non-executable, so `./install.sh` fails with "Permission
    # denied" for anyone who downloads the repository as a tarball rather than
    # cloning it. The local filesystem mode is not enough to catch this - the
    # mode recorded in the index is what ends up in the archive.
    tracked = subprocess.run(
        ["git", "ls-files", "-s", "--", "*.sh"],
        capture_output=True, text=True, cwd=str(ROOT.parent),
    )
    if tracked.returncode == 0:
        not_executable = [
            line.split("\t", 1)[1]
            for line in tracked.stdout.splitlines()
            if line and not line.startswith("100755")
        ]
        check(
            "shell scripts are executable in git",
            not not_executable,
            "run: git update-index --chmod=+x " + " ".join(not_executable),
        )

    service = BACKEND / "neptune-remote.service"
    if service.is_file():
        text = service.read_text(encoding="utf-8")
        check("systemd unit has [Unit]/[Service]/[Install]",
              all(section in text for section in ("[Unit]", "[Service]", "[Install]")))
        check("systemd unit restarts automatically", "Restart=always" in text)
        check("systemd unit has no stray comment syntax",
              not any(line.startswith("//") for line in text.splitlines()))

    print("\nProfiles")
    profiles = BACKEND / "profiles"
    for kind, expected in (
        ("printer", ["neptune3plus_0.2", "neptune3plus_0.4", "neptune3plus_0.6", "neptune3plus_0.8"]),
        ("filament", ["pla", "pla_plus", "petg", "tpu", "asa", "abs", "custom"]),
        ("print", ["quality", "standard", "fast", "klipper_fast", "custom"]),
    ):
        present = {p.stem for p in (profiles / kind).glob("*.ini")}
        missing = [name for name in expected if name not in present]
        check(f"{kind} profiles complete", not missing, str(missing))


def main() -> int:
    print("Neptune 3 Plus Remote - project verification")
    check_project()
    check_swift_syntax()
    check_screens_are_reachable()
    check_localization()
    check_secrets()
    check_backend()

    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED:")
        for name in failures:
            print(f"  - {name}")
        return 1
    print(f"All checks passed ({len(warnings)} warning(s)).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
