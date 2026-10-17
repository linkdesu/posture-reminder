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
# Evidence lands in artifacts/r2-v03-sim/ or artifacts/r1-device/ depending on the surface,
# each run carrying a provenance.txt, so a device pass can never be confused with a
# simulator one.
#
# Every run also asks verify-session.py for the v0.3 evidence: a features line log
# (--expect-features, AC18), the avatar view mode with the debug overlay on
# (--expect-view-mode avatar --expect-overlay, AC13), and -captureSettings so the
# settings screenshot is grabbed. On the simulator the live app container -- the whole
# sandbox, not just Documents -- is audited for anything the privacy rules forbid
# (AC14/AC19) before the evidence is copied out; the phone audits the pulled copy. A
# non-zero audit exit fails the round.
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
  OUT="${OUT:-artifacts/r2-v03-sim}"
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

  # AC19 asks what the sandbox holds, not only what we collect from it, so the simulator
  # audits the live container -- the whole sandbox, Library/ and tmp/ included -- before
  # Documents is copied out. On the phone only the pulled copy is reachable, and the
  # output says so. Either way the manifest lands in the run's evidence directory.
  local container="" audit_root audit_note
  if [[ "$SURFACE" == device ]]; then
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source Documents --destination "$target" >/dev/null 2>&1
    audit_root="$target"
    audit_note="audited the pulled Documents copy only; devicectl cannot reach Library/ or tmp/"
  else
    container=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
    audit_root="$container"
    audit_note="audited the live container before copying Documents out: $container"
  fi

  local audit audit_status
  audit=$(python3 scripts/audit-sandbox.py "$audit_root" --json "$target/sandbox-audit.json" 2>&1)
  audit_status=$?
  echo "$audit"
  echo "sandbox audit: $audit_note"
  if [[ "$audit_status" != 0 ]]; then
    echo "SANDBOX AUDIT FAILED"
    FAILED=1
  fi

  if [[ "$SURFACE" != device ]]; then
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
  python3 scripts/verify-session.py "$log" --expect-scenario "$scenario" --quiet \
    --expect-features --expect-view-mode avatar --expect-overlay "$@" || FAILED=1

  # AC13 also says the highlight is visible in a screenshot, which no log can show.
  local overlay overlay_status
  overlay=$(python3 scripts/check-overlay.py "$log" --quiet 2>&1)
  overlay_status=$?
  echo "$overlay"
  if [[ "$overlay_status" != 0 ]]; then
    echo "OVERLAY COLOUR CHECK FAILED"
    FAILED=1
  fi
}

run_case approach     medium         36 --expect-level1 5 --expect-level2 15 --expect-kind near --expect-sensitivity medium
run_case approach     high           36 --expect-level1 5 --expect-level2 15 --expect-kind near --expect-sensitivity high
run_case approach     low            36 --expect-level1 5 --expect-level2 15 --expect-kind near --expect-sensitivity low
run_case headDown     medium         22 --expect-level1 5 --expect-level2 15 --expect-kind head_down --expect-sensitivity medium
run_case left         medium         20 --expect-pause
run_case shortApproach medium        16 --expect-no-reminders
run_case occlusion    medium         20 --expect-pause --expect-no-reminders
run_case cooldown     medium         45 --expect-level1 5 --expect-level2 15 --expect-kind near --expect-near-reminders 2

# New v0.3 scenarios, in the contract's order: each positive is followed by its near-miss.
# The positives reach both reminder levels; the misses are the AC17 counter-examples and
# must fire nothing, so each names the feature its positive breaches.
run_case headTilt     medium         26 --expect-level1 5 --expect-level2 15 --expect-kind head_tilt
run_case headTiltMiss medium         26 --expect-no-reminders --expect-feature-under head_roll
run_case deskLean     medium         26 --expect-level1 5 --expect-level2 15 --expect-kind desk_lean
run_case deskLeanMiss medium         26 --expect-no-reminders --expect-feature-under head_height_drop
run_case chinRest     medium         30 --expect-level1 5 --expect-level2 15 --expect-kind chin_rest
run_case chinRestMiss medium         30 --expect-no-reminders --expect-feature-under hand_to_face

# Experimental tier (headForward, slouch) is detect-only by default: the feature must read
# over threshold and be highlighted, and nothing may be spoken.
run_case headForward  medium         26 --expect-no-reminders --expect-feature-over head_forward --expect-highlight head_forward
run_case headForwardMiss medium      26 --expect-no-reminders --expect-feature-under head_forward
run_case slouch       medium         26 --expect-no-reminders --expect-feature-over slouch --expect-highlight slouch
run_case slouchMiss   medium         26 --expect-no-reminders --expect-feature-under slouch

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
