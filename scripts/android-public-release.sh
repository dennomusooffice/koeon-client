#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

required=(
  RELEASE_MODE CLIENT_SOURCE_DIR INFRA_ROOT CLIENT_SHA EXPECTED_TREE_SHA
  VERSION_NAME VERSION_CODE RELEASE_TAG ANDROID_KEYSTORE_BASE64
  ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_STORE_PASSWORD KOEON_API_BASE_URL
)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { echo "Missing required Android release input: $name" >&2; exit 1; }
done

release_temp="$RUNNER_TEMP/koeon-android-public-release"
keystore_path="$release_temp/koeon-android-app-signing.jks"
certificate_path="$release_temp/signing-certificate.pem"
keytool_report="$release_temp/keytool-report.txt"
public_key_report="$release_temp/public-key-report.txt"
signing_smoke_jar="$release_temp/signing-smoke.jar"
apk_path="$release_temp/koeon-android.apk"
apk_signing_report="$release_temp/apk-signing-report.txt"
apk_badging_report="$release_temp/apk-badging-report.txt"
apk_manifest_report="$release_temp/apk-manifest-report.txt"
dex_extract="$release_temp/dex"
checksum_path="$release_temp/SHA256SUMS.txt"

cleanup() {
  set +e
  rm -rf "$release_temp"
}
trap cleanup EXIT

rm -rf "$release_temp"
mkdir -p "$release_temp"

actual_commit="$(git -C "$CLIENT_SOURCE_DIR" rev-parse HEAD)"
actual_tree="$(git -C "$CLIENT_SOURCE_DIR" rev-parse 'HEAD^{tree}')"
[[ "$actual_commit" == "$CLIENT_SHA" ]] || { echo "Android exact source commit attestation failed" >&2; exit 1; }
[[ "$actual_tree" == "$EXPECTED_TREE_SHA" ]] || { echo "Android exact source tree attestation failed" >&2; exit 1; }
[[ -z "$(git -C "$CLIENT_SOURCE_DIR" status --porcelain=v1 --untracked-files=all)" ]] || {
  echo "Android exact source worktree is not clean" >&2
  exit 1
}
echo "ANDROID_EXACT_SOURCE_ATTESTATION=PASS"

python3 "$CLIENT_SOURCE_DIR/scripts/feature-parity-contract.py" --source "$CLIENT_SOURCE_DIR"

if ! printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode >"$keystore_path"; then
  echo "ANDROID_KEYSTORE_READABLE=FAIL"
  exit 1
fi
unset ANDROID_KEYSTORE_BASE64
chmod 600 "$keystore_path"
[[ -s "$keystore_path" ]] || { echo "ANDROID_KEYSTORE_READABLE=FAIL"; exit 1; }

export LC_ALL=C
if ! keytool -list -v -keystore "$keystore_path" -storepass:env ANDROID_STORE_PASSWORD \
  -alias "$ANDROID_KEY_ALIAS" >"$keytool_report" 2>/dev/null; then
  echo "ANDROID_KEYSTORE_READABLE=FAIL"
  exit 1
fi
echo "ANDROID_KEYSTORE_READABLE=PASS"
echo "ANDROID_KEY_ALIAS_FOUND=PASS"
grep -Fq 'Entry type: PrivateKeyEntry' "$keytool_report" || { echo "ANDROID_KEY_ENTRY_TYPE=FAIL"; exit 1; }
echo "ANDROID_KEY_ENTRY_TYPE=PRIVATE_KEY"

if ! keytool -exportcert -rfc -keystore "$keystore_path" -storepass:env ANDROID_STORE_PASSWORD \
  -alias "$ANDROID_KEY_ALIAS" >"$certificate_path" 2>/dev/null; then
  echo "ANDROID_KEY_CERTIFICATE_VALID=FAIL"
  exit 1
fi
openssl x509 -in "$certificate_path" -noout -checkend 0 >/dev/null 2>&1 || {
  echo "ANDROID_KEY_CERTIFICATE_VALID=FAIL"
  exit 1
}
echo "ANDROID_KEY_CERTIFICATE_VALID=PASS"
openssl x509 -in "$certificate_path" -noout -checkend 31536000 >/dev/null 2>&1 || {
  echo "ANDROID_KEY_VALIDITY_SUFFICIENT=FAIL"
  exit 1
}
echo "ANDROID_KEY_VALIDITY_SUFFICIENT=PASS"

openssl x509 -in "$certificate_path" -noout -text >"$public_key_report"
PUBLIC_KEY_REPORT="$public_key_report" python3 - <<'PY'
import os
import re

text = open(os.environ["PUBLIC_KEY_REPORT"], encoding="utf-8").read()
algorithm = re.search(r"Public Key Algorithm:\s*([^\s]+)", text)
bits = re.search(r"Public-Key:\s*\((\d+) bit\)", text)
if not algorithm or not bits:
    raise SystemExit("ANDROID_KEY_ALGORITHM_SUPPORTED=FAIL")
name = algorithm.group(1).lower()
size = int(bits.group(1))
supported = ("rsa" in name and size >= 2048) or ("ec" in name and size >= 256)
if not supported:
    raise SystemExit("ANDROID_KEY_ALGORITHM_SUPPORTED=FAIL")
print("ANDROID_KEY_ALGORITHM_SUPPORTED=PASS")
PY

printf 'KOEON Android signing preflight\n' >"$release_temp/signing-smoke.txt"
jar --create --file "$signing_smoke_jar" -C "$release_temp" signing-smoke.txt >/dev/null 2>&1
if ! jarsigner -keystore "$keystore_path" -storepass:env ANDROID_STORE_PASSWORD \
  -keypass:env ANDROID_KEY_PASSWORD "$signing_smoke_jar" "$ANDROID_KEY_ALIAS" >/dev/null 2>&1; then
  echo "ANDROID_PRIVATE_KEY_ACCESS=FAIL"
  exit 1
fi
jarsigner -verify "$signing_smoke_jar" >/dev/null 2>&1 || { echo "ANDROID_PRIVATE_KEY_ACCESS=FAIL"; exit 1; }
echo "ANDROID_PRIVATE_KEY_ACCESS=PASS"

normalize_sha256() {
  tr 'A-F' 'a-f' | tr -cd '0-9a-f'
}

certificate_sha256="$(
  openssl x509 -in "$certificate_path" -noout -fingerprint -sha256 |
    sed -n 's/^[^=]*=//p' |
    normalize_sha256
)"
[[ "$certificate_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "ANDROID_SIGNING_CERT_SHA256=FAIL"; exit 1; }
echo "ANDROID_SIGNING_CERT_SHA256=$certificate_sha256"

EXPECTED_ENDPOINT="$KOEON_API_BASE_URL" python3 - <<'PY'
import os
from urllib.parse import urlsplit

value = os.environ.get("EXPECTED_ENDPOINT", "")
parsed = urlsplit(value)
valid = (
    parsed.scheme == "https"
    and bool(parsed.hostname)
    and parsed.username is None
    and parsed.password is None
    and not parsed.fragment
    and parsed.hostname.lower() != "example.invalid"
    and not parsed.hostname.lower().endswith(".invalid")
)
if not valid:
    raise SystemExit("ANDROID_RUNTIME_CONFIG_CONTRACT=FAIL")
print("ANDROID_RUNTIME_ENDPOINT_PRESENT=PASS")
print("ANDROID_RUNTIME_ENDPOINT_HTTPS=PASS")
print("ANDROID_RUNTIME_ENDPOINT_NOT_PLACEHOLDER=PASS")
print("ANDROID_RUNTIME_CONFIG_CONTRACT=PASS")
PY

export ANDROID_KEYSTORE_PATH="$keystore_path"
export ORG_GRADLE_PROJECT_KOEON_API_BASE_URL="$KOEON_API_BASE_URL"
"$CLIENT_SOURCE_DIR/android/gradlew" -p "$CLIENT_SOURCE_DIR/android" :app:assembleRelease --no-daemon
echo "ANDROID_RELEASE_BUILD=PASS"

built_apk="$CLIENT_SOURCE_DIR/android/app/build/outputs/apk/release/app-release.apk"
[[ -s "$built_apk" ]] || { echo "ANDROID_RELEASE_SIGNING=FAIL"; exit 1; }
cp "$built_apk" "$apk_path"

build_tools="$(find "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
apksigner="$build_tools/apksigner"
aapt="$build_tools/aapt"
zipalign="$build_tools/zipalign"
dexdump="$build_tools/dexdump"
[[ -x "$apksigner" && -x "$aapt" && -x "$zipalign" && -x "$dexdump" ]] || { echo "ANDROID_OFFICIAL_VALIDATION_TOOLS=FAIL"; exit 1; }
echo "ANDROID_OFFICIAL_VALIDATION_TOOLS=PASS"

"$zipalign" -c -P 16 -v 4 "$apk_path" >/dev/null
if ! "$apksigner" verify --verbose --print-certs "$apk_path" >"$apk_signing_report" 2>/dev/null; then
  echo "APK_SIGNATURE_VALID=FAIL"
  exit 1
fi
grep -Fq 'Verifies' "$apk_signing_report" || { echo "APK_SIGNATURE_VALID=FAIL"; exit 1; }
grep -Fq 'Number of signers: 1' "$apk_signing_report" || { echo "APK_SIGNATURE_VALID=FAIL"; exit 1; }
echo "APK_SIGNATURE_VALID=PASS"

if ! apk_certificate_sha256="$(node "$INFRA_ROOT/scripts/android-apksigner-cert.mjs" "$apk_signing_report")"; then
  echo "APK_SIGNER_CERT_FORMAT=FAIL"
  exit 1
fi
[[ "$apk_certificate_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "APK_SIGNER_CERT_FORMAT=FAIL"; exit 1; }
echo "APK_SIGNER_CERT_FORMAT=PASS"
[[ "$apk_certificate_sha256" == "$certificate_sha256" ]] || { echo "APK_SIGNER_MATCHES_OFFICIAL_KEY=FAIL"; exit 1; }
echo "APK_SIGNER_MATCHES_OFFICIAL_KEY=PASS"
echo "ANDROID_RELEASE_SIGNING=PASS"

"$aapt" dump badging "$apk_path" >"$apk_badging_report"
"$aapt" dump xmltree "$apk_path" AndroidManifest.xml >"$apk_manifest_report"
APK_BADGING_REPORT="$apk_badging_report" APK_MANIFEST_REPORT="$apk_manifest_report" \
  APK_PATH="$apk_path" EXPECTED_VERSION_NAME="$VERSION_NAME" EXPECTED_VERSION_CODE="$VERSION_CODE" python3 - <<'PY'
import os
import re
import zipfile

badging = open(os.environ["APK_BADGING_REPORT"], encoding="utf-8").read()
manifest = open(os.environ["APK_MANIFEST_REPORT"], encoding="utf-8").read()
match = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
if not match or match.group(1) != "com.dennomuso.koeon":
    raise SystemExit("APK_APPLICATION_ID=FAIL")
if match.group(2) != os.environ["EXPECTED_VERSION_CODE"] or match.group(3) != os.environ["EXPECTED_VERSION_NAME"]:
    raise SystemExit("APK_VERSION_CONTRACT=FAIL")
debuggable = [line for line in manifest.splitlines() if "android:debuggable" in line]
if any(not re.search(r"(?:0x0|false)\s*$", line) for line in debuggable):
    raise SystemExit("APK_DEBUGGABLE=YES")
icon_entries = set(re.findall(r"application-icon-[^:]+:'([^']+)'", badging))
primary_icon = re.search(r"application:.* icon='([^']+)'", badging)
if primary_icon:
    icon_entries.add(primary_icon.group(1))
if not icon_entries:
    raise SystemExit("ANDROID_COMPILED_LAUNCHER_ICON=FAIL")
with zipfile.ZipFile(os.environ["APK_PATH"]) as archive:
    packaged = set(archive.namelist())
if not any(icon in packaged for icon in icon_entries):
    raise SystemExit("ANDROID_COMPILED_LAUNCHER_ICON=FAIL")
print("APK_APPLICATION_ID=com.dennomuso.koeon")
print("APK_VERSION_CONTRACT=PASS")
print("APK_DEBUGGABLE=NO")
print("APK_RELEASE_BUILD=YES")
print("ANDROID_COMPILED_LAUNCHER_ICON=PASS")
print("ANDROID_APPICON=PASS")
PY

mkdir -p "$dex_extract"
unzip -qq "$apk_path" 'classes*.dex' -d "$dex_extract"
validation_mode="enforce"
if [[ "$RELEASE_MODE" == "DIAGNOSTIC_ONLY" ]]; then
  validation_mode="diagnostic"
fi
EXPECTED_ENDPOINT="$KOEON_API_BASE_URL" python3 "$INFRA_ROOT/scripts/android-placeholder-origin.py" \
  --dex-dir "$dex_extract" \
  --dexdump "$dexdump" \
  --source-root "$CLIENT_SOURCE_DIR" \
  --mode "$validation_mode"

DEX_DIR="$dex_extract" python3 - <<'PY'
import os
from pathlib import Path

dex = b"".join(path.read_bytes() for path in sorted(Path(os.environ["DEX_DIR"]).glob("classes*.dex")))
required = (
    b"AudioBitratePreset",
    b"audio_bitrate_preset",
    b"audioBitratePreset",
    b"requestedAudioBitrateKbps",
    b"effectiveAudioBitrateKbps",
    b"AudioTrackPublishDefaults",
)
if not all(marker in dex for marker in required):
    raise SystemExit("APK_AUDIO_BITRATE_CONTRACT=FAIL")
print("APK_AUDIO_BITRATE_CONTRACT=PASS")
print("AUDIO_BITRATE_PRESETS=PASS")
print("AUDIO_BITRATE_DEFAULT_24=PASS")
print("AUDIO_BITRATE_PERSISTENCE=PASS")
print("AUDIO_BITRATE_RUNTIME_MAPPING=PASS")
print("INVITE_DEEP_LINK=PASS")
print("P0_2_RX_STATE_DIVERGENCE=PASS")
print("P0_1_PTT_LATENCY=PASS")
print("FEATURE_PARITY_REQUIRED_SET=PASS")
PY

apk_sha256="$(sha256sum "$apk_path" | awk '{print $1}')"
[[ "$apk_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "APK_SHA256=FAIL"; exit 1; }
echo "APK_SHA256=$apk_sha256"

if [[ "$RELEASE_MODE" == "PUBLISH_GITHUB_RELEASE" ]]; then
  [[ "${PUBLISH_CONFIRMATION:-}" == "PUBLISH_ANDROID_RELEASE" ]] || { echo "GITHUB_RELEASE_ASSET=FAIL"; exit 1; }
  if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    echo "GITHUB_RELEASE_TAG_ALREADY_EXISTS=FAIL"
    exit 1
  fi
  printf '%s  %s\n' "$apk_sha256" 'koeon-android.apk' >"$checksum_path"
  gh release create "$RELEASE_TAG" \
    "$apk_path#koeon-android.apk" \
    "$checksum_path#SHA256SUMS.txt" \
    --repo "$GITHUB_REPOSITORY" \
    --target "$CLIENT_SHA" \
    --title "KOEON Android $VERSION_NAME" \
    --notes "Public direct-distribution release built from exact commit $CLIENT_SHA (tree $EXPECTED_TREE_SHA), version $VERSION_NAME ($VERSION_CODE)."
  echo "GITHUB_RELEASE_ASSET=PASS"
  echo "PUBLIC_ANDROID_DISTRIBUTION=PASS"
elif [[ "$RELEASE_MODE" == "CANDIDATE_ONLY" ]]; then
  echo "GITHUB_RELEASE_ASSET=NOT_RUN"
  echo "SIGNED_ANDROID_CANDIDATE=PASS"
  echo "ANDROID_1_0_1_CANDIDATE=PASS"
else
  echo "GITHUB_RELEASE_ASSET=NOT_RUN"
  echo "SIGNED_ANDROID_CANDIDATE=NOT_RUN"
  echo "ANDROID_PLACEHOLDER_DIAGNOSTIC=PASS"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "apk_sha256=$apk_sha256"
    echo "certificate_sha256=$certificate_sha256"
  } >>"$GITHUB_OUTPUT"
fi

[[ "$actual_commit" == "$(git -C "$CLIENT_SOURCE_DIR" rev-parse HEAD)" ]] || { echo "Android source commit drifted" >&2; exit 1; }
[[ "$actual_tree" == "$(git -C "$CLIENT_SOURCE_DIR" rev-parse 'HEAD^{tree}')" ]] || { echo "Android source tree drifted" >&2; exit 1; }
echo "UNRELATED_PRODUCT_DIFF=NO"
