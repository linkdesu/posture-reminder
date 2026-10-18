#!/usr/bin/env bash
# Capture the five v0.5 screens Link reviews: the child's screen, the settings page, and the
# day, week and month reports.
#
#   scripts/capture-screens.sh [--build]
#
# Each screen is reached by a launch argument rather than by tapping, because the app already
# photographs a screen shortly after it appears and a simulator has no scriptable tap. The app
# is reinstalled before every shot so the seeded history and the stored settings cannot leak
# from one capture into the next.
#
# Output: artifacts/r4-pomodoro/screenshots/01-main.png ... 05-report-month.png, each beside
# the session log it came from.
set -uo pipefail

SIM="${SIM:-C12DA589-2444-4F2E-A943-4D6BAFB02BF1}"
BUNDLE=me.xieal.posturelab
APP=/tmp/pl-sim/Build/Products/Debug-iphonesimulator/PostureLab.app
OUT="${OUT:-artifacts/r4-pomodoro}"
DO_BUILD=0
[[ "${1:-}" == "--build" ]] && DO_BUILD=1

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ "$DO_BUILD" == 1 ]]; then
  xcodebuild -project PostureLab.xcodeproj -scheme PostureLab \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath /tmp/pl-sim build | tail -1
fi

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true

mkdir -p "$OUT/screenshots"
FAILED=0

# target-file-name | launch arguments
CASES=(
  "pomodoro_main|1-main|-pomodoro 1 -seedHistory 1"
  "pomodoro_settings|2-settings|-pomodoro 1 -settings 1"
  "report_day|3-report-day|-pomodoro 1 -seedHistory 30 -report day"
  "report_week|4-report-week|-pomodoro 1 -seedHistory 30 -report week"
  "report_month|5-report-month|-pomodoro 1 -seedHistory 30 -report month"
)

for entry in "${CASES[@]}"; do
  screen="${entry%%|*}"
  rest="${entry#*|}"
  name="${rest%%|*}"
  launch="${rest#*|}"

  echo
  echo "=== $name ($launch) ==="
  xcrun simctl uninstall "$SIM" "$BUNDLE" >/dev/null 2>&1
  if ! xcrun simctl install "$SIM" "$APP"; then
    echo "INSTALL FAILED"
    FAILED=1
    continue
  fi
  # shellcheck disable=SC2086
  if ! xcrun simctl launch "$SIM" "$BUNDLE" $launch >/dev/null; then
    echo "LAUNCH FAILED"
    FAILED=1
    continue
  fi
  sleep 12

  container=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
  shot="$container/Documents/debug/screenshots/$screen.png"
  if [[ ! -f "$shot" ]]; then
    echo "MISSING SCREENSHOT $screen.png; present:"
    ls "$container/Documents/debug/screenshots" 2>&1 | tr '\n' ' '
    echo
    FAILED=1
    continue
  fi
  cp "$shot" "$OUT/screenshots/$name.png"

  # Keep the log beside the shot so a reviewer can see what the screen was showing.
  mkdir -p "$OUT/$name"
  cp -R "$container/Documents" "$OUT/$name/" 2>/dev/null
  {
    echo "screen:  $screen"
    echo "launch:  $launch"
    echo "commit:  $(git rev-parse HEAD)"
    echo "when:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$OUT/$name/provenance.txt"
  echo "captured $OUT/screenshots/$name.png ($(stat -f%z "$OUT/screenshots/$name.png") bytes)"
done

echo
echo "screens in $OUT/screenshots:"
ls "$OUT/screenshots" | tr '\n' ' '
echo
if [[ "$FAILED" == 1 ]]; then
  echo "CAPTURE RESULT: FAIL"
else
  echo "CAPTURE RESULT: PASS"
fi
exit "$FAILED"
