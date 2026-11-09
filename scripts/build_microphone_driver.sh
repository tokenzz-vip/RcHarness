#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:?usage: build_microphone_driver.sh <output-directory> [local|distribution]}"
SIGNING_MODE="${2:-local}"
DRIVER="${OUTPUT}/RcHarnessMicrophone.driver"
mkdir -p "${DRIVER}/Contents/MacOS"
install -m 644 "${ROOT}/Drivers/RcHarnessMicrophone/Info.plist" "${DRIVER}/Contents/Info.plist"
xcrun clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -Werror \
  -mmacosx-version-min=14.0 -bundle -fvisibility=hidden \
  -framework CoreAudio -framework CoreFoundation \
  "${ROOT}/Drivers/RcHarnessMicrophone/Driver.c" \
  -o "${DRIVER}/Contents/MacOS/RcHarnessMicrophone"
"${ROOT}/scripts/sign_macos_code.sh" "${DRIVER}" vip.tokenzz.rcharness.microphone "${SIGNING_MODE}"
