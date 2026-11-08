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

## 2026-11-09 追記: 配信と受信停止の切り分け

iOS 1.0（2026110804）、ソース `41fed2c8b184ef8c3c6cb48284995bf11c133dce` をTestFlightへ配信した。Apple処理VALID、内部・外部ともIN_BETA_TESTING、既存の内部2グループ・外部1グループへ割当済み。IPA SHA256は `7bfbd04aaa3b3c3618e55f896381b912e8912578008ddb9f5e9f5fe5d2160828`。実機インストールのビルド番号も確認した。TestFlight更新説明がアプリの上に残り、アプリのアクセシビリティ情報だけでは分からなかったため、スクリーンショットで確認して説明を閉じた。ロック後初回受信の実機受入れはまだ完了していない。main未マージ。

Android 15 AVDで継続する受信停止を [#57](https://github.com/dennomusooffice/koeon-client/issues/57) に分離記録した。Android 16送信アプリ再起動後、他2台は受信するがAndroid 15は出力約6.2万サンプルのみで既知音声なし。この状態は送信元をAndroid 14に変更しても続いた。問題端末自身の送信は他3台で検出できたが、その後も受信は戻らなかった。CONNECTED/READY表示、OS音声フォーカス保持を確認した。

証拠保存後、受信側だけPOWER OFF→ONすると、Android 14からの音声を全3受信端末で検出した。問題端末は954,368サンプル、全体相関0.237、後半3区間相関0.911/0.909/0.850。相対offsetは採取開始基準であり通信遅延ではない。Room再接続で復旧する境界を1回確認しただけで、原因確定・修正・安定性の証明ではない。SDK購読、デコード・再生状態、AVD採取側の影響を引き続き切り分ける。Android 16初回TX入力無音とは分けて扱う。

利用者によると実機OPPO A79 5Gはpovo速度制限LTEで継続利用中。回線設定は変更せず、AVDの上下128kbps制限とは別集計する。現行試験後にOpus低帯域12・通常24・高音質48kbpsを比較する。実回線の実効速度を128kbpsと測定済み扱いにしない。

### 受信再接続後の追試と診断不足

受信側Android 15のPOWER再接続後、Android 16送信アプリをもう一度force-stopして再起動し、3台へ送った。今回は全3台で既知音声を検出した。Android 15は954,879サンプル、全体相関0.218、4区間相関0.825〜0.932。したがって送信側アプリ再起動だけで必ず発生する問題とは確定できない。根本原因は未解明で、#57は継続する。

Android診断JSONのliveKit節に既存のremoteAudioTracks/remoteAudioStateを追加した。これまではUIに表示されても保存JSONから欠落していた。購読情報は音声のデコード・聴取成功を示さないため、未計測のremoteDecodedPcmObserved/remoteAudiblePlaybackConfirmedはnullで出力する。診断契約のテストを追加した。これは診断改善であり、受信停止そのものの修正ではない。公開Android 1.0.14(15)には未配信。

ADBではOPPOと4台のAVDを確認したが、moto g64 5Gは未接続になっていた。再接続を依頼済み。8台の受入れ範囲から除外せず、実機確認を保留する。

### Android 1.0.15(16) 診断候補

LiveKit 2.28.0のRemoteAudioTrackにメタデータ専用sinkを付け、現在のRoom全体のコールバック数・フレーム数・最終時刻・サンプルレートを計測する。音声内容や参加者識別子は保持しない。UIへの反映は1秒間隔とし、音声スレッドから直接更新しない。購読解除・Room破棄時はsinkを外し、古いtokenのコールバックを無視する。

remoteDecodedPcmObservedは現在Roomのコールバック観測を意味する。無音やPLCを含み得るためネットワークパケット受信や実聴取の証明ではない。observer未接続かつ観測ゼロならnull、接続済みで観測ゼロならfalse、観測ありならtrue。remoteAudiblePlaybackConfirmedは引き続きnull。古いRoomの遅延通知、unsubscribe後の保持、複数トラックの並行集計、JSONの解釈をテストし、Android単体205件成功・0失敗、Lint/Debugビルド成功。受信停止本体の修正・配信・実機確認ではなく、原因特定用の候補である。

診断候補の署名ビルドは、旧バージョンを固定した契約検査で一度停止した。契約を1.0.15(16)へ同期して全項目の合格を確認し、ソース `aef0ae41e209d7309c02fa805f45bd07fca21116` から候補作成に成功した。APK SHA256 `d707a48838b11bd9719886fb3f7b86c99edc9304ab5c46864994c4c75d9ada86`。公開配信はせずAndroid 15 AVDだけ更新した。

更新後のAndroid 14→Android 15/16/17では3台とも既知音声を検出。診断版受信側は953,922サンプル、全体相関0.142。採取JSONに購読3トラック・observer3・18,795 callbacks・9,021,600 frames・48kHzを確認した。これはRoom内の累積で、無音中もcallbackが続くため当該発話の受信フレーム数ではない。聴取確認はnullを維持する。

moto g64のUSB再接続とKOEON起動を確認した。利用者の自律的な画面復帰の要望に従い、元の設定を非公開保存してUSB給電中の画面維持を設定した。PIN/認証設定は変更せず、試験終了時に元の値へ復元する。

診断版導入後のAndroid 16送信アプリ再起動試験では、3台とも約95.4万出力サンプルが得られる一方、既知音声は検出されなかった（全体相関0.020〜0.024）。送信TALKINGと注入完了、READY復帰は確認済み。受信診断はcallback継続、送信診断はWEBRTC_APM_FLOAT_S16、229,920サンプル、入力/出力とも-120dBFS。今回の失敗は送信側で無音を測定しており、Android 15単独の受信停止とは異なる。注入タイミング・入力/APM/アプリ側を切り分ける必要がある。

送信診断の最初のコピーはボタンが画面下のシステム操作領域に重なり、古いクリップボードが返った。鮮度検証が拒否したため結果として採用せず、補助ツールで画面上下端を除外して再採取した。新しい診断の採取時刻を確認済み。

POWER操作をせずAndroid 16から再送すると、3台すべてで既知音声を検出（全体相関約0.165）。初回入力無音は温間再送で解消したが原因未確定。利用者の要望でOPPOもUSB給電中の画面維持を設定し、元値を非公開保存した。画面ロック試験時には一時解除し、試験終了時に元値へ戻す。povo回線設定は維持した。

OPPOの画面維持設定はOEMによりshellのsvc/settings書込が拒否された。標準の画面点灯＋キーロック解除は成功したため、開発者オプションの「充電中、画面をオンのままにする」をUIから有効化し、保存値15（給電種別全体、USBを含む）を確認した。元値は0。KOEONへ戻した。終了時の復元も同じ設定画面を使用する。ロック方式・OEMロック解除・回線は変更していない。

## 2026-11-09 帯域検証の訂正

以前の本番APK試験ではAVDコンソールの128:128設定を確認していたが、実効速度を測っていなかった。ホスト向け合成512KiB転送を独立測定すると、128000bits/s表示でもWi-Fi時約36Mbps、Wi-Fi無効比較でも約160Mbpsであり、この転送経路には制限を確認できなかった。従来の本番APK/AVDの「128kbps設定下で音声到達」は音声到達の事実として残すが、速度制限下の合格証拠には使わない。別のローカルSFU/帯域プロキシ試験とは分ける。

[Android公式資料](https://developer.android.com/studio/run/emulator-console)ではnetwork操作の対象がethernet/cellular、36.5以降Wi-Fiがnetsim経路であることが説明されている。今回の迂回経路の確定はまだで、ホスト宛の例外も含めて確認が必要。仮想端末内のtc/IFBで上下経路を制御する方式へ移行し、実転送速度の確認を合格条件に追加する。実機OPPOのpovo回線は変更しない。

### 実効確認した制限方式での音質比較（途中結果）

仮想端末内のtc/IFBで送受信を128kbit/s上限、burst8KiB・queue latency1000msに設定した。合成256KiB TCP転送で下り93.54kbps・上り118.47kbpsを実測。これはホスト向けペイロード速度で、実キャリアやUDP損失の再現ではない。最初のburst1600bytes/200ms queueでは下り55.23kbpsまで低下したため、過度な損失条件を分けて記録し、音質比較には8KiB/1000msを使用した。

Android 14送信・Android 15/16/17受信、Android 14と15の両端末を上下制限した試験で、低帯域12kbpsは1回×3受信、標準24kbpsは2回×3受信、高音質48kbpsも2回×3受信で既知合成音声を検出した。各回TALKING→READY復帰、各回の帯域制御撤去を確認。送信アプリは公開1.0.14(15)、Android15受信のみ診断候補1.0.15(16)、他受信は公開1.0.14(15)。低帯域は適用値12kbps、Floor40ms・RX_READY待機487msを保存診断で確認した。

これは前面・参加済み状態のPTT試験であり、接続開始自体は制限前。逆方向・制限下の初期接続・反復回数拡大・背景復帰・実LTE・人の聴取・実音声遅延の検証は残る。高音質がキャリア128kbpsで安定すると結論しない。

公開した帯域測定ツール自身でも下り91.56kbps・上り118.75kbps、全256KiB転送を確認。通常終了後のcleanupFailuresは空。1秒タイムアウトで試験子プロセスを止める故障注入でも、追加した帯域設定は撤去されcleanupFailuresは空だった。標準・高音質は保存診断の実効公開値24/48kbpsとも照合済み（最後のPTT Floor36/37ms、RX_READY待機501/468ms）。これらは音声のend-to-end遅延ではない。

## 2026-11-09 追加: 逆方向コーデック比較と測定基盤の限界

ソース `49a6322baa9a876700be0c3dc0ade82bc0dd684f` の帯域ラッパーを使用し、Android15候補1.0.15(16)→Android14/16/17公開1.0.14(15)を比較した。Android14/15の上下をtc/IFBで128kbit/sに制限し、初回Room参加も制限内で行った。LOW12kbpsとHIGH48kbpsはそれぞれ2回、3受信先すべてで既知音声を検出。STANDARD24kbpsは最初の1回が全受信先で検出失敗し、送信側入力はRMS -97.86dBFS、peak -73.65dBFSだった。POWER操作なしの再試験では3受信先すべてで検出した。全ラッパーのcleanupFailuresは空。これを各コーデックの一般的な128kbps回線対応の合格とはしない。

[Issue #59](https://github.com/dennomusooffice/koeon-client/issues/59)として測定基盤の問題を分離した。KOEONを停止した独立AudioRecordアプリでも、同じ合成入力が通常RMS約-23dBFSに対して-87〜-104dBFSになる回を確認。録音開始の試験ID、端末時計差、注入区間を照合済み。エミュレータ本体のinjectAudio内でEXC_BAD_ACCESS/SIGSEGVも発生した。録音前から継続入力する比較でも同じスタックのクラッシュが起きたため、その方式の反復を停止。既存AVDデータを保持して再起動し、boot_completedとKOEON起動を確認した。生ログ・クラッシュ原本は非公開保存し、人の音声は録音していない。

測定スクリプトは注入前後のPTTジェスチャー生存と残り時間を確認し、期限切れの操作を拒否する。端末異常時にも途中結果を残し、他の端末のマイク設定復元を継続する。全受信先の結果と復元成功を合格条件に含める。既知信号検出の校正4件は成功。ただし、この安全策で仮想マイク自体の障害が解消したとは扱わない。Android15の受信停止(#57)、iOS長時間ロック後初回無音(#54)は引き続き未解決。

## 車載・Bluetooth追加試験の範囲

利用者から、音声試験後のBluetoothヘッドセット、CarPlay、Android Auto試験が依頼された。CarPlayは利用者の不具合報告あり、[Issue #58](https://github.com/dennomusooffice/koeon-client/issues/58)で追跡。車種・接続方式・症状の詳細・発生ビルドは未確定。Android Autoは未再現で、障害があるとは断定しない。

- Apple公式の[CarPlay Simulator](https://developer.apple.com/carplay/)はAdditional Tools for Xcodeに含まれる。このMacの確認対象ディレクトリには単体アプリがなく、公式ダウンロードはAppleアカウント認証へ遷移した。利用者の認証操作を要求せず、準備可能な範囲を調査する。
- Google公式の[Desktop Head Unit](https://developer.android.com/training/cars/testing/dhu)はmacOSからAndroid Autoヘッドユニットを模擬できる。SDKパッケージの入手を進める。Android Automotive OSのAVDとは別の試験である。
- Mac内の音声ループバックを、実Bluetooth HFP/A2DPのペアリング・ルート切替試験の代用として合格扱いしない。同等の仮想ヘッドセット環境を確認できなければ、指示どおり実ヘッドセット到着まで保留する。
- 接続前後の音声ルート、双方向PTT、切断・再接続、割込み復旧を優先する。疑似環境での成功は、実車の音響・無線・全車種での動作保証ではない。

### 公式Android Auto疑似ヘッドユニットの接続結果

Android SDKの`extras/google/auto`、DHU 2.0-mac（build 2022-03-30-438482292）をインストールし起動確認。moto g64 5GのAndroid Auto 18.0.664264-releaseとUSB accessory modeで接続し、protocol 1.7、TLS1.2のネゴシエーション成功を記録した。OPPOのpovo回線設定は変更していない。

その後、端末は「Android Autoへようこそ」の初回設定画面となり、連絡先・SMS・位置情報等へのアクセス同意を要求した。この同意は代行せず、DHUを終了してKOEONへ戻した。したがって確認済みなのは公式ツール導入とUSB通信開始までであり、車載音声ルート・送受信・再接続の合格ではない。利用者の初回設定後に続行する。CarPlayは公式ツール取得のApple認証待ち、Bluetoothの同等仮想環境は未確立のため実ヘッドセット試験を保留。通常音声と通信復旧の調査は続行する。

## 2026-11-09 通信断復旧と古いBUSY表示

`fc54a49d5c75fa6510cb2dc809190fdc235be7b1`時点の試験器でAndroid14/16/17公開1.0.14(15)、Android15候補1.0.15(16)を検証。各AVDをREADYから機内モード＋Wi-Fi停止にして12秒待ち、OFFLINE/RECONNECTINGを確認。設定復元から12秒待った採取ですべてCONNECTED/READYに復帰した。Android16の初回はクラッシュ復旧後POWER OFFだったため試験開始前に拒否され、POWER ON後の別試行だけを結果に含める。音声・復旧後PTTの合格とは分離する。

続けてAndroid15候補から12秒の有限PTT（音声注入なし）。Android14/16の画面はREADY→BUSY REMOTE→READY、Android17は途中画面でBUSYを捕捉できなかったが、後採取した診断では同じ試験のSTART受信・RX_READY送信成功・受信終了を確認できた。途中のUIスナップショットだけで制御未到達とは判断しない。

OPPOとmotoの公開1.0.14(15)は、試験前・途中・終了後に以前の話者のBUSY REMOTEを表示したまま。POWER操作なしで両実機の新鮮な診断とlogcatを保存。CONNECTED / PTT IDLE / RX_IDLEにもかかわらず、PTTはREMOTE_BUSYで禁止される。両機とも今回のSTART受信・RX_READY送信成功・終了時のremoteClearAt更新を確認し、アプリ全体の停止ではない。独立の[Issue #60](https://github.com/dennomusooffice/koeon-client/issues/60)で追跡する。

コード調査では、Androidが既存currentSpeakerをLiveKit snapshot更新時に保持し、Floor status失敗を捨てていることを確認。本番サーバーの読み取り調査ではJoinセッションのTTLは作成から2時間、期限超過は401/SESSION_INVALID、参照時の延長なし。サービス起動は2026-11-08 19:49:59 JST。LiveKit接続が生存する一方でFloorセッションだけ失効する可能性があり、長時間起動の実機と再参加したAVDの差と整合する。ただし実機の当該HTTP応答を直接取得していないため、観測症状の原因確定とは区別する。次は失効応答の再現・登録を保持した再参加・POWER OFF優先・多重復旧防止を検証する。未修正、未配信。

### Join失効へのAndroid修正（候補1.0.16 / 17）

Floor statusのHTTP401かつSESSION_INVALIDを検出して、古いPTT・Room・ポーリングを停止し、既存の登録を使って同じチャンネルへ再参加する。端末登録credentialは消去しない。復旧処理を停止対象のpollerの子にせず、通常の参加・退出と同じmutexで直列化。世代付きチケットで重複、古いセッション、POWER OFF、チャンネル変更を照合し、停止中に操作意図が変わった場合は再参加しない。キャンセル例外をポーリングが握り潰さない。

MockWebServerの実401応答からの判定、停止→再参加の順序、停止中のPOWER OFFによる再参加抑止、旧セッション・重複・チャンネル変更、端末資格失効/通信エラーとの区別を追加。Android全210テスト・Lint・assembleDebug・parity成功。新しい署名候補番号を1.0.16(17)としたが、この記録時点で候補生成・端末導入・実セッション再参加の確認は未完了。一般公開・mainマージは未実施。現在の自動再参加は1回であり、再参加自体が通信エラーになるケースの復旧継続は追加検証事項。Issue #60を閉じない。

### 署名候補と実セッション失効試験

ソース `e7cf936d038d7326def3c6def3b9342e08aa5b9e` の1.0.16(17)を正式鍵で非公開候補としてビルド。APK SHA256 `46b44fb00a49a14a5c6bfde805174079cde42b3a2c44684f6cb856c680bb0ca9`。署名一致、バージョン、非debuggable、release、compiled iconのゲート成功。Android15 AVDだけに上書き導入し既存登録を保持してREADYを確認した。

直前に参加したテストユーザーのセッションをfixtureとサーバー監査で一意に照合し、その1件だけをサーバー側leaveで無効化。旧sessionへのFloor statusが401/SESSION_INVALIDとなることを確認。その後利用者操作なしで同じユーザー・同じチャンネルへの新Joinが1件発生し、CONNECTED/READYへ復帰。失効操作開始から新Join監査まで0.966秒。これは実サービスでのセッション無効化試験であり、自然な2時間満了・失効中の実音声・再参加の通信失敗・全機種合格とは区別する。

実機の原因照合も進めた。画面上のユーザーをfixtureと一致させてサーバー監査の最新Joinを確認すると、OPPOは23:11:05 JST、motoは23:14:33 JST。採取時点で各約3.35/3.30時間経過しており、どちらの最新sessionへのFloor statusも401/SESSION_INVALIDを返した。これでLiveKit CONNECTED/RX_IDLEと失効したFloorセッションの併存を確認。旧版が失効応答を無視して古いBUSYを維持する原因と整合する。実機の旧状態は保存済みで、この記録時点ではまだ候補へ更新していない。

## 2026-11-09 候補17の実機導入とiOS失効対策

OPPO・motoを署名候補1.0.16(17)、e7cf936へ上書き更新。登録と音質設定を保持し、両機のREADY復帰を確認。Android15候補からの12秒有限PTT（音声注入なし）で両機READY→BUSY REMOTE→READY、旧話者BUSYは残らなかった。更新自体が再起動・再参加を伴うため、これを自然な2時間満了への実機自動復旧の証拠とはしない。Android14/16/17 AVDも同候補へ更新し、全Android6端末をそろえた。

iOSにもFloor照会の`try?`による失効応答の無視を確認したため、HTTP401のJSON error.codeがSESSION_INVALIDで、現在のセッション・POWER ONに一致する場合に既存のruntime resumeを要求する修正を追加。LiveKit CONNECTEDでもfresh resumeを選ぶ専用理由を設ける。Apple PTT登録・音声所有権を保持する既存処理を利用し、古い応答・POWER OFF・一般認証失敗を区別する。

iOS27.2/arm64 Simulatorで310件中308成功・2件スキップ、parity成功。失効判定、旧セッション/POWER OFF拒否、他の認証エラー、fresh resume選択を追加し、既存の登録保持/明示OFF解除も回帰確認。初回の暗黙x86_64ビルドはLiveKit依存解決で失敗したが、Apple Silicon arm64を明示した再実行は成功。iOS変更は未配信・実機未検証。

6台の制御マトリクスは送信開始前の画面採取中に中断した。Android14/15/17 Emulator本体がHangDetector→GenerateDumpAndDieで終了し、プロセス消失と3件の.ipsを確認。注入中のaudio_forwarderクラッシュとは異なるスタック。iOS回帰試験と同時間帯だが、メモリ不足等の原因は断定しない。失敗結果・原本は非公開保存、製品の通信不良判定から除外。回帰試験用iOS Simulatorは既にShutdown、登録済みiOS27.0 Simulatorは維持し、終了済み3AVDをデータ保持で再起動した。マトリクスは未完了。

### Android6台の制御マトリクス再試験

仮想端末の復旧後、重いiOS回帰テストと並行せず再実施。全6台は候補1.0.16(17)、ソースe7cf936。Android15・14・16・17 AVD、OPPO、motoを順に送信元とする各12秒の有限PTTを行った。各回の開始前は全台CONNECTED/READY、送信元TALKING・他5台すべてBUSY REMOTEを観測し、終了後は全6台READY。6回・受信側30観測、エラー0、各途中採取時も有限ジェスチャーが継続していることを確認。OPPOのpovo設定は変更していない。

音声注入を使用せず、既知音声の可聴性・音量・語頭語尾・通信遅延・iOS2台への到達は未判定。古いBUSY残留の解消と各Android送信元からの制御遷移を確認した範囲に限定する。実機の自然2時間満了は、更新後セッションを意図的に切り直さず別途確認する。
