# 固定LCD・透過キー版の限定配布

2026-11-12、#88 / PR #90 / [TASK](development/CONSOLE_UI_REFINEMENT_RELEASE_TASK.md)。配布ソース `4d268c4042929bf280221f17208cc6aea60ece82`、tree `410a3d12194c1da5ca4bc18fe6d8b6107582b4a8`。既存の未コミット文書を除いた隔離ソースを使用。

- Android **1.0.24 (25)**: [GitHub prerelease](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.24-25) 公開済み。署名、版、非debuggable等の候補検証に成功。APK SHA256 `3c16bc80afb9cfac035d4afe20368fcb57225f2dd250a983996c0d534d2e961d` とGitHub asset digest一致。
- iOS **1.0 (2026111136)**: 外部TestFlight署名候補成功。Appleアップロードと処理・配布状態は確認中。
- 自動回帰: Android223件成功/0失敗、Lint成功。iOS280件中279成功/1専用SFU skip/0失敗。配布版の現行文字列と版番号に合わせたparity gate成功。
- 先行ローカル候補で、OPPO/moto/iPhoneの標準縦画面のPTT表示、OPPOのCH0→12→0切替中のメイン維持を確認。配布番号そのものの実機再試験は実機許可期限終了により未実施。
- [MIX7音声試験](testing/RESULTS_20261112_MIX7_SYNTHETIC_AUDIO.md): 複数端末のPTT制御表示は成功。合成音声の可聴再生は未合格で、音声ルートと音量の切り分けが残る。配布を通話安定性の受入れ完了とは扱わない。

App Store/Play一般公開とmainマージは未実施。TestFlightの最終状態、Issue/PR更新は追記する。
