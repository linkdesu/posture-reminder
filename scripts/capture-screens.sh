#!/usr/bin/env bash
# Capture the v0.5.1 screens Link reviews: the home page idle, mid-focus and mid-focus with the
# debug overlay, the settings page, and the day, week and month reports.
#
#   scripts/capture-screens.sh [--build]
#
# Each screen is reached by a launch argument rather than by tapping, because a simulator has no
# scriptable tap, and the shot is taken with `simctl io screenshot`, which photographs whatever
# is on screen at that moment. The app's own per-screen screenshot cannot be used here: it fires a
# fraction of a second after a screen appears, so it can only ever show the entry state — fine as
# evidence that a screen was visited, useless for showing a running countdown over a live cloud.
#
# The app is reinstalled before every shot so the seeded history and the stored settings cannot
# leak from one capture into the next.
#
# Every screen is captured from one run: the shots land in artifacts/r5-pomodoro/screenshots/, and
# each one is accompanied by the sandbox Documents copy it was showing and a provenance.txt.
set -uo pipefail

SIM="${SIM:-C12DA589-2444-4F2E-A943-4D6BAFB02BF1}"
BUNDLE=me.xieal.posturelab.depth
APP=/tmp/pl-sim/Build/Products/Debug-iphonesimulator/PostureLab.app
OUT="${OUT:-artifacts/r5-pomodoro}"
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

# output name | seconds to wait | launch arguments
#
# The two mid-focus home shots are the AC10 pair and differ only in the overlay: App.swift turns
# debug on for any scripted run, and the scenario is what feeds the screens live joints, so the
# child's screen has to say `-debug 0` to be free of joint data and the debug one `-debug 1` to
# show it. Both wait the same 26 seconds, which puts them mid-focus over a running countdown.
CASES=(
  "1-home-idle|10|-pomodoro 1"
  "2-home-focus|26|-debug 0 -scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1"
  "3-home-debug|26|-debug 1 -scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1"
  "4-settings|10|-settings 1"
  "5-stats-day|10|-seedHistory 30 -report day"
  "6-stats-week|10|-seedHistory 30 -report week"
  "7-stats-month|10|-seedHistory 30 -report month"
)

for entry in "${CASES[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  wait_seconds="${rest%%|*}"
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
  sleep "$wait_seconds"

  # The simulator's screenshot helper is refused write access to this volume, so it writes to
  # /tmp and a normal process copies the file into the evidence directory.
  scratch="$(mktemp -t posturelab-shot).png"
  if ! xcrun simctl io "$SIM" screenshot "$scratch" >/dev/null 2>&1; then
    echo "SCREENSHOT FAILED"
    rm -f "$scratch"
    FAILED=1
    continue
  fi
  if ! cp "$scratch" "$OUT/screenshots/$name.png"; then
    echo "COPY FAILED"
    rm -f "$scratch"
    FAILED=1
    continue
  fi
  rm -f "$scratch"

  # Keep the log beside the shot so a reviewer can see what the screen was showing.
  container=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
  mkdir -p "$OUT/$name"
  cp -R "$container/Documents" "$OUT/$name/" 2>/dev/null
  {
    echo "screen:  $name"
    echo "launch:  $launch"
    echo "waited:  ${wait_seconds}s"
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
