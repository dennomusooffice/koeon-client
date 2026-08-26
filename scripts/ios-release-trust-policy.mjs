#!/usr/bin/env node

import { appendFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

export const FULL_SHA = /^[0-9a-f]{40}$/u;
export const VERSION = /^[0-9]+(?:\.[0-9]+){1,2}$/u;
export const BUILD = /^[1-9][0-9]*$/u;
export const MODES = new Set(["CANDIDATE_ONLY", "TESTFLIGHT_UPLOAD"]);
export const REQUIRED_PUBLIC_CHECKS = [
  "protocol",
  "android",
  "publication-safety",
  "ci-public-safety",
  "ios-simulator",
];

export function validateDispatchInputs({ mode, clientSha, expectedTreeSha, marketingVersion, buildNumber, uploadConfirmation }) {
  if (!MODES.has(mode)) throw new Error("Unsupported release mode");
  if (!FULL_SHA.test(clientSha)) throw new Error("client_sha must be a full lowercase 40-hex SHA");
  if (!FULL_SHA.test(expectedTreeSha)) throw new Error("expected_tree_sha must be a full lowercase 40-hex SHA");
  if (!VERSION.test(marketingVersion)) throw new Error("marketing_version must have two or three numeric components");
  if (!BUILD.test(buildNumber)) throw new Error("build_number must be a positive integer");
  if (mode === "TESTFLIGHT_UPLOAD" && uploadConfirmation !== "UPLOAD_TESTFLIGHT") {
    throw new Error("TESTFLIGHT_UPLOAD requires the exact upload confirmation");
  }
}

export function classifyTrustedSource({ requestedSha, mainSha, isMainAncestor, pullRequests, checkRuns }) {
  if (isMainAncestor) return { kind: "PROTECTED_MAIN", prNumber: "" };

  const trustedAssociations = new Set(["OWNER", "MEMBER", "COLLABORATOR"]);
  const pullRequest = pullRequests.find((pr) =>
    pr.state === "open" &&
    pr.merged_at == null &&
    pr.head?.sha === requestedSha &&
    pr.head?.repo?.full_name === pr.base?.repo?.full_name &&
    trustedAssociations.has(pr.author_association),
  );
  if (!pullRequest) throw new Error("Source is neither protected main ancestry nor an authorized same-repository PR head");

  const missing = REQUIRED_PUBLIC_CHECKS.filter((name) =>
    !checkRuns.some((check) => check.name === name && check.status === "completed" && check.conclusion === "success"),
  );
  if (missing.length) throw new Error(`Required Public CI checks are missing or unsuccessful: ${missing.join(", ")}`);
  return { kind: "SAME_REPO_PR", prNumber: String(pullRequest.number), mainSha };
}

async function github(path, token) {
  const headers = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(`https://api.github.com${path}`, {
    headers,
    redirect: "error",
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`GitHub API ${path.split("?")[0]} returned HTTP ${response.status}`);
  return response.json();
}

async function isAncestor(repository, baseSha, headSha, token) {
  if (baseSha === headSha) return true;
  const comparison = await github(`/repos/${repository}/compare/${baseSha}...${headSha}`, token);
  return comparison.status === "ahead";
}

export async function resolveTrustedSource(config) {
  validateDispatchInputs(config);
  if (config.githubRef !== "refs/heads/main") throw new Error("Release workflow must be dispatched from protected default main");
  if (!FULL_SHA.test(config.workflowSha)) throw new Error("Workflow authority must be an immutable full SHA");

  const repository = await github(`/repos/${config.repository}`, config.token);
  if (repository.private) throw new Error("Public release policy requires a Public repository");
  if (repository.default_branch !== "main") throw new Error("Protected release policy currently requires default branch main");
  const mainCommit = await github(`/repos/${config.repository}/commits/${repository.default_branch}`, config.token);
  const mainSha = mainCommit.sha;
  if (!(await isAncestor(config.repository, config.workflowSha, mainSha, config.token))) {
    throw new Error("Workflow definition SHA is not protected main ancestry");
  }

  const requestedCommit = await github(`/repos/${config.repository}/git/commits/${config.clientSha}`, config.token);
  if (requestedCommit.tree?.sha !== config.expectedTreeSha) throw new Error("Human-provided tree SHA does not match the requested commit");

  const mainAncestry = await isAncestor(config.repository, config.clientSha, mainSha, config.token);
  let pullRequests = [];
  let checkRuns = [];
  if (!mainAncestry) {
    pullRequests = await github(`/repos/${config.repository}/commits/${config.clientSha}/pulls`, config.token);
    // Check results are public metadata. Read them anonymously so the
    // workflow token does not need checks:read beyond the minimal policy.
    const checks = await github(`/repos/${config.repository}/commits/${config.clientSha}/check-runs?filter=latest&per_page=100`, null);
    checkRuns = checks.check_runs ?? [];
  }
  const classification = classifyTrustedSource({
    requestedSha: config.clientSha,
    mainSha,
    isMainAncestor: mainAncestry,
    pullRequests,
    checkRuns,
  });
  return {
    ...classification,
    clientSha: config.clientSha,
    treeSha: config.expectedTreeSha,
    workflowSha: config.workflowSha,
    mainSha,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const result = await resolveTrustedSource({
      repository: process.env.GITHUB_REPOSITORY,
      token: process.env.GITHUB_TOKEN,
      githubRef: process.env.GITHUB_REF,
      workflowSha: process.env.GITHUB_WORKFLOW_SHA,
      mode: process.env.RELEASE_MODE,
      clientSha: process.env.CLIENT_SHA,
      expectedTreeSha: process.env.EXPECTED_TREE_SHA,
      marketingVersion: process.env.MARKETING_VERSION,
      buildNumber: process.env.BUILD_NUMBER,
      uploadConfirmation: process.env.UPLOAD_CONFIRMATION,
    });
    const output = process.env.GITHUB_OUTPUT;
    if (!output) throw new Error("GITHUB_OUTPUT is unavailable");
    await appendFile(output, [
      `source_kind=${result.kind}`,
      `client_sha=${result.clientSha}`,
      `tree_sha=${result.treeSha}`,
      `workflow_sha=${result.workflowSha}`,
      `main_sha=${result.mainSha}`,
      `pr_number=${result.prNumber}`,
      "",
    ].join("\n"));
    console.log(`TRUSTED_SOURCE_POLICY=PASS kind=${result.kind}`);
    console.log("EXACT_TREE_ATTESTATION=PASS");
  } catch (error) {
    console.error(`Trusted source policy failed: ${error.message}`);
    process.exitCode = 1;
  }
}
