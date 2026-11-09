# 車載音声互換性・環境②の検証（2026-11-10）

実装は [PR #71](https://github.com/dennomusooffice/koeon-client/pull/71)、設計・受入れは [#70](https://github.com/dennomusooffice/koeon-client/issues/70)。**車載機を通した音声の受入れは未完了**。専用車載画面、Telecom、車載ボタンの自動有効化は今回の実装範囲に含めない。

## 実装・候補

基準ソース `b35d6d59923fbfdc7b1242ab25304ce7b3bd10bb`。

- iOS: CarPlay/USB/有線/Bluetoothではspeaker優先とdefaultToSpeakerを外す。OSのPTT activationを維持し、強制的な音声出力変更は追加しない。
- Android: API31以降の通信device変更を監視し、選択済み外部経路を失ったTXを停止する。診断イベントのバッファとは独立して安全通知を渡す。Room/RXは維持し、TXを自動再開しない。
- 実装コミット時の検証はAndroid202件成功・Lint/build成功、iOS255件中254成功・専用1skip・失敗0。今回の端末試験はそれと別の証拠。

| 対象 | 候補と配布状態 |
| --- | --- |
| iPhone | 1.0（2026111001）。TestFlight VALID / INTERNAL_ONLY / IN_BETA_TESTING。内部2グループ、外部0。接続実機への更新を確認 |
| iOS Simulator | 同じソース・1.0（2026111001）、iOS27.0 |
| Android | 1.0.19（20）、正式署名した内部候補。実機・AVDへ登録保持で導入 |

Android候補APK SHA256: `d47fceec065aeb1b8b2a5b66e1c9c01e5f2827927504c1cde0b7813127ecc704`。同じ版番号の既存GitHub公開APKとは別成果物で、公開版を差し替えていない。外部TestFlight配信・mainマージも未実施。

## 条件と判定

許可枠は07:00 JSTまで、週次利用枠の残量5%未満でも停止。SIM5（Android14/15/16/17、iOS27）とiPhone/OPPO A79 5GのMIX7。任意追加機motoはPINロックのため参加させない。OPPOのpovo/LTE設定は維持した。車載自動playからの意図しないTXを避け、両実機のヘッドセットPTTをOFFにして試験した。

制御試験は有限PTT、受信側BUSY、終了後の全台READYを判定する。これだけで実音声の聴取成功とはしない。合成音声はAVDマイクへ注入し、受信PCMをメモリ上で照合する。受信音声はファイル保存しない。相関offsetは採取開始基準であり通信遅延ではない。

## 結果

| 試験 | 観測・判定 |
| --- | --- |
| MIX7制御 | OPPO/iPhone/Android15/16/17/iOS Simulatorの6送信、計36受信UI観測成功。送信終了後は全7台READY |
| Android14→混在6台 | 2回ともAndroid16で一時OFFLINE、他5台BUSY。全台READYへ復帰。**失敗を保持** |
| OPPO一時focus割込み | helperのOS focus取得成功。INTERRUPTED・送信不可、約10秒後の解放で自動READY |
| OPPO恒久focus割込み | 解放後もINTERRUPTED・再接続ボタン表示。設計上の明示復旧経路。再接続後の新規PTTで6台BUSY、全台READY |
| OPPO送信中の一時割込み | TALKING→INTERRUPTED・送信不可→READYを確認。helperは取得成功・解放済み。前面Activity切替でタッチ取消も起き得るため、通信device切断callbackの単独実証ではない |
| Android14→16合成音声 | 1,530,121サンプル、既知音声・順序一致を検出 |
| Android14→15合成音声 | 同時採取98,769サンプル、単独採取98,838サンプル、どちらも既知音声未検出。**既存#57の再発** |
| Android15だけPOWER再接続後 | 同じ音声で1,530,368サンプル、4区間相関 .633/.680/.720/.847、既知音声・順序一致。復旧であり根本修正ではない |

Android16の最初の切断は00:56:25.727→00:56:27.300 JSTのRECONNECTING→CONNECTED（1573ms）。AVDの帯域・遅延制限なし。製品・SDK・OS/ホスト負荷のどれが原因かは未確定。音声採取中の別試験では当該端末に切断を記録せず音声を検出したが、制御試験の失敗を取り消さない。

Android15の無音中もOS focusをKOEONが保持し、音量は非ミュート。診断の集計PCM callbackは継続していた。callbackには無音/PLCも含み得るため、再生できた証拠ではない。受信側Room再生成での復旧を追加確認し、[#57](https://github.com/dennomusooffice/koeon-client/issues/57#issuecomment-6744955497)へ記録した。今回の車載変更が原因だとは断定しない。

## 車載ツールの制約

- Android Auto DHU 2.0: OPPOとUSB protocol1.7/TLS handshake成功。初回設定が連絡先・通話履歴・メッセージ・位置情報等の共有同意を要求したため、確認画面までで止め、同意せずDHU接続を終了した。投影・車載マイク/スピーカーの成功ではない。
- CarPlay Simulator: DeviceHubから実機を選択、Connecting→Disconnected。再試行はMacの画面ロックで停止。認証を迂回しない。
- 実車の有線/無線音声、切断中TX停止callback、車載ナビ/電話との競合は未検証。実車の音響とOS callbackの配送を、unit testやDHU handshakeで代替しない。

## 次の受入れ

Android Autoの共有同意とMacのロック解除が可能な枠で、停車中に車載機種/OS/有線無線を記録し、電話画面のPTTで双方向10回、TX停止中RX、送信中経路切断、ナビ/電話割込み、再接続後の新規PTTを確認する。ヘッドセットPTTはOFF。#57は音声信号/再生段階の診断とSDKログで追跡し、混在制御の一時切断は#56/#70へ引き継ぐ。部分成功だけでIssueを閉じない。

## 終了・復元

01:15 JSTに端末操作を終了。OPPO/motoの画面消灯30秒・USB接続中の常時点灯OFFを元値と照合し、OPPOのヘッドセットPTTを元のONへ復元した。iPhoneの自動ロックは開始前から「なし」、ヘッドセットPTTは開始前からOFFで、そのまま保持。OPPOのWi-Fi OFFも維持。

今回のAppiumセッション・補助アプリ・SIM5・Macの一時スリープ抑止を終了。Appiumサーバーや実機KOEONの登録は削除しない。DHUは終了済み。CarPlay Simulatorは切断済みだが、Macロック中のためウィンドウを閉じていない。

iPhone809件（今回run175件）、OPPO632件（今回run181件）のjournalを保存。iPhoneの今回runにはRX_PCM12件があるが、これを実機聴取の代用にはしない。生診断・識別子は保護領域に保存し、公開しない。

利用枠は直近確認で残量40%、残量不足による終了ではない。実行可能な試験を終え、車載ツールの同意・認証待ちの項目は未実施として引き継ぐ。#57と一時切断の原因調査も残る。

## 04:14 JST以降の再開（途中経過）

利用者がMac/motoの解除とAndroid Auto初回共有を明示許可したため、同じ07:00までの枠で再開。車載実機は未接続で模擬環境を使う。motoを加えたMIX8。motoはUSB給電時の常時点灯、OPPOは30分消灯、MacはAC時消灯・スクリーンセーバーを一時停止。元値を保護領域へ保存し、終了時に復元する。Macのパスワード要求は変更しない。

- DHUの投影画面を確認。OPPOの通信音声経路は本体スピーカーのままで、投影は車載音響の証明ではない。
- DHU接続中、OPPOとmoto各送信で7受信側BUSY、全8台READYを確認。iPhone送信ではOPPOのみREADYの失敗。35秒の有限PTTで再試行すると7台BUSYだったが、終了後Android15が一時OFFLINE。失敗を残し、全行列成功とはしない。
- DHUのfocus audio offでOPPOはINTERRUPTED・送信不可。onだけでは再開せず、明示的な音声再接続でREADY。focus nav off/onはREADY継続。DHU切断でもINTERRUPTEDとなり、明示再接続した。実車通話・車載マイク切断の試験ではない。
- focus復旧後のOPPO送信で、04:31:55.997 REQUESTING_FLOOR、04:32:03.415 TRANSMITTING、04:32:03.518 RELEASING、04:32:03.795 IDLEを記録。診断にはFloor lease renewal failedも存在する。制御通信の失敗としてfocusとは分離し、期限切れFloorの送信継続は許可しない。
- Mac解除後もCarPlay SimulatorはConnectingからDisconnected。Apple側ログはCoreDevice.ActionError 5のMobileGestalt問い合わせ失敗、およびremote-iapサービス作成でCoreDeviceError 4000 / POSIX 83。投影前に失敗し、KOEON音声経路の成否は判定できない。OS互換性が根因とは未確定。
- 04:40頃にホストのQEMUプロセスがSIGSEGVで終了し、Android14がADB一覧から消えた。混在試験はpreflightで停止しPTTを発行していない。アプリ不具合とは分類しない。重いビルドと混在受入れは時間を分ける。
- 別途、iOSのキャッシュ済みセッション復帰で送信制御番号が巻き戻るコード上の不具合を実クラスの再現テストで確定。[#74](https://github.com/dennomusooffice/koeon-client/issues/74)・[PR #75](https://github.com/dennomusooffice/koeon-client/pull/75)、修正ecb19a4527ddfcd2d42571b1acf82f397982441c。全iOS257件中256成功・専用SFU1skip。実機の今回の失敗との因果関係は未確定。内部TestFlight 2026111002の作成を開始したが、この段落の時点で配信・実機確認は未完了。

この節は途中経過で、復元・終了の記録は後続追記を確認する。

## 再開後の最終結果

車載機を外した比較ではOPPO・moto・Android14各送信で7台BUSY、全8台READYを確認した。その後Android15送信で途中終了を再現。journalは04:55:04.740 TRANSMITTING、04:55:11.116 RECONNECTINGとRELEASING、04:55:11.237 IDLE、04:55:12.077 CONNECTEDを記録する。後半に採取した受信側READYは、STARTを一度も受け取れなかった証拠ではない。接続異常時の安全停止は維持し、接続異常を起こす根因は未確定。新規PTTで復旧確認する手順とともに[#56](https://github.com/dennomusooffice/koeon-client/issues/56#issuecomment-6750030669)へ記録した。

iPhoneをTestFlightから1.0（2026111002）へ更新し、端末アプリ一覧でも同番号を確認。ソース`ecb19a4527ddfcd2d42571b1acf82f397982441c`、署名IPA SHA256 `2430b8f9d3351b608b06ec9b2057f6a64cd1e84fdb48cee29cb468dd44b0e7d7`。VALID / INTERNAL_ONLY / IN_BETA_TESTING、内部2グループ・外部0。登録・POWER ONを保持して起動した。iOS Simulatorは1001、Androidはb35d6d5の内部候補1.0.19（20）のまま。

更新後のiPhone・再接続後Android15・Android16・Android17・iOS Simulatorの5送信で、それぞれ7台BUSY、全8台READYを確認した。前段の3送信と合わせて全8送信元を確認したが、途中にiPhone更新と再接続があるため、単一条件の連続行列成功とは扱わない。iOSのキャッシュ済みセッション復帰をこの実機試験で通ったことは未確認で、#74は閉じない。

音声測定はAndroid14→15/16で失敗。Android16は99,110サンプル、15は99,075サンプルで既知音声を検出できなかった。Android15の04:55のlogcatに、emulatorのranchu音声HALのpcm_readi I/O error 106件、pcm_writei I/O error 573件を確認。アプリ例外ではなく試験基盤の異常を含むため、[#57](https://github.com/dennomusooffice/koeon-client/issues/57#issuecomment-6750060728)へ分離して記録した。これだけで無音や再接続の根因と断定しない。

Android15シミュレーターだけを登録保持で再起動し、新規POWER ON後に同じ送信元・合成音声で再測定すると1,530,660サンプル、既知音声と区間順序の一致を検出した。注入完了・送信後READY・cleanup errorなし。これは環境復旧の証拠で、アプリ修正の効果ではない。受信音声は保存していない。Android16の音声再検証と環境異常の根因特定は残る。

Android15のクリップボード採取は古い値だったため2回とも新規証拠として不採用。送信時系列には24時間journalを用いた。iPhone1,509件、OPPO1,270件、moto717件のjournalを保護領域へ保存した。実音声の聴取、車載音響、車載経路切断の実callback、CarPlay投影は未完了。

## 05:11 JSTの終了・復元

実機操作を05:11に終了。OPPO/motoの消灯30秒・USB常時点灯OFFを元値と照合、OPPOヘッドセットPTTを元のONへ復元。povo/LTEとWi-Fi OFFは維持した。iPhoneの自動ロックは元から「なし」、ヘッドセットPTTは元からOFFで保持。MacはAC消灯10分・スクリーンセーバー20分へUIで復元し、バッテリー消灯2分・即時パスワード要求は変更していない。自分のcaffeinateを終了した。

DHUは終了、切断済みCarPlay Simulatorのウィンドウも閉じた。今回のAppiumセッション、OPPO/Android15の診断補助アプリ、SIM5を終了・削除し、実機のKOEON登録と候補アプリは保持した。単体テスト用iOS Simulatorも停止済み。利用枠は最後の確認で32%残っており、残量不足による停止ではない。

実行できた範囲の結果と障害を保存して終了した。次回はCarPlayのApple側接続問題、実車音響・経路切断、#56の再接続原因、#57の音声HALとSDK受信の切り分け、#74の実機キャッシュ済み復帰受入れを継続する。mainマージ・Android公開APKの差し替え・外部TestFlight配信は行っていない。
