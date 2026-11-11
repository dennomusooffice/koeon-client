# TASK: 共通UIのTestFlight・GitHub配布

2026-11-11、#88、R5、担当Codex/所有者レビュー。所有者が最新UIのTestFlight/GitHub公開と外部テスター利用を明示許可。基準4ea0ad7、UI製品f4815d5。既存の未コミット文書は含めない。

## 要求・設計・依存

iOSは既存内部/外部グループへ配布し、必要なベータ審査を申請。Androidは既存GitHub prerelease経路へ署名APK/checksumのみ公開。App Store/Play一般公開、mainマージ、実機操作、新規テスター/公開リンク作成は対象外。

公開済みAndroid1.0.22(23)の本体PTT既定値変更7de4eea/0c1c9e5を統合して退行を防止し、1.0.23(24)へ更新。iOSは未使用の1.0(2026111133)をAppleで確認。保存済みOFF/権限/Floor/LiveKitは維持。UIの限定実機証拠は既存記録を引き継ぎ、配布版実機確認と区別する。

## 受入れ・STOP CONDITION

既定値統合後の両OS自動回帰、Android lint、parity、差分検査。clean隔離ソースで署名・版・entitlement・非debuggable・成果物hash検証。iOS候補後は同じSHA/treeから再構築してupload、Apple処理/既存グループ/外部状態を確認。Androidは既存ローカル配布経路（feature SHA）で候補検証後draft asset digestを照合し公開する。GitHub Actionsのmain限定経路は変更しない。秘密/生ログ/音声を公開しない。

STOPはSHA/版/hash/配信状態/制限をIssueと配信記録へ保存。外部審査待ちは利用可能と表現しない。取り消しが必要ならTestFlight build失効/GitHub配布取り下げを別判断、端末のダウングレードは強行しない。

## 結果

10eb3deからAndroid1.0.23(24) GitHub prerelease公開、iOS1.0(2026111133) Apple VALID・外部IN_BETA_TESTING/既存外部グループ関連付け確認。内部はREADY_FOR_BETA_TESTING/全ビルドアクセス設定だが明示関連付け未確認、Appleが手動追加を拒否したため残件として区別する。自動回帰・署名/hash・既存補助検査の古い固定値/試験用aliasによる不一致は[配信記録](../RELEASE_20261111_CONSOLE_UI.md)参照。実機操作/mainマージなし。
