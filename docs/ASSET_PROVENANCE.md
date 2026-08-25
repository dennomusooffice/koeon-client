# Asset provenance（asset来歴）

```text
EVENT_ASSETS = 0
UNKNOWN_PROVENANCE_ASSETS = 0
BRAND_LOGO_ICON_ASSETS = 0
ASSET_PROVENANCE_STATUS = READY_WITH_BRAND_ASSETS_DEFERRED
```

tracked candidateには、PNG / JPEG / WebP / GIFのvisual asset、event screenshot、logo、AppIconは含まれません。Xcode projectにはasset catalogへのsource referenceがありますが、asset-catalog contentはtrackされていません。UI colorとsystem symbolはsource内で定義し、独立したbrand fileとしては扱いません。

`android/gradle/wrapper/gradle-wrapper.jar`はbuild-tool artifactであり、visual / brand assetではありません。dependency / build provenance reviewの対象です。

将来logo / iconを復元する場合は、origin、owner、license / trademark、public-safe reviewを別途必要とします。そのprocessを通じてrawまたはsanitized event imageryを取り込んではいけません。

