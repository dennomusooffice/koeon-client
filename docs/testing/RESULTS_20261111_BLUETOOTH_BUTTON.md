# iPhone Bluetooth再生ボタンPTTの限定試験

追跡: [Issue #86](https://github.com/dennomusooffice/koeon-client/issues/86)。2026-11-11 JST、担当Codex、実ボタン操作と聴取報告は利用者。

## 範囲と条件

- iPhone 17 Pro Max / iOS 26.6.2 (23G90)、導入済みKOEON 1.0 (2026111102)。TestFlight 1103の試験ではない。
- コード調査HEAD: `08aaab36ba68c45687300b195b7a5cdc5ab822db`。1102は[既存試験記録](../development/HARDWARE_PTT_BACKGROUND_TASK.md)参照。
- ヘッドセットのメーカー・型番・FWは不明。利用者がマルチファンクションボタンを短押し。接続時の音声経路はBluetoothHFP。
- 許可枠は当初08:47–09:17、利用者の30分延長により09:47まで。過去のAndroid操作許可は転用しない。
- 目的は入力配送の切り分け。製品変更・ビルド・配信・Android操作は含まない。実測と次の設計候補を記録して停止する。
- 音声の保存なし。診断は通常のアプリ内書き出しを使用し、公開するのは時刻・状態・件数のみ。

## 比較結果

| 条件 | 利用者の結果 | 証拠・限界 |
| --- | --- | --- |
| Headset ON、KOEON前面、CONNECTED/READY | 短押しで無反応 | 09:07:46の診断は送信可能、開始・音声有効化時刻なし。アクセサリ適用Enabled、Handsfree開始/終了0/0 |
| Headset OFF、チャンネル参加継続、未選曲 | 無反応 | この段階では再生対象未準備の影響を除外できない |
| POWER OFF、ホーム、未選曲 | 無反応 | ヘッドセット非対応の証明にはしない |
| POWER OFF、ミュージックで曲を選択 | ボタンで再生/一時停止できる | ミュージックを背景へ移しても操作できる。通常メディアキー配送の対照成功 |
| 選曲後、Headset ON、再参加、KOEON前面READY | 無反応 | 09:19:08の診断はCONNECTED/READY、送信可能 |
| 上記から参加を維持しHeadsetだけOFF | 音楽の再生/一時停止に戻る | 設定による処理先の変化を確認 |
| Headset ONへ戻し、KOEONをホーム背景へ | 音楽操作になる | 背景の保存値true。その後の診断でもAccessory Enabled、Handsfree0/0。背景中のOS内部配送先を直接取得したわけではない |
| Action buttonで送信/停止した直後のMFB | Action buttonは開始/停止成功、MFBは音楽操作 | 利用者報告。09:33:35–09:33:42の完了済み送信試行と09:33:42のFloor解放・control ENDを診断で照合。相手の聴取は今回未確認 |

ロック・消灯中のBluetoothボタンPTT成功、相手への音声到達、他ヘッドセット対応は本記録で確認していない。

## 切り分け上の注意

初期はヘッドセット設定の画面表示OFF。設定操作後は保存値ONでも画面表示OFFの期間があった。RootViewが観測するsessionと、設定を持つpushToTalkの変更通知が直接つながっていないことが有力な説明で、表示値だけをOS適用結果と扱わない。

開始時にはruntime_restoring/RECONNECTINGが継続していた。通常POWER OFF後も参加ボタンが無効だったため、送信停止状態でアプリを再起動。08:58:34にBluetooth/CONNECTED/READYへ復帰した。復元待ちの原因は未確定で、ボタン配送とは区別する。

09:20:01に短い開始/停止記録があるが、入力元はdeveloperRequest、Handsfree件数0/0。設定操作の画面スクロールと重なっており、ヘッドセット起点の証拠から除外した。マイクunmute/talkingなし、終端cleanup PASS。以後はPTT領域を通る画面スクロールを避けた。

最初に取得したfield-journal-exportは前日23:35 JSTの古いファイルだったため、今回の証拠から除外。通常のCopy Field Diagnostic JSONが出力する新規snapshotのcapturedAtを照合した。

## 現時点の結論と設計候補

一般的な再生/一時停止操作は届く。一方、今回のヘッドセット・OS・1102では、アクセサリ設定EnabledだけではPTTへのイベント到達を確認できない。「設定ONにすれば解決」「この機種は非対応」「OS不具合」とは断定しない。

次の製品変更候補は、設定表示の更新、OS適用状態と実イベント受信の分離、要求世代を持つ設定適用、アクセサリ診断の通常snapshotへの追加。通常メディア操作の受信を、そのまま背景マイク利用の許可として扱わない。

別の静的所見として、PttRequestGate.didBeginはbeginRequested以外からの開始を停止する。OS/アクセサリ起点の開始を受理する経路は、opt-in・認可・有効なチャンネル・同一世代・停止中拒否を明示して設計する必要がある。今回のHandsfree0/0を説明する原因としては未立証。単に全ての予期しない開始を許可してはならない。

公式根拠: [Appleのアクセサリ対応説明](https://developer.apple.com/forums/thread/804205)、[requestBeginTransmittingの背景実行条件](https://developer.apple.com/documentation/pushtotalk/ptchannelmanager/requestbegintransmitting(channeluuid:))。

## 終了状態

09:35 JST頃、許可期限前に実機操作を終了。09:34:38の最新snapshotはCONNECTED/READY、Bluetooth、PTT IDLE、終端cleanup完了。前面復帰後のcurrent TX欄は初期化されていたため、最後のAction button試行はlastCompletedTxAttempt/lastCompletedReleaseで照合した。最後のMFB試験後のHandsfree件数は再取得しておらず、前段の0/0を最終試行の測定値として流用しない。

Headset PTT Buttonは試験前のOFFへ戻し、画面0と保存値falseを確認。POWER ONと登録を維持し、Action buttonの既存PTT割り当て・opt-inは変更しなかった。アプリを終了しない設定で試験用Appium sessionをDELETEして終了。一時設定コピーを削除。製品修正・新規ビルド・配信・マージは行っていない。今回の許可枠を次回へ延長しない。

今回の比較では、直前にAction buttonでPTTを使うだけではMFBの配送先はPTTへ切り替わらなかった。次は設定/適用/実イベントを同じ時刻で診断できる最小変更と、OS起点開始の安全な受理設計を別TASKで用意する。今回の結果だけでMPRemoteCommandCenter追加による背景PTTの実現や、このヘッドセットの完全非対応を断定しない。


## 追加調査・修正（09:40–10:10 JST許可枠）

所有者が原因調査・実装修正を許可。以降は前節の調査のみの範囲を拡張した。

- 開発版2026111104、ソース `0a726e374d9b15a9ce8d79c78125508ffb28fdad`。設定表示通知、OS起点開始のopt-in/送信適格性ゲート、チャンネル整合性、アクセサリ診断を修正。270件中269成功・1スキップ。ローカル実機導入のみ、TestFlight未配信。
- 利用者の1104前面MFB短押しは「無反応」。09:52:54 snapshotは設定ON/適用ENABLED/JOINED/CONNECTED/READY/IDLE、handsfree 0/0、source unknown。状態ゲート修正だけではAVRCP配送は解決しない。
- 1104ソースに隔離fixtureを使用した無音声プローブ2026111105を一時導入。Appleチャンネルのアプリ側Control Beginはbegin/end 1/1、activation 1（09:57:08）。録音・音声送信なし。物理ボタン試験の回答は得られておらずNOT_RUN。これをヘッドセット非対応の証拠にしない。
- 10:06–10:07頃、Leave Probe操作後に通常1104へ更新復元。POWER ON、Headset PTT Button OFFをUIで確認。Action button割り当ては変更なし。Appium sessionを終了。復元後の音声疎通・READY診断再取得は未実施。プローブを端末に残していない。

### 原因説明の訂正と採用設計

[Apple DTS回答850343](https://developer.apple.com/forums/thread/850343?answerId=909261022#909261022)と[856176](https://developer.apple.com/forums/thread/856176?answerId=915584022#915584022)は、現行PushToTalkのアクセサリ設定がAVRCPを直接取り込まないこと、アプリ側Now Playingイベント処理が必要なことを説明している。初期調査の「一般再生ボタンがアクセサリ通知へ直接配送される」という読み方を訂正する。今回の無通知と整合するが、手持ちヘッドセットで代替方式が成功した証拠ではない。

DTSに従い、Now Playingのplaying状態を設定し、リモートコマンドのハンドラを返した後で通常PTT開始を要求する限定試作へ変更。Now Playing状態とAVAudioSessionのactivationは別で、音声所有権は引き続きApple PushToTalkに任せる。サイレント音源再生、音声session直接activate、CoreBluetooth権限追加は行わない。

- 利用者がBluetooth接続後にHeadset設定を明示ONした場合のみメディア入力を有効化。アプリ再起動・経路離脱でメモリ上のarmingを失い、自動再接続のみでは再有効化しない。既存設定がONならOFF→ONが必要で、画面にも説明する。
- playは開始、pause/stopは停止、togglePlayPauseは反転。待機中のstopから送信開始しない。連続playで再反転しない。停止・rearming中の新規開始を拒否する。
- Floor/送信適格性/同一runtimeを確認する既存経路に入力する。ハンドラ登録世代と遅延開始世代を確認し、OFF・取消後の古い入力を拒否する。
- タイトルは固定KOEON PTT。診断はarming/有効状態/件数/最後のコマンド分類のみ。音声や利用者・チャンネル情報をNow Playingへ出さない。
- 音楽操作との競合、OS/ヘッドセットが自動発行するplayと人の押下を完全には区別できない限界は残る。既に有効な接続での自動playは実機受入れが必要。設定ONを無条件に安全と宣言しない。

### 受入れ・残件

自動試験ではコマンド分類、停止中拒否、遅延開始、OFF/ONを跨ぐ取消、二重開始抑制を確認する。実機では前面→背景→ロック→5分待機、相手の聴取、Music競合、再接続、自動play、電話割込みを確認する。コマンド受信と実音声到達を別々に判定する。

Now Playing追加版は実機未導入・未検証であり、BluetoothボタンPTTの問題は未解決として#86を開いたままとする。受入れ条件が満たされるまで一般/内部/外部配信へ進まない。次の実機検証には新しい有効な時間枠が必要。Android変更、サーバー変更、マージはなし。

Now Playing追加後の最終シミュレータ回帰: 272件中271成功・1スキップ・失敗0。実機成功を意味しない。診断fixtureは製品targetに含めていない。
