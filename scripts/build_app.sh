#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${ROOT}/.build/RcHarness.app}"
SIGNING_MODE="${2:-local}"
CONFIGURATION="${RC_HARNESS_CONFIGURATION:-release}"
case "${SIGNING_MODE}" in local|distribution) ;; *) echo "Unknown signing mode" >&2; exit 1 ;; esac
case "${CONFIGURATION}" in debug|release) ;; *) echo "Unknown build configuration" >&2; exit 1 ;; esac
case "${OUT}" in *.app) ;; *) echo "Output must be an .app bundle path" >&2; exit 1 ;; esac
if [[ -L "${OUT}" ]]; then echo "Refusing to replace a symlink" >&2; exit 1; fi
if [[ -e "${OUT}" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${OUT}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "${EXISTING_ID}" != "vip.tokenzz.rcharness" ]]; then
    echo "Refusing to replace a bundle that is not RcHarness" >&2
    exit 1
  fi
fi
if [[ "${SIGNING_MODE}" == "distribution" ]]; then
  : "${RC_HARNESS_SIGNING_IDENTITY:?set RC_HARNESS_SIGNING_IDENTITY for distribution signing}"
fi
mkdir -p "$(dirname "${OUT}")"
PARENT="$(cd "$(dirname "${OUT}")" && pwd -P)"
OUT="${PARENT}/$(basename "${OUT}")"
STAGE="$(mktemp -d "${PARENT}/.rcharness-build.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT
APP="${STAGE}/RcHarness.app"
swift build --package-path "${ROOT}" --arch arm64 -c "${CONFIGURATION}"
BIN="$(swift build --package-path "${ROOT}" --show-bin-path --arch arm64 -c "${CONFIGURATION}")/RcHarness"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/PlugIns" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/RcHarness"
cp "${ROOT}/Sources/RcHarness/Info.plist" "${APP}/Contents/Info.plist"
cp "${ROOT}/LICENSE" "${APP}/Contents/Resources/LICENSE"
# Info.plist is the single version source; optionally stamp a release version.
if [[ -n "${RC_HARNESS_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${RC_HARNESS_VERSION}" "${APP}/Contents/Info.plist"
fi
if [[ -n "${RC_HARNESS_BUILD:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${RC_HARNESS_BUILD}" "${APP}/Contents/Info.plist"
fi
cp "${ROOT}/assets/brand/RcHarness-v2.icns" "${APP}/Contents/Resources/RcHarness.icns"
cp "${ROOT}/assets/app/controller-dashboard-xiaomi-rc001.png" "${APP}/Contents/Resources/controller-dashboard-xiaomi-rc001.png"
cp "${ROOT}/assets/app/controller-dashboard-xiaomi-remote.png" "${APP}/Contents/Resources/controller-dashboard-xiaomi-remote.png"
cp "${ROOT}/assets/app/controller-dashboard-google-g9n9n.png" "${APP}/Contents/Resources/controller-dashboard-google-g9n9n.png"
"${ROOT}/scripts/build_microphone_driver.sh" "${APP}/Contents/PlugIns" "${SIGNING_MODE}"
bash "${ROOT}/scripts/embed_sparkle.sh" "${APP}" "${SIGNING_MODE}"
"${ROOT}/scripts/sign_macos_code.sh" "${APP}" vip.tokenzz.rcharness "${SIGNING_MODE}" "${ROOT}/scripts/RcHarness.entitlements"
/usr/bin/codesign --verify --deep --strict "${APP}"
if [[ -e "${OUT}" ]]; then mv "${OUT}" "${STAGE}/previous.app"; fi
if ! mv "${APP}" "${OUT}"; then
  if [[ -e "${STAGE}/previous.app" ]]; then
    mv "${STAGE}/previous.app" "${OUT}" || { trap - EXIT; exit 1; }
  fi
  exit 1
fi
echo "Built ${OUT}"
