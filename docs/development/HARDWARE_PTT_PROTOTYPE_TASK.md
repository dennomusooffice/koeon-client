# TASK: 本体ボタンPTTの配信版確認・iPhone試作

- Issue: [#80](https://github.com/dennomusooffice/koeon-client/issues/80)、R4→限定R5試作。
- 担当Codex / レビュー所有者 / 2026-11-11 / 状態: 限定実機検証済み、残件あり。
- 基準SHA: b35d6d59923fbfdc7b1242ab25304ce7b3bd10bb。最新試作ソース8abd801fbecf08e939749e1c2d9d65c131a37af3、iOS開発版1.0(2026111083)。接続実機のみ導入、公開/TestFlight未配信。
- 実機はiPhone17 Pro MaxとOPPO A79 5G。初回2026-11-10 23:02:37–翌00:02:37 JST、追加許可23:51:29–翌00:51:29 JST。公開配信は対象外。

## 要求・範囲

Android公開APKに既存音量トグルが含まれるかを版/hash/コードで確認する。iPhoneではAction buttonから送信を切り替える公式App Intentを試作し、参加済みセッションの背景・ロック中操作を目指す。Android背景キー取得、端末再登録、サーバー変更、公開配信は今回の実装対象外。実機操作は上記対象・時間枠のみ。

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

### 実機で判明したダイアログ阻害の修正設計（2026-11-10）

許可済み60分枠でiPhone 17 Pro Maxへ1.0(2026111080)を導入。利用者がロック中のAction button長押しを実施し、成功応答ダイアログを閉じるまで次の長押しで停止できないと報告した。`ProvidesDialog`による成功応答を原因として、開始/停止/終了処理中は表示なしの`IntentResult`を返す。無効設定/開始不能だけ説明付きエラーとし、送信を作らない。既存の開始音と送信上限、Floor/OS認可は維持する。受入れはSDKビルドと再導入、ロック中の長押し2回でダイアログ操作なしに開始/停止できること。長押し/音声の実確認と診断状態は別記録。時間枠終了時は操作を止め、未確認分を残す。

2026111081でダイアログ解消と前面の実ボタントグルを利用者確認。ただし背景/ロックで相手に音声が届かない。診断の最終開始要求にはApple didBegin/didActivateがなく、Control START未発行。要求直後のIntent完了がOSの実行期間を終える仮説を限定検証する。開始だけ最大3秒の非ブロッキング待機で同じattemptの送信開始までIntentを保持し、停止は即応答。期限/取消は同じattemptだけ終了し、古い待機が新しい送信を止めない。OS認可を代替せず、拒否・開始不能をエラーとして返す。受入れは冷起動拒否の回帰、全体回帰、署名build、背景・ロック実ボタンの再検証。仮説不成立の場合は原因未確定として残し、無期限待機やOS迂回はしない。

延長枠の切り分けでは既存FieldJournalの許可フィールドに、Intent判断/拒否理由、Apple送信失敗のenumコード、開始待機終了を記録する。自由文エラー・識別子・音声を追加しない。既存の24時間/容量上限と文字種フィルタを使用し、OS拒否とアプリのreadiness拒否を区別する。診断UIにも既存のApple失敗コードとblock reasonを表示する。

以下の初期自動結果は実機試験前の記録。最新の実機結果は末尾を参照。実装/自動検証/配信/実機/mainマージは別に記録する。

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

### 限定実機結果（2026-11-10/11 JST）

- Android OPPO A79 5G: 導入済み公開検証版1.0.19(20)を確認。TOGGLE・前面READYでADB音量短押し注入によりTALKING→次の短押しでREADY。人の本体ボタン押下と音響は未確認。初回BUSY_REMOTEは前提未成立として除外。OSロック確認後の音量キー注入では復帰時READY。画面の前後比較だけで瞬間的な送信不存在まで保証しない。現行実装は前面限定で、背景/ロック対応PASSとはしない。
- iPhone17 Pro Max / iOS26.6.2: 既存登録を維持し1.0(2026111080)→81→82→83を同一bundleへ開発導入。元の導入版は1.0(2026111002)。初版77fd3a5、83は8abd801。公開配信と区別する。
- 1080: ShortcutsにIntent実表示、単一アクションの試験Shortcut作成、Action button割当を確認。opt-in OFFでは拒否、ON後は背景TRANSMITTING→IDLEを診断確認。しかし成功ダイアログが次の長押し停止を阻害し、利用者がダイアログを閉じると停止できた。
- 1081: 成功ダイアログ除去。利用者が前面で実ボタンの長押し開始/再長押し停止を確認。背景/ロックでは音声未到達。診断は背景REQUESTING_FLOOR後にERROR/IDLE、前面では3回のTRANSMITTING→IDLE。
- 1082/83: 開始Intentを最大3秒だけ維持して開始状態を待機。83は分類診断追加。82の初回自動操作は前回エラーのOK表示に遮られており、有効な送信試行として数えない。
- 1083 背景待機後: CONNECTION_NOT_READYで拒否。接続直後の背景ShortcutはUTC14:56:43開始要求→44音声ACTIVE/TRANSMITTING→49停止要求→50 IDLE。ダイアログなし。
- 1083 ロック実ボタン: 利用者は初回失敗、2回目以降は意図した開始/停止と相手への音声到達を確認。診断は14:58:01 NOT_JOINED、14:58:11/26開始要求→12/27 TRANSMITTING、14:58:21/33停止→IDLE。全てlifecycle BACKGROUND。試験後のOS isLocked=trueも確認。単一機種・限定反復の成功であり一般安定性の保証ではない。
- 初回拒否の直前に既存のforeground recoveryによる再接続/セッション再構築を観測。NOT_JOINEDを送信認可迂回で解消しない。復元中の初回開始、長時間ロック後、冷起動、通信断、着信、経路変更、60秒上限の実ボタン受入れは残件。
- 1080送信中のUI sourceはREADY、同時期journalはTRANSMITTING。UI取得鮮度/表示の不一致は原因未確定。以降はjournalと利用者聴取を分離して判定。
- 自動: 最大3秒待機版は261件中260成功・専用SFU1skip・失敗0。83の署名実機SDK build、codesign検証、Intent metadataのPTT systemProtocol/background実行/alwaysAllowedを確認。
- 最終ソース8abd801でも261件中260成功・専用SFU1skip・失敗0（2026-11-11 00:02 JST）。
- 5分ロック後も利用者は初回失敗、後続2回成功と報告。OSロックを前後とも確認。UTC15:04:00はCONNECTEDのまま開始判断した直後にRECONNECTINGとなりERROR、安全停止。15:04:08の追加操作はCONNECTION_NOT_READYで拒否、09に再接続。13→20、34→39の2回は背景TRANSMITTING→IDLE。ユーザー報告の操作回数と診断の要求件数は区別する。Apple stopのrawValue 5はcleanup時のtransmissionNotFoundであり、開始拒否の原因とはしない。初回失敗は古い接続状態からの復帰問題として#80に残し、ボタンごとのRoom再接続や認可迂回は追加しない。

Android背景方式の追加質問には、AccessibilityService入力と明示許可、前面POWER ON後のmicrophone foreground service維持を候補として説明。キー配送とマイク権限は別問題で、OPPO消灯中/省電力挙動の実機検証、Play申告・説明/同意条件が必要。Android製品実装には追加していない。
