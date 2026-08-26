#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

required=(
  RELEASE_MODE CLIENT_SOURCE_DIR INFRA_ROOT CLIENT_SHA EXPECTED_TREE_SHA
  KOEON_API_BASE_URL MARKETING_VERSION BUILD_NUMBER APPLE_TEAM_ID
  KOEON_BUNDLE_ID KOEON_ASSOCIATED_DOMAIN IOS_CREDENTIAL_DIR
)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { echo "Missing required release input: $name" >&2; exit 1; }
done

project="$CLIENT_SOURCE_DIR/ios/KOEON.xcodeproj"
template_entitlements="$INFRA_ROOT/ios/KOEON/KOEON.Release.entitlements"
generated_entitlements="$RUNNER_TEMP/KOEON.Release.entitlements"
generated_project_workspace="$CLIENT_SOURCE_DIR/ios/KOEON.xcodeproj/project.xcworkspace"
project_workspace_preexisting=0
[[ -e "$generated_project_workspace" ]] && project_workspace_preexisting=1
archive_path="$RUNNER_TEMP/KOEON-public-release.xcarchive"
export_path="$RUNNER_TEMP/koeon-public-release-export"
signed_extract="$RUNNER_TEMP/koeon-public-release-signed"
source_packages="$RUNNER_TEMP/koeon-public-release-packages"
derived_data="$RUNNER_TEMP/koeon-public-release-derived"

cleanup() {
  set +e
  rm -rf "$archive_path" "$export_path" "$signed_extract" "$source_packages" "$derived_data"
  if [[ "$project_workspace_preexisting" -eq 0 ]]; then rm -rf "$generated_project_workspace"; fi
  rm -f "$generated_entitlements" "$RUNNER_TEMP/PublicReleaseExportOptions.plist"
  rm -f "$RUNNER_TEMP/public-release-settings.txt" "$RUNNER_TEMP/public-release-signed-entitlements.plist"
  rm -f "$RUNNER_TEMP/public-release-profile.plist" "$RUNNER_TEMP/public-release-preserved-entitlements.plist"
}
trap cleanup EXIT

actual_commit="$(git -C "$CLIENT_SOURCE_DIR" rev-parse HEAD)"
actual_tree="$(git -C "$CLIENT_SOURCE_DIR" rev-parse 'HEAD^{tree}')"
[[ "$actual_commit" == "$CLIENT_SHA" ]] || { echo "Exact source commit attestation failed" >&2; exit 1; }
[[ "$actual_tree" == "$EXPECTED_TREE_SHA" ]] || { echo "Exact source tree attestation failed" >&2; exit 1; }
[[ -z "$(git -C "$CLIENT_SOURCE_DIR" status --porcelain=v1 --untracked-files=all)" ]] || {
  echo "Exact source worktree is not clean before ephemeral configuration" >&2
  exit 1
}
echo "PUBLIC_EXACT_SOURCE_ATTESTATION=PASS"

node "$INFRA_ROOT/scripts/ios-release-candidate-contract.mjs"

TEMPLATE_ENTITLEMENTS="$template_entitlements" GENERATED_ENTITLEMENTS="$generated_entitlements" python3 - <<'PY'
import os
import plistlib

with open(os.environ["TEMPLATE_ENTITLEMENTS"], "rb") as stream:
    template = plistlib.load(stream)
expected = {
    "aps-environment": "production",
    "com.apple.developer.push-to-talk": True,
}
for key, value in expected.items():
    if template.get(key) != value:
        raise SystemExit(f"Public Release entitlement template is invalid: {key}")
if template.get("com.apple.developer.associated-domains") != ["$(KOEON_ASSOCIATED_DOMAIN)"]:
    raise SystemExit("Public Release entitlement template must use the environment variable placeholder")
generated = dict(template)
generated["com.apple.developer.associated-domains"] = [os.environ["KOEON_ASSOCIATED_DOMAIN"]]
with open(os.environ["GENERATED_ENTITLEMENTS"], "wb") as stream:
    plistlib.dump(generated, stream, sort_keys=False)
os.chmod(os.environ["GENERATED_ENTITLEMENTS"], 0o600)
print("RELEASE_ENTITLEMENTS=PASS")
PY

python3 "$INFRA_ROOT/scripts/ios-appicon-contract.py" --source "$CLIENT_SOURCE_DIR"

release_overrides=(
  "KOEON_API_BASE_URL=$KOEON_API_BASE_URL"
  "MARKETING_VERSION=$MARKETING_VERSION"
  "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
  "PRODUCT_BUNDLE_IDENTIFIER=$KOEON_BUNDLE_ID"
  "DEVELOPMENT_TEAM=$APPLE_TEAM_ID"
  "CODE_SIGN_ENTITLEMENTS=$generated_entitlements"
  "ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon"
)

xcodebuild -resolvePackageDependencies \
  -project "$project" -scheme KOEON -clonedSourcePackagesDirPath "$source_packages"

release_settings="$RUNNER_TEMP/public-release-settings.txt"
xcodebuild -showBuildSettings -project "$project" -target KOEON -configuration Release \
  "${release_overrides[@]}" >"$release_settings"
RELEASE_SETTINGS="$release_settings" GENERATED_RELEASE_ENTITLEMENTS="$generated_entitlements" \
  node "$INFRA_ROOT/scripts/ios-release-candidate-contract.mjs" --validate-release-settings

xcodebuild archive \
  -project "$project" -scheme KOEON -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$source_packages" \
  CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  "${release_overrides[@]}"

archive_app="$archive_path/Products/Applications/KOEON.app"
[[ -d "$archive_app" ]] || { echo "Unsigned archive app is missing" >&2; exit 1; }
python3 "$INFRA_ROOT/scripts/ios-appicon-contract.py" --app "$archive_app"
codesign --force --sign - --entitlements "$generated_entitlements" "$archive_app"
codesign --verify --strict --verbose=2 "$archive_app"
preserved="$RUNNER_TEMP/public-release-preserved-entitlements.plist"
codesign -d --entitlements :- "$archive_app" >"$preserved" 2>/dev/null
PRESERVED_ENTITLEMENTS="$preserved" python3 - <<'PY'
import os
import plistlib

with open(os.environ["PRESERVED_ENTITLEMENTS"], "rb") as stream:
    entitlements = plistlib.load(stream)
checks = [
    entitlements.get("aps-environment") == "production",
    entitlements.get("com.apple.developer.push-to-talk") is True,
    os.environ["KOEON_ASSOCIATED_DOMAIN"] in entitlements.get("com.apple.developer.associated-domains", []),
]
if not all(checks):
    raise SystemExit("Archive entitlement preservation failed")
print("ARCHIVE_ENTITLEMENTS=PASS")
PY

key_path="$IOS_CREDENTIAL_DIR/AuthKey.p8"
key_id="$(cat "$IOS_CREDENTIAL_DIR/key-id")"
issuer_id="$(cat "$IOS_CREDENTIAL_DIR/issuer-id")"
export_options="$RUNNER_TEMP/PublicReleaseExportOptions.plist"
cat >"$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>teamID</key><string>${APPLE_TEAM_ID}</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><true/>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
chmod 600 "$export_options"
xcodebuild -exportArchive \
  -archivePath "$archive_path" -exportPath "$export_path" -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$key_path" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer_id"

ipa=("$export_path"/*.ipa)
[[ ${#ipa[@]} -eq 1 && -f "${ipa[0]}" ]] || { echo "Expected exactly one signed IPA" >&2; exit 1; }
mkdir -p "$signed_extract"
ditto -x -k "${ipa[0]}" "$signed_extract"
signed_app="$signed_extract/Payload/KOEON.app"
signed_entitlements="$RUNNER_TEMP/public-release-signed-entitlements.plist"
profile="$RUNNER_TEMP/public-release-profile.plist"
[[ -d "$signed_app" && -f "$signed_app/embedded.mobileprovision" ]] || { echo "Signed app or provisioning profile is missing" >&2; exit 1; }
python3 "$INFRA_ROOT/scripts/ios-appicon-contract.py" --app "$signed_app"
"$INFRA_ROOT/scripts/ios-validate-runtime-frameworks.sh" "$signed_app"
codesign --verify --deep --strict --verbose=2 "$signed_app"
codesign -d --entitlements :- "$signed_app" >"$signed_entitlements" 2>/dev/null
security cms -D -i "$signed_app/embedded.mobileprovision" >"$profile"
APP_PATH="$signed_app" SIGNED_ENTITLEMENTS="$signed_entitlements" PROFILE_PLIST="$profile" \
  python3 "$INFRA_ROOT/scripts/ios-signed-candidate-validation.py"
echo "ARCHIVE=PASS"
echo "CODE_SIGNING=PASS"
echo "PROVISIONING=PASS"
echo "EXPECTED_ENTITLEMENTS=PASS"
echo "RUNTIME_ENDPOINT_CONFIGURED=YES"
echo "EFFECTIVE_EXAMPLE_INVALID=NO"

ipa_sha256="$(shasum -a 256 "${ipa[0]}" | awk '{print $1}')"
[[ "$ipa_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "Signed IPA SHA-256 calculation failed" >&2; exit 1; }
echo "SIGNED_IPA_SHA256=$ipa_sha256"

if [[ "$RELEASE_MODE" == "TESTFLIGHT_UPLOAD" ]]; then
  private_keys="$IOS_CREDENTIAL_DIR/private_keys"
  mkdir -p "$private_keys"
  cp "$key_path" "$private_keys/AuthKey_${key_id}.p8"
  chmod 600 "$private_keys/AuthKey_${key_id}.p8"
  API_PRIVATE_KEYS_DIR="$private_keys" xcrun altool --upload-app \
    --file "${ipa[0]}" --type ios --apiKey "$key_id" --apiIssuer "$issuer_id"
  echo "TESTFLIGHT_UPLOAD=PASS"
else
  echo "TESTFLIGHT_UPLOAD=NO"
fi

if [[ "$project_workspace_preexisting" -eq 0 ]]; then rm -rf "$generated_project_workspace"; fi
[[ "$actual_commit" == "$(git -C "$CLIENT_SOURCE_DIR" rev-parse HEAD)" ]] || { echo "Source commit drifted" >&2; exit 1; }
[[ "$actual_tree" == "$(git -C "$CLIENT_SOURCE_DIR" rev-parse 'HEAD^{tree}')" ]] || { echo "Source tree drifted" >&2; exit 1; }
[[ -z "$(git -C "$CLIENT_SOURCE_DIR" status --porcelain=v1 --untracked-files=all)" ]] || {
  echo "Public Product source diff is non-zero after release build" >&2
  exit 1
}
echo "PRODUCT_SOURCE_DIFF=0"
echo "SIGNED_CANDIDATE=READY"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "ipa_sha256=$ipa_sha256" >>"$GITHUB_OUTPUT"
fi
