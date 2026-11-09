#!/usr/bin/env bash
# Runs every automated check that needs no remote, permissions or audio hardware.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> swift test"
swift test --package-path "${ROOT}"

echo "==> HAL driver tests (ASan/UBSan)"
"${ROOT}/scripts/test_microphone_driver.sh"

echo "==> audio exception guard + output probe"
# The probe exits 2 (skip) without microphone permission and an installed loopback.
status=0
"${ROOT}/scripts/test_audio_output.sh" || status=$?
if [[ ${status} -ne 0 && ${status} -ne 2 ]]; then exit "${status}"; fi

echo "All checks passed."
