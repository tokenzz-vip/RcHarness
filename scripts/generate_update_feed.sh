#!/usr/bin/env bash
# Run only after notarization/stapling and final ZIP packaging. No private key
# is written to disk or passed as a command-line argument.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${1:?release assets directory required}"
TAG="${2:?release tag required}"
REPO="${3:-tokenzz-vip/RcHarness}"
if [[ ! "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo 'Expected a stable vMAJOR.MINOR.PATCH tag.' >&2; exit 1
fi
if [[ ! -f "$DIST/RcHarness-$TAG-macos-arm64.zip" ]]; then
  echo 'Final release ZIP is missing.' >&2; exit 1
fi
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle"
if [[ ! -x "$TOOLS/bin/generate_appcast" ]]; then
  echo 'Sparkle tools missing; run swift package resolve first.' >&2; exit 1
fi
ARGS=(--maximum-deltas 0 --maximum-versions 1 \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO/releases/tag/$TAG")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/bin/generate_appcast" \
    --ed-key-file - "${ARGS[@]}" "$DIST"
else
  "$TOOLS/bin/generate_appcast" --account vip.tokenzz.rcharness "${ARGS[@]}" "$DIST"
fi
if [[ ! -f "$DIST/appcast.xml" ]]; then echo 'No appcast was generated.' >&2; exit 1; fi
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/bin/sign_update" \
    --ed-key-file - --verify "$DIST/appcast.xml"
else
  "$TOOLS/bin/sign_update" --account vip.tokenzz.rcharness --verify "$DIST/appcast.xml"
fi
# Fail closed if the archive was not signed (e.g. wrong key), or metadata
# differs from the app that will actually be shipped.
python3 "$ROOT/scripts/validate_update_feed.py" "$DIST/appcast.xml" "$DIST/RcHarness-$TAG-macos-arm64.zip" "$TAG" "$REPO"
