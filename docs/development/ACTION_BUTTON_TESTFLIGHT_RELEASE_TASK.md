# TASK: Action button PTTのTestFlight配信と利用案内

2026-11-11。所有者が内部TestFlightに加え外部テスターへの配信、利用マニュアル、サーバーLP改修のGitHub登録を明示依頼。担当Codex、レビュー所有者。Issue #80 / PR #83。App Store一般公開・Android公開・mainマージ・サーバー本番変更は対象外。

## 要求・設計・依存

既存のAction button opt-in/直接App Shortcutと初回復帰修正をRelease構成へ含め、production APNs/PushToTalk entitlementと署名/版番号/正確なSHAを既存ローカル配信pipelineで検証。外部対象で候補を検証後、同じSHA/treeから再ビルドしてAppleへアップロードする。既存内部/外部グループを確認して配信し、必要なBeta App Reviewを申請する。審査待ちを配信済みとしない。公開リンク新設やテスター追加はしない。

既存の未コミット文書は混入させず、隔離されたclean checkoutを使う。credential/生診断/音声は公開しない。Floor/音声所有権/取消/送信上限は既存のまま。

## 受入れと現在の証拠

- iOS216a947（停止再確認d92c98dを含む）: 267件中266成功/専用SFU1skip。開発版1102で通常背景初回の開始停止、停止から5分14秒後の開始直後切断→同じIntent内の認可付き復元→送信開始/次押下停止を診断と利用者回答で確認。後者は入口から送信状態まで4673ms。
- iPhone開発版はdevelopment APNs entitlement。OPPO送信のiPhone背景受信不達があり、前面ではPCM受信を確認。production配信版での背景受信受入れとは区別して残件化する。全条件の安定性を宣伝しない。
- ローカル署名設定check、Appleアクセス、1.0(2026111103)未使用のpreflight成功。候補/アップロード/Apple processing/グループ配信は未実施。
- [利用マニュアル](../ACTION_BUTTON_PTT_GUIDE.md)を整備。設定/長押しトグル/開始音/復帰時の待ち/無効化/制約を案内。
- LP改修を[サーバーIssue #41](https://github.com/dennomusooffice/koeon/issues/41)へ登録済み。LP本体未変更。

## STOP CONDITION

配信対象SHA/版/候補検証/Apple処理/内部・外部状態をIssue/PR/配信記録へ明記し、マニュアルに配信状態を反映。Apple審査/環境で停止した場合は具体状態と再開手順を残し、配信済みとしない。実機は指定iPhone/OPPOの08:23 JST枠まで、以後は端末操作を停止する。配信作業の時間枠とは混同しない。
