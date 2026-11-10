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

ptt04の通知列では画面dumpの実行に対応してUNBOUND/DESTROYED/CONNECTEDが反復した。標準UiAutomationは既存AccessibilityServiceを抑止するため、これを製品の不安定性と混同しない。[公式FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES](https://developer.android.com/reference/android/app/UiAutomation#FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)。試験専用の無ネットワーク/無マイクInstrumentationでこのflagを使用し、通常UI階層をローカル私有領域にだけ保存する。製品への組込みなし、許可実機だけ、取得は最大10000node/深さ64/処理15秒、終了時helper削除。これで接続表示・設定OFF/サービスOFF試験を再実行する。従来dump取得中の未接続表示は実際に一時解除された状態の可能性が高く、前面へ戻した後の停止も自動化による解除と区別が必要。

### 観測方法の修正と停止受入れ 2026-11-11 03:35 JST

- 64f0aec / 1.0.19-ptt04(20)を指定OPPOへ導入。207件/Lint/署名成功。サービス分類診断で標準UI dumpごとのUNBOUND→DESTROYED→CONNECTED反復を観測した。新UI probe（要求permissionなし、FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES）で取得すると「OSサービス: 接続済み」が表示され、設定OFF試験中の不要な解除通知もなくなった。表示不一致を製品の接続不安定性として扱わない。d92c4f5の状態再構築時の設定引き継ぎは別のコード上の欠落を修正している。
- 設定OFF: Home背景から仮想USB音量キーで18:30:03.111 UTC TRANSMITTING。アプリ前面へ戻して設定OFF後、06.419 RELEASING、07.044 IDLE。背景へ戻してキー2回を追加しても新しいTX/STARTは0。UI probeの取得によるUNBOUNDはなく、設定OFFの停止として区別できる。
- OSサービスOFF: OS設定画面（アプリ背景）で仮想キーから18:33:29.462 UTC TRANSMITTING。通常スイッチをOFFにすると33.979 RELEASING、33.980 UNBOUND、33.981 DESTROYED、34.684 IDLE。解除後の仮想キーで新規TXなし。全TXがBACKGROUND_OR_LOCKED/CONNECTED/audio READY。実内蔵キー/音声聴取の証拠ではない。
- ptt04では追加boolが既存診断whitelistにより除外され、reasonだけ保存された。候補ptt05は5個のboolキーだけ型付きで許可し、保存と文字列/未知項目拒否の回帰を追加。208件成功、Lint/署名ビルド成功、SHA256 `54a945a7dce8299fd256fcf172183ab00a45d13efd5993e2a21f91c419ea08ad`。候補のみ未導入で、上記実測はptt04。
- 新UI probeは非表示nodeも返すため、最初の診断回収で非表示の古い保存名を選択した。回収済みコピーを端末の同じ場所へ戻し、SHA256一致を確認。対象の可視性条件を修正して今回の診断を回収し、今回の一時ファイルだけ削除した。生のUI/診断は保護領域のみ。今後の選択はvisible=trueを必須とする。
- 現在OPPOはPOWER ON、背景設定ON、TOGGLE、専用OSサービスOFF、UI probe導入済み。次は消灯キー試験を新観測方法で再実行し、最後に背景設定/サービス/POWERと音量を復元、helperを撤去する。iPhoneは87の5分超初回Intent成功1回を維持し、実ボタン/反復/音声到達と通常unlock後の復元が残る。

### ptt05追加受入れと朝の再開（2026-11-11）

- 1.0.19-ptt05(20)、source7af7c4dを指定OPPOへ更新導入。新観測方法でOSサービス接続済みを確認。Home背景で800ms長押し・上下同時押しに対するTX開始は0。
- 消灯10秒/30秒の両条件で、最初の仮想USBキー前はPowerManager Asleep、押下後はAwake。初回のTXはなく、2回目の音量DOWNで開始、3回目の音量UPで停止。端末journalは18:38:04.732/46.152 UTCにTRANSMITTING、09.790/51.343にIDLE、全TXがBACKGROUND_OR_LOCKED/CONNECTED/audio READY。設定/サービス/所有ラッチのboolも正しく保存された。画面復帰後の開始・停止は成立するが、消灯中初回と本体内蔵キーの成立を保証しない。
- POWER OFF中の仮想キーでは新規TXなし。18:41:22.909 UTCに再接続後も背景設定ON/サービス接続trueを診断とUIで確認。d92c4f5の設定引き継ぎ修正をこの境界で確認した。
- iPhone87の長時間ロック後の直接Siriフレーズは今回もIntentイベントなし。Android送信に対応する新しいiPhone RXイベントも取得できず、音声到達の証拠にはしない。
- OPPOは背景設定OFF、音量PTT OFF、POWER OFF、専用OSサービスOFFへ通常UIで復元。通話speaker3/メディアspeaker1/着信speaker16を確認、消灯30000ms/stay-on 0、Accessibility一覧は試験前と一致（空値とnullは正規化）。元々のHeadset設定は変更しない。UI probe撤去成功、端末の試験階層ファイルを削除。通常UIで許可した「制限付き設定」はallowが残り、許可後の独自アプリ情報に取消メニューは表示されなかった。特権で取り消して完全復元と偽らず、この差分を残す。専用サービスは無効、foreground serviceも不在。内部版ptt05は端末に残す。
- 06:44 JST、利用者がiPhoneを解除し検証継続を依頼。87のCONNECTED/READYとロック解除を確認し、アクションボタンを元のボイスメモからKOEONの直接App Shortcut「送信を切り替える」へ通常UIで割り当てた。310秒待機の試験Shortcutは割り当てていない。実ボタン長押しを自動再現できないため、ロック→長押し→発話→再度長押しを利用者へ依頼中。結果はまだ未確定。元の07:00 JST終了条件を延長と解釈しない。

### iPhone実アクションボタン受入れ（06:49–07:00 JST）

- iPhone17 Pro Max / iOS26.6.2 / 1.0(2026111087)、source a8d67c1。直接App Shortcut割当後のロック直後、21:48:53 UTCに初回ENTRY/復元READY/STARTREQUESTED、54秒TRANSMITTING、次の長押し21:49:15 STOPREQUESTED/IDLE、16秒audio INACTIVE。利用者は「初回から成功しました」と報告。
- 端末へのアプリ/設定操作を行わず、前回停止から5分以上待機。利用者の次の実ボタン長押しで21:55:07 UTCに初回ENTRY/RECONNECTING/復元BEGIN、08秒CONNECTED/READY/STARTREQUESTED、09秒TRANSMITTING。次の長押し16秒STOPREQUESTED/RELEASING、17秒IDLE、18秒audio INACTIVE。取得時OS locked=true。前回停止から初回操作まで5分52秒。利用者が「初回で相手に届きました！」と音声到達を明示確認した。初回復帰問題はこの端末・ビルド・試験条件で改善を実証した。復元中には既存Apple stopエラー分類も記録されるが、その同じ初回Intent内で復帰・送信・停止が成立した。
- 利用者は検証後もPTT割当を維持することを明示選択。opt-in/直接App Shortcut割当を残した。通常ロック解除後、今回作成した待機付き「KOEON Toggle Lab」だけ削除し、一覧から消えたことを確認、KOEONへ戻した。他のショートカットは削除しない。
- 07:00 JSTで実機操作枠終了。最後の画面再取得と自動操作セッション終了を行うコマンドは開始前の期限guardに拒否され、実行されなかった。最終READYの再取得やセッション手動終了を実施済みとはしない（既存sessionは無操作timeout、アプリ終了しない設定）。以後、許可の更新なしに実機へアクセスしない。
- iPhoneの実ボタン初回・5分超後・相手の聴取・次押下停止は今回確認した範囲で成立。長時間反復/他端末/通信損失全般の安定性や公開配信受入れを保証しない。Androidは仮想USBキーによる背景入力・停止安全性までで、本体内蔵キーと音声聴取、消灯中の初回成立は未確認。Issueは部分検証のままOpen、PRはDraft/未マージを維持する。

### 再発調査TASK（2026-11-11 07:30 JST）

利用者は通常背景（非ロック）で送信開始エラーを報告。正確な表示文は未保存。iPhoneもOPPOと同じ08:23 JSTまで診断・再現試験を明示許可。内部/外部TestFlight配信は調査・必要修正の受入れまで保留。

87の診断で22:22:06.314 UTCにCONNECTEDからSTARTREQUESTED、4ms後RECONNECTING、続いてREQUESTING_FLOOR→ERROR→RELEASING→ERROR。07.027に復元BEGIN、07.077にNOT_STARTED。07.663に接続復帰しても11/14/18秒の次押下がREARMING/SETTLINGで停止。Floor解除完了07秒、control END完了は記録なし。前面復帰後には正常runtimeを復元できた。原因候補は、切断中のマイクOFF拒否による停止未確認と、再接続時の停止再確認不足。現時点ではコードと時系列の推論であり、合成回帰で切り分ける。

要求/範囲: 接続切断と開始が競合した後、Floor解除とマイクOFFを再確認して安全に復帰する。復帰確認前の新規TX拒否は維持。実装前設計: 接続復帰時に未確認のマイクOFFだけを有限回再試行し、保有Floor/実行中取得/停止処理の確認を省略しない。Intentは総8秒・同一scope・最大1回session復元の範囲で停止完了と再接続を待つ。新規自動送信、無期限retry、音声保存、認可やApple音声所有権の緩和は対象外。

受入れ: 切断中のOFF失敗→再接続後OFF成功を合成試験で再現し、停止確認と次操作可能を検証。OFF再失敗、Floor解除失敗、進行中取得、取消/期限/別scopeは拒否を維持。指定実機で背景の初回開始・次押下停止を確認し、人の音声聴取と診断を分離。STOP: 原因/修正/テスト/実機結果をIssue/PRへ記録、または試験枠終了（未完了を残す）。担当Codex、レビュー所有者。

合成回帰で原因候補を再現: 切断相当のmicrophone OFF失敗→Floor解除→再接続の順で、修正前はcleanupIsConfirmedがfalseのまま（追加1件が失敗）。修正後は再接続時に保有leaseなし/取得・終端処理なし/押下なしを確認し、OFFを1回再確認。失敗すればERROR維持、成功時だけ停止完了を通知する。Floor解除失敗は再接続でも解除済みにしない。Intentは既存8秒内で再接続と独立したApple停止gateの完了を待ち、2回目のsession復元は行わない。iOS267件中266成功・SFU専用1skip、失敗0。実機で同じ競合を通った受入れは未実施。

修正d92c98dを開発版1.0(2026111101)として指定iPhoneへ更新導入。22:38:44 UTC、通常背景・非ロックで初回ENTRY/復元BEGIN→45秒READY/STARTREQUESTED→46秒TRANSMITTING、次押下51秒STOPREQUESTED/IDLE、52秒audio INACTIVE。利用者は「バックグラウンドでのアクションボタンは初回で成功」と報告。開始直後の切断競合を同じ試験で通ったわけではなく、今回の音声聴取も明示回答ではない。

OPPO ptt05の本体音量短押しを利用者が実施。22:40:29.574 UTC BACKGROUND_START、30.516 TRANSMITTING、次押下40.082 RELEASING、40.691 IDLE、全てBACKGROUND_OR_LOCKED/CONNECTED/audio READY。実ボタンで背景開始/停止が成立した新証拠。利用者は開始音を確認したが、iPhoneには声が聞こえなかった。iPhone1101の同時刻の新受信journalはなし。音声到達・消灯/ロックの本体入力は未達/未確認であり、前面受信側との比較を次に行う。OPPOの開始前はPOWER ON/接続済み（利用者操作で以前の復元時から変更）、背景設定OFF/専用OSサービスOFF。試験用に背景設定/音量TOGGLE/専用OSサービスを通常UIで有効化した。

1101の待機後再発（22:44:40 UTC、前回停止から5分49秒）: STARTREQUESTED直後RECONNECTING→ERROR。今回のOFF再確認により43秒にIDLEへ戻ったが、復元BEGIN直後に停止未確認としてruntime復元が先に終了しており、43.829のPTT_INTENTはreason NONE / operational ERROR。利用者もエラーを報告。従ってd92c98dだけでは初回背景復帰は未解決。

追加設計: Action button起点の同じruntime復元処理内で、停止確認を最大3秒待つ。保有leaseやマイクOFFの確認を省略しない。SDK再接続時の有限OFF再確認により停止確認が成立した後で、既存の認可付きresumeへ進みoperational ACTIVEまで完成させる。Intent総8秒・最大1回resumeは維持、取消/POWER OFF/取得未完了/lease未解除/期限切れ時は送信しない。READY診断は実際の復元完了と区別し、拒否理由にoperational/restore状態を含めてNONE誤表示を防ぐ。

追加順序修正のiOS回帰267件中266成功・1skip、失敗0。実機で切断競合を通す検証は次の開発版で実施する。1101の長期待機は失敗のまま記録し、直後成功だけで置き換えない。

### Android長押しへの仕様変更TASK（2026-11-11 利用者追加指示）

目的: iPhoneと同じ「長押しで開始・次の長押しで停止」に統一。前面/背景の本体音量キーを対象、既存Headset操作は変更しない。600ms以上を長押しとし、OS repeat到着時に1回だけトグル、repeatが届かない場合は解放時の継続時間で判定する。短押しはPTTせずOSの通常音量調整APIで1段階調整する。キー注入や音声再生による背景権限生成はしない。

共通の2キー有界gateでdownTime/時刻/世代/取消/同時押し/重複UPを検証。停止は開始適格性低下後も所有中なら優先。設定OFF/leave/サービス停止で未完了入力を無効化。画面消灯のOPPOキー非配送は別のOS制約として維持。受入れ: 599/600ms境界、repeatで二重反転なし、UP fallback、短押し音量のみ、同時押し/取消/設定変更/失効後に送信なし、前面/背景で同じ判定、既存Floor/音声所有権/60秒上限を維持。自動テスト・Lint・署名ビルドと指定OPPOの限定実機受入れまで。公開Android配信は対象外。STOPは結果/制約の記録または08:23実機枠終了。担当Codex、レビュー所有者。

Android短押し版の比較結果: iPhoneを前面にすると22:47:24 UTCにRX_PCM/ACTIVE、28秒DRAINING→29秒IDLEを観測、利用者はホーム背景の音量短押し成功と回答。OPPO消灯後の実ボタンは送信開始せず、押下後もPowerManager Asleep。画面だけ点灯（解除なし）後は22:49:36.467 BACKGROUND_START→37.401 TRANSMITTING→39.619 RELEASING、iPhoneは37秒RX_PCM→41秒IDLE。利用者は「画面が点灯していれば使える、消灯していたら使えない」と確認。背景/点灯ロックの本体キー成立と、消灯時非成立を分離。背景iPhoneへの不達は受信側前面で改善し、背景受信の別残件とする。

長押し変更の自動回帰・Lint・Debug APK成功。600ms境界/repeat単発/解放fallback/取消/同時押し/短押しvolume/前面50往復を検証。消灯時のキー配送を変える機能は追加していない。内部署名版ptt06を準備し、実機確認はこれから。

利用マニュアルは[ACTION_BUTTON_PTT_GUIDE](../ACTION_BUTTON_PTT_GUIDE.md)へ整備。内部/外部TestFlight未配信と待機後再発を明記した検証中の手順であり、配信完了後の対象ビルド追記が必要。サーバーLP改修はkoeon Issue #41へ登録済み。本番LP自体は変更していない。

長押し版ptt06は利用者が短押し音量のみ/長押しPTTを成功と回答。ただし押したまま実行する動作を希望し、解放時fallbackだけでは操作感が揃わないと追加指定。押下ごとに最大2個の600ms timerを持ち、期限時に同じキー/downTime/世代/現在適格性を再検証して1回だけtoggleする。UP/取消/設定OFF/サービス停止ではtimerを取消。OS repeatとtimerの両方が来ても共通gateのfiredで重複拒否する。実ボタンを押したままで開始/停止し、解放後に反転しないことを追加受入れにする。

押下継続timerを前面/背景に接続し、自動テスト212件・Lint/Debug APK成功。repeatなし/UPなしで600ms時点の1回発火、599ms時点の未発火、解放時の二重反転なし、短押し/設定取消、OS repeatとtimer競合を検証。ptt07を内部署名し実機受入れへ進む。

1102（製品216a947）待機後受入れ: 前回停止22:51:10 UTCから5分14秒後、22:56:24にENTRY/STARTREQUESTED直後RECONNECTING→ERROR。今回は同じIntent内で停止確認/認可付き復元を完了、28秒READY/STARTREQUESTED、29秒TRANSMITTING。次押下35秒STOPREQUESTED/IDLE、36秒audio INACTIVE、locked=false。入口→TRANSMITTINGは4673ms。利用者は初回成功、振動後に少し待って開始音と報告。振動を送信開始としない案内をマニュアルへ追記。単回限定成功で広い安定性は未保証。内部/外部配信は[別TASK](ACTION_BUTTON_TESTFLIGHT_RELEASE_TASK.md)へ進む。

ptt07（製品f65c62f、内部署名SHA256 87714ac18feafecbed4f10421153a9d7416967f0f89d386ff29c8a70d165e66c）をOPPOへ導入。利用者が画面点灯・ホーム背景で押したままの開始/停止を成功と回答。23:10:34.570 UTC BACKGROUND_START→35.865 TRANSMITTING、次押下40.418 IDLE。iPhone1102は36秒RX_PCM→41秒IDLE。実ボタンの動作確認とPCM受信証拠で、聴取の詳細を別の記録と混同しない。ptt07の点灯ロック/消灯再試験は未実施。消灯の制約は前段実機結果のまま残す。

利用者がAndroidも長押しPTTを残すことを明示選択。背景設定/音量TOGGLE/OSサービス/POWER ONを維持。iPhoneも従前指定のopt-in/Action button割当/POWER ONを維持。最終の両端末CONNECTED/READYを確認し、OPPOのUI helperをアンインストール（Success）、画面timeout30000msを確認。iPhone自動操作sessionをDELETE完了（アプリ終了しない設定）。実機操作を終了。AndroidのHeadset設定は変更せず、試験中の利用者の音量短押しを元の推測値へ上書きしない。
