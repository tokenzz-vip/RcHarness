#!/usr/bin/env bash
# Record caller wall time, engine work and waiting-thread stacks together.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: scripts/capture_audio_latency.sh [seconds: 1-300, default 30] [app or latency probe PID]"
  echo "Start recording before reproducing; use capture_hang.sh in another terminal during a hang."
  exit 0
fi
if [[ $# -gt 2 ]]; then echo "Too many arguments; use --help." >&2; exit 1; fi
SECONDS_TO_RECORD="${1:-30}"
if [[ ! "${SECONDS_TO_RECORD}" =~ ^[1-9][0-9]{0,2}$ ]] || (( SECONDS_TO_RECORD > 300 )); then
  echo "Recording duration must be 1-300 seconds." >&2
  exit 1
fi
APP_PID="${2:-$(/usr/bin/pgrep -f '^/Applications/RcHarness[.]app/Contents/MacOS/RcHarness$' | head -n 1 || true)}"
if [[ ! "${APP_PID}" =~ ^[1-9][0-9]*$ ]]; then
  echo "No running RcHarness found; supply its PID as the second argument." >&2
  exit 1
fi
# Exclude the volume guard and unrelated processes even with an explicit PID.
APP_COMMAND="$(/bin/ps -p "${APP_PID}" -o args= || true)"
case "${APP_COMMAND}" in
  */RcHarness.app/Contents/MacOS/RcHarness) ;;
  */audio-output-probe/probe\ --latency\ --wait-for-profiler) ;;
  *) echo "PID must identify RcHarness without helper arguments, or the waiting latency probe." >&2; exit 1 ;;
esac
mkdir -p "${ROOT}/.build/diagnostics"
CAPTURE_DIR="$(mktemp -d "${ROOT}/.build/diagnostics/audio-latency-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
cat > "${CAPTURE_DIR}/recording-options.json" <<'EOF'
{
  "Hangs": { "detectPriorityInversions": false, "hangsThreshold": 250 },
  "Time Profiler": {
    "contextSwitchSampling": false,
    "highFrequencySampling": false,
    "recordKernelStacks": false,
    "recordWaitingThreads": true
  },
  "Points of Interest": { "excludeOSLogs": false }
}
EOF
/bin/ps -p "${APP_PID}" -o pid=,stat=,etime=,comm= > "${CAPTURE_DIR}/process.txt"
/usr/bin/sw_vers > "${CAPTURE_DIR}/system.txt"
echo "Recording PID ${APP_PID} for ${SECONDS_TO_RECORD}s; reproduce after xctrace reports recording started."
echo "Output: ${CAPTURE_DIR}"
xcrun xctrace record --template 'Time Profiler' --instrument 'Points of Interest' \
  --recording-options "${CAPTURE_DIR}/recording-options.json" \
  --attach "${APP_PID}" --time-limit "${SECONDS_TO_RECORD}s" \
  --output "${CAPTURE_DIR}/audio.trace" 2>&1 | tee "${CAPTURE_DIR}/recording-status.txt"
