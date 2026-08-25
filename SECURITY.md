# Security policy — pre-publication draft

This repository candidate is not yet public and has no public vulnerability intake address. Do not report secrets in a public issue or pull request. A private security contact and response SLA must be assigned before publication.

Security invariants:

- LiveKit API secrets and token signing remain server-side only.
- Clients receive short-lived room tokens after membership validation.
- Access tokens, invite values, credentials and private keys must never be logged.
- Public/fork CI receives no signing or Production secret and performs no deploy.
- Audio content is not stored or recorded.

If a credential is accidentally committed, stop distribution, preserve evidence privately, and have the authorized operator revoke/rotate it outside this repository. This document does not authorize Production mutation.
