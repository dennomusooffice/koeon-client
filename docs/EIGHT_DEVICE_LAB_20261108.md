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

## 公開済みアプリの実音声経路（23:04〜23:12 JST）

Android14/15 AVDで、公開済み1.0.14 (15)、ソース`44b6eb3cb68b508577c14fc2ff34c11ff945ed6f`、STANDARD Opus目標24kbpsを使用。実招待登録・実バックエンドFloor・実LiveKit・通常画面のPTTを使用し、ローカル疑似Floorには置き換えていない。

測定にはインストール済みAndroid SDKの`emulator_controller.proto`の`injectAudio`/`streamAudio`を使用した。AVDを`-grpc PORT -grpc-use-token`付きで再起動し、ローカル認証トークンは非公開discoveryファイルから読み取った。`-no-audio`は測定対象2台だけ外し、`setMicrophoneState(realAudioEnabled=false)`でホストの実マイク入力は無効化した。再起動後は登録を保持してPOWER ONした。物理端末の設定は変更していない。

送信仮想マイクへ48kHz・mono・S16LEの既知信号を20ms単位で投入し、受信側仮想スピーカーのPCMをメモリ上で解析。取得した受信PCMは保存していない。測定打切りのgRPC `DEADLINE_EXCEEDED`は予定した有限の出力観測終了であり、アプリ通信エラーではない。

| 条件 | 結果 |
| --- | --- |
| Android14→15、無制限、660Hz音6秒 | 出力864,484サンプル。660Hz成分の最大電力比0.882、半秒窓6個で比率0.2超。既知音の到達を観測 |
| Android15→14、無制限、同660Hz音 | 既知音を検出せず。送信APM後メーター-120dBFS。権限allow・OS mic mute=false。音声処理による抑制も仮説であり、アプリ送信障害の根拠とはしない |
| Android15→14、無制限、合成音声6.88秒 | 受信出力と入力の最大正規化相関0.353、959,999サンプル |
| Android14→15、上下128kbps、同合成音声 | 最大正規化相関0.250、959,999サンプル |
| Android15→14、上下128kbps、同合成音声 | 最大正規化相関0.200、960,512サンプル |

合成音声はmacOSのKyoko読み上げをファイル出力し、48kHz monoへ変換したもの。人間の発話を録音していない。相関は双方を8kHzへ間引き、入力全長のテンプレートと受信の全長窓を比較した。既知音声成分の到達確認であって、主観的明瞭さ・語頭語尾の完全保持・MOSの評価ではない。記録開始からの相関位置には準備操作時間が入るため、エンドツーエンド遅延として扱わない。

128kbpsは対象2 AVDの`emu network speed 128:128`を用い、`network status`で上下128,000bits/s・追加遅延0msを確認。各試験後に`full`へ戻した。制限設定は確認したが独立した帯域飽和測定は未実施。実LTEのジッター・損失・輻輳・基地局切替を再現したものではない。各方向1回の観測であり、反復・ネットワーク復旧直後・8台同時受信・iOS/実機の音声受入れは残る。

試験後の両Android診断はREADY、入力APM後RMSは約-19.88/-17.92dBFS。直近送信のFloor応答42ms、RX_READY待機500/502msを記録した（音声の到達遅延ではない）。

## 4世代AVDの一斉受信（23:19〜23:31 JST）

同じ公開APK・実バックエンド・実LiveKitを使用し、送信元を交代して各回3受信AVDのスピーカー出力を同時に測定した。標準音質、無制限回線、前面、合成音声6.88秒。全8台の受入れとは区別する。

| 送信元 | 受信先3台 | 初回の観測 | 追試 |
| --- | --- | --- | --- |
| Android14 | 15 / 16 / 17 | 全3台で既知音声検出、送信後READY | — |
| Android15 | 14 / 16 / 17 | 全3台で既知音声検出、送信後READY | — |
| Android16 | 14 / 15 / 17 | 全3台で未検出。送信TALKING・注入API完了・送信後READY | 有効な追試では全3台で検出、送信後READY |
| Android17 | 14 / 15 / 16 | 全3台で既知音声検出、送信後READY | — |

Android16初回は送信APM後メーター-120dBFS、229,760サンプル、Floor44ms、RX_READY待機501ms。受信全長相関は0.024/0.024/0.031で区間順序も一致しなかった。原因は未確定で、注入側/音声入力/APM/アプリのどこで無音化したかを切り分ける必要がある。POWER操作をせず診断保存後に再試験した。有効な追試では3台の区間相関0.74〜0.91、全長約0.207を確認したが、初回失敗を解決済みにはしない。

途中の追試1回は、診断画面から戻ったPTTが画面上端に一部だけ見え、操作で通知パネルが開いたため無効。TALKING未確認で合成音声は注入していない。通知パネルを閉じてPTT全体を表示し、測定器にもボタンの最小表示サイズ・位置と新規UI dumpの確認を追加した。失敗時の部分結果も保存する。診断コピーの探索も大きいスクロールでボタンを通過しないよう、小刻みに戻して取得した。この操作上の失敗を初回の送信無音と混同しない。

測定器は[scripts/mixed-lab/emulator-audio-probe.py](../scripts/mixed-lab/emulator-audio-probe.py)。全長相関0.1以上に加え、4区間中3区間で相関0.35以上かつ相対位置の差0.35秒以内を要求する。全長相関だけでは0.1%の時計ずれで大幅に値が低下し、逆再生/位相対照の単純な倍率では偽陰性となった。校正用4テストで音量変更・遅延・小さい時計ずれを検出し、逆再生と独立雑音/無音を拒否した。これは既知信号検出器の検証であり、製品の安定性や人間の聴取を保証しない。

実機iPhoneは既存WDAへの接続に成功しCONNECTED/READYを読み取った。最初の接続失敗はMac側ポートと端末側ポートを明示して解消した（local 8102 / remote 8100）。ユーザーの再解除や登録変更は不要だった。新しいiOS修正の導入・音声受入れは引き続き未完了。
