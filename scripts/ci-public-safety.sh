#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

mapfile -t workflows < <(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort)
if ((${#workflows[@]} == 0)); then
  echo "No workflows found" >&2
  exit 1
fi

reject() {
  local pattern="$1"
  local message="$2"
  if grep -IEn "$pattern" "${workflows[@]}"; then
    echo "$message" >&2
    exit 1
  fi
}

reject '(^|[[:space:]])pull_request_target:' 'Privileged pull_request_target trigger is forbidden'
reject '(^|[[:space:]])workflow_run:' 'workflow_run execution of PR code is forbidden'
reject '\$\{\{[[:space:]]*secrets\.' 'Secrets are forbidden in public PR workflows'
reject '(^|[[:space:]])(contents|actions|checks|deployments|id-token|issues|packages|pull-requests|security-events|statuses):[[:space:]]*write([[:space:]]|$)' 'Workflow write permission is forbidden'
reject '(^|[[:space:]])eval[[:space:]]' 'Shell eval is forbidden'
reject '\$\{\{[^}]*github\.event\.' 'PR-controlled event metadata must not be interpolated into workflow execution'
reject 'actions/(cache|upload-artifact|download-artifact)@' 'Shared cache/artifact transfer is disabled for initial public CI'
reject 'ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION' 'Node runtime security fallback is forbidden'
reject '(^|[^A-Za-z])(sign|signing|archive|testflight|app[[:space:]_-]*store|play[[:space:]_-]*upload|deploy|release)([^A-Za-z]|$)' 'Signing, release, or deploy workflow semantics are forbidden'

while IFS= read -r reference; do
  if [[ "$reference" == ./* ]]; then
    continue
  fi
  if [[ ! "$reference" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$ ]]; then
    echo "Action is not pinned to an immutable 40-hex commit: $reference" >&2
    exit 1
  fi
done < <(sed -nE 's/^[[:space:]]*-[[:space:]]*uses:[[:space:]]*([^[:space:]#]+).*$/\1/p' "${workflows[@]}")

checkout_count="$(grep -Eh 'uses:[[:space:]]*actions/checkout@[0-9a-f]{40}' "${workflows[@]}" | wc -l | tr -d ' ')"
persist_false_count="$(grep -Eh 'persist-credentials:[[:space:]]*false' "${workflows[@]}" | wc -l | tr -d ' ')"
if [[ "$checkout_count" -eq 0 || "$checkout_count" -ne "$persist_false_count" ]]; then
  echo "Every checkout must set persist-credentials: false" >&2
  exit 1
fi

for forbidden in server backend web event event-lp deploy task public/moty2026 docs/private; do
  if [[ -e "$forbidden" ]]; then
    echo "Forbidden public path present: $forbidden" >&2
    exit 1
  fi
done

echo 'PULL_REQUEST_TARGET=0'
echo 'WORKFLOW_RUN_TRUSTED_PR_EXECUTION=0'
echo 'PR_SECRET_REFERENCES=0'
echo 'WORKFLOW_WRITE_PERMISSIONS=0'
echo 'SIGNING_DEPLOY_JOBS=0'
echo 'SHELL_INJECTION_FINDINGS=0'
echo 'SHARED_CACHE_OR_ARTIFACT_CHANNELS=0'
echo 'UNPINNED_ACTIONS=0'
echo 'CHECKOUT_PERSIST_CREDENTIALS_FALSE=PASS'
