# 3色エリア罫線版の限定配布

2026-11-13、#88 / PR #90 / [TASK](development/CONSOLE_AREA_RELEASE_TASK.md)。製品ソース `d487fd00c90a02cbf0f6cf65a027446a848a5bc9`、tree `e48497070aaf8d9ae2f58b7a8c4c834244e6130a`。INDICATOR（ピンク）、CHANNEL SELECT（水色）、ACTION（白本体で黒、黒本体で明るい中性線）の見出し＋水平罫線を追加。PTT/RXランプをそれぞれTX/RXメーターと同じ行に揃えた。

- Android **1.0.26 (27)**: [GitHub prerelease](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.26-27) 公開済み。署名候補・parity検証成功。APK SHA256 `7e920a61ccb53e5da0b26e246865e328a056761584250355b96aaa970805713a` とGitHub asset digest一致。
- iOS **1.0 (2026111138)**: 同一SHAで外部TestFlight署名候補・再ビルド・Appleアップロード成功。IPA SHA256 `aef34717a649f5c34820526cac5665d9296ba9e9de2ec373a6b8b7cb8c30e14d`。Apple processing `VALID`、内部/外部とも `IN_BETA_TESTING`。既存内部2群・外部1群すべてのbuild関係を再取得して確認。外部ベータ審査申請済み、自動通知ON。
- 変更時検証: Android Kotlin compile、iOS Simulator Debug build、parity、diff check成功。前回までの通話自動テスト結果は引き継ぐが、この配布版では再実行していない。
- 配布版の実機レイアウトと音声可聴再生は未確認。前回の[合成音声試験](testing/RESULTS_20261112_MIX7_SYNTHETIC_AUDIO.md)は可聴再生未合格。今回の配布を通話安定性受入れ完了とは扱わない。

App Store/Play一般公開、mainマージは未実施。
