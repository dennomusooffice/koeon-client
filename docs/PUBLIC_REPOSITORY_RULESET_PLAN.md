# Public repository Ruleset / branch protection計画

```text
PRIVATE_BRANCH_PROTECTION = UNSUPPORTED_CURRENT_PLAN
PUBLIC_RULESET_PLAN = READY
PLAN_UPGRADE = NO
```

A6ではruleを変更していません。明示的に承認されたvisibility変更の直前または直後に、Human administratorがcurrent GitHub capabilityを再評価し、`main`へ次を適用します:

1. force pushとbranch deletionを禁止する。
2. 対応可能な場合、merge前にpull requestを必須とする。
3. Protocol、Android、publication safety v2、CI policy、iOS Simulator / XCTestを含む`Public client checks` status checksを必須とする。
4. 運用costが許容できる範囲で、branchを最新状態にすることを必須とする。
5. material change後のstale approvalを無効化する。
6. 必要に応じてconversation resolutionを必須とする。
7. bypass actorを最小化し、auditする。
8. public repositoryへsigning / deploy credentialを直接追加することを禁止する。
9. 公開後、無害なnon-member fork PRを使用してruleを検証する。

PRIVATE staging中のcompensating controlとして、Human Gate、no-force-push運用、exact SHA / diff review、CI evidenceの保全を継続します。

