# Public Export Manifest

```text
source repository = dennomusooffice/koeon (PRIVATE)
source branch = main
source main SHA = 2158c6fbb18a0004eade7650162ebbc9a512d666
export timestamp = 2026-08-25T12:45:31+09:00
export method = ALLOWLIST-BASED CLEAN-ROOT
source Git history copied = NO
public status at export timestamp = NOT AUTHORIZED
```

## Included roots

- `ios/` — 30 source files
- `android/` — 65 source files
- `protocol/src/` — 8 source files relocated from the safe shared subset
- newly authored generic docs, test configuration, safety script and public CI candidate

## Excluded roots/categories

- Web application and deferred Web client
- server/API implementation, auth/membership/Floor backend, token signing, APNs provider and persistent-listening backend
- database/migrations, Admin/Billing and Production deployment/operations
- legacy event landing pages/documents, raw assets and sanitized screenshot derivatives
- private task/audit evidence, private access codes, signing material and build/cache outputs
- all private Git history

## Sanitized source paths

18 source files were changed only in this derivative: Xcode team/bundle/AppIcon settings; iOS API/invite/LiveKit hosts, queue/Keychain identifiers, Info.plist, development entitlement and fixtures; Android application ID/API default, manifest host/icon verification, LiveKit/invite fixtures and synthetic workspace/user fixtures. Android's license-metadata packaging exclusion was removed.

Safe defaults use `example.invalid` and `livekit.example.invalid`. No real endpoint credential is present.

## Current source decision and separate commercial gates

- `A7_SOURCE_HUMAN_GATE = PASS` by Human risk decision; formal counsel review was not performed.
- `PUBLIC_SOURCE_LICENSE = MPL-2.0` for source code controlled by the KOEON rights holder.
- `KOEON_RIGHTS_OWNER_DISPLAY = 電脳夢創企画（個人事業）`.
- Third-party dependencies retain their own licenses and terms; technical evidence does not assert legal compatibility.
- `EXTERNAL_CORE_PRS = CLOSED_INITIAL`; a CLA or equivalent rights-chain process is required before accepting external code.
- `A7_COMMERCIAL_BINARY_GATE = BLOCKED`.
- `JAIN_SIP_COMMERCIAL_BINARY_GATE = REVIEW_REQUIRED`.
- `GOOGLE_COMMERCIAL_PRIVACY_GATE = REVIEW_REQUIRED`.
- KOEON logo/AppIcon and other official brand assets remain excluded and deferred.
- Historical invite/Production review remains outside this public client repository.

```text
REMOTE_CONFIGURATION_AUTHORIZED = NO
FORMAL_COUNSEL_REVIEW = NOT_PERFORMED
COMMERCIAL_ANDROID_IOS_DISTRIBUTION = SEPARATE_GATE_REQUIRED
```
