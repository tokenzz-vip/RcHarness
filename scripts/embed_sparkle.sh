#!/usr/bin/env bash
# Embed and sign Sparkle from the exact SwiftPM-resolved binary artifact.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?app bundle required}"
MODE="${2:?signing mode required}"
FRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$FRAMEWORK" ]]; then
  echo 'Sparkle artifact missing; run swift package resolve first.' >&2
  exit 1
fi
DEST="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$FRAMEWORK" "$DEST"
cp "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"
# No sandbox services are enabled in RcHarness. Keep Sparkle's original
# helper entitlements when re-signing, then seal the enclosing framework.
case "$MODE" in
  local) ARGS=(--force --sign "${RC_HARNESS_LOCAL_SIGNING_IDENTITY:--}") ;;
  distribution) ARGS=(--force --sign "${RC_HARNESS_SIGNING_IDENTITY:?distribution identity required}" --options runtime --timestamp) ;;
  *) exit 1 ;;
esac
for target in \
  "$DEST/Versions/B/XPCServices/Installer.xpc" \
  "$DEST/Versions/B/XPCServices/Downloader.xpc" \
  "$DEST/Versions/B/Autoupdate" \
  "$DEST/Versions/B/Updater.app" \
  "$DEST"; do
  codesign "${ARGS[@]}" --preserve-metadata=entitlements "$target"
done
codesign --verify --deep --strict "$DEST"
