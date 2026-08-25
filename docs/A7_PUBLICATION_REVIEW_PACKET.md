# A7 source-publication decision and technical evidence

This packet records the Human source-publication decision and preserves the technical evidence boundary. Formal counsel review was not performed, and commercial Android/iOS binary distribution remains a separate blocked gate.

```text
A6_BASE_MAIN_SHA = 8b34628bc2a3f0094b23cfa826359d7f55355d9d
A6_MERGED_MAIN_SHA = 5ccc438fd0818ecca33db5ff83f24cea03050333
PUBLIC_SOURCE_LICENSE = MPL-2.0
A7_SOURCE_HUMAN_GATE = PASS
FORMAL_COUNSEL_REVIEW = NOT_PERFORMED
A7_COMMERCIAL_BINARY_GATE = BLOCKED
JAIN_SIP_COMMERCIAL_BINARY_GATE = REVIEW_REQUIRED
GOOGLE_COMMERCIAL_PRIVACY_GATE = REVIEW_REQUIRED
SBOM_STATUS = COMPLETE_TECHNICAL / SPDX 2.3 / 421 components
NOTICE_STATUS = COMPLETE_TECHNICAL / FORMAL_COUNSEL_REVIEW_NOT_PERFORMED
DEPENDENCY_A6_BASELINE = 52 NOASSERTION / 13 LEGAL_REVIEW_REQUIRED / 44 UNKNOWN
GOOGLE_COMPONENT_STATUS = COMMERCIAL_PRIVACY_REVIEW_REQUIRED
ASSET_PROVENANCE_STATUS = READY_WITH_BRAND_ASSETS_DEFERRED
TRADEMARK_POLICY_STATUS = APPROVED_FOR_INITIAL_PUBLIC_SOURCE
EXTERNAL_CORE_PRS = CLOSED_INITIAL
CLA_STATUS = REQUIRED_BEFORE_EXTERNAL_CODE / INITIAL_FINALIZATION_DEFERRED
SECURITY_REPORTING_PRIMARY = GITHUB_PRIVATE_VULNERABILITY_REPORTING
CI_THREAT_STATUS = STATIC_CONTROLS_READY
ACTUAL_FORK_PR_TEST = NOT_SUPPORTED_WHILE_PRIVATE
A8_POST_PUBLIC_FORK_PR_SMOKE_TEST = REQUIRED
PUBLIC_RULESET_PLAN = APPROVED / APPLY_IMMEDIATELY_AFTER_PUBLIC
PUBLICATION_SAFETY_STATUS = PASS_REQUIRED_ON_FINAL_PR
```

## Evidence index

- `sbom/koeon-client.spdx.json`
- `THIRD_PARTY_NOTICES.md`
- `docs/DEPENDENCY_LICENSE_REVIEW.md`
- `docs/GOOGLE_DEPENDENCY_PRIVACY_REVIEW.md`
- `docs/PRIVACY_DISCLOSURE_DRAFT.md`
- `docs/ASSET_PROVENANCE.md`
- `docs/ACTIONS_RUNTIME_EVIDENCE.md`
- `docs/PUBLIC_CI_SECURITY.md`
- `docs/PUBLIC_REPOSITORY_RULESET_PLAN.md`
- `SECURITY.md`, `CONTRIBUTING.md`, `TRADEMARKS.md`

## Separate commercial and post-public gates

1. Keep commercial Android/iOS binary distribution blocked pending JAIN SIP and third-party binary-obligation review.
2. Complete Google Code Scanner privacy policy and Play Data Safety review before commercial distribution.
3. Enable and verify GitHub Private Vulnerability Reporting immediately after public activation.
4. Apply the approved public Ruleset and run the required non-member fork PR smoke test.
5. Complete a CLA or equivalent contribution rights-chain process before accepting external code.
6. Keep historical invite/Production review outside this public client repository.

```text
KOEON_ORIGINAL_CODE_RIGHTS = CONFIRMED_BY_HUMAN
KOEON_RIGHTS_OWNER_DISPLAY = 電脳夢創企画（個人事業）
KOEON_MARK_OWNER_DISPLAY = 電脳夢創企画（個人事業）
COUNSEL = NOT_ASSIGNED
FORMAL_COUNSEL_REVIEW = NOT_PERFORMED
```
