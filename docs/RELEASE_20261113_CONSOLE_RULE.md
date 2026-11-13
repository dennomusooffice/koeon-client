# パネル罫線仕上げ版の限定配布

2026-11-13、#88 / PR #90 / [TASK](development/CONSOLE_RULE_RELEASE_TASK.md)。製品ソース `4cec07e251a967f7c62b7587d26ee552be05d606`、tree `011322ff7bc0424e1021cd1b57681dae9878d0f7`。3色エリア罫線を3pt/dpの丸端グラデーションと控えめな上面ハイライトに変更し、区画名を本体シルク印刷調の中性色へ戻した。PTT/CH操作・認可と音声処理には変更なし。

- Android **1.0.27 (28)**: [GitHub prerelease](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.27-28) 公開。署名候補とparity検証成功。APK SHA256 `a17c1c180dc6bde10333f5efa8dfbb53532b01dca18acf61087e68dc4ced586e` とGitHub asset digest一致。
- iOS **1.0 (2026111301)**: 同一SHAで外部TestFlight署名候補・再ビルド・Appleアップロード成功。IPA SHA256 `345e976d46413d53328339c2a756015146215b9041731218c6922e066329a07c`。Apple processing `VALID`、内部/外部とも `IN_BETA_TESTING`。既存内部2群・外部1群すべてのbuild関係を再取得して確認。外部ベータ審査申請済み、自動通知ON。
- 変更時検証: Android Kotlin compile、iOS Simulator Debug build、parity、diff check成功。前回までの通話自動テスト結果は引き継ぐが、この配布版で再実行していない。
- 配布版の実機レイアウトと音声可聴再生は未確認。前回の[合成音声試験](testing/RESULTS_20261112_MIX7_SYNTHETIC_AUDIO.md)は可聴再生未合格。今回の配布を通話安定性受入れ完了とは扱わない。

App Store/Play一般公開、mainマージは未実施。
