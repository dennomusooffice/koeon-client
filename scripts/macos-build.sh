#!/bin/bash
# Local development builds. Compatible with the Bash shipped with macOS.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This helper requires macOS.' >&2
  exit 1
fi

action="${1:-help}"
build_dir="$root/.build/macos"

android_environment() {
  export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
  export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
  if [[ ! -x "$JAVA_HOME/bin/java" || ! -d "$ANDROID_HOME/platforms/android-36" ]]; then
    echo 'JDK 17 and Android SDK 36 are required. See docs/MACOS_LOCAL_BUILD.md.' >&2
    exit 1
  fi
}

ios_build() {
  local operation="$1"
  local destination='generic/platform=iOS Simulator'
  if [[ "$operation" == test ]]; then
    if [[ -n "${SIMULATOR_UDID:-}" ]]; then
      destination="platform=iOS Simulator,arch=arm64,id=$SIMULATOR_UDID"
    else
      local udid
      udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
matches = [d["udid"] for runtime in sorted(devices, reverse=True)
           if ".iOS-" in runtime for d in devices[runtime]
           if d.get("isAvailable") and d.get("name", "").startswith("iPhone")]
if not matches:
    sys.exit("No iPhone Simulator available. Install an iOS runtime in Xcode Settings > Components.")
print(matches[0])')"
      destination="platform=iOS Simulator,arch=arm64,id=$udid"
    fi
  fi
  mkdir -p "$build_dir"
  local build_args=(-project ios/KOEON.xcodeproj -scheme KOEON)
  if [[ "$operation" == test ]]; then
    build_args+=(-only-testing:KOEONTests -parallel-testing-enabled NO)
  fi
  xcodebuild "${build_args[@]}" \
    -configuration Debug -destination "$destination" \
    -derivedDataPath "$build_dir/DerivedData" \
    -clonedSourcePackagesDirPath "$build_dir/SourcePackages" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "$operation"
}

case "$action" in
  android)
    android_environment
    ./android/gradlew -p android assembleDebug --no-daemon
    ;;
  android-check)
    android_environment
    ./android/gradlew -p android testDebugUnitTest lintDebug assembleDebug --no-daemon
    ;;
  ios) ios_build build ;;
  ios-test) ios_build test ;;
  doctor)
    xcode-select -p
    xcodebuild -version
    xcodebuild -checkFirstLaunchStatus
    xcrun simctl list runtimes
    android_environment
    "$JAVA_HOME/bin/java" -version
    "$ANDROID_HOME/platform-tools/adb" version
    ;;
  help|-h|--help)
    echo 'Usage: bash scripts/macos-build.sh {doctor|android|android-check|ios|ios-test}'
    ;;
  *) echo "Unknown action: $action" >&2; exit 2 ;;
esac
