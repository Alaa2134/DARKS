#!/usr/bin/env python3
"""Generate ios/NeptuneRemote.xcodeproj from the source tree.

The generated project is committed, so Xcode users never need this script.
Run it again after adding or removing Swift files:

    python3 scripts/generate_xcodeproj.py

Targets produced:
    NeptuneRemote          iOS app (SwiftUI, iOS 17+)
    NeptuneRemoteWidget    WidgetKit extension, embedded in the app
    NeptuneRemoteTests     XCTest bundle hosted by the app
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / "ios"
PROJECT = IOS / "NeptuneRemote.xcodeproj"

APP = "NeptuneRemote"
WIDGET = "NeptuneRemoteWidget"
TESTS = "NeptuneRemoteTests"

BUNDLE_ID = "com.neptune.remote"
WIDGET_BUNDLE_ID = BUNDLE_ID + ".widget"
TESTS_BUNDLE_ID = BUNDLE_ID + ".tests"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"
MARKETING_VERSION = "1.0.0"
BUILD_VERSION = "1"

# Files compiled into the widget extension as well as the app.
SHARED_WITH_WIDGET = [
    "NeptuneRemote/Shared/SharedModels.swift",
    "NeptuneRemote/Shared/ConnectionConfig.swift",
    "NeptuneRemote/Core/Utils/Formatters.swift",
]

_used_ids: set[str] = set()


def uid(*parts: str) -> str:
    """Deterministic 24-character hex identifier."""
    digest = hashlib.sha1("::".join(parts).encode("utf-8")).hexdigest().upper()
    candidate = digest[:24]
    salt = 0
    while candidate in _used_ids:
        salt += 1
        candidate = hashlib.sha1(f"{'::'.join(parts)}#{salt}".encode()).hexdigest().upper()[:24]
    _used_ids.add(candidate)
    return candidate


def collect(directory: Path, suffixes: tuple[str, ...]) -> list[Path]:
    out: list[Path] = []
    for path in sorted(directory.rglob("*")):
        if path.is_file() and path.suffix in suffixes and ".lproj" not in str(path):
            out.append(path.relative_to(IOS))
    return out


def rel(path: Path | str) -> str:
    return str(path).replace("\\", "/")


class Node:
    """A group in the Xcode navigator."""

    def __init__(self, name: str, path: str | None = None):
        self.name = name
        self.path = path
        self.children: dict[str, "Node"] = {}
        self.files: list[tuple[str, str]] = []  # (ref id, filename)
        self.uid = uid("group", name, path or "")

    def child(self, name: str) -> "Node":
        if name not in self.children:
            node = Node(name, name)
            self.children[name] = node
        return self.children[name]


def file_type(name: str) -> str:
    mapping = {
        ".swift": "sourcecode.swift",
        ".plist": "text.plist.xml",
        ".entitlements": "text.plist.entitlements",
        ".strings": "text.plist.strings",
        ".xcassets": "folder.assetcatalog",
        ".md": "net.daringfireball.markdown",
        ".h": "sourcecode.c.h",
    }
    return mapping.get(Path(name).suffix, "text")


def main() -> None:
    # ------------------------------------------------------------------ files
    app_sources = collect(IOS / APP, (".swift",))
    widget_sources = collect(IOS / WIDGET, (".swift",))
    test_sources = collect(IOS / TESTS, (".swift",))

    if not app_sources:
        raise SystemExit("No app sources found - run this from the repository")

    app_plist = f"{APP}/Resources/Info.plist"
    widget_plist = f"{WIDGET}/Info.plist"
    app_entitlements = f"{APP}/{APP}.entitlements"
    widget_entitlements = f"{WIDGET}/{WIDGET}.entitlements"
    app_assets = f"{APP}/Resources/Assets.xcassets"
    widget_assets = f"{WIDGET}/Assets.xcassets"

    localizations = ["en", "ar"]
    strings_refs = {
        code: uid("strings", code)
        for code in localizations
        if (IOS / APP / "Resources" / f"{code}.lproj" / "Localizable.strings").is_file()
    }
    variant_group = uid("variant", "Localizable.strings")

    objects: list[str] = []

    def emit(text: str) -> None:
        objects.append(text)

    # ------------------------------------------------------- file references
    refs: dict[str, str] = {}

    def file_ref(path: str, name: str | None = None) -> str:
        if path in refs:
            return refs[path]
        ref = uid("fileref", path)
        refs[path] = ref
        base = name or Path(path).name
        emit(
            f'\t\t{ref} /* {base} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = {file_type(base)}; path = "{base}"; sourceTree = "<group>"; }};'
        )
        return ref

    product_app = uid("product", APP)
    product_widget = uid("product", WIDGET)
    product_tests = uid("product", TESTS)
    emit(
        f'\t\t{product_app} /* {APP}.app */ = {{isa = PBXFileReference; explicitFileType = '
        f'"wrapper.application"; includeInIndex = 0; path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }};'
    )
    emit(
        f'\t\t{product_widget} /* {WIDGET}.appex */ = {{isa = PBXFileReference; explicitFileType = '
        f'"wrapper.app-extension"; includeInIndex = 0; path = {WIDGET}.appex; sourceTree = BUILT_PRODUCTS_DIR; }};'
    )
    emit(
        f'\t\t{product_tests} /* {TESTS}.xctest */ = {{isa = PBXFileReference; explicitFileType = '
        f'"wrapper.cfbundle"; includeInIndex = 0; path = {TESTS}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};'
    )

    # ----------------------------------------------------------- group tree
    root = Node("mainGroup")

    def add_to_tree(path: str) -> None:
        parts = rel(path).split("/")
        node = root
        for part in parts[:-1]:
            node = node.child(part)
        node.files.append((file_ref(path), parts[-1]))

    for source in app_sources + widget_sources + test_sources:
        add_to_tree(rel(source))
    for extra in (app_plist, widget_plist, app_entitlements, widget_entitlements,
                  app_assets, widget_assets):
        if (IOS / extra).exists():
            add_to_tree(extra)

    # The localised strings live in a variant group under Resources.
    resources_node = root.child(APP).child("Resources")
    resources_node.files.append((variant_group, "Localizable.strings"))

    for code, ref in strings_refs.items():
        emit(
            f'\t\t{ref} /* {code} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.strings; '
            f'name = {code}; path = "{code}.lproj/Localizable.strings"; sourceTree = "<group>"; }};'
        )
    if strings_refs:
        children = "\n".join(
            f"\t\t\t\t{ref} /* {code} */," for code, ref in sorted(strings_refs.items())
        )
        emit(
            f"\t\t{variant_group} /* Localizable.strings */ = {{\n"
            f"\t\t\tisa = PBXVariantGroup;\n"
            f"\t\t\tchildren = (\n{children}\n\t\t\t);\n"
            f"\t\t\tname = Localizable.strings;\n"
            f'\t\t\tsourceTree = "<group>";\n'
            f"\t\t}};"
        )

    products_group = uid("group", "Products")
    emit(
        f"\t\t{products_group} /* Products */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n"
        f"\t\t\t\t{product_app} /* {APP}.app */,\n"
        f"\t\t\t\t{product_widget} /* {WIDGET}.appex */,\n"
        f"\t\t\t\t{product_tests} /* {TESTS}.xctest */,\n"
        f"\t\t\t);\n"
        f"\t\t\tname = Products;\n"
        f'\t\t\tsourceTree = "<group>";\n'
        f"\t\t}};"
    )

    def emit_group(node: Node, is_root: bool = False) -> str:
        child_lines = []
        for name in sorted(node.children):
            child = node.children[name]
            child_lines.append(f"\t\t\t\t{emit_group(child)} /* {name} */,")
        for ref, name in sorted(node.files, key=lambda item: item[1]):
            child_lines.append(f"\t\t\t\t{ref} /* {name} */,")
        if is_root:
            child_lines.append(f"\t\t\t\t{products_group} /* Products */,")

        path_line = f'\t\t\tpath = "{node.path}";\n' if node.path and not is_root else ""
        name_line = "" if node.path and not is_root else "\t\t\tname = Sources;\n"
        emit(
            f"\t\t{node.uid} /* {node.name} */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n" + "\n".join(child_lines) + "\n\t\t\t);\n"
            + path_line
            + (name_line if is_root else "")
            + '\t\t\tsourceTree = "<group>";\n'
            f"\t\t}};"
        )
        return node.uid

    main_group = emit_group(root, is_root=True)

    # ------------------------------------------------------------ build files
    def build_files(paths: list[str], target: str) -> list[tuple[str, str]]:
        result = []
        for path in paths:
            ref = file_ref(path)
            build = uid("buildfile", target, path)
            name = Path(path).name
            emit(
                f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; "
                f"fileRef = {ref} /* {name} */; }};"
            )
            result.append((build, name))
        return result

    app_source_build = build_files([rel(p) for p in app_sources], APP)
    widget_source_build = build_files(
        [rel(p) for p in widget_sources] + SHARED_WITH_WIDGET, WIDGET
    )
    test_source_build = build_files([rel(p) for p in test_sources], TESTS)

    def resource_build(path: str, target: str, ref: str | None = None) -> tuple[str, str]:
        reference = ref or file_ref(path)
        build = uid("resource", target, path)
        name = Path(path).name
        emit(
            f"\t\t{build} /* {name} in Resources */ = {{isa = PBXBuildFile; "
            f"fileRef = {reference} /* {name} */; }};"
        )
        return build, name

    app_resources = [resource_build(app_assets, APP)]
    if strings_refs:
        app_resources.append(
            resource_build("Localizable.strings", APP, ref=variant_group)
        )
    widget_resources = [resource_build(widget_assets, WIDGET)]
    if strings_refs:
        widget_resources.append(
            resource_build("Localizable.strings", WIDGET, ref=variant_group)
        )

    # Embed the widget extension in the app.
    embed_build = uid("embed", WIDGET)
    emit(
        f"\t\t{embed_build} /* {WIDGET}.appex in Embed Foundation Extensions */ = "
        f"{{isa = PBXBuildFile; fileRef = {product_widget} /* {WIDGET}.appex */; "
        f"settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};"
    )

    # ------------------------------------------------------------ build phases
    def phase(isa: str, name: str, files: list[tuple[str, str]], suffix: str, extra: str = "") -> str:
        phase_id = uid(isa, name, suffix)
        lines = "\n".join(f"\t\t\t\t{fid} /* {fname} in {suffix} */," for fid, fname in files)
        emit(
            f"\t\t{phase_id} /* {suffix} */ = {{\n"
            f"\t\t\tisa = {isa};\n"
            f"\t\t\tbuildActionMask = 2147483647;\n"
            f"\t\t\tfiles = (\n{lines}\n\t\t\t);\n"
            + extra
            + "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            f"\t\t}};"
        )
        return phase_id

    app_sources_phase = phase("PBXSourcesBuildPhase", APP, app_source_build, "Sources")
    app_resources_phase = phase("PBXResourcesBuildPhase", APP, app_resources, "Resources")
    app_frameworks_phase = phase("PBXFrameworksBuildPhase", APP, [], "Frameworks")

    widget_sources_phase = phase("PBXSourcesBuildPhase", WIDGET, widget_source_build, "Sources")
    widget_resources_phase = phase("PBXResourcesBuildPhase", WIDGET, widget_resources, "Resources")
    widget_frameworks_phase = phase("PBXFrameworksBuildPhase", WIDGET, [], "Frameworks")

    tests_sources_phase = phase("PBXSourcesBuildPhase", TESTS, test_source_build, "Sources")
    tests_frameworks_phase = phase("PBXFrameworksBuildPhase", TESTS, [], "Frameworks")
    tests_resources_phase = phase("PBXResourcesBuildPhase", TESTS, [], "Resources")

    embed_phase = uid("copyfiles", "embed")
    emit(
        f"\t\t{embed_phase} /* Embed Foundation Extensions */ = {{\n"
        f"\t\t\tisa = PBXCopyFilesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f'\t\t\tdstPath = "";\n'
        f"\t\t\tdstSubfolderSpec = 13;\n"
        f"\t\t\tfiles = (\n"
        f"\t\t\t\t{embed_build} /* {WIDGET}.appex in Embed Foundation Extensions */,\n"
        f"\t\t\t);\n"
        f'\t\t\tname = "Embed Foundation Extensions";\n'
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};"
    )

    # ----------------------------------------------------------- dependencies
    project_id = uid("project", "NeptuneRemote")
    app_target = uid("target", APP)
    widget_target = uid("target", WIDGET)
    tests_target = uid("target", TESTS)

    def dependency(name: str, target_id: str) -> str:
        proxy = uid("proxy", name)
        dep = uid("dependency", name)
        emit(
            f"\t\t{proxy} /* PBXContainerItemProxy */ = {{\n"
            f"\t\t\tisa = PBXContainerItemProxy;\n"
            f"\t\t\tcontainerPortal = {project_id} /* Project object */;\n"
            f"\t\t\tproxyType = 1;\n"
            f"\t\t\tremoteGlobalIDString = {target_id};\n"
            f"\t\t\tremoteInfo = {name};\n"
            f"\t\t}};"
        )
        emit(
            f"\t\t{dep} /* PBXTargetDependency */ = {{\n"
            f"\t\t\tisa = PBXTargetDependency;\n"
            f"\t\t\ttarget = {target_id} /* {name} */;\n"
            f"\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;\n"
            f"\t\t}};"
        )
        return dep

    widget_dependency = dependency(WIDGET, widget_target)
    app_dependency = dependency(APP, app_target)

    # -------------------------------------------------------- configurations
    def configuration(name: str, target: str, settings: dict[str, str]) -> str:
        config_id = uid("config", target, name)
        lines = "\n".join(f"\t\t\t\t{key} = {value};" for key, value in sorted(settings.items()))
        emit(
            f"\t\t{config_id} /* {name} */ = {{\n"
            f"\t\t\tisa = XCBuildConfiguration;\n"
            f"\t\t\tbuildSettings = {{\n{lines}\n\t\t\t}};\n"
            f"\t\t\tname = {name};\n"
            f"\t\t}};"
        )
        return config_id

    def configuration_list(target: str, debug: str, release: str) -> str:
        list_id = uid("configlist", target)
        emit(
            f"\t\t{list_id} /* Build configuration list for {target} */ = {{\n"
            f"\t\t\tisa = XCConfigurationList;\n"
            f"\t\t\tbuildConfigurations = (\n"
            f"\t\t\t\t{debug} /* Debug */,\n"
            f"\t\t\t\t{release} /* Release */,\n"
            f"\t\t\t);\n"
            f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
            f"\t\t\tdefaultConfigurationName = Release;\n"
            f"\t\t}};"
        )
        return list_id

    project_common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "NO",
        "SDKROOT": "iphoneos",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": SWIFT_VERSION,
        "TARGETED_DEVICE_FAMILY": '"1,2"',
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
    }
    project_debug = configuration(
        "Debug", "PROJECT",
        {**project_common,
         "DEBUG_INFORMATION_FORMAT": "dwarf",
         "ENABLE_TESTABILITY": "YES",
         "GCC_OPTIMIZATION_LEVEL": "0",
         "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
         "ONLY_ACTIVE_ARCH": "YES",
         "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
         "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"'},
    )
    project_release = configuration(
        "Release", "PROJECT",
        {**project_common,
         "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
         "ENABLE_NS_ASSERTIONS": "NO",
         "MTL_ENABLE_DEBUG_INFO": "NO",
         "SWIFT_COMPILATION_MODE": "wholemodule",
         "VALIDATE_PRODUCT": "YES"},
    )
    project_config_list = configuration_list("PROJECT", project_debug, project_release)

    signing_free = {
        # The IPA is produced unsigned on purpose; sign it yourself afterwards.
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": '""',
        "CODE_SIGN_IDENTITY": '""',
        "PROVISIONING_PROFILE_SPECIFIER": '""',
    }

    app_settings = {
        **signing_free,
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": f'"{app_entitlements}"',
        "CURRENT_PROJECT_VERSION": BUILD_VERSION,
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f'"{app_plist}"',
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    app_debug = configuration("Debug", APP, app_settings)
    app_release = configuration("Release", APP, app_settings)
    app_config_list = configuration_list(APP, app_debug, app_release)

    widget_settings = {
        **signing_free,
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME": "WidgetBackground",
        "CODE_SIGN_ENTITLEMENTS": f'"{widget_entitlements}"',
        "CURRENT_PROJECT_VERSION": BUILD_VERSION,
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f'"{widget_plist}"',
        "INFOPLIST_KEY_CFBundleDisplayName": '"Neptune Widget"',
        "INFOPLIST_KEY_NSHumanReadableCopyright": '""',
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"',
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": WIDGET_BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SKIP_INSTALL": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    widget_debug = configuration("Debug", WIDGET, widget_settings)
    widget_release = configuration("Release", WIDGET, widget_settings)
    widget_config_list = configuration_list(WIDGET, widget_debug, widget_release)

    tests_settings = {
        **signing_free,
        "BUNDLE_LOADER": '"$(TEST_HOST)"',
        "CURRENT_PROJECT_VERSION": BUILD_VERSION,
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": TESTS_BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "TEST_HOST": f'"$(BUILT_PRODUCTS_DIR)/{APP}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/{APP}"',
    }
    tests_debug = configuration("Debug", TESTS, tests_settings)
    tests_release = configuration("Release", TESTS, tests_settings)
    tests_config_list = configuration_list(TESTS, tests_debug, tests_release)

    # ---------------------------------------------------------------- targets
    emit(
        f"\t\t{app_target} /* {APP} */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {app_config_list};\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{app_sources_phase} /* Sources */,\n"
        f"\t\t\t\t{app_frameworks_phase} /* Frameworks */,\n"
        f"\t\t\t\t{app_resources_phase} /* Resources */,\n"
        f"\t\t\t\t{embed_phase} /* Embed Foundation Extensions */,\n"
        f"\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n"
        f"\t\t\tdependencies = (\n\t\t\t\t{widget_dependency} /* PBXTargetDependency */,\n\t\t\t);\n"
        f"\t\t\tname = {APP};\n"
        f"\t\t\tproductName = {APP};\n"
        f"\t\t\tproductReference = {product_app} /* {APP}.app */;\n"
        f'\t\t\tproductType = "com.apple.product-type.application";\n'
        f"\t\t}};"
    )
    emit(
        f"\t\t{widget_target} /* {WIDGET} */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {widget_config_list};\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{widget_sources_phase} /* Sources */,\n"
        f"\t\t\t\t{widget_frameworks_phase} /* Frameworks */,\n"
        f"\t\t\t\t{widget_resources_phase} /* Resources */,\n"
        f"\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n"
        f"\t\t\tdependencies = (\n\t\t\t);\n"
        f"\t\t\tname = {WIDGET};\n"
        f"\t\t\tproductName = {WIDGET};\n"
        f"\t\t\tproductReference = {product_widget} /* {WIDGET}.appex */;\n"
        f'\t\t\tproductType = "com.apple.product-type.app-extension";\n'
        f"\t\t}};"
    )
    emit(
        f"\t\t{tests_target} /* {TESTS} */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {tests_config_list};\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{tests_sources_phase} /* Sources */,\n"
        f"\t\t\t\t{tests_frameworks_phase} /* Frameworks */,\n"
        f"\t\t\t\t{tests_resources_phase} /* Resources */,\n"
        f"\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n"
        f"\t\t\tdependencies = (\n\t\t\t\t{app_dependency} /* PBXTargetDependency */,\n\t\t\t);\n"
        f"\t\t\tname = {TESTS};\n"
        f"\t\t\tproductName = {TESTS};\n"
        f"\t\t\tproductReference = {product_tests} /* {TESTS}.xctest */;\n"
        f'\t\t\tproductType = "com.apple.product-type.bundle.unit-test";\n'
        f"\t\t}};"
    )

    # ---------------------------------------------------------------- project
    emit(
        f"\t\t{project_id} /* Project object */ = {{\n"
        f"\t\t\tisa = PBXProject;\n"
        f"\t\t\tattributes = {{\n"
        f"\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
        f"\t\t\t\tLastSwiftUpdateCheck = 1500;\n"
        f"\t\t\t\tLastUpgradeCheck = 1500;\n"
        f"\t\t\t\tTargetAttributes = {{\n"
        f"\t\t\t\t\t{app_target} = {{CreatedOnToolsVersion = 15.0; }};\n"
        f"\t\t\t\t\t{widget_target} = {{CreatedOnToolsVersion = 15.0; }};\n"
        f"\t\t\t\t\t{tests_target} = {{CreatedOnToolsVersion = 15.0; TestTargetID = {app_target}; }};\n"
        f"\t\t\t\t}};\n"
        f"\t\t\t}};\n"
        f"\t\t\tbuildConfigurationList = {project_config_list};\n"
        f"\t\t\tcompatibilityVersion = \"Xcode 15.0\";\n"
        f"\t\t\tdevelopmentRegion = en;\n"
        f"\t\t\thasScannedForEncodings = 0;\n"
        f"\t\t\tknownRegions = (\n"
        f"\t\t\t\ten,\n"
        f"\t\t\t\tBase,\n"
        + "".join(f"\t\t\t\t{code},\n" for code in localizations if code != "en")
        + f"\t\t\t);\n"
        f"\t\t\tmainGroup = {main_group};\n"
        f"\t\t\tproductRefGroup = {products_group} /* Products */;\n"
        f'\t\t\tprojectDirPath = "";\n'
        f'\t\t\tprojectRoot = "";\n'
        f"\t\t\ttargets = (\n"
        f"\t\t\t\t{app_target} /* {APP} */,\n"
        f"\t\t\t\t{widget_target} /* {WIDGET} */,\n"
        f"\t\t\t\t{tests_target} /* {TESTS} */,\n"
        f"\t\t\t);\n"
        f"\t\t}};"
    )

    # ------------------------------------------------------------------ write
    PROJECT.mkdir(parents=True, exist_ok=True)
    body = "\n".join(objects)
    content = (
        "// !$*UTF8*$!\n"
        "{\n"
        "\tarchiveVersion = 1;\n"
        "\tclasses = {\n\t};\n"
        "\tobjectVersion = 56;\n"
        "\tobjects = {\n"
        f"{body}\n"
        "\t};\n"
        f"\trootObject = {project_id} /* Project object */;\n"
        "}\n"
    )
    (PROJECT / "project.pbxproj").write_text(content, encoding="utf-8")

    workspace = PROJECT / "project.xcworkspace"
    workspace.mkdir(parents=True, exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Workspace version = "1.0">\n'
        '   <FileRef location = "self:">\n'
        "   </FileRef>\n"
        "</Workspace>\n",
        encoding="utf-8",
    )

    schemes = PROJECT / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    (schemes / f"{APP}.xcscheme").write_text(
        scheme_xml(app_target, product_app, tests_target, product_tests), encoding="utf-8"
    )

    print(f"Wrote {PROJECT}/project.pbxproj")
    print(f"  app sources    : {len(app_sources)}")
    print(f"  widget sources : {len(widget_sources)} (+{len(SHARED_WITH_WIDGET)} shared)")
    print(f"  test sources   : {len(test_sources)}")
    print(f"  localizations  : {', '.join(sorted(strings_refs))}")


def scheme_xml(app_target: str, app_product: str, tests_target: str, tests_product: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "{APP}.app"
               BlueprintName = "{APP}"
               ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{tests_target}"
               BuildableName = "{TESTS}.xctest"
               BlueprintName = "{TESTS}"
               ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{APP}.app"
            BlueprintName = "{APP}"
            ReferencedContainer = "container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{APP}.app"
            BlueprintName = "{APP}"
            ReferencedContainer = "container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


if __name__ == "__main__":
    main()
