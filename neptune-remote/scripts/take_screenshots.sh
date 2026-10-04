#!/usr/bin/env bash
# Launch the app on a simulator in screenshot mode and photograph each screen.
#
# There is no Mac where this app is written, so this is the only way anybody
# gets to *see* a design change before it ships. Each screen is a fresh launch
# with NEPTUNE_SHOWCASE naming it (see App/Showcase.swift), so every picture is
# deterministic: no taps to replay, no state carried over from the shot before.
#
# Usage: scripts/take_screenshots.sh [output-dir]
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="${1:-dist/screenshots}"
DEVICE="${SCREENSHOT_DEVICE:-iPhone 15 Pro}"
BUNDLE="com.neptune.remote"
DERIVED="build/screenshots-derived"

SCREENS=(home-printing home home-simple library files more queue alerts slice settings setup)
LANGS=(ar en)
APPEARANCES=(dark light)

mkdir -p "$OUT"

echo "==> Building for the simulator"
set -o pipefail
xcodebuild build \
  -project ios/NeptuneRemote.xcodeproj \
  -scheme NeptuneRemote \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=${DEVICE}" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  | xcpretty

APP="$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name '*.app' | head -1)"
if [[ -z "$APP" ]]; then
  echo "No .app was produced" >&2
  exit 1
fi

echo "==> Booting ${DEVICE}"
UDID="$(xcrun simctl list devices available -j \
  | python3 -c "import json,sys
data=json.load(sys.stdin)['devices']
for runtime, devices in data.items():
    if 'iOS' not in runtime: continue
    for d in devices:
        if d['name']=='${DEVICE}':
            print(d['udid']); sys.exit()")"
if [[ -z "$UDID" ]]; then
  echo "No simulator named ${DEVICE}" >&2
  xcrun simctl list devices available >&2
  exit 1
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

# The status bar every App Store screenshot has: 9:41, full battery, full bars.
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

xcrun simctl install "$UDID" "$APP"

shoot() {
  local screen="$1" lang="$2" appearance="$3"
  local name="${lang}-${appearance}-${screen}"
  xcrun simctl ui "$UDID" appearance "$appearance"
  SIMCTL_CHILD_NEPTUNE_SHOWCASE="$screen" \
  SIMCTL_CHILD_NEPTUNE_SHOWCASE_LANG="$lang" \
  SIMCTL_CHILD_NEPTUNE_SHOWCASE_APPEARANCE="$appearance" \
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" >/dev/null
  # Long enough for the demo printer to publish a reading and for every
  # entrance animation to settle - a picture of a spinner proves nothing.
  sleep "${SHOT_DELAY:-7}"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/${name}.png" >/dev/null
  echo "    ${name}.png"
}

echo "==> Shooting"
for lang in "${LANGS[@]}"; do
  for appearance in "${APPEARANCES[@]}"; do
    for screen in "${SCREENS[@]}"; do
      shoot "$screen" "$lang" "$appearance"
    done
  done
done

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
echo "==> $(ls "$OUT" | wc -l | tr -d ' ') screenshots in $OUT"
