# Public repository ruleset / branch-protection plan

```text
PRIVATE_BRANCH_PROTECTION = UNSUPPORTED_CURRENT_PLAN
PUBLIC_RULESET_PLAN = READY
PLAN_UPGRADE = NO
```

No rule is changed during A6. Immediately before or after an explicitly authorized visibility change, Human administrators must re-evaluate current GitHub capabilities and apply the following to `main`:

1. block force pushes and branch deletion;
2. require a pull request before merge where supported;
3. require the `Public client checks` status checks, including Protocol, Android, publication safety v2, CI policy and iOS Simulator/XCTest;
4. require branches to be up to date where the operational cost is acceptable;
5. dismiss stale approvals after material changes;
6. require conversation resolution where appropriate;
7. minimize and audit bypass actors;
8. prohibit direct signing/deploy credentials in the public repository;
9. verify rules using a harmless non-member fork PR after publication.

During PRIVATE staging, compensating controls remain Human Gates, no-force-push operation, exact SHA/diff review and preserved CI evidence.

