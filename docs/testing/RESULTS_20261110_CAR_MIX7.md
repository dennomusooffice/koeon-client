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
