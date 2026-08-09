#!/bin/bash
# R0 SPIKE harness (THROWAWAY — VR-CHARTER §5 R0). Runs one VR spike variant on
# the visionOS simulator and dumps what it logged.
#
#   scripts/vr-spike-sim.sh <variant 1|2|3> [seconds]
#
# Lane rules (~/dev/CLAUDE.md): visionOS lane 1 is the ONE Apple Vision Pro
# device; never create a simulator, and always shut it down when finished — this
# script does both. The ROM is a RUNTIME input (M-3), staged into the container
# like scripts/verify-0010-sim.sh does.
#
# Env reaches the app through SIMCTL_CHILD_*; `simctl launch` argv famously does
# not reach the engine.
set -uo pipefail

VARIANT="${1:?usage: vr-spike-sim.sh <1|2|3> [seconds]}"
SECS="${2:-45}"

UDID=9D4499E9-CCED-4AF1-9303-925E9515D346   # Apple Vision Pro, visionOS 27.0 (lane 1)
BUNDLE=com.rebelancap.sm64coopdx
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build-vision-sim/Release-xrsimulator/sm64coopdx.app"
ROM="$HOME/Library/Application Support/sm64coopdx/baserom.us.z64"
OUT="$ROOT/work/vr-spike"
mkdir -p "$OUT"

say() { echo; echo "############ $* ############"; }

[[ -d "$APP" ]] || { echo "FATAL: no sim app — run scripts/build-vision-sim.sh" >&2; exit 1; }
[[ -f "$ROM" ]] || { echo "FATAL: no ROM at $ROM" >&2; exit 1; }

say "boot $UDID"
xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b

say "install"
xcrun simctl install "$UDID" "$APP" || exit 1
D=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data) || exit 1
mkdir -p "$D/Documents"
cp -f "$ROM" "$D/Documents/baserom.us.z64"
rm -rf "$D/Documents/logs"

# World mode is ON by default in the app (the device has no env channel); pass
# SM64_VR_WORLD=0 to get R0.1's clear-only style probe back.
say "launch (variant=$VARIANT world=${SM64_VR_WORLD:-1}, ${SECS}s)"
SIMCTL_CHILD_SM64_VR_SPIKE="$VARIANT" \
SIMCTL_CHILD_SM64_VR_SPIKE_AT=10 \
SIMCTL_CHILD_SM64_VR_WORLD="${SM64_VR_WORLD:-1}" \
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE"

sleep "$SECS"

say "screenshot"
xcrun simctl io "$UDID" screenshot "$OUT/variant$VARIANT.png" 2>/dev/null

say "collect"
cat "$D"/Documents/logs/*.log > "$OUT/variant$VARIANT.log" 2>/dev/null
wc -l "$OUT/variant$VARIANT.log"
echo "--- [vrspike] lines ---"
grep -a "vrspike" "$OUT/variant$VARIANT.log" || echo "(NONE — investigate)"

say "still alive?"
xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -c "$BUNDLE" || true

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null
echo "artifacts in $OUT"
