#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$source_dir/../../.." && pwd)"
build_dir="$repo_dir/.build/test-lab/ui-probe"
export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
export PATH="$JAVA_HOME/bin:$PATH"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
bt="$sdk/build-tools/${ANDROID_BUILD_TOOLS:-35.0.0}"
mkdir -p "$build_dir/classes" "$build_dir/dex"
cd "$build_dir"
"$bt/aapt2" link -o base.apk --manifest "$source_dir/AndroidManifest.xml" -I "$sdk/platforms/android-36/android.jar"
javac -source 8 -target 8 -classpath "$sdk/platforms/android-36/android.jar" -d classes "$source_dir"/src/com/dennomuso/koeon/uiprobe/*.java
"$bt/d8" --lib "$sdk/platforms/android-36/android.jar" --output dex classes/com/dennomuso/koeon/uiprobe/*.class
zip -j base.apk dex/classes.dex >/dev/null
"$bt/zipalign" -f 4 base.apk aligned.apk
"$bt/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-pass pass:android --out ui-probe.apk aligned.apk
"$bt/apksigner" verify ui-probe.apk
printf 'UI probe built: %s/ui-probe.apk\n' "$build_dir"
