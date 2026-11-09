#!/usr/bin/env bash
# Capture the unresponsive app before force-quitting; never samples the guard.
set -euo pipefail

CAPTURE_ROOT="$(cd "$(dirname "$0")/.." && pwd)/.build/diagnostics"
APP_PID="$(/usr/bin/pgrep -f '^/Applications/RcHarness[.]app/Contents/MacOS/RcHarness$' | head -n 1 || true)"
if [[ -z "${APP_PID}" ]]; then
  echo "未找到正在运行的 /Applications/RcHarness.app；请在强制退出前采集。" >&2
  exit 1
fi

mkdir -p "${CAPTURE_ROOT}"
CAPTURE_DIR="$(mktemp -d "${CAPTURE_ROOT}/hang-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
echo "正在采集 RcHarness（PID ${APP_PID}），请暂时不要强制退出。"
# Sample first: the call stacks are the evidence that disappears on exit.
/usr/bin/sample "${APP_PID}" 3 1 -file "${CAPTURE_DIR}/threads.txt" >"${CAPTURE_DIR}/sample-status.txt" 2>&1
/bin/ps -p "${APP_PID}" -o pid=,stat=,etime=,comm= >"${CAPTURE_DIR}/process.txt" || true
/usr/bin/sw_vers >"${CAPTURE_DIR}/system.txt"
/usr/bin/codesign -dvv /Applications/RcHarness.app >"${CAPTURE_DIR}/signature.txt" 2>&1
/usr/bin/log show --last 5m --style compact --info \
  --predicate 'subsystem == "vip.tokenzz.rcharness"' >"${CAPTURE_DIR}/app.log" 2>"${CAPTURE_DIR}/log-status.txt"
if [[ -f "${HOME}/Library/Logs/RcHarness/audio.log" ]]; then
  cp "${HOME}/Library/Logs/RcHarness/audio.log" "${CAPTURE_DIR}/audio.log"
fi
echo "采集完成：${CAPTURE_DIR}"
