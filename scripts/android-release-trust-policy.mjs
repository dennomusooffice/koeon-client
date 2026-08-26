#!/usr/bin/env node

import { appendFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

export const FULL_SHA = /^[0-9a-f]{40}$/u;
export const VERSION_NAME = /^[0-9]+\.[0-9]+\.[0-9]+$/u;
export const VERSION_CODE = /^[1-9][0-9]*$/u;
export const MODES = new Set(["CANDIDATE_ONLY", "PUBLISH_GITHUB_RELEASE"]);
export const REQUIRED_PUBLIC_CHECKS = [
  "protocol",
  "android",
  "publication-safety",
  "ci-public-safety",
  "ios-simulator",
];

export function validateDispatchInputs({ mode, clientSha, expectedTreeSha, versionName, versionCode, publishConfirmation }) {
  if (!MODES.has(mode)) throw new Error("Unsupported Android release mode");
  if (!FULL_SHA.test(clientSha)) throw new Error("client_sha must be a full lowercase 40-hex SHA");
  if (!FULL_SHA.test(expectedTreeSha)) throw new Error("expected_tree_sha must be a full lowercase 40-hex SHA");
  if (!VERSION_NAME.test(versionName)) throw new Error("version_name must have three numeric components");
  if (!VERSION_CODE.test(versionCode)) throw new Error("version_code must be a positive integer");
  if (mode === "PUBLISH_GITHUB_RELEASE" && publishConfirmation !== "PUBLISH_ANDROID_RELEASE") {
    throw new Error("PUBLISH_GITHUB_RELEASE requires the exact publish confirmation");
  }
}

export function validateRequiredChecks(checkRuns) {
  const missing = REQUIRED_PUBLIC_CHECKS.filter((name) =>
    !checkRuns.some((check) => check.name === name && check.status === "completed" && check.conclusion === "success"),
  );
  if (missing.length) throw new Error(`Required Public CI checks are missing or unsuccessful: ${missing.join(", ")}`);
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

export async function resolveTrustedSource(config) {
  validateDispatchInputs(config);
  if (config.githubRef !== "refs/heads/main") throw new Error("Android release must be dispatched from protected default main");
  if (!FULL_SHA.test(config.workflowSha)) throw new Error("Workflow authority must be an immutable full SHA");

  const repository = await github(`/repos/${config.repository}`, config.token);
  if (repository.private) throw new Error("Android public release policy requires a Public repository");
  if (repository.default_branch !== "main") throw new Error("Android release policy currently requires default branch main");

  const mainCommit = await github(`/repos/${config.repository}/commits/main`, config.token);
  if (config.workflowSha !== mainCommit.sha || config.clientSha !== mainCommit.sha) {
    throw new Error("Workflow and release source must both equal current protected main");
  }
  const requestedCommit = await github(`/repos/${config.repository}/git/commits/${config.clientSha}`, config.token);
  if (requestedCommit.tree?.sha !== config.expectedTreeSha) throw new Error("Expected tree does not match exact protected main commit");

  const checks = await github(`/repos/${config.repository}/commits/${config.clientSha}/check-runs?filter=latest&per_page=100`, null);
  validateRequiredChecks(checks.check_runs ?? []);
  return {
    clientSha: config.clientSha,
    treeSha: config.expectedTreeSha,
    workflowSha: config.workflowSha,
    releaseTag: `android-v${config.versionName}-${config.versionCode}`,
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
      versionName: process.env.VERSION_NAME,
      versionCode: process.env.VERSION_CODE,
      publishConfirmation: process.env.PUBLISH_CONFIRMATION,
    });
    if (!process.env.GITHUB_OUTPUT) throw new Error("GITHUB_OUTPUT is unavailable");
    await appendFile(process.env.GITHUB_OUTPUT, [
      `client_sha=${result.clientSha}`,
      `tree_sha=${result.treeSha}`,
      `workflow_sha=${result.workflowSha}`,
      `release_tag=${result.releaseTag}`,
      "",
    ].join("\n"));
    console.log("ANDROID_TRUSTED_SOURCE_POLICY=PASS");
    console.log("ANDROID_EXACT_TREE_ATTESTATION=PASS");
    console.log("ANDROID_REQUIRED_PUBLIC_CI=PASS");
  } catch (error) {
    console.error(`Android trusted source policy failed: ${error.message}`);
    process.exitCode = 1;
  }
}
