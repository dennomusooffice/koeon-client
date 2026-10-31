# KOEON client: investigation and change records

Read [docs/BUG_TRACKING.md](docs/BUG_TRACKING.md) before investigating or fixing a bug. The repository owner requires each finding, fix, release and verification result to be recorded on GitHub so another developer or AI agent can continue without this chat.

- Search existing Issues before creating one. Record the symptom, affected build, reproducible conditions, observed evidence, hypotheses, and next action.
- Update the Issue and related PR when a cause is established, code changes, tests finish, a build ships, or a blocker changes. Include commit SHA and exact build number.
- Distinguish implemented, automatically tested, distributed, device-verified, and merged. A passing unit test or single device run is not proof of general stability.
- Link fixes and follow-up Issues from the PR. Do not auto-close a partially resolved Issue on merge.
- Publish sanitized evidence only. Follow CONTRIBUTING.md and SECURITY.md for private data and security findings.
- Respect the user's current device-testing window. A previous authorization or a recorded plan does not extend an expired window.
