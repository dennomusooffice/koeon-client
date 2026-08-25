# Dependency license review — technical evidence

これはHuman / counsel reviewのためのtechnical classificationです。legal adviceや最終的なcompatibility decisionではありません。

## Inventory result

| Declared metadata | Component数 |
|---|---:|
| Apache-2.0 | 252 |
| MIT | 103 |
| BSD-3-Clause | 7 |
| ISC | 2 |
| LGPL-2.1-only | 2 |
| EPL-1.0 | 1 |
| EDL-1.0 | 1 |
| MPL-1.1 | 1 |
| NOASSERTION | 52 |
| **Total** | **421** |

Review classification:

```text
TECHNICALLY_COMPATIBLE_CANDIDATE = 364
LEGAL_REVIEW_REQUIRED = 13
UNKNOWN = 44
BLOCK_PUBLICATION = 0 (no clear technical blocker found; not legal approval)
```

legal-review 13行には、reciprocal-license metadataとGoogle / Android proprietary SDK termsが含まれます。`UNKNOWN` 44行には、exact POM metadata内に一意なSPDX declarationがありません。全行とevidence URLは`THIRD_PARTY_NOTICES.md`と`sbom/evidence/license-evidence.json`に記録しています。

## 残るHuman / counsel review

1. 意図するsource releaseについて、MPL-2.0 compatibilityとfile-level obligationを確認する。
2. EPL / EDL / MPL-1.1 / LGPL metadataと、各build / test / runtime artifactが配布物へ含まれるかをreviewする。
3. open-source license metadataとは独立して、正確なGoogle ML Kit / Android SDK termsをreviewする。
4. source、Android binary、将来のsigned distributionに同梱すべきcopyright / license textを判断する。
5. 実質的な外部codeを受け入れる前に、Commercial OEM / dual-license rights chainとCLA policyを承認する。

`MPL-2.0 = PREFERRED / LEGAL REVIEW REQUIRED`は変更されていません。

