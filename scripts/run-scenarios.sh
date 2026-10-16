#!/usr/bin/env bash
# Run every scripted scenario through the iOS simulator and check each session log.
#
#   scripts/run-scenarios.sh [--build] [--long] [--devices]
#
# The app has no camera on the simulator, so every run uses -scenario and the
# scripted SampleSource. Screenshots need a rendered window, which a headless
# simulator does not provide, so the P2 check only passes on hardware; pass
# --devices to run on the connected iPhone instead (it must be unlocked).
set -uo pipefail

SIM="${SIM:-C12DA589-2444-4F2E-A943-4D6BAFB02BF1}"
DEVICE="${DEVICE:-00008110-001271181AD3801E}"
BUNDLE=me.xieal.posturelab
SIM_APP=/tmp/pl-sim/Build/Products/Debug-iphonesimulator/PostureLab.app
DEV_APP=/tmp/pl-device/Build/Products/Debug-iphoneos/PostureLab.app
OUT="${OUT:-artifacts/r1-prototype}"
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

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ "$DO_BUILD" == 1 ]]; then
  if [[ "$ON_DEVICE" == 1 ]]; then
    xcodebuild -project PostureLab.xcodeproj -scheme PostureLab -destination "id=$DEVICE" \
      -allowProvisioningUpdates -derivedDataPath /tmp/pl-device build | tail -1
  else
    xcodebuild -project PostureLab.xcodeproj -scheme PostureLab -destination "platform=iOS Simulator,id=$SIM" \
      -derivedDataPath /tmp/pl-sim build | tail -1
    xcrun simctl boot "$SIM" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true
  fi
fi

# name:duration:extra verify flags
RUNS=(
  "approach:36:--expect-level1 5 --expect-level2 15"
  "approach-high:36:--expect-level1 5 --expect-level2 15 -sensitivity high"
  "approach-low:36:--expect-level1 5 --expect-level2 15 -sensitivity low"
  "headDown:22:--expect-level1 5 --expect-level2 15"
  "left:20:"
  "shortApproach:16:--expect-no-reminders"
  "occlusion:20:"
  "cooldown:45:--expect-level1 5 --expect-level2 15 --expect-near-reminders 2"
)
if [[ "$DO_LONG" == 1 ]]; then
  RUNS+=("longRun:1800:")
fi

FAILED=0
for run in "${RUNS[@]}"; do
  label="${run%%:*}"
  rest="${run#*:}"
  duration="${rest%%:*}"
  flags="${rest#*:}"
  scenario="${label%%-*}"
  launch_args=(-scenario "$scenario")
  case "$label" in
    approach-high) launch_args+=(-sensitivity high) ;;
    approach-low) launch_args+=(-sensitivity low) ;;
  esac

  echo
  echo "=== $label ($scenario, ${duration}s) ==="
  if [[ "$ON_DEVICE" == 1 ]]; then
    xcrun devicectl device install app --device "$DEVICE" "$DEV_APP" >/dev/null 2>&1
    if ! xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" -- "${launch_args[@]}" >/dev/null 2>&1; then
      echo "$label: LAUNCH FAILED (is the phone unlocked?)"
      FAILED=1
      continue
    fi
  else
    xcrun simctl uninstall "$SIM" "$BUNDLE" >/dev/null 2>&1
    xcrun simctl install "$SIM" "$SIM_APP"
    xcrun simctl launch "$SIM" "$BUNDLE" "${launch_args[@]}" >/dev/null
  fi

  sleep $((duration + 17))

  target="$OUT/$label"
  rm -rf "$target"
  mkdir -p "$target"
  if [[ "$ON_DEVICE" == 1 ]]; then
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source Documents --destination "$target" >/dev/null 2>&1
  else
    container=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
    cp -R "$container/Documents" "$target/"
  fi

  log=$(find "$target" -name 'session-*.jsonl' | sort | tail -1)
  if [[ -z "$log" ]]; then
    echo "$label: NO LOG PULLED"
    FAILED=1
    continue
  fi
  # shellcheck disable=SC2086
  python3 scripts/verify-session.py "$log" --expect-scenario "$scenario" --quiet $flags || FAILED=1
done

echo
if [[ "$FAILED" == 1 ]]; then
  echo "ROUND RESULT: FAIL"
else
  echo "ROUND RESULT: PASS"
fi
exit "$FAILED"
