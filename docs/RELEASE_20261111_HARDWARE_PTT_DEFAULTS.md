# 本体ボタンPTTの既定ON配信

2026-11-11、所有者のビルド/配信依頼。Issue #80 / PR #87。配信ソース`0c1c9e5065e00142d52331810010ec71b58e901b`、tree`453cc60c7f27cb91724ee9b1f3a3e5a9466a595b`。08aaab3を基準に、Bluetooth未解決試作を含めず隔離したclean checkoutから作成。

## 変更

未設定時のiOS Action button PTTをON、Android本体音量長押しPTTをTOGGLE・背景設定をONに変更。保存済みOFFを上書きしない。OSのアクションボタン割当とAndroidユーザー補助許可は自動変更しない。送信権限/Floor/LiveKit/音声所有権/停止上限は不変。

## 検証

iOS268件中267成功・専用SFU1skip。初回は旧既定OFF期待が2件失敗し、既定ONでも未接続送信を拒否する期待へ更新、保存済みOFF維持を追加して再検証。Android212件成功、Lint成功。版番号・機能契約成功。両OS署名/版/接続先検証成功。実機試験は行っていない。

汎用publication-safety scanは既存の`emulator-throughput.py`のAndroidエミュレータ標準ホスト表記をprivate IPとして検出して停止。基準08aaab3と同一の試験コードであり私用接続先ではないことを個別照合した。スキャン全体PASSとは記録しない。今回の差分は手動で秘密/音声/私有証拠の不在を確認。既存の署名候補検証を省略していない。

## Android

1.0.22（23）、[GitHub Release](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.22-23)として公開済み。既存と同じ署名鍵、non-debuggable/版/endpoint/署名/compiled resource検証PASS。APKとSHA256SUMS.txtのみ添付、公開asset digest照合済み。既存同様の検証用prereleaseで、Google Play配信ではない。

APK SHA256: `3ea662fd10a60521ae8ba5b1f360be500e830334ea1cbefee65cd69b8418ba00`。

## iOS

1.0（2026111107）、external audienceの候補検証後、同じSHA/treeから再構築してAppleへアップロード成功。署名/provisioning/production APNs/PushToTalk/Associated Domains/runtime framework検証成功。API鍵の一時コピー、archive、IPAはpipelineが削除。

候補IPA SHA256: `05291caef7a5cf719c534fd6c9531de48929a12bcf66884f45d4ef28cdf8121f`。
アップロードIPA SHA256: `f7808c96cda8b716b561e500c001a1e91d5ca461127a478a46fc8996ac5a6d68`。

Apple processing=VALID、internal/externalともIN_BETA_TESTINGを確認。既存内部2グループ・外部1グループで1107のbuild関係を再取得して確認した。既存直近5版の暗号化申告falseと今回の非変更を照合して申告、日本語テスト案内を登録、外部ベータ審査申請を実施。自動通知ON、テスター/公開リンクの新設なし。

## 制限・引継ぎ

Android消灯中の本体キー未到達は未解消。OPPO点灯ホームの長押し開始/停止は前段ptt07の受入れで、今回APKの実機受入れではない。iOS背景受信/長期待機/割込みなどの残件も引き継ぐ。Bluetooth再生ボタン対応を本配信に含めず、#86は未解決。App Store/Google Play一般公開・mainマージ・端末への自動導入は行っていない。

[設定・操作: iPhone](ACTION_BUTTON_PTT_GUIDE.md) / [Android](ANDROID_VOLUME_PTT_GUIDE.md)
