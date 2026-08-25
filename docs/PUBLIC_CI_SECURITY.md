# Public CI security model

Status: public-client CI security policy. Public activation and the first non-member fork test remain separate operational gates.

## Trust boundary

Pull-request content is treated as untrusted. The workflow executes untrusted build/test code only on ephemeral GitHub-hosted runners with `contents: read`, no repository secrets, no private network, no signing state and no deploy authority.

```text
PULL_REQUEST_TARGET = 0
WORKFLOW_RUN_TRUSTED_PR_EXECUTION = 0
PR_SECRET_REFERENCES = 0
WORKFLOW_WRITE_PERMISSIONS = 0
SIGNING_DEPLOY_JOBS = 0
UNPINNED_ACTIONS = 0
```

## Workflow jobs

| Job | Runner | Allowed work | Credentials |
|---|---|---|---|
| protocol | Linux | frozen install, typecheck, tests | read-only token only |
| android | Linux | unit, lint, unsigned debug build | read-only token only |
| publication-safety | Linux | full clean-root tree/history scan | read-only token only |
| ci-public-safety | Linux | machine-test workflow policy | read-only token only |
| ios-simulator | macOS | exact Swift resolution, unsigned ARM64 Simulator build, XCTest | read-only token only |

Every external Action is pinned to an immutable 40-hex commit. Checkout credentials are not persisted. No cache or artifact transfer channel is enabled for initial public CI.

## Threat review

| Threat | Control | Residual status |
|---|---|---|
| privileged PR trigger / pwn-request | privileged and chained PR triggers prohibited | none found |
| shell injection | no PR metadata interpolation; `eval` prohibited | none found |
| cache poisoning | no shared cache Action | none |
| artifact poisoning | no upload/download artifact Action | none |
| unpinned Action supply chain | immutable full SHA plus version comment | none found |
| writable checkout credentials | `persist-credentials: false` everywhere | none found |
| signing/deploy abuse | no credentials or jobs; signing disabled in xcodebuild | none found |
| dependency registry compromise | frozen lock/exact package resolution where supported | residual ecosystem risk |
| malicious test/build execution | ephemeral hosted runners, timeouts, read-only token | residual compute/log risk |

`scripts/ci-public-safety.sh` fails on future privileged triggers, secret references, write permissions, PR metadata interpolation, shared cache/artifact Actions, signing/deploy semantics, mutable Action references or persisted checkout credentials.

## Fork test

```text
ACTUAL_FORK_PR_TEST = NOT_SUPPORTED_WHILE_PRIVATE
A8_POST_PUBLIC_FORK_PR_SMOKE_TEST = REQUIRED
```

After publication, a non-member fork must open a harmless documentation-only PR to confirm no secrets, write permissions, signing/deploy behavior, private network access or duplicate macOS execution is exposed.

