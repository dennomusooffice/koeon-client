import assert from "node:assert/strict";
import test from "node:test";
import {
  REQUIRED_PUBLIC_CHECKS,
  classifyTrustedSource,
  validateDispatchInputs,
} from "./ios-release-trust-policy.mjs";

const sha = "a".repeat(40);
const tree = "b".repeat(40);
const successfulChecks = REQUIRED_PUBLIC_CHECKS.map((name) => ({ name, status: "completed", conclusion: "success" }));
const sameRepositoryPullRequest = {
  number: 6,
  state: "open",
  merged_at: null,
  author_association: "OWNER",
  head: { sha, repo: { full_name: "example/koeon-client" } },
  base: { repo: { full_name: "example/koeon-client" } },
};

test("accepts immutable candidate and upload inputs with an explicit upload confirmation", () => {
  assert.doesNotThrow(() => validateDispatchInputs({
    mode: "CANDIDATE_ONLY", clientSha: sha, expectedTreeSha: tree,
    marketingVersion: "1.0", buildNumber: "42", uploadConfirmation: "",
  }));
  assert.doesNotThrow(() => validateDispatchInputs({
    mode: "TESTFLIGHT_UPLOAD", clientSha: sha, expectedTreeSha: tree,
    marketingVersion: "1.0", buildNumber: "42", uploadConfirmation: "UPLOAD_TESTFLIGHT",
  }));
  assert.throws(() => validateDispatchInputs({
    mode: "TESTFLIGHT_UPLOAD", clientSha: sha, expectedTreeSha: tree,
    marketingVersion: "1.0", buildNumber: "42", uploadConfirmation: "yes",
  }));
  assert.throws(() => validateDispatchInputs({
    mode: "CANDIDATE_ONLY", clientSha: "main", expectedTreeSha: tree,
    marketingVersion: "1.0", buildNumber: "42", uploadConfirmation: "",
  }));
});

test("accepts protected main ancestry without PR authority", () => {
  assert.deepEqual(classifyTrustedSource({
    requestedSha: sha, mainSha: sha, isMainAncestor: true, pullRequests: [], checkRuns: [],
  }), { kind: "PROTECTED_MAIN", prNumber: "" });
});

test("accepts only an authorized same-repository open PR head with all Public CI checks", () => {
  const result = classifyTrustedSource({
    requestedSha: sha, mainSha: "c".repeat(40), isMainAncestor: false,
    pullRequests: [sameRepositoryPullRequest], checkRuns: successfulChecks,
  });
  assert.equal(result.kind, "SAME_REPO_PR");
  assert.equal(result.prNumber, "6");
});

test("rejects fork, unknown, stale, and unauthorized PR sources", () => {
  const variants = [
    { ...sameRepositoryPullRequest, head: { ...sameRepositoryPullRequest.head, repo: { full_name: "fork/koeon-client" } } },
    { ...sameRepositoryPullRequest, head: { ...sameRepositoryPullRequest.head, sha: "d".repeat(40) } },
    { ...sameRepositoryPullRequest, state: "closed" },
    { ...sameRepositoryPullRequest, author_association: "CONTRIBUTOR" },
  ];
  for (const pullRequest of variants) {
    assert.throws(() => classifyTrustedSource({
      requestedSha: sha, mainSha: "c".repeat(40), isMainAncestor: false,
      pullRequests: [pullRequest], checkRuns: successfulChecks,
    }));
  }
  assert.throws(() => classifyTrustedSource({
    requestedSha: sha, mainSha: "c".repeat(40), isMainAncestor: false,
    pullRequests: [], checkRuns: successfulChecks,
  }));
});

test("rejects a same-repository PR when any required Public CI check is missing or failed", () => {
  assert.throws(() => classifyTrustedSource({
    requestedSha: sha, mainSha: "c".repeat(40), isMainAncestor: false,
    pullRequests: [sameRepositoryPullRequest], checkRuns: successfulChecks.slice(1),
  }));
  const failed = successfulChecks.map((check, index) => index === 0 ? { ...check, conclusion: "failure" } : check);
  assert.throws(() => classifyTrustedSource({
    requestedSha: sha, mainSha: "c".repeat(40), isMainAncestor: false,
    pullRequests: [sameRepositoryPullRequest], checkRuns: failed,
  }));
});
