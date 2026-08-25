# A7 publication review packet — technical evidence

This packet supports Human/legal review. It is not publication or legal approval.

```text
SOURCE_MAIN_SHA = 8b34628bc2a3f0094b23cfa826359d7f55355d9d
A6_BRANCH = codex/task004i-a6-public-readiness
A6_BRANCH_HEAD = authoritative PR head recorded at Human Gate I1
LICENSE_CANDIDATE = MPL-2.0 / LEGAL REVIEW REQUIRED
SBOM_STATUS = COMPLETE_TECHNICAL / SPDX 2.3 / 421 components
NOTICE_STATUS = PARTIAL_LEGAL_REVIEW
DEPENDENCY_REVIEW_STATUS = 52 NOASSERTION / 13 LEGAL_REVIEW_REQUIRED / 44 UNKNOWN
GOOGLE_COMPONENT_STATUS = PRIVACY_DISCLOSURE_REQUIRED
ASSET_PROVENANCE_STATUS = READY_WITH_BRAND_ASSETS_DEFERRED
TRADEMARK_POLICY_STATUS = DRAFT_FOR_LEGAL_REVIEW
EXTERNAL_CORE_PRS = CLOSED_INITIAL
CLA_STATUS = LEGAL_REVIEW_REQUIRED
SECURITY_POLICY_STATUS = PARTIAL
CI_THREAT_STATUS = STATIC_CONTROLS_READY
ACTUAL_FORK_PR_TEST = NOT_SUPPORTED_WHILE_PRIVATE
A8_POST_PUBLIC_FORK_PR_SMOKE_TEST = REQUIRED
PUBLIC_RULESET_PLAN = READY
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

## Remaining Human/legal decisions

1. Assign `LEGAL_BUSINESS_OWNER` and `COUNSEL` and approve/reject MPL-2.0 compatibility and notices.
2. Resolve the 52 `NOASSERTION` component records and the 13 explicit legal-review classifications.
3. Approve Google Code Scanner privacy-policy and Google Play Data safety disclosures.
4. Enable/validate GitHub private vulnerability reporting or approve a public security contact.
5. Approve trademark ownership/usage policy and the future brand-asset strategy.
6. Approve a CLA/DCO/rights-chain policy before accepting material external code.
7. Re-evaluate/apply public Rulesets and run the required post-public fork smoke test.
8. Keep historical invite authoritative review in the private security backlog; do not connect to Production from this repository.

```text
LEGAL_BUSINESS_OWNER = HUMAN_TBD
COUNSEL = HUMAN_TBD
A7_LEGAL_GATE = BLOCKED
PUBLICATION_AUTHORIZED = NO
```
