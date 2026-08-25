# Dependency license review — technical evidence

This is a technical classification for Human/counsel review, not legal advice or a final compatibility decision.

## Inventory result

| Declared metadata | Components |
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

The 13 legal-review rows include reciprocal-license metadata and Google/Android proprietary SDK terms. The 44 `UNKNOWN` rows have no unambiguous SPDX declaration in the exact POM metadata. All rows and evidence URLs are in `THIRD_PARTY_NOTICES.md` and `sbom/evidence/license-evidence.json`.

## Required Human/counsel decisions

1. Confirm MPL-2.0 compatibility and file-level obligations for the intended source release.
2. Review EPL/EDL/MPL-1.1/LGPL metadata and whether each build/test/runtime artifact is distributed.
3. Review exact Google ML Kit and Android SDK terms independently of open-source license metadata.
4. Determine which copyright/license texts must accompany source, Android binaries and future signed distributions.
5. Approve the Commercial OEM/dual-license rights chain and CLA policy before accepting material external code.

`MPL-2.0 = PREFERRED / LEGAL REVIEW REQUIRED` remains unchanged.

