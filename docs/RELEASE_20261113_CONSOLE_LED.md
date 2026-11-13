# CH/PTT LED両側発光の実機テスト配布

2026-11-13。#88 / PR #90 / [TASK](development/CONSOLE_LED_TEST_RELEASE_TASK.md)。配布ソース `af37062d154e528ded200910dc47486e10eaafdd`、tree `7282468e257887c6df519a9724aadba305896358`。前回配布版に、CHキーとPTTの発光線を一周内側に置き、両側へ光が広がるUI変更を追加。

- Android **1.0.25 (26)**: [GitHub prerelease](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.25-26) 公開。署名候補検証成功。APK SHA256 `3a01a2fd50a5576afbdb2b88ee4b1efb64492a573943ffd5576fd1cac2978c98` とGitHub asset digest一致。
- iOS **1.0 (2026111137)**: 同一SHAで外部TestFlight署名候補・再ビルド・Appleアップロード成功。IPA SHA256 `882218f06bb1a12d2d73233e53127df929061fbf9e5062822f3cccd1807542c3`。Apple processing `VALID`、内部/外部とも `IN_BETA_TESTING`。既存内部2群・外部1群すべてのbuild関係を再取得して確認。外部ベータ審査申請済み、自動通知ON。
- 変更時検証: Android `compileDebugKotlin`、iOS Simulator Debug build、parity、diff check成功。UI描画のみ変更。既存のAndroid223件・Lint、iOS279成功/1専用skipは前回配布時の結果であり、このコミットで再実行していない。
- 今回の配布版は実機未操作。所有者の実機テスト用。合成音声の可聴再生は[前回試験](testing/RESULTS_20261112_MIX7_SYNTHETIC_AUDIO.md)で未合格であり、通話安定性の受入れ完了ではない。

App Store/Play一般公開、mainマージは未実施。
