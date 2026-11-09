#!/usr/bin/env bash
# Opt-in: requires a logged-in macOS GUI session; briefly activates its own fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${ROOT}/.build/harness-activation-probe"
BUNDLE="${OUTPUT}/Fixture.app"
mkdir -p "${BUNDLE}/Contents/MacOS"
cat > "${BUNDLE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundleIdentifier</key><string>vip.tokenzz.rcharness.activation-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library \
  "${ROOT}/Sources/RcHarness/HarnessApplicationActivation.swift" \
  "${ROOT}/Sources/RcHarness/Log.swift" \
  "${ROOT}/tests/harness-activation-probe/main.swift" \
  -o "${BUNDLE}/Contents/MacOS/Probe"
"${BUNDLE}/Contents/MacOS/Probe" --probe "${OUTPUT}"
