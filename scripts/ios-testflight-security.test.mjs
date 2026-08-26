import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflowPath = new URL("../.github/workflows/ios-testflight-internal.yml", import.meta.url);
const workflow = readFileSync(workflowPath, "utf8");
const workflowLines = workflow.split(/\r?\n/u);

test("uses workflow_dispatch as the only trigger", () => {
  const triggerBlock = workflow.match(/^on:\s*\n([\s\S]*?)^permissions:/mu)?.[1] ?? "";
  assert.match(triggerBlock, /^  workflow_dispatch:/mu);
  for (const trigger of ["pull_request", "pull_request_target", "push", "workflow_run", "issue_comment", "repository_dispatch", "schedule"]) {
    assert.doesNotMatch(triggerBlock, new RegExp(`^  ${trigger}:`, "mu"));
  }
});

test("keeps token permissions read-only and every checkout credential-free", () => {
  assert.doesNotMatch(workflow, /^\s+[a-z-]+:\s*write\s*$/mu);
  const checkouts = workflow.match(/uses:\s*actions\/checkout@[0-9a-f]{40}/gu) ?? [];
  const persistFalse = workflow.match(/persist-credentials:\s*false/gu) ?? [];
  assert.equal(checkouts.length, 3);
  assert.equal(persistFalse.length, checkouts.length);
});

test("pins every external action and uses no cache or artifact transport", () => {
  for (const line of workflowLines.filter((line) => /^\s*-?\s*uses:/u.test(line))) {
    assert.match(line, /uses:\s*[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+@[0-9a-f]{40}(?:\s|$)/u);
  }
  assert.doesNotMatch(workflow, /actions\/(?:cache|upload-artifact|download-artifact)@/u);
});

test("binds every secret reference to the single protected Environment job", () => {
  const secretReferences = workflow.match(/\$\{\{\s*secrets\.([A-Z0-9_]+)\s*\}\}/gu) ?? [];
  assert.deepEqual(new Set(secretReferences), new Set([
    "${{ secrets.KOEON_API_BASE_URL }}",
    "${{ secrets.IOS_APP }}",
  ]));
  const privilegedJob = workflow.match(/^  build-sign-validate:\n([\s\S]*)$/mu)?.[1] ?? "";
  assert.match(privilegedJob, /environment:\s*\n\s+name:\s*testflight-internal/u);
  assert.equal((privilegedJob.match(/\$\{\{\s*secrets\./gu) ?? []).length, secretReferences.length);
  const unprivilegedJob = workflow.match(/^  trust-gate:\n([\s\S]*?)^  build-sign-validate:/mu)?.[1] ?? "";
  assert.doesNotMatch(unprivilegedJob, /\$\{\{\s*secrets\./u);
});

test("does not interpolate dispatch inputs directly into shell commands", () => {
  let inRun = false;
  let runIndent = 0;
  for (const line of workflowLines) {
    const indent = line.match(/^\s*/u)?.[0].length ?? 0;
    if (/^\s+run:\s*[|>]\s*$/u.test(line)) {
      inRun = true;
      runIndent = indent;
      continue;
    }
    if (inRun && line.trim() && indent <= runIndent) inRun = false;
    if (inRun) assert.doesNotMatch(line, /\$\{\{\s*inputs\./u);
  }
});

test("uses the standard public macOS runner and never stores a signed IPA artifact", () => {
  assert.match(workflow, /^\s+name:\s*testflight-internal\s*$/mu);
  assert.match(workflow, /^\s+runs-on:\s*macos-26\s*$/mu);
  assert.match(workflow, /Signed IPA retained as Actions artifact: NO/u);
  assert.doesNotMatch(workflow, /upload-artifact/u);
});

test("contains no private checkout, task branch gate, or permanent candidate hardcode", () => {
  assert.doesNotMatch(workflow, /dennomusooffice\/koeon(?:\s|['"]|$)/u);
  assert.doesNotMatch(workflow, /codex\/task/u);
  const immutableReferences = workflow.match(/[0-9a-f]{40}/gu) ?? [];
  assert.deepEqual(new Set(immutableReferences), new Set(["3d3c42e5aac5ba805825da76410c181273ba90b1"]));
});
