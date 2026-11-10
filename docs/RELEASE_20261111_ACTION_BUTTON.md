# Action button PTTのTestFlight配信記録

2026-11-11。所有者の依頼による内部・外部TestFlight向け配信。App Store一般公開・mainマージ・Android一般公開ではない。

## iOS

- 版: **1.0（2026111103）**。
- 配信ソース: `2ab1584b6e1618bb7f9d82518df6e7c19da7886a`。
- tree: `18be67ef78dd2fde98db13bdb97270104dd0dfde`。
- IPA SHA256: `52cba4846bdfd569e7799486d5c7d2a82cbe9cffcf64a84142cf4bf4923764f8`。
- external audienceの候補を隔離clean checkoutで検証後、同じSHA/treeから再ビルドしてアップロード成功。署名、provisioning、版/接続先、production APNs/PushToTalk/Associated Domains entitlement、runtime framework検証PASS。一時credentialコピー/archive/IPAは既存pipelineが削除した。
- **Apple processing=VALID、internal/external=IN_BETA_TESTINGを確認済み**。既存内部2グループ（全ビルドアクセス）と外部1グループで1103への関係を読み取り照合した。ベータ審査申請API成功後、外部テスト可能状態を再取得した。自動通知ON、テスター/公開リンクの新設なし。
- 暗号化の申告は既存直近5版のfalseを照合し、暗号化方式/依存/entitlementの該当差分なしを確認して引き継いだ。日本語のテスト内容に設定手順/初回復帰/開始音までの待ち/残る背景受信検証を登録。buildからgroupへの読取りは403だったため、groupからbuildへの関係APIで3グループすべてを検証した。

## 修正と受入れ

Action buttonをKOEONの直接App Shortcutへ割り当て、アプリ側opt-inをONにして接続済みから利用する。成功ダイアログなし、長押しで開始・次の長押しで停止。背景復帰は総8秒・同一scope・最大1回認可付きresume、Floor/Apple音声所有権/60秒上限を維持する。

背景待機後の開始直後に切断すると、マイクOFF未確認と復元の早期終了が重なって以後送信できなかった。d92c98dで再接続後の停止再確認、216a947で同じ復元処理内の停止確認待ちを追加。267件中266成功/専用SFU1skip。旧1101の待機後失敗を記録し、1102で通常背景初回と停止から5分14秒後の最初の操作を確認。後者は開始直後切断から同じIntent内で復帰して送信/停止、入口からTRANSMITTINGまで4673ms。利用者は初回成功と開始音までの待ちを報告した。

この実機は開発版1.0(2026111102)/製品216a947で、TestFlight配信版1103の実機受入れとは区別する。開発署名のAPNsはdevelopment。背景iPhoneへのOPPO音声不達、前面でPCM受信を観測しており、production配信版の背景受信は残件。長時間・割込み・全機種の安定性は未保証。

## Androidの関連作業

一般配信はしていない。内部1.0.19-ptt07（20）/製品f65c62fで、約600ms押したままで単発トグル、短押しは解放時の音量調整へ変更。212件/Lint/署名成功。OPPO A79 5Gの点灯ホーム背景で実ボタン開始/停止、iPhone前面のPCM受信を確認。点灯ロック成功と消灯非成立は前段短押し版の結果で、最新長押し版の点灯ロック/消灯は再試験未実施。

両端末のPTT設定を残す利用者指定。最終READY確認、UI helper削除、自動操作session終了。実機枠は08:23 JSTまでで、枠内に操作を終了した。

## 利用案内・引継ぎ

- [iPhoneマニュアル](ACTION_BUTTON_PTT_GUIDE.md)
- [Androidマニュアル](ANDROID_VOLUME_PTT_GUIDE.md)
- [詳細TASK](development/HARDWARE_PTT_BACKGROUND_TASK.md) / [配信TASK](development/ACTION_BUTTON_TESTFLIGHT_RELEASE_TASK.md)
- [Issue #80](https://github.com/dennomusooffice/koeon-client/issues/80) / [PR #83](https://github.com/dennomusooffice/koeon-client/pull/83)
- [サーバーLP改修依頼 #41](https://github.com/dennomusooffice/koeon/issues/41)。本番LP自体は変更していない。
