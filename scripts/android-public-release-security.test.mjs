import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";

const workflow = await readFile(new URL("../.github/workflows/android-public-release.yml", import.meta.url), "utf8");
const gradle = await readFile(new URL("../android/app/build.gradle.kts", import.meta.url), "utf8");
const inviteHandoff = await readFile(new URL("../android/app/src/main/java/com/dennomuso/koeon/core/enrollment/InviteHandoff.kt", import.meta.url), "utf8");
const releaseScript = await readFile(new URL("./android-public-release.sh", import.meta.url), "utf8");
const originScript = new URL("./android-placeholder-origin.py", import.meta.url);
const originSource = await readFile(originScript, "utf8");

test("uses manual dispatch and the protected Android Environment only", () => {
  const trigger = workflow.slice(workflow.indexOf("on:\n"), workflow.indexOf("\npermissions:"));
  assert.match(trigger, /workflow_dispatch:/u);
  assert.doesNotMatch(trigger, /pull_request|pull_request_target|push:|workflow_run/u);
  assert.match(workflow, /environment:\n\s+name: android-public-release/u);
  assert.doesNotMatch(workflow, /pull_request_target|workflow_run/u);
});

test("keeps ordinary authority read-only and scopes write to the publish-capable job", () => {
  assert.match(workflow, /permissions:\n\s+contents: read/u);
  const privileged = workflow.slice(workflow.indexOf("  build-sign-validate-publish:"));
  assert.match(privileged, /permissions:\n\s+contents: write/u);
  assert.equal((workflow.match(/contents: write/gu) ?? []).length, 1);
  assert.doesNotMatch(workflow, /actions: write|checks: write|id-token: write|pull-requests: write/u);
});

test("pins Actions, disables checkout credentials, and has no cache or artifact channel", () => {
  const uses = [...workflow.matchAll(/uses:\s*([^\s#]+)/gu)].map((match) => match[1]);
  assert.ok(uses.length >= 3);
  assert.ok(uses.every((reference) => /^[\w.-]+\/[\w.-]+@[0-9a-f]{40}$/u.test(reference)));
  assert.equal((workflow.match(/actions\/checkout@[0-9a-f]{40}/gu) ?? []).length,
    (workflow.match(/persist-credentials: false/gu) ?? []).length);
  assert.doesNotMatch(workflow, /actions\/(?:cache|upload-artifact|download-artifact)@/u);
});

test("binds every signing secret to one protected job and never interpolates inputs into shell", () => {
  const privileged = workflow.slice(workflow.indexOf("  build-sign-validate-publish:"));
  const secretReferences = workflow.match(/\$\{\{\s*secrets\.[A-Z0-9_]+\s*\}\}/gu) ?? [];
  assert.equal(secretReferences.length, 5);
  assert.equal((privileged.match(/\$\{\{\s*secrets\.[A-Z0-9_]+\s*\}\}/gu) ?? []).length, 5);
  assert.doesNotMatch(workflow, /run:[^\n]*\$\{\{\s*inputs\./u);
  assert.doesNotMatch(workflow, /github\.event\./u);
});

test("uses exact protected main attestation and disposable signing material", () => {
  assert.match(workflow, /CLIENT_SHA: \$\{\{ needs\.trust-gate\.outputs\.client_sha \}\}/u);
  assert.match(workflow, /EXPECTED_TREE_SHA: \$\{\{ needs\.trust-gate\.outputs\.tree_sha \}\}/u);
  assert.match(releaseScript, /git -C "\$CLIENT_SOURCE_DIR" rev-parse 'HEAD\^\{tree\}'/u);
  assert.match(releaseScript, /printf '%s' "\$ANDROID_KEYSTORE_BASE64" \| base64 --decode/u);
  assert.match(releaseScript, /trap cleanup EXIT/u);
  assert.match(releaseScript, /rm -rf "\$release_temp"/u);
  assert.doesNotMatch(releaseScript, /set -x/u);
});

test("locks official identity, release signing seam, version, and fail-closed debug endpoint", () => {
  assert.match(gradle, /namespace = "com\.dennomuso\.koeon"/u);
  assert.match(gradle, /applicationId = "com\.dennomuso\.koeon"/u);
  assert.match(gradle, /versionName = "1\.0\.5"/u);
  assert.match(gradle, /versionCode = 6/u);
  assert.match(gradle, /create\("release"\)/u);
  assert.match(gradle, /signingConfig = signingConfigs\.getByName\("release"\)/u);
  assert.match(gradle, /https:\/\/example\.invalid/u);
  assert.match(gradle, /KOEON_API_BASE_URL/u);
  assert.doesNotMatch(gradle, /org\.example\.koeon/u);
});

test("locks the public invite origin to the approved historical authority", () => {
  assert.match(inviteHandoff, /INVITE_ORIGIN = "https:\/\/koeon\.muso-apps\.net"/u);
  assert.doesNotMatch(inviteHandoff, /https:\/\/example\.invalid/u);
  assert.doesNotMatch(inviteHandoff, /BuildConfig\.KOEON_BACKEND_URL/u);
});

test("verifies official signature, app identity, non-debuggable runtime, and publishes only after validation", () => {
  assert.match(releaseScript, /apksigner.*verify --verbose --print-certs/su);
  assert.match(releaseScript, /normalize_sha256\(\)/u);
  assert.match(releaseScript, /tr -cd '0-9a-f'/u);
  assert.match(releaseScript, /android-apksigner-cert\.mjs/u);
  assert.match(releaseScript, /APK_SIGNER_CERT_FORMAT=PASS/u);
  assert.match(releaseScript, /APK_SIGNER_MATCHES_OFFICIAL_KEY=PASS/u);
  assert.match(releaseScript, /APK_APPLICATION_ID=com\.dennomuso\.koeon/u);
  assert.match(releaseScript, /APK_DEBUGGABLE=NO/u);
  assert.match(originSource, /APK_RUNTIME_ENDPOINT_CONFIGURED=PASS/u);
  assert.match(releaseScript, /FEATURE_PARITY_REQUIRED_SET=PASS/u);
  assert.match(releaseScript, /ANDROID_COMPILED_LAUNCHER_ICON=PASS/u);
  assert.match(releaseScript, /ANDROID_1_0_1_CANDIDATE=PASS/u);
  assert.ok(releaseScript.indexOf("feature-parity-contract.py") < releaseScript.indexOf("gh release create"));
  assert.ok(releaseScript.indexOf("ANDROID_COMPILED_LAUNCHER_ICON=PASS") < releaseScript.indexOf("gh release create"));
  assert.ok(releaseScript.indexOf("android-placeholder-origin.py") < releaseScript.indexOf("gh release create"));
  assert.doesNotMatch(releaseScript, /upload-artifact|download-artifact/u);
});

test("keeps diagnostic mode non-publishing and classifies placeholder owners deterministically", () => {
  assert.match(workflow, /- DIAGNOSTIC_ONLY/u);
  assert.match(releaseScript, /RELEASE_MODE" == "DIAGNOSTIC_ONLY/u);
  assert.match(releaseScript, /android-placeholder-origin\.py/u);
  assert.ok(releaseScript.indexOf("android-placeholder-origin.py") < releaseScript.indexOf("gh release create"));
  if (process.platform !== "win32") {
    const output = execFileSync("python3", [fileURLToPath(originScript), "--self-test"], { encoding: "utf8" });
    assert.match(output, /ANDROID_PLACEHOLDER_ORIGIN_SELF_TEST=PASS/u);
  }
});
