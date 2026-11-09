#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${ROOT}/.build/audio-output-probe"
mkdir -p "${OUTPUT}"
xcrun clang -fobjc-arc -fmodules -c "${ROOT}/Sources/AudioExceptionGuard/AudioExceptionGuard.m" \
  -I "${ROOT}/Sources/AudioExceptionGuard/include" -o "${OUTPUT}/AudioExceptionGuard.o"
xcrun clang -fobjc-arc "${ROOT}/tests/test_audio_exception_guard.m" "${OUTPUT}/AudioExceptionGuard.o" \
  -I "${ROOT}/Sources/AudioExceptionGuard/include" -framework Foundation -framework AVFoundation \
  -o "${OUTPUT}/exception-guard-test"
"${OUTPUT}/exception-guard-test"
cat > "${OUTPUT}/module.modulemap" <<EOF
module AudioExceptionGuard {
  header "${ROOT}/Sources/AudioExceptionGuard/include/AudioExceptionGuard.h"
  export *
}
EOF
# Keep in sync with the files RemoteMicrophoneOutput depends on.
xcrun swiftc "${ROOT}/Sources/RcHarness/RemoteMicrophoneOutput.swift" \
  "${ROOT}/Sources/RcHarness/CoreAudioRemoteMicrophonePlayback.swift" \
  "${ROOT}/Sources/RcHarness/AudioDeviceCatalog.swift" \
  "${ROOT}/Sources/RcHarness/PCMBacklog.swift" \
  "${ROOT}/Sources/RcHarness/SettingsKeys.swift" \
  "${ROOT}/Sources/RcHarness/SettingsStorage.swift" \
  "${ROOT}/Sources/RcHarness/Log.swift" \
  "${ROOT}/Sources/RcHarness/AudioDiagnostics.swift" \
  "${ROOT}/tests/audio-output-probe/main.swift" "${OUTPUT}/AudioExceptionGuard.o" \
  -I "${OUTPUT}" -o "${OUTPUT}/probe"
"${OUTPUT}/probe" "$@"
