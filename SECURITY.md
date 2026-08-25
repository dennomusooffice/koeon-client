# Security policy — pre-publication draft

## Reporting a vulnerability

Do not disclose a vulnerability, credential, invite value or exploit in a public issue or pull request.

Before publication, the repository owner must enable and validate GitHub private vulnerability reporting so that the repository Security tab exposes **Report a vulnerability**, or designate another approved public security contact. The current PRIVATE-plan API did not expose an authoritative setting during A6, so the external intake route remains a Human publication decision.

```text
SECURITY_POLICY_STATUS = PARTIAL
PUBLIC_SECURITY_CONTACT = HUMAN_TBD
PRIVATE_VULNERABILITY_REPORTING = VERIFY_BEFORE_PUBLICATION
```

## Supported scope

Security reports may cover the iOS client, Android client, safe protocol package, public CI policy and dependency/supply-chain risks. The private KOEON server and release-signing systems are not hosted here.

## Security invariants

- LiveKit API secrets and token signing remain server-side only.
- Clients use short-lived room tokens issued only after membership validation.
- Access tokens, invite values, credentials and private keys must not be logged.
- Pull-request CI receives no signing or Production secrets and performs no deploy.
- Audio content is not stored or recorded.

If a credential is accidentally disclosed, preserve evidence privately and contact an authorized operator. This document does not authorize revocation, rotation or any Production mutation.

