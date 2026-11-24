#!/usr/bin/env bash
set -euo pipefail

APP="${1:?signed .app path required}"
OUTPUT="${2:?output .dmg path required}"
VOLUME_NAME="${3:-RcHarness}"

case "$APP" in
  *.app) ;;
  *) echo 'Application path must end in .app.' >&2; exit 1 ;;
esac
case "$OUTPUT" in
  *.dmg) ;;
  *) echo 'DMG output path must end in .dmg.' >&2; exit 1 ;;
esac
if [[ ! -d "$APP" || ! -f "$APP/Contents/Info.plist" ]]; then
  echo 'A valid application bundle is required.' >&2
  exit 1
fi
if [[ -L "$OUTPUT" ]]; then
  echo 'Refusing to replace a symlink.' >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
PARENT="$(cd "$(dirname "$OUTPUT")" && pwd -P)"
OUTPUT="$PARENT/$(basename "$OUTPUT")"
STAGE="$(mktemp -d "$PARENT/.rcharness-dmg.XXXXXX")"
cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

# Keep the application bundle intact and add the conventional Applications
# shortcut. The same image is used for first-install downloads and Sparkle
# updates, so it must contain one copy of the app with its original name.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -quiet \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov "$OUTPUT"
# The disk image service can briefly be unavailable just after creation.
for attempt in 1 2 3; do
  verify_status=0
  verify_log=$(LC_ALL=C hdiutil verify "$OUTPUT" 2>&1 >/dev/null) || verify_status=$?
  if [[ -n "$verify_log" ]]; then
    printf '%s\n' "$verify_log" >&2
  fi
  if [[ "$verify_status" -eq 0 ]]; then
    break
  fi
  if [[ "$attempt" -eq 3 || "$verify_log" != *'hdiutil: verify failed - Resource temporarily unavailable' ]]; then
    exit "$verify_status"
  fi
  echo 'Retrying DMG verification in 2 seconds.' >&2
  sleep 2
done
echo "Packaged $OUTPUT"
