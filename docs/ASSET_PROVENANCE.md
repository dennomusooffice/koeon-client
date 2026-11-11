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


## 2026-11-11 Consoleエンブレム追加

所有者の明示指示により、既存Androidアイコンの`android/app/src/main/res/drawable-xxxhdpi/ic_launcher_monochrome.png`を、iOSの`Assets.xcassets/ConsoleEmblem.imageset/ConsoleEmblem.png`へバイト単位で複製してヘッダーに再利用。新規生成/外部取得なし。Kと電波の既存シルエットを角丸ゴールド板の彫り込みマスクとして再利用し、金属面/溝/ハイライトを実行時描画する（初案シルバーから所有者指示で更新）。所有者・商標権は既存KOEONブランドと同じで、MPLによる商標権付与ではない。公開安全性: 既存ブランド図形のみ、個人情報/画面/音声/秘密なし。上記「iOS AppIconのみ」は初回基準時点の記録であり、現在のAndroidアイコンと本派生コピーを除外する意味ではない。

複製元/複製先SHA256: `b89e71ebb011d9b24922e2f9ceedb2e9da07f216bcb40c48e5d977bc5ae3d4e4`。
