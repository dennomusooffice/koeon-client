# Public-style CI security model

Status: private staging. Public release is not authorized.

The CI configuration treats pull-request code as untrusted. It is limited to compilation, lint, unit tests, simulator tests and publication-safety assertions.

## Trust boundaries

- Fork or pull-request code receives no signing, Production or deployment credential.
- Workflows use the ordinary pull-request event, never a privileged base-context PR trigger.
- The workflow token has `contents: read` only.
- Hosted runners have no private network route or persistent signing state.
- Release signing, TestFlight, App Store, Play upload and Production deployment remain in separate PRIVATE/PROTECTED infrastructure.

## Workflow jobs

| Job | Runner | Allowed work | Secrets |
|---|---|---|---|
| protocol | Linux | dependency install, strict typecheck, tests | none |
| android | Linux | unit, lint, unsigned debug assemble | none |
| publication-safety | Linux | path, endpoint, filename and high-confidence secret assertions | none |
| ios-simulator | macOS | Swift resolution, unsigned simulator build, XCTest | none |

## Required invariants

```text
PULL_REQUEST_TARGET = 0
SIGNING_SECRET_CONSUMPTION = 0
PRODUCTION_SECRET_CONSUMPTION = 0
DEPLOY_JOBS = 0
WORKFLOW_WRITE_PERMISSIONS = 0
FORK_PR_SECRETS = NONE
```

Residual risks include arbitrary build-script execution, dependency-registry compromise, runner resource abuse and malicious test output. These are contained by ephemeral hosted runners, read-only token permissions, absence of protected credentials and immutable pinning of external Actions where used.

Any future signing, release, cache, artifact-publication, self-hosted runner, OIDC or write-permission change requires a separate security review. A failing macOS job must not be retried without Human approval during TASK004F.
