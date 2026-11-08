# 8台混在の受入れ試験（2026-11-08）

追跡: [Issue #56](https://github.com/dennomusooffice/koeon-client/issues/56)、[PR #55](https://github.com/dennomusooffice/koeon-client/pull/55)。完了条件はIssueで管理する。READY表示だけでは音声・復旧の合格とはしない。

| 対象 | アプリ | セットアップ確認 |
| --- | --- | --- |
| iPhone実機 | 1.0 (2026110803) | 接続確認。後続の初回受信修正は未導入 |
| OPPO A79 5G実機 | 1.0.14 (15) | ADB接続確認 |
| moto g64 5G実機 | 1.0.14 (15) | ADB接続確認 |
| Android 14 / API 34 AVD | 1.0.14 (15) | 登録・CONNECTED・READY |
| Android 15 / API 35 AVD | 1.0.14 (15) | 登録・CONNECTED・READY |
| Android 16 / API 36 AVD | 1.0.14 (15) | 登録・CONNECTED・READY |
| Android 17 / API 37.0 AVD | 1.0.14 (15) | 登録・CONNECTED・READY |
| iOS 27.0 Simulator | Debug 0.1 (1) | 登録・前面専用モード・CONNECTED・READY確認 |

ユーザー・端末・チャンネル識別子、招待コード、生のUI/XML、診断JSONは公開しない。既存ユーザーの権限・チャンネルを変更せず、所有者の許可したテストアカウントを使用した。

## iOS Simulatorの制約

Apple PTChannelManager生成が `com.apple.pushtotalk.instantiation error 1` で失敗した。実バックエンドとLiveKitの前面通信を検証するため、DebugかつSimulator限定で `KOEON_SIMULATOR_FOREGROUND=1` を指定した場合だけ、アプリがAVAudioSessionを有効化する。実機・Releaseでは有効にならない。画面には専用モードの表示を出す。

このモードは招待登録、バックエンド認証、Floor取得、LiveKitの音声経路を置き換えない。APNsトークンは発行せず、Apple PushToTalkの背景起動を模擬しない。ロック・省電力・Bluetoothの合否には実機が必要。

署名無効のSimulatorビルドでは登録時のKeychain保存が-34018で失敗した。開発チーム指定・アドホック署名のSimulatorビルドで登録できた。再実行時は登録情報を保持して上書きインストールする。

## 検証状態

- Android 14〜17の4 AVDを同時起動し、実OSバージョンと各アプリのCONNECTED／READY表示を再確認。
- iOS回帰: 307件実行、305成功、専用ラボ2件スキップ、失敗0。専用モード初期化・未参加時の送信拒否・APNsトークン未発行テストを含む。
- iOS署名付きSimulator Debugビルド成功。既存登録を保持して更新し、専用モード表示、実サーバー参加後のCONNECTED／READYを確認。
- 8台同時音声、各送信元から他7台への到達、競合、ネットワーク切断・128kbps・再接続、実機長時間ロックの受入れは未完了。
- ヘッドレスAVDの無音マイクやMac読み上げ音を、人間の聴取成功と同一視しない。

## 通信断と復旧後の発話権（22:55〜22:58 JST）

Android 14/15/16/17の各AVDで、元の機内モードOFF・Wi-Fi ONを確認し、一時的に機内モードON・Wi-Fi OFFへ変更。12秒待機後は全4台がRECONNECTING／OFFLINE。設定を元に戻し、12秒待機後の観測で全4台がCONNECTED／READYに復帰した。POWER操作・再登録は不要だった。復旧時間そのものは連続測定していないため「12秒で復旧」とは断定しない（UI採取の約2秒も別途ある）。

再実行: `python3 scripts/mixed-lab/emulator-network-recovery.py --serial emulator-NNNN --output-dir PRIVATE_DIRECTORY`。対象はAVD限定で物理端末を拒否し、通信設定はfinallyで戻す。生UI/XMLは非公開ディレクトリに保存する。Android14初回は同じ条件の個別スクリプト、15/16/17はこの共通スクリプトを使用した。

復旧後のAndroid14から10秒間のPTT操作を1回実施。押下3秒後から並列に採取したUIでは送信側TALKING、Android15/16/17の各受信側BUSY REMOTE。解放後の送信側READYを確認した。これは実バックエンドを経由する発話権と通知の確認であり、ヘッドレスAVDの入力音声・全端末PCM・聴取・語頭語尾の検証ではない。復旧後の実音声受入れは残る。

iOS Simulatorの診断JSONも22:58:31 JSTに保存した。標準経路はLIVEKIT_OPUS_RTP、controlToFirstPcm=618ms、firstPcmGeneration=1。一方、受信履歴にはtrackSubscribed=false／pcmObserved=falseのtimeout観測も残り、終了理由はsilence。無音入力を用いた単回試験であり、PCM指標の存在から音声の聴取・安定再生を推論しない。既知信号での反復測定と履歴の時系列照合が必要。
