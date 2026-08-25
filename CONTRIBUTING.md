# Contribution policy — 初期公開方針

```text
EXTERNAL_CORE_PRS = CLOSED_INITIAL
CLA_REQUIRED_BEFORE_EXTERNAL_CODE = YES
CLA_FINALIZATION_BEFORE_INITIAL_PUBLICATION = DEFERRED
```

初期公開段階では、iOS、Android、protocol、audio、PTT、networking、build behaviorのcore部分に対する外部変更を受け付けません。maintainerがこの方針を明示的に変更するまで、core codeのpull requestは作成しないでください。

Issueと再現可能なbug reportは受け付けます。文書修正は個別に検討しますが、先にIssueで相談してください。

計画中のCommercial OEM / dual-license architectureに必要なrights-chain policyとCLA / DCO processをHuman ownerとcounselが承認するまで、実質的な外部codeは受け入れません。この文書はCLAではなく、新たなlicense grantを与えるものでもありません。

credential、invite value、access token、private endpoint、recording、user / channel / device identifier、signing material、event asset、privateな運用情報を提出しないでください。

security vulnerabilityはpublic Issueやpull requestへ記載せず、[SECURITY.md](SECURITY.md)に従って報告してください。

## Code of Conductの状態

`CODE_OF_CONDUCT_STATUS = DEFERRED_HUMAN_CONTACT`

公開可能なenforcement contactが承認されていないため、正式なCode of Conductはまだ追加していません。追加前に、enforcement routeと採用する標準文面/versionについてHuman approvalが必要です。

