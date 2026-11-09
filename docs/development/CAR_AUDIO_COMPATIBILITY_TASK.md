# TASK: 専用画面なしの車載音声互換性

- Issue: #70、関連 #58/#63。段階R3、2026-11-09の追加依頼で実装を許可。
- 基準SHA: `30e910690faa80ebcdbc9652af711437a7e0cb51`。担当Codex、レビュー所有者。状態: 実装・自動検証済み、実車受入れ待ち。
- 対象: 現行iOS/Android。既存登録・Session・LiveKit・Floorを利用。新規依存/サーバー契約なし。

## 要求・範囲

車載接続時にも既存PTTで送受信できるよう音声経路を尊重し、外部経路を失った送信を停止する。初期操作は停車中の電話画面PTT。車載専用画面、CarPlay entitlement、Telecom、車載ボタンの自動有効化、VOX、配信、実機操作は対象外。既存のヘッドセット操作は追加拡張しない。実車試験では自動playを避けるためヘッドセットPTTをOFFにして電話画面で操作する。

## 現状と設計

- iOS: carAudio分類/切断停止は既存。`speakerOutputPreferred`はBluetooth以外trueで、CarPlay/USB/有線もspeaker優先。外部routeではspeaker優先とdefaultToSpeakerオプションを外し、内蔵時の既存動作は維持する。OSのPTT activationを維持しsetActive/出力強制は追加しない。元の#58無音原因と断定しない。
- Android: AudioRouteMonitorは機器追加/削除のみ監視。API31以降の通信device変更listenerを追加し、選択済み外部deviceが別device/nullに変われば既存安全停止へ通知。device IDは比較用RAMのみでログ/診断に出さない。停止後の旧callbackを世代で無視する。
- USB device/accessory/headsetを外部音声経路として扱う。USB接続自体をAndroid Auto投影成功やマイク能力の証拠にしない。API29/30では既存の接続機器観測を残し、選択routeの保証をしない。
- AudioSwitchのルーティングと既存アプリfocus ownerは変更しない。イベントではTXだけ停止しRoom/RXは切断しない。自動TX復旧なし。
- 安全イベントは有界保持し、監視のstart/stopで初期化。停止処理を待たずに消失通知が落ちない構成とする。

## 受入条件・STOP CONDITION

外部routeでspeaker優先false、内蔵で従来値。Androidは選択外部→内蔵/null/別外部で停止通知、同一device/初期取得は不要停止なし。USB取り外し・旧callback・停止後イベントを試験する。既存Floor/割込み/受信回帰を実行し、iOS/Androidビルド・関連テスト・Lint・差分チェック結果を記録して終了。実機未検証を対応完了としない。

実機枠なしのため自動検証まで。後続実車受入れは車種/OS/有線無線/build/SHAを指定し、電話操作で双方向10回、TX OFF中RX、送信中切断、電話/ナビ割込み、再接続後の新規PTTを停車中に検証する。音声・識別子は保存しない。

## 移行・切戻し

設定/DB/権限変更なし。変更箇所を戻せば旧routeポリシーへ戻る。専用UIの審査未決は今回の実装を妨げない。実車不一致が残れば#58/#63を継続する。

## 結果・引継ぎ

2026-11-09 JSTの最終変更で以下を確認。

- Android: `testDebugUnitTest lintDebug assembleDebug --offline --no-daemon`成功。202 tests / 0 failures / 0 errors / 0 skipped。route政策の追加4件で外部→内蔵/null/別外部、重複、初期状態、USB/BLEを検証。Debugは既存versionName 1.0.19 / versionCode 20（新しい配布版として採番していない）。
- iOS: Xcode27.2 / iOS27.2 Simulator、`KOEONTests`255件中254成功・1skip・失敗0、アプリ/テストbuild成功。追加テストでCarPlay/USB/有線/Bluetoothのactivation optionsと内蔵復帰を確認。Debugプロジェクト値は0.1(1)、署名/配布用の版とは別。
- 両OSの既存Floor/停止/受信/割込み回帰を含む。feature-parity-contract / git diff --check成功。
- Androidの監視世代、listener解除、診断stream満杯と独立の安全通知は静的レビュー。OS callbackの実配送・実車音響は未検証。安全通知は現在のPTT controllerだけへ渡し、RX接続を切らない。
- 既存の非関連文書変更と他TASKの試験記録は保持した。音声・秘密・生診断を公開成果物に含めない。

今回の新配信ビルドなし。実機確認/配信/mainマージ未実施。変更SHAはGitHub #70/#58/#63の結果記録を参照。次は有効な実機時間枠で車載routeと双方向聴取を確認する。専用UI/車載ボタン/Telecomには進まない。
