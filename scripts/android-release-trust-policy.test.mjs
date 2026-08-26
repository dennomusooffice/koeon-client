import assert from "node:assert/strict";
import test from "node:test";
import {
  REQUIRED_PUBLIC_CHECKS,
  validateDispatchInputs,
  validateRequiredChecks,
} from "./android-release-trust-policy.mjs";

const sha = "a".repeat(40);
const tree = "b".repeat(40);
const successfulChecks = REQUIRED_PUBLIC_CHECKS.map((name) => ({ name, status: "completed", conclusion: "success" }));

test("accepts candidate and explicitly confirmed publish inputs", () => {
  assert.doesNotThrow(() => validateDispatchInputs({
    mode: "DIAGNOSTIC_ONLY", clientSha: sha, expectedTreeSha: tree,
    versionName: "1.0.0", versionCode: "1", publishConfirmation: "",
  }));
  assert.doesNotThrow(() => validateDispatchInputs({
    mode: "CANDIDATE_ONLY", clientSha: sha, expectedTreeSha: tree,
    versionName: "1.0.0", versionCode: "1", publishConfirmation: "",
  }));
  assert.doesNotThrow(() => validateDispatchInputs({
    mode: "PUBLISH_GITHUB_RELEASE", clientSha: sha, expectedTreeSha: tree,
    versionName: "1.0.0", versionCode: "1", publishConfirmation: "PUBLISH_ANDROID_RELEASE",
  }));
});

test("rejects mutable refs, invalid versions, and unconfirmed publish", () => {
  assert.throws(() => validateDispatchInputs({
    mode: "CANDIDATE_ONLY", clientSha: "main", expectedTreeSha: tree,
    versionName: "1.0.0", versionCode: "1", publishConfirmation: "",
  }));
  assert.throws(() => validateDispatchInputs({
    mode: "CANDIDATE_ONLY", clientSha: sha, expectedTreeSha: tree,
    versionName: "0.1.0-task002", versionCode: "1", publishConfirmation: "",
  }));
  assert.throws(() => validateDispatchInputs({
    mode: "PUBLISH_GITHUB_RELEASE", clientSha: sha, expectedTreeSha: tree,
    versionName: "1.0.0", versionCode: "1", publishConfirmation: "yes",
  }));
});

test("requires every Public CI check to be successful", () => {
  assert.doesNotThrow(() => validateRequiredChecks(successfulChecks));
  assert.throws(() => validateRequiredChecks(successfulChecks.slice(1)));
  assert.throws(() => validateRequiredChecks(successfulChecks.map((check, index) =>
    index === 0 ? { ...check, conclusion: "failure" } : check,
  )));
});
