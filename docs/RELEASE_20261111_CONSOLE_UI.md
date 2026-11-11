# 共通Console UIの配信記録

2026-11-11、所有者がTestFlight内部/外部とGitHub配布を明示許可。#88 / PR #90 / [配信TASK](development/CONSOLE_UI_RELEASE_TASK.md)。mainマージ、App Store/Play一般公開、実機操作なし。

## ソースと自動検証

- source: `10eb3de3cdd55207b5b3d16ea33ff4d357937bfd`
- tree: `58c1615a5ff4ca6fc1b9097d27cf9254d69cfe05`
- UI製品f4815d5に公開済み本体PTT既定値7de4eea/0c1c9e5を統合し、保存済みOFFを維持。Android配布番号のみ1.0.23(24)へ更新。
- Android222件成功/失敗0、Lint成功。iOS280件中279成功/専用SFU1skip/失敗0。parityと差分検査成功。署名候補の版/entitlement/実行時設定/署名/アイコン検証成功。
- 補助release-security試験は16件中15成功、旧1.0.9固定の期待値1件が失敗。現在版のAPK識別/非debuggable/署名検証は成功。既存の古い試験契約との不一致として区別し、全検査PASSとはしない。
- publication-safetyは既存試験用のAndroidエミュレータhost aliasをprivate IPとして検出。該当8行の5ファイルは公開済み0c1c9e5から変更なし、全検出値が同じ合成試験用aliasであることを照合。生ログ/端末識別子/秘密/音声は公開しない。

## Android

**1.0.23 (24)**。既存ローカル経路でclean隔離ソースから署名候補を作成し、draftへAPKとchecksumのみ添付。アップロード後のGitHub asset digestとローカルSHA256一致を検証してprerelease公開。

- [GitHub Release](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.23-24)
- APK SHA256: `6826254d1d069934b2be426410f24fb016458267b6e801ccc895f8fca611dcfc`
- 1.0.9以降と同じ署名鍵。前回公開1.0.22(23)から単調増加。

## iOS

**1.0 (2026111133)**。external audienceで署名候補成功後、同一SHA/treeから再構築してAppleアップロード成功。一時署名素材/archive/IPAはpipelineで削除。

- アップロードIPA SHA256: `628cbd1525b247cf5e54eeb580b65f176575d2e1120865752084cfa4379a7316`
- Apple processing=VALID、external=IN_BETA_TESTING。ベータ審査申請成功後、既存外部1グループのbuild関係を読み取り照合し、外部テスター利用可能を確認。自動通知ON、新規テスター/公開リンク作成なし。
- 直近5版の暗号化申告falseを照合し、暗号化依存/方式に変更がないため引き継いだ。UI変更と確認ポイントをテスト内容へ登録。
- 最終再取得でinternal/externalともIN_BETA_TESTING、既存内部2/外部1グループすべてのbuild関係を確認。内部は一時READY_FOR_BETA_TESTINGで、全ビルドアクセスグループへの手動追加はAppleに拒否されたが、その後の自動反映を読み取り確認した。内部の配布残件は解消。

## 実機証拠・残件

ui19 OPPOとiOS開発版の[限定UI検証](testing/RESULTS_20261111_CHANNEL_NUMBER_LED.md)を引き継ぐ。本配布版そのものの実機再試験は未実施。iPhoneは検証終了、Android追加15分枠も終了しており操作していない。長時間/背景受信/全Bluetooth/全端末/極端な文字拡大は未受入れ。Bluetoothボタンの試作を含む既存制限は#86、通話課題は既存Issueを継続し、UI公開を音声全条件の安定性証明としない。

PR #90は#87のブランチを親とするdraft、main未マージ。#88を部分受入れのまま自動closeしない。
