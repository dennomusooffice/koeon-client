# TASK: 本体ボタンPTTの配信版確認・iPhone試作

- Issue: [#80](https://github.com/dennomusooffice/koeon-client/issues/80)、R4→限定R5試作。
- 担当Codex / レビュー所有者 / 2026-11-10 / 状態: 実装中。
- 基準SHA: b35d6d59923fbfdc7b1242ab25304ce7b3bd10bb。試作ビルドは既存Debug 0.1(1)、未配信。
- 今回の追加依頼でAndroid配信版確認とiPhone試作を許可。実機対象・時間枠、配信は未指定。

## 要求・範囲

Android公開APKに既存音量トグルが含まれるかを版/hash/コードで確認する。iPhoneではAction buttonから送信を切り替える公式App Intentを試作し、参加済みセッションの背景・ロック中操作を目指す。Android背景キー取得、端末再登録、サーバー変更、公開配信、実機操作は今回の実装対象外。

## 設計・依存

- PushToTalkTransmissionIntent（iOS17.4+、製品target18）をアプリ内に配置。openAppWhenRun=false、authenticationPolicy=alwaysAllowed。設定で明示opt-in、既定OFF。ユーザーがShortcutをAction buttonに割り当てる。
- AppとIntentが同じMainActor上のsessionを利用。画面生成を通信処理の条件にしない。冷起動時の自動送信/新規参加は行わず、準備未完了なら再操作を求める。OS既存復元は妨げず、古いIntentを復元後へ持ち越さない。
- 開始は実request gateがidleかつ既存canPressPTTを満たす場合のみ。Apple begin要求をIntent内から直接出す先行Apple要求経路とし、既存prearmでFloorを取得し、delegateのApple開始・音声activationと合流してLiveKitへ進む。FloorとApple音声activation両方を必要とする既存条件を維持。
- 停止/準備中取消を開始条件より優先。release/rearm中は新しい送信を予約しない。UIタッチgateとは分離し、実gateを正本とする。開始watchdogは3秒、連続送信は既存60秒上限。watchdogはattempt世代で照合し、終了/リセットで解除。
- opt-in取消はIntent由来の送信/待機を停止。停止、切断、権限失効、チャンネル変更後に自動再開しない。既存安全停止とRX維持、音声非保存、LiveKit限定を維持。
- バックグラウンド実行可否やロック時の音声所有権はSDKビルドだけでは証明できない。実機受入れ前は試作と明示。

## 受入れ・STOP CONDITION

1. APKの版・hash・設定UI・音量キー入力経路を確認。配信済みと実機確認を区別。
2. Intent metadata抽出、iOS build、gateの開始/停止/取消/失敗/連打/再arm/無効設定の自動試験。
3. 未接続/POWER OFFで送信要求を作らず、開始待ち再操作で取消、古いwatchdogが次の試行を停止しない。
4. 実機手順: 前面で設定ON・参加→Shortcut登録→前面/別アプリ/ロック直後/5分ロック各開始停止、Floor競合、通信断、着信、経路変更、60秒停止、POWER OFF後の拒否。新たに対象・時間枠を確定して実施。音声は保存しない。
5. STOP: 照合・試作・自動結果・未検証点をIssueへ記録して提出。実機枠なしで実機合格を主張しない。

## 結果・引継ぎ

作業中。実装/自動検証/配信/実機/mainマージは別に記録する。

### Android公開成果物の照合

2026-11-10取得: [公開検証版1.0.19(20)](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.19-20)、ソースd38a07db65483387d582f686aee91eee0f5de491、公開2026-11-09。APIの`latest`は正式版1.0.9(10)を返すため、プレリリースを含む一覧から選択。

APK SHA256: `537bf0f08d97de5aeef3f3215c4c863f96ade950e8d75074f3ca50c40874236a`。公開digestと一致。apkanalyzerのmanifestは1.0.19 / 20。DEXでMainActivity.onKeyDown/onKeyUp→IntercomSessionManager.onHardwareVolumeKey→HardwareVolumePttGate→HARDWARE_VOLUME_BUTTONのpttDown/pttUpを確認。設定のHardwareAndGainSettingsと「Hardware Volume PTT · foreground only」も収録。公開ソースSHAでも同じUI/経路を照合。

**判定: 配信APKへの収録PASS、実機での作動NOT_RUN。** 設定TOGGLE・前面・参加済み・送信権限・音声READYが条件。上下どちらかの短押しを離すと切替、長押し/リピートでは切り替わらない。標準OFF。画面ロック/別アプリ中は現行機能の対象外。端末に同版が入っていることは未確認。

### iPhone試作の設定手順・制限

1. KOEON設定の「アクションボタンPTT（試作）」をON。
2. Apple「ショートカット」で新規ショートカットを作り、KOEONの「KOEON送信を切り替える」アクションを追加。
3. iPhone設定→アクションボタン→ショートカットで作成したものを選ぶ。
4. KOEONを前面でPOWER ONして参加、送信可能状態を確認してからロック。長押しで開始要求、再度長押しで停止/取消。

OSへ開始要求を出したことと実際の送信開始を区別し、Intentの返答は「開始を要求」とする。音声発行はFloor準備とOS音声activationの両方が必要。接続未完了/POWER OFFでは開始要求を残さず拒否。冷起動からの自動送信はこの試作では非対応。背景で生きている接続済みsessionが最初の実機受入れ対象。

AppShortcutsProviderによるSiri定型フレーズの自動登録は範囲から外した。初回ビルドでSSUアーカイブの非致命的エラーを観測し、Action buttonに不要な自動フレーズ登録を除去。通常のApp IntentをShortcutsで選択する方式。意図せずユーザー/チャンネル名や本文をIntent metadataへ入れない。

### 最終自動結果（2026-11-10）

- iOS27.2 arm64 Simulator: 260件、259成功・専用SFU1skip・失敗0。追加5件はopt-in/readiness、準備中取消、終了処理中の連打、冷起動session拒否、Apple先行activationでもFloor準備前にはマイク公開しないこと。既存prearm取消・権限・60秒上限等の回帰を含む。
- Simulator/実機向けDebug build PASS。実機向けは署名なし、未導入・未配信。App Intent metadataのPushToTalkTransmission識別、openAppWhenRun=false、明示alwaysAllowed、パラメータなしを両SDKで確認。
- 初回はx86_64向け依存モジュール不足でbuild失敗。実行対象に合わせONLY_ACTIVE_ARCH=YESとして再実行しPASS。初回SSU非致命的エラーは自動フレーズProvider除去後に再発なし。
- 対象iOS差分のgit diff --check PASS。公開資料に秘密/音声/個人識別子/生診断なし。
- 実機操作、ロック中音声、Shortcutアクション一覧への実表示、配信、mainマージ: NOT_RUN。試作は自動検証済みだがロック対応の製品受入れ完了ではない。
- 実機受入れに必要な対象機種/日本時間枠を利用者へ質問済み。まず本体Action button搭載iPhoneとAndroidの現在の配信版を対象に、上記手順で確認する。

再実行: `xcodebuild test -project ios/KOEON.xcodeproj -scheme KOEON -destination 'platform=iOS Simulator,id=<許可されたSimulator>' -derivedDataPath <専用一時path> -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO`。固定Package.resolvedを使い、実機とは区別する。

### 公式仕様の根拠

- [PTT用Intent](https://developer.apple.com/documentation/appintents/pushtotalktransmissionintent)
- [ロック中も許可するIntent認証ポリシー](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy/alwaysallowed)
- [アクションボタンへのShortcut割当](https://support.apple.com/en-gb/guide/iphone/iphe89d61d66/ios)

これらはAPI・設定の根拠であり、KOEON実機での成功証拠ではない。
