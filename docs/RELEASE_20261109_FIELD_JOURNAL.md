# 診断履歴強化版の配信（2026-11-09）

利用者の明示依頼によるローカルビルド・配信。PR #64、Issue #50/#56/#65。mainへのマージや実機受入れを意味しない。

ソース: `bc735ba3488a34542f6c6b67689b783235427054`、tree `aa929d71891a71b9aaf6e168e930d1feabfb8342`。未コミット変更なしの隔離checkoutから作成。

## Android

- **1.0.18 (19)**: [GitHub検証版](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.18-19)。公開済みprerelease。
- 正式署名、non-debuggable、版番号、接続設定、iconのcandidate検証成功。
- APK SHA256: `3b5040f30a7440bc4d8008d1f45dab734f1d1f3c0031c632325e9a6ea63a07d6`。
- `koeon-android.apk`と`SHA256SUMS.txt`を添付。GitHub側のasset digest/sizeを照合して公開。
- draft作成後のtag lookupは404だったため、release一覧の一致するIDとexact target commit・asset digestを確認し、そのdraftを公開した。重複releaseは作らない。

## iOS

- **1.0 (2026110909)**。external audienceでアーカイブ・署名/provisioning/entitlements/runtime/版番号検証・AppleアップロードPASS。Apple processing=`VALID`、internal/external=`IN_BETA_TESTING`を再取得して確認。既存内部2グループ・外部1グループへ割当済み、自動通知有効。ベータ審査申請APIを実行後、外部テスト可能な状態を確認した。
- 署名済みIPA SHA256: `fb7df761d95acb8b6c95df1c3dfc49d9c3384c5691f5e74f5848f31fc71d31f7`。一時キーコピー・archive・IPAはpipeline完了時に削除済み。

## 内容と検証範囲

最大24時間/32MiBの私有診断ジャーナル、非同期export、Mac回収とlease相関、初回PCMの重複防止。iOSは正常ENDでLiveKit購読を維持し、次受信の不要なtrack再構築を避ける。異常復旧・世代フェンスは保持する。

Android234件/Lint/build、iOS333件（2skip/失敗0）、Python4件成功。5台×3巡の15送信/60受信UI、iOS12受信世代PCM、両OS616件/28lease突合を確認。SIM5の統合候補はiOS0908/630512f・Android19/7e3fb4cであり、最後のログフェンス修正は単体回帰まで。配信候補を実機合格として扱わない。

実24h soak、全機種の可聴性、実機背景/Bluetooth/車載、実サーバーログ照合は未完了。詳細は[検証結果](testing/RESULTS_20261109.md)。

## ログ回収

症状発生後、POWER操作前にDiagnostics → **Export 24-hour Field Journal**。Androidは保存先を選択、iOSは完了後 **Share Field Journal**。時刻・端末・送受信方向を添えて管理者Macへ回収する。音声そのものは記録しない。手動Copy Field Diagnostic JSONも引き続き利用可能。診断原本は公開Issueへ貼らず、[回収・突合手順](../scripts/field-diagnostics/README.md)に従う。
