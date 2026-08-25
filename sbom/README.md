# SBOM evidence（依存関係証跡）

`koeon-client.spdx.json`は、A6で作成した技術的なSoftware Bill of Materialsで、SPDX 2.3 JSON formatです。

```text
COMPONENTS = 421
PROTOCOL_NPM = 103
ANDROID_MAVEN = 314
IOS_SWIFTPM = 4
NOASSERTION_LICENSES = 52
PRODUCT_SOURCE_CHANGE = NO
DEPENDENCY_SEMANTIC_CHANGE = NO
```

evidence inputは`sbom/evidence/`以下に保持します:

- exact pnpm lock dataは`protocol/pnpm-lock.yaml`に保持します。
- Android runtime / test / build coordinateはGradle-resolved outputです。
- iOS packageは、validated main CIでXcode 26.6がresolveした正確なSwiftPM結果です。
- license evidenceは、正確なnpm registry metadata、Maven POM、Swift repository tagに基づきます。

metadataが存在しない、曖昧である、またはnon-open-source SDK termsが適用される場合、意図的に`NOASSERTION`としています。SBOMの`licenseConcluded` valueは`NOASSERTION`のままです。A6は法的結論を示しません。

dependency versionを変更せずevidenceを再生成する場合は、`docs/DEPENDENCY_EVIDENCE.md`に記載したscriptを実行してください。

