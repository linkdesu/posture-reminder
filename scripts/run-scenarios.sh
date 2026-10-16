#!/usr/bin/env bash
# Run every scripted scenario through the simulator or the phone and check each session log.
#
#   scripts/run-scenarios.sh [--build] [--long] [--devices]
#
# The app has no camera on the simulator, so every run uses -scenario and the scripted
# SampleSource. Each run also passes -sensitivity explicitly: a launch argument is an
# override, but an earlier round leaked one scenario's sensitivity into the next through
# UserDefaults and a head-down run silently fired nothing.
#
# Evidence lands in artifacts/r1-sim/ or artifacts/r1-device/ depending on the surface,
# each run carrying a provenance.txt, so a device pass can never be confused with a
# simulator one.
set -uo pipefail

SIM="${SIM:-C12DA589-2444-4F2E-A943-4D6BAFB02BF1}"
DEVICE="${DEVICE:-00008110-001271181AD3801E}"
BUNDLE=me.xieal.posturelab
SIM_APP=/tmp/pl-sim/Build/Products/Debug-iphonesimulator/PostureLab.app
DEV_APP=/tmp/pl-device/Build/Products/Debug-iphoneos/PostureLab.app
DO_BUILD=0
DO_LONG=0
ON_DEVICE=0
for arg in "$@"; do
  case "$arg" in
    --build) DO_BUILD=1 ;;
    --long) DO_LONG=1 ;;
    --devices) ON_DEVICE=1 ;;
  esac
done

if [[ "$ON_DEVICE" == 1 ]]; then
  SURFACE=device
  OUT="${OUT:-artifacts/r1-device}"
else
  SURFACE=simulator
  OUT="${OUT:-artifacts/r1-sim}"
fi
mkdir -p "$OUT"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ "$DO_BUILD" == 1 ]]; then
  if [[ "$SURFACE" == device ]]; then
    xcodebuild -project PostureLab.xcodeproj -scheme PostureLab -destination "id=$DEVICE" \
      -allowProvisioningUpdates -derivedDataPath /tmp/pl-device build | tail -1
  else
    xcodebuild -project PostureLab.xcodeproj -scheme PostureLab -destination "platform=iOS Simulator,id=$SIM" \
      -derivedDataPath /tmp/pl-sim build | tail -1
    xcrun simctl boot "$SIM" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true
  fi
fi

FAILED=0
RAN=0

run_case() {
  local scenario="$1" sensitivity="$2" duration="$3"
  shift 3
  local label="$scenario"
  [[ "$sensitivity" != medium ]] && label="$scenario-$sensitivity"

  echo
  echo "=== $label ($scenario, $sensitivity, ${duration}s) ==="
  RAN=$((RAN + 1))

  local launch=(-scenario "$scenario" -sensitivity "$sensitivity" -captureSettings 1)
  if [[ "$SURFACE" == device ]]; then
    if ! xcrun devicectl device install app --device "$DEVICE" "$DEV_APP" >/dev/null 2>&1; then
      echo "INSTALL FAILED"
      FAILED=1
      return
    fi
    if ! xcrun devicectl device process launch --terminate-existing --device "$DEVICE" \
      "$BUNDLE" -- "${launch[@]}" >/dev/null 2>&1; then
      echo "LAUNCH FAILED (is the phone unlocked?)"
      FAILED=1
      return
    fi
  else
    xcrun simctl uninstall "$SIM" "$BUNDLE" >/dev/null 2>&1
    if ! xcrun simctl install "$SIM" "$SIM_APP"; then
      echo "INSTALL FAILED"
      FAILED=1
      return
    fi
    if ! xcrun simctl launch "$SIM" "$BUNDLE" "${launch[@]}" >/dev/null; then
      echo "LAUNCH FAILED"
      FAILED=1
      return
    fi
  fi

  sleep $((duration + 17))

  local target="$OUT/$label"
  rm -rf "$target"
  mkdir -p "$target"
  if [[ "$SURFACE" == device ]]; then
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source Documents --destination "$target" >/dev/null 2>&1
  else
    local container
    container=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
    cp -R "$container/Documents" "$target/"
  fi

  local log
  log=$(find "$target" -name 'session-*.jsonl' | sort | tail -1)
  if [[ -z "$log" ]]; then
    echo "NO LOG PULLED"
    FAILED=1
    return
  fi

  {
    echo "surface: $SURFACE"
    echo "target:  ${DEVICE} / ${SIM}"
    echo "commit:  $(git rev-parse HEAD)"
    echo "launch:  ${launch[*]}"
    echo "verify:  $*"
    echo "when:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$target/provenance.txt"

  # shellcheck disable=SC2086
  python3 scripts/verify-session.py "$log" --expect-scenario "$scenario" --quiet "$@" || FAILED=1
}

run_case approach     medium         36 --expect-level1 5 --expect-level2 15 --expect-kind near --expect-sensitivity medium
run_case approach     high           36 --expect-level1 5 --expect-level2 15 --expect-kind near --expect-sensitivity high
run_case approach     low            36 --expect-level1 5 --expect-level2 15 --expect-kind near --expect-sensitivity low
run_case headDown     medium         22 --expect-level1 5 --expect-level2 15 --expect-kind head_down --expect-sensitivity medium
run_case left         medium         20 --expect-pause
run_case shortApproach medium        16 --expect-no-reminders
run_case occlusion    medium         20 --expect-pause --expect-no-reminders
run_case cooldown     medium         45 --expect-level1 5 --expect-level2 15 --expect-kind near --expect-near-reminders 2
if [[ "$DO_LONG" == 1 ]]; then
  run_case longRun medium 1800
fi

echo
echo "$RAN run(s) on the $SURFACE"
if [[ "$FAILED" == 1 ]]; then
  echo "ROUND RESULT: FAIL"
else
  echo "ROUND RESULT: PASS"
fi
exit "$FAILED"
