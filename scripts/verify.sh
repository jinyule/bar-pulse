#!/usr/bin/env bash
# End-to-end verification: unit tests → app build → metric cross-checks → real UI screenshots.
# Output: verification/README.md + verification/screenshots/
#
# Requirements: Xcode, ffmpeg, and a running Cua Driver daemon with Screen Recording +
# Accessibility (`cua-driver permissions grant`). Pass --no-ui to skip the screenshot stage.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d -t barpulse-verify)"
trap 'rm -rf "$WORK"' EXIT

echo "== 单元测试"
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -n 1

echo "== 构建 BarPulse.app"
scripts/build-app.sh | tail -n 1

echo "== 编译验证工具"
mkdir -p "$WORK/tools"
swiftc -O scripts/verify/windows.swift -o "$WORK/tools/windows"
swiftc -O scripts/verify/gpu-load.swift -o "$WORK/tools/gpu-load"
swiftc -O scripts/verify/cursor.swift -o "$WORK/tools/cursor"
swiftc -O scripts/verify/axframe.swift -o "$WORK/tools/axframe"
swiftc -O scripts/verify/backdrop.swift -o "$WORK/tools/backdrop"

if [[ " $* " != *" --no-ui "* ]]; then
  cua-driver status >/dev/null 2>&1 || { open -g -a CuaDriver --args serve; sleep 2; }
fi

BP_TOOLS="$WORK/tools" BP_WORK="$WORK" python3 -I scripts/verify/e2e.py "$@"
