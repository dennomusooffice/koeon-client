# Security policy

## Reporting a vulnerability

Do not disclose a vulnerability, credential, invite value or exploit in a public issue or pull request.

Use GitHub Private Vulnerability Reporting through the repository **Security** tab and select **Report a vulnerability**. Do not publish sensitive details if that control is temporarily unavailable during initial repository activation. The repository owner will enable and verify this route immediately after public visibility is activated; this document does not claim that the control is already enabled while the repository remains private.

```text
SECURITY_REPORTING_PRIMARY = GITHUB_PRIVATE_VULNERABILITY_REPORTING
PRIVATE_VULNERABILITY_REPORTING = ENABLE_AND_VERIFY_IMMEDIATELY_AFTER_PUBLIC
PERSONAL_EMAIL_FALLBACK_PUBLISHED = NO
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

