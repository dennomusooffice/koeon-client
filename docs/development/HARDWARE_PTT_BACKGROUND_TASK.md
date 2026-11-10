# TASK: 初回背景復帰PTTとAndroid背景入力

- Issue #80 / Draft PR #83 / R3復帰修正・限定R5背景入力試作。
- 担当Codex、レビュー所有者。2026-11-11、基準893b45c（製品コード8abd801）。
- 利用者が自律修正・複数方式の試行を明示許可。指定iPhone17 Pro MaxとOPPO A79 5G、2026-11-11 07:00 JSTまたはCodex利用枠残量50%まで。開始時残量83%。時間/枠の上限到達は作業停止であり目標達成ではない。

## 要求・対象外

iPhoneはロック/背景待機後の最初の明示操作から送信開始・停止できるようにする。Androidは前面以外でも本体ボタンでPTTを切り替える方法を実機で比較し、成立する方法を限定統合する。単なるAPI説明や後続押下だけの成功を完了にしない。

公開配信、mainマージ、他の実機操作、サーバー変更、再登録、OS権限迂回、音声保存は対象外。試験用の設定とhelperは終了時に復元する。

## 現状・原因の証拠

iOS2026111083は5分ロック後の最初のIntentが古いCONNECTEDを見て開始判断し、直後にRECONNECTINGとなって安全停止。別の初回はsession再構築中のNOT_JOINED。再接続後は実ボタンと音声到達が成功。最大3秒の開始待機だけでは接続復帰を解決しない。

Android1.0.19(20)の既存Activity音量入力は前面限定。microphone/mediaPlayback foreground serviceは既存。入力取得と背景マイク権限を分離して検証する。

## 設計・依存・信頼境界

- iPhone: まず接続喪失/復帰と既存の単一復元処理を検証。現在の明示Intentだけに有効な期限・世代・scopeを持たせ、接続失敗を観測した場合のみ認可済みsessionを再構築して有限回試行する。正常なPTTごとの無条件Room再接続は禁止。復帰中の再操作は取消、期限/POWER OFF/設定OFF/チャンネル変更後に古い要求を再送信しない。開始待機3秒と送信60秒上限は維持。復帰の総期限と回数はコード変更前に追記する。
- Android第1段階: ネットワーク/マイク/音声権限を持たない独立AccessibilityService helperでvolume DOWN/UP/repeat/取消の配送を測る。observe（非消費）とconsumeを比較し、前面/別アプリ/ロック/消灯を区別。window内容は取得せず、非音量キーは記録/消費しない。OS設定は通常UIで明示有効化し、特権shellで許可を書き換えない。
- Android第2段階: 観測結果から方式を選定。AccessibilityService、MediaSessionの実メディアキー、OEM本体キーを比較し、音量イベントの偽装や常時無音再生で権限を作らない。OPPOで成立する場合のみ、既定OFF/用途説明/ユーザー設定付きで既存sessionとFloor gateへ接続。送信権限・音声focus・foreground serviceが準備できていなければ拒否する。新規参加/停止アプリの無条件起動はしない。
- 診断は分類・件数・単調時刻・interactive/locked状態だけ。秘密/画面内容/音声なし。probeの保存件数は固定、counterは飽和。製品側は既存の24時間・容量制限を維持する。
- API/配信条件はApple/Android/Google Play一次資料で確認。Google Play適合の説明と実機技術成立は別判定。

## 受入れ・STOP CONDITION

1. iPhoneの古いCONNECTED/再接続/復元中を再現する回帰試験。取消・期限・別scope・古い完了通知・Floor拒否・音声所有権を検証。
2. 同一実機でロック直後、5分以上待機後、再接続直後の初回操作から開始/停止を反復。ユーザーの実ボタン/音声聴取と自動診断を区別し、初回失敗が残る場合は未達。
3. Androidの入力配送を各状態で測定。成立方式を統合した場合は既定OFF/設定取消/サービス停止/長押しrepeat/連打/POWER OFF/ロックを試験。キー注入と実ボタン、状態遷移と音声到達は別の証拠。
4. 関連ビルド・ソースSHA・自動結果・実機結果・制約・復元をIssue/PR/TASKへ記録。AndroidでOS/機種制約が残る場合は実測を伴う代替案と必要条件を示す。
5. 完了はiPhone初回問題の修正・検証とAndroid解決策の実測具体化。期限や利用枠到達では完了扱いにせず、未達を引き継ぐ。

## 検証結果・引継ぎ

### iPhone実装前の具体化

明示Intentの開始処理は単調時計で総8秒、現在の操作世代/ユーザー/チャンネルに限定。既に正常参加したことがある同一プロセスのPOWER ON sessionだけを復帰対象とし、冷起動の未参加状態を新規参加させない。進行中の復元があれば期限内で合流し、dirtyな背景runtime、接続非ready、または開始後の実接続喪失を観測した場合に限り、既存認可付きresumeを最大1回実施する。正常な連続PTTではRoomを再生成しない。

復帰の前に旧Floor/送信の安全停止を既存単一復元処理で確認する。再操作は準備中の操作を取消し、復帰だけが遅れて完了してもTXは開始しない。取消/期限/設定OFF/POWER OFF/ユーザーやチャンネル変更では同じattemptだけを終了する。最終canPressPTTとFloor/Apple activation条件を再確認してから送信する。各開始の待機は既存3秒以内かつ総期限以内。復帰の成否と回数を分類診断へ残す。操作世代gate、期限、scope変更、1回上限を製品で使用する純粋gateの回帰試験で確認する。

進行中。前段の限定結果は[試作TASK](HARDWARE_PTT_PROTOTYPE_TASK.md)。本TASKはその残件を対象とし、前段のSTOP CONDITIONを新しい目標の完了条件に流用しない。

### Android統合前の具体化（2026-11-11）

独立probeはOPPOの前面/ホーム背景/点灯ロックで、uinput仮想USB音量キーをobserve/consumeとも検出した。ADB input keyeventはこの配送を通らず0件。消灯からは最初の仮想キーが画面復帰に使用され、2個中1組のみ配送（配送時interactive=true）。本体キー/消灯継続中の動作を保証する証拠ではない。

限定統合は専用AccessibilityServiceを採用。既定OFFの背景音量PTT設定、用途・音量操作の変化・非音量キー/画面内容を保存送信しない説明と同意、通常OS設定への導線を設ける。背景設定と既存TOGGLE設定の両方、参加/送信権限/音声READY/実接続/稼働中foreground serviceを開始条件とする。サービスはウィンドウ内容/ジェスチャーを要求せず、非音量キーを即座に返す。製品へのキー注入・画面操作機能は持たない。

キーごとのDOWN/UP、downTime、repeat、取消、長押し期限を有界gateで管理し、完了した短押しだけを1回トグルする。設定OFF/切断/サービス停止は自身の送信を解除する。開始拒否でラッチを残さず、停止は開始条件の喪失後も優先する。Accessibilityがキーを消費した場合Activityへ重複配送されないが、サービス経由とActivity経由の入力gateは分離し、同じ送信を独立にラッチしない。既存Floor/pttDownとpttUpを利用し、背景からサービス/新規sessionを起動しない。

これは技術試作で、Google Play審査の適合確認・申告/掲載説明は公開前の別ゲート。isAccessibilityTool=false。[Android API](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService)、[Play利用条件](https://support.google.com/googleplay/android-developer/answer/10964491?hl=en)、[公式uinput試験経路](https://android.googlesource.com/platform/frameworks/base/+/HEAD/cmds/uinput/)を参照。MediaSessionは本来のメディアボタン用で、本体音量キーの代替と偽装しない。

### 中間検証 2026-11-11 00:55 JST

- iOS 1.0(2026111084): 265件中264成功、専用SFU1スキップ、失敗0。署名ビルド/指定実機への更新導入成功。
- 背景RECONNECTINGからショートカット1回で復元→TRANSMITTING、次の実行でIDLEを確認。Siri直接呼出しは送信せず、Siriの音声割込みとの区別が残る。
- 試験専用ショートカット「10秒待機→送信切替→5秒待機→送信切替」を通常UIで作成し、待機中にロック。15:55:15 UTCに背景RECONNECTING/復元開始、16秒にCONNECTED/STARTREQUESTED、17秒にTRANSMITTING、22秒にSTOPREQUESTED/IDLE、23秒にaudio INACTIVE。前後ともOS locked=true。初回Intentから開始停止した診断証拠であり、実アクションボタン/音声聴取の追加確認ではない。5分ロック後は次の試験。
- Android統合試作: 207単体テスト成功、Lint/Debug APK成功。内部署名APKは1.0.19-ptt01 (20)、SHA256 `686f94209a33a91793c3e93ea07d14ed6dad405a74c1733c0841ec2ed8241af9`。版名のみ内部Gradle initで上書きし、公開版のdefaultConfigは変更していない。製品統合後の実機検証はこれから。公開配信・マージなし。

### 起動経路の追加切り分け

5分ロック後のSiri経由ではPTT開始イベントがなく、一般ショートカットの起動条件とSiriの音声占有が混ざる。OSの通常unlock/アプリ起動はロック認証で拒否。Shortcutsの公開URLをno-activate起動で渡すと起動自体は受理されるが、PTT実行の証拠はない。拒否を迂回せず、AppShortcutsProviderから同じPushToTalkTransmissionIntentを直接公開する方法を追加比較する。アクションボタン設定時の選択肢にもなる既存Intentの入口であり、認可・opt-in・冷起動拒否・8秒上限を変更しない。フレーズにはアプリ名だけを含め、ユーザー/チャンネル情報をSiriパラメータへ渡さない。実ボタンとの同等性は別に判定する。[Apple App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)。

診断版2026111085は入口と早期拒否分類を追加し、署名ビルド・更新導入済み。ただしロック中の通常起動はOSに拒否され、実行診断は未取得。85を実機成功版として扱わない。

### 中間検証 2026-11-11 01:30 JST

- Android 1.0.19-ptt01(20)、ソース23aee76: KOＥONが対象MediaSessionであることを毎回確認して合成MEDIA_PLAY_PAUSEを入力。ホーム背景で16:13:11.449 UTCにTRANSMITTING、15.630にRELEASING、16.279にIDLE。消灯中は18.708にTRANSMITTING、22.909にRELEASING、24.124にIDLE。全TXイベントがBACKGROUND_OR_LOCKED / CONNECTED / audio READY。RX_READYは両回とも期待3/応答2。音声の聴取確認ではない。
- 音量キーの独立入力probeと既存メディアボタン経由の背景TXは個別に成立したが、統合版の音量→TXは未確認。OPPO Android14の「制限付き設定」が新サービスの有効化を拒否し、標準App Infoに許可メニューが出ない。アプリ情報再生成/通知のOK/メニュー操作でも同じ。権限の特権変更・インストーラー偽装・データを消す再インストールは行っていない。
- 独立probeは撤去済み。Android診断はアプリのExport操作で取得し、端末Downloadへ作ったコピーは削除。音声保存なし。背景試作の設定をOFFに戻してメディア入力を試験した。元々有効なHeadset PTT設定はそのまま。
- Android追加レビュー: OSサービスのonUnbindで直ちに自身のPTTを解除。POWER OFF/leave要求の時点で新しい背景開始を拒否し、認可済みjoinの完了後だけ解除。207件成功、Lint/Debug APK/署名候補成功。内部候補1.0.19-ptt02(20)、SHA256 `57273dbdd59a4e0c791a98fc399751813a181aa9431b6aba75787d777bf011c0` は未導入。
- iOS2026111086は85の分類診断と同じIntentへの直接App Shortcut入口を追加。署名ビルド成功、実行結果は未確定。84で確認したロック直後の初回成功を、85/86や5分ロック後の成功へ拡張しない。

### 復帰資格のscope確認

レビューで、初回復帰の資格が「このプロセスで一度正常接続した」というBoolだったため、要求された同一user/channel条件を資格自体にも持たせる。正常runtimeのサーバーJoin応答からuser/channelを保存し、Intent入口で現在scopeと一致する場合だけ復帰可能にする。明示leave/チャンネル変更で消去し、同一scopeの復元中だけ保持する。既存のサーバー認可は引き続き最終権威。異なるuser/channelと冷起動、leave後の拒否を純粋scope gateで確認する。

### 中間検証・復元 2026-11-11 01:42 JST

- iOSの同一scope資格を追加した回帰は266件中265成功、専用SFU1スキップ、失敗0。内部候補1.0(2026111087)の署名ビルド成功、未導入。端末は86であり、86の直接Siriフレーズでも実行診断は得られていない。これ以上、同じロック起動を繰り返して成功扱いにはしない。
- Android ptt01の前面音量トグルを再確認。16:35:04.209 UTCにFOREGROUND/TRANSMITTING、08.372にRELEASING、09.097にIDLE。サービス未有効のホーム背景では新たなREQUESTING_FLOOR/TRANSMITTINGは0。ホスト時刻で直前の停止を背景イベントと分類せず、端末journalのlifecycleで判定した。
- OPPOの制限付き設定はread-onlyのAppOps照合でignore。原因をインストール元や企業管理と断定していない。許可状態の書換えはしていない。
- OPPOは背景音量設定OFFをcheckable値で確認、既存音量トグルOFF、POWER OFFへ復元。メディア音量speakerだけ試験前1→試験後2だったため1へ復元。通話speaker3・ring speaker16は試験前後同じ。元々ONのHeadset設定は変更していない。画面消灯30000ms・stay-on 0・Accessibility設定の試験前一致・foreground service不在を確認した。音量の直接設定APIは反映されなかったため通常の音量ダウン1回でmusic speaker1を確認し、ring16/通話3も維持した。
- iPhoneのAction buttonは前段で復元した「ボイスメモ」のまま。新しい試験用Shortcut「KOEON Toggle Lab」は10秒待機/切替/5秒待機/切替。ロック解除ができないため、このShortcutの削除とアプリ内opt-in OFFのUI復元は未完了。86への更新で旧実行プロセスは終了し、その後の起動は未確認。Action buttonをそのまま試験押下しない。

次の実機受入れは、通常のロック解除後に候補87を起動して認可済み接続を成立させ、アクションボタンに直接App Shortcutを割り当て、ロック直後/5分以上後の最初の開始と停止を反復する。Androidは通常OS設定でサービスを許可できる条件を確認した上で、ptt02の本体音量キー→背景送信を実測する。OS認証/許可を迂回せず、一般的な安定性や音声聴取の成功を未確認のまま宣言しない。

### 再開・統合検証 2026-11-11 03:18 JST

- 再開時にiPhoneのロック解除を確認し、1.0(2026111087)、製品ソースa8d67c1を更新導入・起動。準備時にPOWER OFFを操作したため、最初の接続後の切断を不具合再現には数えない。18:02:46 UTCに再接続してCONNECTED/READYを確認した。
- 試験Shortcutを310秒待機→切替→5秒待機→切替に変更。18:03:04に開始し2秒後ロック、330秒後までOS locked=trueを55秒間隔で確認。18:08:17に初回ENTRY/RECOVERY BEGIN (RECONNECTING)、18秒CONNECTED/READY/STARTREQUESTED、19秒TRANSMITTING、24秒STOPREQUESTED、25秒IDLE、26秒audio INACTIVE。5分超ロック後の初回Intent成功を1回診断確認した。物理Action button、音声聴取、反復安定性は未確認。その後の通常unlockは拒否され、試験Shortcutは310秒待機のまま残る。Action buttonはボイスメモのままで押下していない。
- OPPOの許可経路を特定。標準ACTION_APPLICATION_DETAILS_SETTINGSはInstalledAppDetailsを表示し許可メニューがなかったが、通常設定→アプリ→アプリ管理→KOEONはSubSettingsを表示し「その他のオプション→制限付き設定を許可」が存在した。このUIから許可後、read-only照合でallowを確認。通常ユーザー補助設定で専用サービスを有効化しBound servicesを確認。特権による権限書換え・インストーラー偽装は不使用。[Googleの通常許可手順](https://support.google.com/android/answer/12623953?hl=ja)。
- Android 1.0.19-ptt02(20)、Android製品ソース8de81beを登録保持で更新導入。背景設定ON/TOGGLE/OSサービスON。初回のHome直後の試験は開始時journalがFOREGROUNDだったため背景開始の成功に数えない。
- Home移行後10秒待機し、仮想USB音量キー（uinput KEY_VOLUMEDOWN）で2回反復。18:15:47.935 UTCと57.571にBACKGROUND_START、48.921と58.524にTRANSMITTING、53.984と18:16:03.550にIDLE。全てBACKGROUND_OR_LOCKED/CONNECTED/audio READY。背景で音量キー入力から既存Floor/TX経路まで統合して開始・停止できた限定証拠。実内蔵ボタン/聴取確認とは区別する。
- 消灯10秒後の仮想キー2回では、初回に開始せず2回目にBACKGROUND_START (18:16:22.663)、23.656にTRANSMITTING。前面へ戻した後39.797にRELEASING、40.375にIDLE。2回の操作で開始・停止した成功ではない。先行probeの「初回が画面復帰に使用される」と整合するが、製品試験の画面電源状態は追加照合が必要。本体キー/消灯中初回の成立は未達。
- OSではBoundでもアプリUIが一時的に「未接続」を表示した観測があり、設定・診断の同期は追加確認する。現在OPPOの試験設定はONのため終了時復元が必要。今回の一時診断JSONは保護領域へ回収後、端末Downloadから当該ファイルだけ削除。音声保存なし。公開配信・マージなし。

### 設定表示の同期修正（実装前の限定設計）

POWER OFF/登録解除でSessionDiagnosticsを作り直す2箇所が、背景設定とOSサービス接続の実際の値を引き継がず既定falseに戻すことをコードで確認。参加状態と独立した設定・サービス状態が画面から欠落するため、この2値だけを実際のmanager状態から再構築する。送信所有ラッチは停止時falseのまま維持し、認可・入力資格・再接続処理は変更しない。受入れは回帰/ビルドと、OSサービス有効のままPOWER OFF→ON後も設定表示を維持し、設定OFFで以後の背景入力が拒否されること。先の一時的な未接続表示の全てをこの原因と断定せず、反映待ちも区別する。範囲外の設定整理へ進まず、これらの結果記録をSTOP CONDITIONとする。

実装d92c4f5、207件成功、Lint/署名ビルド成功。内部版1.0.19-ptt03(20)、SHA256 `0b47e75531cf148c680d9d260c21cc010767753239f74870a3e8d79423c58da1`を指定OPPOへ更新導入。接続後も設定ONは表示されるがサービスは未接続表示で、OSのBound servicesは専用サービスを保持。時間経過後も同じため、この修正で表示不一致全体が解消したとはしない。次はサービス接続/解除通知順序を分類診断で観測し、実入力と照合する。POWERサイクル、設定OFF/サービス解除時の停止試験はまだ未実施。

分類診断はCONNECTED/UNBOUND/DESTROYEDのサービス通知と、実managerの接続bool・設定bool・UI診断の接続boolだけを既存有界FieldJournalへ追加する。キー内容、画面内容、識別子は増やさない。STATEにはUIの背景設定/サービス/所有ラッチboolを含め、更新境界を観測する。入力処理の意味は変えず、通常UIでサービスを再接続した後に通知順と表示を比較する。
