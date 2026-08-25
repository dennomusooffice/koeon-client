# Public Export Manifest

```text
source repository = dennomusooffice/koeon (PRIVATE)
source branch = main
source main SHA = 2158c6fbb18a0004eade7650162ebbc9a512d666
export timestamp = 2026-08-25T12:45:31+09:00
export method = ALLOWLIST-BASED CLEAN-ROOT
source Git history copied = NO
public status = NOT AUTHORIZED
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
- Event landing page, MOTY documents, raw assets and sanitized screenshot derivatives
- private task/audit evidence, private access codes, signing material and build/cache outputs
- all private Git history

## Sanitized source paths

18 source files were changed only in this derivative: Xcode team/bundle/AppIcon settings; iOS API/invite/LiveKit hosts, queue/Keychain identifiers, Info.plist, development entitlement and fixtures; Android application ID/API default, manifest host/icon verification, LiveKit/invite fixtures and synthetic workspace/user fixtures. Android's license-metadata packaging exclusion was removed.

Safe defaults use `example.invalid` and `livekit.example.invalid`. No real endpoint credential is present.

## Review blockers

- `A7_LEGAL_GATE = BLOCKED`; legal owner and counsel are `HUMAN_TBD`.
- MPL-2.0 is preferred, not finally approved for publication.
- Complete transitive dependency SBOM/NOTICE and Google Code Scanner terms review are required.
- KOEON brand asset provenance/trademark policy is unresolved; 19 existing icon paths were excluded.
- iOS simulator/XCTest requires macOS CI validation.
- invite authoritative Production review remains a separate required security follow-up.

```text
PUBLICATION_AUTHORIZED = NO
REMOTE_CONFIGURATION_AUTHORIZED = NO
PUSH_AUTHORIZED = NO
```
