# Asset provenance（asset来歴）

```text
EVENT_ASSETS = 0
UNKNOWN_PROVENANCE_ASSETS = 0
BRAND_LOGO_ICON_ASSETS = 1
ASSET_PROVENANCE_STATUS = VERIFIED_IOS_APPICON_ONLY
```

tracked sourceに含めるvisual brand assetは、iOS application packagingに必要な`ios/KOEON/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`だけです。旧Private Event baseline `37337941ba06daba83fdf5ee61f7c5b58e8c51e7`のGit blob `586f3968c3eed7ce9ddde7db3173c76f9641da4b`と一致し、電脳夢創企画（個人事業）がHuman確認したKOEON brand assetです。MPL-2.0はこのAppIconの商標・brand利用権を付与しません。

event screenshot、logo pack、その他のofficial brand assetは含めません。UI colorとsystem symbolはsource内で定義し、独立したbrand fileとしては扱いません。

`android/gradle/wrapper/gradle-wrapper.jar`はbuild-tool artifactであり、visual / brand assetではありません。dependency / build provenance reviewの対象です。

将来logo packまたは別のbrand assetを追加する場合は、origin、owner、license / trademark、public-safe reviewを別途必要とします。そのprocessを通じてrawまたはsanitized event imageryを取り込んではいけません。

