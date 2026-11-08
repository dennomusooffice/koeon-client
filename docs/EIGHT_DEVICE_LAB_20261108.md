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
