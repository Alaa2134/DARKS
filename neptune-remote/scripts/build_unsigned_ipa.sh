#!/usr/bin/env bash
#
# Build an UNSIGNED .ipa of Neptune 3 Plus Remote.
#
#   ./scripts/build_unsigned_ipa.sh
#
# Requires macOS with Xcode 15 or newer. The resulting IPA has no code
# signature at all - sign it yourself afterwards, for example:
#
#   codesign -f -s "Apple Development: you@example.com" --entitlements \
#     ios/NeptuneRemote/NeptuneRemote.entitlements Payload/NeptuneRemote.app
#   zip -qry NeptuneRemote-signed.ipa Payload
#
# or use a tool such as Sideloadly / AltStore / TrollStore, which sign for you.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${ROOT}/ios/NeptuneRemote.xcodeproj"
SCHEME="NeptuneRemote"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${ROOT}/build"
DIST_DIR="${ROOT}/dist"
DERIVED="${BUILD_DIR}/DerivedData"
PAYLOAD="${BUILD_DIR}/Payload"
IPA="${DIST_DIR}/NeptuneRemote-unsigned.ipa"

C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_INFO=$'\033[0;36m'; C_OFF=$'\033[0m'
step() { printf '%s==>%s %s\n' "${C_INFO}" "${C_OFF}" "$*"; }
ok()   { printf '%s  ok%s %s\n' "${C_OK}" "${C_OFF}" "$*"; }
die()  { printf '%s fail%s %s\n' "${C_ERR}" "${C_OFF}" "$*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Preconditions - never pretend an IPA exists
# --------------------------------------------------------------------------- #
step "Checking the toolchain"
if [[ "$(uname -s)" != "Darwin" ]]; then
    cat >&2 <<EOF

${C_ERR}Cannot build here.${C_OFF}

  Building an iOS binary requires macOS with Xcode. This machine is
  $(uname -s), so no .ipa can be produced.

  Options:
    1. Run this script on a Mac with Xcode 15+ installed.
    2. Push the repository to GitHub - .github/workflows/build-ios.yml
       builds the unsigned IPA on a macOS runner and uploads it as the
       "NeptuneRemote-unsigned" artifact.

  All project sources are complete and validated; only the compile step
  needs Xcode.

EOF
    exit 2
fi

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"

# Regenerate so a newly added source file is never silently left out of the IPA.
if command -v python3 >/dev/null 2>&1; then
    python3 "${SCRIPT_DIR}/generate_xcodeproj.py" >/dev/null || die "Could not regenerate the Xcode project"
fi
[[ -d "${PROJECT}" ]] || die "Xcode project not found at ${PROJECT}"

ok "$(xcodebuild -version | head -1)"
ok "Project: ${PROJECT}"

# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #
step "Cleaning previous output"
rm -rf "${PAYLOAD}" "${IPA}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

step "Building ${SCHEME} (${CONFIGURATION}, unsigned)"
set +e
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -sdk iphoneos \
    -derivedDataPath "${DERIVED}" \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    ENTITLEMENTS_REQUIRED=NO \
    EXPANDED_CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    ONLY_ACTIVE_ARCH=NO \
    build
BUILD_STATUS=$?
set -e

if [[ ${BUILD_STATUS} -ne 0 ]]; then
    die "xcodebuild failed with status ${BUILD_STATUS}. No IPA was produced."
fi
ok "Compilation succeeded"

# --------------------------------------------------------------------------- #
# Package
# --------------------------------------------------------------------------- #
APP_PATH="$(find "${DERIVED}/Build/Products/${CONFIGURATION}-iphoneos" -maxdepth 1 -name '*.app' -print -quit || true)"
[[ -n "${APP_PATH}" && -d "${APP_PATH}" ]] || die "Build reported success but no .app was found under ${DERIVED}/Build/Products"

BINARY="${APP_PATH}/$(basename "${APP_PATH}" .app)"
[[ -f "${BINARY}" ]] || die "The .app bundle contains no executable - refusing to package a broken IPA"
ok "App bundle: ${APP_PATH}"

# --------------------------------------------------------------------------- #
# Verify App Transport Security in the BUILT bundle
#
# Moonraker and the backend are plain HTTP over Tailscale, so the shipped app
# has to permit arbitrary loads. Checking the source Info.plist is not enough -
# build settings and the packaging step both get a say - so this reads the
# binary plist that actually ends up inside the IPA.
#
# The subtle half is the override rule: Apple ignores NSAllowsArbitraryLoads,
# and uses its default of NO, if NSAllowsLocalNetworking,
# NSAllowsArbitraryLoadsInWebContent or NSAllowsArbitraryLoadsForMedia is also
# present. A plist can read "true" and still block every http:// request, which
# is exactly the bug this check exists to prevent shipping again.
# --------------------------------------------------------------------------- #
step "Verifying App Transport Security in the built app"
BUILT_PLIST="${APP_PATH}/Info.plist"
[[ -f "${BUILT_PLIST}" ]] || die "No Info.plist inside ${APP_PATH}"

ats_value() {
    /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:$1" "${BUILT_PLIST}" 2>/dev/null || true
}

[[ "$(ats_value NSAllowsArbitraryLoads)" == "true" ]] \
    || die "NSAppTransportSecurity:NSAllowsArbitraryLoads is not true in the built Info.plist - HTTP to the Pi would be blocked"

for key in NSAllowsLocalNetworking NSAllowsArbitraryLoadsInWebContent NSAllowsArbitraryLoadsForMedia; do
    if [[ -n "$(ats_value "${key}")" ]]; then
        die "NSAppTransportSecurity:${key} is present; it makes iOS ignore NSAllowsArbitraryLoads and blocks plain HTTP over Tailscale. Remove it from ios/NeptuneRemote/Resources/Info.plist"
    fi
done
ok "ATS: NSAllowsArbitraryLoads = true, with no key that would override it"

step "Packaging Payload/$(basename "${APP_PATH}") into an IPA"
mkdir -p "${PAYLOAD}"
cp -R "${APP_PATH}" "${PAYLOAD}/"

# Strip any signature remnants so the IPA is genuinely unsigned.
rm -rf "${PAYLOAD}/$(basename "${APP_PATH}")/_CodeSignature" 2>/dev/null || true
rm -f  "${PAYLOAD}/$(basename "${APP_PATH}")/embedded.mobileprovision" 2>/dev/null || true

( cd "${BUILD_DIR}" && zip -qry "${IPA}" Payload )
rm -rf "${PAYLOAD}"

[[ -f "${IPA}" ]] || die "Packaging failed - no IPA at ${IPA}"

SIZE="$(du -h "${IPA}" | cut -f1)"
SHA="$(shasum -a 256 "${IPA}" | cut -d' ' -f1)"
cat <<EOF

${C_OK}Unsigned IPA created.${C_OFF}

  Path   : ${IPA}
  Size   : ${SIZE}
  SHA256 : ${SHA}

  It contains Payload/$(basename "${APP_PATH}") and is NOT code signed.
  Sign it with your own certificate, or install it with a sideloading tool.

EOF
