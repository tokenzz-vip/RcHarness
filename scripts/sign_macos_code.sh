#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:?target path required}"
IDENTIFIER="${2:?identifier required}"
MODE="${3:-local}"
ENTITLEMENTS="${4:-}"
case "${MODE}" in local|distribution) ;; *) echo "Unknown signing mode" >&2; exit 1 ;; esac

# Nested code (the HAL driver) is signed on its own before the app, so --deep
# is never needed; it is deprecated for signing and would re-sign nested code.
ARGS=(--force --sign)
if [[ "${MODE}" == "distribution" ]]; then
  ARGS+=("${RC_HARNESS_SIGNING_IDENTITY:?set RC_HARNESS_SIGNING_IDENTITY for distribution signing}")
  # Notarization requires the hardened runtime and a secure timestamp.
  ARGS+=(--options runtime --timestamp)
else
  ARGS+=("${RC_HARNESS_LOCAL_SIGNING_IDENTITY:--}")
fi
ARGS+=(--identifier "${IDENTIFIER}")
if [[ -n "${ENTITLEMENTS}" ]]; then ARGS+=(--entitlements "${ENTITLEMENTS}"); fi

/usr/bin/codesign "${ARGS[@]}" "${TARGET}"
