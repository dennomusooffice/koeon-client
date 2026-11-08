#!/bin/bash
set -euo pipefail
serial="${1:?emulator serial required}"
role="${2:?lab role required}"
mode="${3:-all}"
case "$mode" in all|prepare|run) ;; *) exit 2 ;; esac
case "$serial:$role" in
  emulator-5554:android35|emulator-5556:android36) ;;
  *) echo 'Only the two dedicated lab emulators are permitted' >&2; exit 2 ;;
esac
adb="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
ready=false
for ((attempt=0; attempt<60; attempt++)); do
  if [[ "$($adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]] || { echo 'Emulator boot timed out' >&2; exit 1; }
"$adb" -s "$serial" reverse tcp:18765 tcp:18765
if [[ "$mode" != run ]]; then
  "$adb" -s "$serial" install -r android/app/build/outputs/apk/debug/app-debug.apk
  "$adb" -s "$serial" install -r android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
fi
[[ "$mode" != prepare ]] || exit 0
log_file=$(mktemp /tmp/koeon-instrumentation.XXXXXX)
trap 'rm -f "$log_file"' EXIT
"$adb" -s "$serial" shell am instrument -w -r -e class com.dennomuso.koeon.MixedEmulatorTransportTest -e labRole "$role" com.dennomuso.koeon.test/androidx.test.runner.AndroidJUnitRunner | tee "$log_file"
grep -q '^OK (2 tests)' "$log_file"
