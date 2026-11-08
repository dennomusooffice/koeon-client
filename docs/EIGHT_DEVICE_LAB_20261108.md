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

### iOS Simulator更新時の登録画面遷移

回帰試験済みab06162のDebug Simulatorアプリを、既存のラボ接続先へ設定してad-hoc署名し、登録済みiOS27.0へ上書き。bundleと接続先の一致は確認したが、起動後は登録画面になったため、実サービスの失効再参加試験は開始していない。Simulator用Appiumセッションは作成済み。実機iPhoneは変更していない。

コード調査でloadFixture()がapi.me()のすべての失敗に対して資格を消去する独立の欠陥を確認し、[Issue #61](https://github.com/dennomusooffice/koeon-client/issues/61)へ登録した。今回のSimulator画面遷移が実際に通信失敗・Keychain・署名のどれによるものかはまだ未確定。資格ストアを注入した再現テストで、通信失敗・キャンセル・5xxと確定した端末資格失効を分離する必要がある。未修正・未配信。既存の実機登録は保持している。

## 2026-11-09 iOS起動時の登録資格保持修正 (#61)

実IntercomSessionControllerに偽APIと資格ストアを注入し、修正前のオフライン・HTTP503・不明なHTTP401・キャンセルで資格が消えることを再現。3件の初期試験で通信失敗・キャンセルの2試験が失敗（16 assertion failures）、明示失効の試験は成功した。

loadFixtureは保存資格を確認し、取得成功またはエラーの適用前に資格が変わっていないことを照合する。HTTP401の構造化error.codeがDEVICE_CREDENTIAL_INVALID/EXPIREDの場合だけ消去して登録へ戻る。通信失敗・サービス障害・不明な401は資格を保持し、エラーと「再試行」を表示する。キャンセルは登録に触れない。資格取得中の重複要求を抑止し、遅れて届く失効応答で更新済み資格を消さない。

修正後のiOS27.2/arm64全314件は312成功・2スキップ、parity成功。再試行後のユーザー情報復元、明示失効、キャンセル、資格変更中の古い401を確認。実機未配信・画面での再試行操作とSimulator再登録は未確認。先のSimulator登録画面遷移の直接原因を確定したとは扱わない。

以前の並行試験時のHangDetector終了を避けるため、試験開始時にREADY待機中のAndroid4AVDを正常終了した（userdata保持）。OPPO・motoは操作せず接続継続し、自然な2時間満了の確認対象を保持した。

### iOS Simulator session expiry validation (2026-11-09 02:10 JST)

Source: 59dcea13e5716ea7abc0cc43e09f76e1d89baa10; Debug Simulator 0.1(1), iOS 27.0. The unsigned-build-then-codesign artifact lacked the executable __entitlements section and enrollment failed with DeviceCredentialStoreError. The earlier successful signing-enabled build contained this section. Rebuilding with signing enabled and preserving bundle/endpoint restored the existing enrollment without another invite entry, then POWER ON reached CONNECTED/READY. This packaging failure is distinct from the independently reproduced startup transport-error credential deletion in #61. Audit the attempted recovery enrollment privately before any orphan cleanup.

The simulator session was uniquely attributed using fixture and server journal. Invalidating only this session through /api/leave yielded 401 SESSION_INVALID on its old floor/status. Without manual POWER or registration changes, exactly one ptt.session_resumed event created a new session for the same user/channel in 1.022 seconds. Its floor/status returned 200; UI showed CONNECTED/READY.

Scope: real HTTP recovery after explicit server invalidation, not natural two-hour expiry. Foreground Simulator only: no claim about Apple PTT/APNs, locked first reception, audible audio, or network failure during recovery. Physical sessions were preserved for natural expiry observation. Tracking: #60, #61, PR #55.

### Android expiry recovery interrupted by network failure (2026-11-09)

A new regression test failed on the previous implementation: after stopping the expiry poller/runtime, one failed rejoin ended recovery with no remaining trigger. The recovery owner now retries transport failures and HTTP408/429/5xx with 1/2/4/8/15-second capped backoff. Registration/auth denial and cancellation are not retryable. POWER OFF invalidates the intent and wakes the backoff immediately; a connection that succeeds after invalidation is torn down. The foreground service is retained during transient recovery rather than repeatedly stopped, and RECOVERING_SESSION retains a usable POWER OFF control while disallowing PTT.

Validation: red baseline 6 tests/1 failure; final Android suite 216 tests/0 failures, feature parity PASS. Lint/debug assembly checked. This is implemented and automatically tested only: no new signed/public build, emulator network-failure acceptance and physical acceptance remain pending. Existing physical candidate1.0.16(17) sessions are left untouched for natural expiry observation. Follow-up to #60, PR #55.

### Android15 actual-client transient rejoin and cancellation (2026-11-09 02:20 JST)

Source a74fc924df013a5ef979a6a72f3ab7fbea648bd5; a separate Debug 1.0.16(17) build changed only the backend endpoint to the emulator's localhost proxy and was signed with the existing key to preserve enrollment. Private test APK SHA256 dd41d1e303b221e5d49e2eea6da40d1a491a7daec946719f272cb97220e11120. This artifact is not a release. The proxy forwarded normal real-backend requests and injected HTTP503 only for /api/join; it logged method/path/status/time, not credentials, bodies or audio.

The uniquely attributed emulator session was invalidated on the service. Five failed joins occurred with intervals approximately 1.14, 2.07, 4.07 and 8.15 seconds. UI showed RECOVERING_SESSION and enabled POWER OFF. After removing the fault, the next join succeeded after the capped 15-second interval and UI returned ACTIVE/CONNECTED/READY without manual POWER. A second invalidation/failure trial used the actual POWER OFF button during backoff: the app returned to the powered-off screen and no /api/join requests occurred in the following 18 seconds. These are actual client/service control tests, not mocked coroutine-only results.

Limitations: injected HTTP503 rather than packet loss/timeouts, one API35 emulator, no audible-audio assertion. Physical devices remained on the previous candidate and were not reset. Normal direct-backend signed release candidate from the same source (still private 1.0.16(17), APK SHA256 a494a3024fb1bc16613d63882678ef178894781ba959422450b4983cc05a7eff) replaces the Debug test artifact after this trial. Distinguish APK/source hashes despite the same private version code. Public release is unchanged.

### Post-retry audio and network verification (2026-11-09 02:28 JST)

API35 uses signed private a74fc92 candidate1.0.16(17); API34/36/37 remain e7cf936 candidate1.0.16(17). Unshaped synthetic6.88s speech: API34 to35/36/37 passed3/3; reverse API35 to34/36/37 passed3/3. Full-wave correlation ranges0.192-0.207 and0.144-0.236 respectively, all ordered-segment criteria passed, gesture remained active, sender returned READY and cleanupErrors were empty. Physical OPPO/moto remained CONNECTED and recent decoded-PCM callbacks were observed (168/572ms before diagnostic capture); this is not audible or waveform-matching proof.

API35 airplane-mode plus Wi-Fi-off trial observed OFFLINE/RECONNECTING; after restoration, READY/CONNECTED was observed at12s. Subsequent API34 multicast detected speech at recoveredAPI35 andAPI37, butAPI36 yielded only156588 captured samples and no match. No POWER reset: another trial still failedAPI36 (99517 samples), whileAPI37 passed (1530368 samples). All endpoints stayed alive; injection/gesture/cleanup checks passed. API36 diagnostic remained CONNECTED/READY/RX_IDLE, RX_READY publicationSUCCESS and recent decoded-PCM callbacks (876ms old). This does not establish whether app playback or emulator output capture stopped. Whole multicast trials remain failed; do not count as general recovery/audio acceptance. Next: independent AudioTrack output versus gRPC capture on the affected emulator, before any POWER reset. Related #57/#59/#56.

### API36 output failure isolated outside KOEON (2026-11-09 02:34 JST)

An independent AudioTrack app generated10s of660Hz PCM (48kHz mono, VOICE_COMMUNICATION/SPEECH). No microphone, human recording, network or KOEON API was used. Playback-head metadata and gRPC streamAudio capture were compared over16s; raw output was analyzed only in memory.

| Condition | AudioTrack frames written/played | Captured samples | Dominant frequency | RMS (S16 units) |
| --- | --- | --- | --- | --- |
| AffectedAPI36, KOEON still running | 480000/480000 | 50082 | 5647Hz (not test tone) | 2.80 |
| SameAPI36, KOEON force-stopped | 480000/480000 | 44301 | 5647Hz (not test tone) | 2.83 |
| ControlAPI37, same probe | 480000/480000 | 768511 | 660Hz | 848.54 |
| API36 after graceful AVD restart, data retained | 480000/480000 | 621411 | 659.43Hz | 944.59 |

All probe playback heads completed in about10.2-10.4s without an Android playback error. The failure persisted without KOEON running and recovered after AVD restart, supporting an emulator output/capture runtime fault rather than attributing this event to the KOEON receive path. Exact emulator subsystem/root cause remains unknown; do not generalize this finding to unresolved product issue#57.

After restoring enrollment/READY, the original KOEON synthetic-speech trial API34->API36/API37 passed2/2: each captured1530879 samples, correlations0.194/0.252, ordered speech detected, senderREADY and cleanupErrors empty. Physical devices were untouched. Latest evidence is linked from#59; natural physical Join expiry and iOS locked first reception remain pending.

### Repeated 128kbps codec matrix on retry-fixed Android15 (2026-11-09)

SenderAPI35: signed private a74fc92 1.0.16(17); receiversAPI34/36/37: signed e7cf936 1.0.16(17). API34 andAPI35 both shaped with tc/IFB128kbit/s, burst8KiB, queue latency1000ms; API36/37 were unshaped comparison receivers. Independent256KiB calibration: API34 download98.33/upload119.34kbps; API35 download91.72/upload117.53kbps. These are TCP payload rates, not measured LTE or UDP rates.

Each preset began with senderPOWER OFF, so initial join occurred while shaping was active. Real enrollment/backend Floor/LiveKit and normal PTT were used. Six synthetic6.88s utterances (two per preset) yielded18/18 known-speech detections across three receivers. All6 senderREADY/gesture/cleanup checks passed, and all12 shaping-wrapper cleanups were empty. Effective bitrate was independently read from diagnostics after each preset.

| Opus setting | Effective bitrate | Trials | Receiver detections |
| --- | --- | --- | --- |
| LOW | 12kbps | 2 | 6/6 |
| STANDARD | 24kbps | 2 | 6/6 |
| HIGH | 48kbps | 2 | 6/6 |

Conclusion limited to this controlled cap: all three settings carried known speech, including to the capped receiver. No artificial packet loss/jitter/handover was added; human intelligibility, speech-edge loss and end-to-end latency were not measured by waveform offset. Real carrier speed-limit acceptance and eight-device audibility remain open. Restored senderSTANDARD/READY, removed all shaping and disabled temporary adb root onboth AVDs. Existing physical sessions andpovo settings untouched. Evidence retry-codec-5554-summary.json plus per-round diagnostics/wrapper results stays private; #54/#56 track public conclusions.

### Physical iPhone overnight evidence collection (2026-11-09 02:55 JST)

Apple devicectl reported passcodeRequired=false/unlockedSinceBoot=true; the existing Appium runner was reconnected without reinstall, enrollment or POWER changes. Foreground KOEON showed READY/POWER OFF. Diagnostics reported Copied, but WDA pasteboard reads returned empty even after runner activation. A RemoteXPC tunnel attempt with noninteractive sudo stopped because administrator authentication was required; no password prompt or user operation was requested. The tunnel was not started.

Read-only devicectl appDataContainer copy of Library/Preferences obtained the persisted breadcrumb history instead. It contains64 events from physical build1.0(2026110804):26 APPLE_DID_ACTIVATE,26 APPLE_DID_DEACTIVATE,6 APP_INACTIVE,3 APP_BACKGROUND,3 APP_RESUME, all resultClassOK. Activation/deactivation pairs overlap the synthetic transmission trials. This supports Apple audio-session lifecycle activity only; it does not prove decoded waveform, audible playback or locked-first-RX acceptance. Foregrounding for collection also means this is not an undisturbed lock trial. Full fresh fieldJSON was not obtained. Closed Diagnostics and confirmed READY/POWER ON retained. No auto-lock, registration or network settings changed. Private files: iphone-night-preferences.plist, iphone-night-breadcrumbs.json, iphone-night-summary.json. Follow-up#54/#56; future diagnostics should not depend solely on a pasteboard path requiring foreground automation.

### Clipboard-independent diagnostic export (2026-11-09)

Follow-up to#50/#54: the host's official devicectl pasteboard command was also attempted, but its CoreDevice/Mercury connection was invalidated. Existing Apple remoted service relay attempts failed without starting a relay. Thus administrator authentication is not established as the sole cause of missing clipboard data; earlier tunnel-auth limitation is only one tested path. Read-only app-container file retrieval continues to work for saved preferences.

Implemented an alternate export on the existing Copy Field Diagnostic JSON action: after clipboard copy, write the identical JSON atomically to Library/Caches/KOEONDiagnostics/field-diagnostic-latest.json, replacing one previous snapshot. No audio, automatic periodic recording or growing history is added. Cache storage avoids backup; file protection is completeUntilFirstUserAuthentication. The diagnostics result distinguishes file saved/unavailable while preserving clipboard success if file output fails.

Validation: iOS316total/314passed/2skipped, parityPASS. Signed iOS27.0 Simulator UI Copy produced schema koeon.field-diagnostic.v2, byte-for-byte equal to simctl clipboard, one saved file; returnedtest05READY. This change is not yet distributed to physical iPhone and its app-container export remains unverified there. The physical device still has2026110804.

After deploying a build with this change and invoking Copy, retrieve privately with devicectl device copy from --device DEVICE --domain-type appDataContainer --domain-identifier com.dennomuso.koeon --source Library/Caches/KOEONDiagnostics/field-diagnostic-latest.json --destination PRIVATE_PATH. Check capturedAt/build/schema before use; cache may be purged and the last snapshot is not automatically refreshed by subsequent reception. Do not publish raw diagnostic contents.


### TestFlight distribution and Android startup follow-up (2026-11-09 03:16 JST)

iOS1.0(2026110901), source ffd34f620028d13f96ed55366ea0c5a7abc720fc, was locally archived/exported/uploaded successfully. IPA SHA256 c57987fc00e9fccf07c99af3fe8291744598b5c2099dace5126abcf3eaf1e0d3. App Store Connect reread confirms VALID, internal and external IN_BETA_TESTING, with the same two internal and one external groups as the preceding build. Includes diagnostic file export and the previously tested startup/session-expiry recovery changes. Physical iPhone remains on0804 at this checkpoint; distribution is not device verification. PR#55 remains unmerged.

After restarting the AVDs, API34 showed enrollment despite retaining encrypted credentials. Without re-enrollment or data deletion, restarting the app restored the existing user; POWER ON then reached READY. Issue#62 records the startup error-classification defect and unresolved initiating cause. API35/36/37 also returned READY. Physical OPPO/moto sessions were preserved for natural expiry observation.


### Android startup enrollment preservation (#62, 2026-11-09)

The production startup path now distinguishes absent credentials, explicitly invalid/expired device credentials, temporary failures, and stale responses after credential replacement. Only HTTP401 with DEVICE_CREDENTIAL_INVALID/EXPIRED clears the store. Network errors, unknown401, service errors and keystore read failures preserve enrollment and show a retry action. Cancellation propagates without clearing credentials. Startup requests are gated while loading or already initialized. Keystore reads no longer create a missing encryption key or silently collapse decryption errors into absent enrollment.

Validation: Android222 unit tests passed, zero failures/errors/skips; Lint, debug assembly and parity passed. Six added tests exercise the production startup loader, including actual HTTP401 JSON responses, offline/503, read failure then retry, cancellation, missing credentials and late success/denial after replacement. These establish the error handling fix, not the initiating cause of the earlier AVD event. Signed distribution and actual AVD fault-injection UI acceptance remain pending; physical sessions were not reset.


### Android14 startup offline/retry UI acceptance (2026-11-09 03:22 JST)

Signed private1.0.16(17), source6711527709a88710c063538f99c8d84b62feaf85, APK SHA256 d5e2cd62cf4a98a7c8c72c111c088135acceab7091a7da2904febf9343b97d2d, was installed over the existing API34 app without clearing data. Only this emulator was placed into airplane mode with Wi-Fi disabled, then the actual app was stopped and relaunched. Startup showed the retry action and no enrollment screen. Restoring the previous airplane/Wi-Fi settings and tapping Retry restored the existing user's POWER ON screen without an invite. POWER ON then reached READY. Final connectivity settings matched their original values.

This verifies an actual offline-startup and manual-retry UI path on Android14, not simulated keystore failure or the exact earlier initiating cause. Physical OPPO/moto settings and sessions were untouched. Other Android devices retain their previously recorded candidate hashes. Public Android release remains unchanged; #62 is still open for remaining conditions. Raw UI/result files stay private (startup-avd-result.json and associated XML).


### Physical iPhone0901 diagnostic export and foreground receive (2026-11-09 03:26 JST)

Updated the physical iPhone through TestFlight to1.0(2026110901), verified independently by devicectl bundleVersion and diagnostic build. Enrollment and powered-on READY state survived without invite entry or manual POWER cycle. Explicit Copy generated fresh field JSON in the app cache; devicectl appDataContainer retrieval succeeded at18:25:10Z and18:26:20Z. This closes the previously unverified physical file-export path, not the general locked-reception issue.

API34 (signed6711527 candidate17) sent known6.88s synthetic speech to the mixed room. API35/36/37 each detected the signal (3/3; correlation0.436/0.439/0.439; ordered segments passed); sender returnedREADY and cleanupErrors empty. Physical iPhone0901 recorded firstPCM generation1 in active lifecycle. This is decoded-PCM evidence, not speaker audibility or human intelligibility. Other builds remain as previously recorded; no physical OPPO/moto reset.

The iPhone diagnostic's20 divergence-event slots contained repeated rx_divergence_recovered after this single receive. The PCM handler returns recovered repeatedly while timeout/recovery flags persist; follow-up#50 will distinguish the first recovery transition from subsequent PCM callbacks. A confirmed device lock starts a separate first-reception-after-five-minutes trial; no result claimed yet.


### Locked0901 trial and diagnostic recovery-event fix (2026-11-09 03:35 JST)

Appium confirmed physical iPhone locked before and after a single synthetic utterance, after310.79s of continuous lock. SenderAPI34 returnedREADY and cleanup was empty. API35/37 detected known speech (correlation0.170/0.203); API36 captured only100231 samples and failed detection, resembling but not proving the previously isolated emulator output fault. This multicast trial is failed overall.

Unlock returned an error and devicectl confirmed passcodeRequired=true. No PIN or further UI operations were attempted. Fresh explicit fieldJSON could not be generated; read-only app preferences retrieval still worked. Persisted0901 breadcrumbs show APPLE_DID_ACTIVATE at18:26:56Z and DID_DEACTIVATE at18:32:27Z. Activation preceded the test send (18:32:05Z), so this does not prove a suspended/cold audio engine was awakened by that send. DecodedPCM and audibility for this locked reception remain unknown. Device remains locked; user intervention is deferred while asleep.

Fixed repeated recovery diagnostics: RxConsistencyGuard.handleRemotePcm now returns recovered only when PCM was not already observed for the current validated generation. The focused execution of extracted production guard code reproduced100 recovered results per100 frames before the fix and1 after, for each of two generations. The added XCTest also rejects stale PCM and verifies a new generation can report recovery once. Full iOS317 tests:315passed/2skipped; parityPASS. No audio recovery timing or media route changes. Not yet distributed; physical0901 retains the previous diagnostic behavior. #50 tracks this fix; #54 remains open.


### User-unlocked iPhone collection and physical Android natural expiry (2026-11-09 03:37 JST)

The user unlocked the iPhone. Without retransmission or POWER changes, explicit Copy and app-container retrieval saved fresh0901 JSON captured18:37:17Z. State was CONNECTED/READY, PTT IDLE, RX_IDLE. The diagnostic retains background push18:32:15Z and completedWake18:33:34Z, but also foreground reconnection/full cold resume18:36:36-38Z, runtimeGeneration9, firstPcmAt null, and last completedRX18:36:38-43Z. Therefore lifecycle fields cannot be attributed directly to the earlier locked synthetic utterance; compare preserved breadcrumbs/server logs. No audible-success claim. Closed Diagnostics and preserved POWER.

Both physical Androids remain signed private1.0.16(17), sourcee7cf936. With no POWER/reinstall/explicit invalidation since their joins, server audit recorded OPPO16:35:32.649Z->18:35:34.603Z (two hours+1.954s), moto16:35:46.451Z->18:35:47.551Z (two hours+1.100s), new joins for the same users/channels. Fresh physical diagnostics18:36:55-57Z showed bothCONNECTED/READY, PTT IDLE, RX_IDLE. This verifies natural expiry/rejoin under the observed connected condition, not packet loss during rejoin or audibility. Thepovo settings were not changed. #60 tracks the result.

AVD restoration afteriOS tests: first attempt failed on a transient boot-time storage error; retry restoredAPI34/35 but stopped atAPI36 beforeREADY. No further AVD restart is implied; inspect current UI and continue recovery on the live process. API37 remains to be checked.


### Post-natural-expiry physical control and AVD restoration (2026-11-09 03:43 JST)

API36's restoration blocker was a System UI not responding dialog, not KOEON enrollment. Selecting Wait on that observed dialog allowed the same liveAVD to recover; API36/37 reachedREADY, and allfourAVDs are restored without data wipe. This does not establish the precise cause of the earlier API36 audio capture failure.

The first physical control attempt stopped before transmitting because moto's connection label was offscreen although its PTT readREADY. After scrolling that device to expose the required status, two finite12s PTT trials used OPPO thenmoto as sender. Each trial observed senderTALKING, allfive otherAndroidsBUSY REMOTE, gesture stillactive during observation, then allsixREADY. Errors0. No synthetic audio was injected and no human audibility claim is made. Server joins were independently rechecked: each physical user's channel stayed the same and its session changed across the two-hour expiry. This verifies post-expiry control usability under the tested condition; voice and network-failure acceptance remain separate. Physical buildse7cf936;API34/35/36/37 sources6711527/a74fc92/e7cf936/e7cf936 respectively, allprivate1.0.16(17).


### Locked receive server/physical-session correlation (2026-11-09 03:45 JST)

For the03:32 locked trial, Floor grant and push dispatch occurred18:32:15.413Z. Three APNs acceptance records occurred18:32:15.590-.591Z (177-178ms after grant); APNs acceptance alone does not prove delivery, but physical JSON independently records the incoming push at18:32:15Z in background. Server resume18:32:21.337Z matches the exact lastBackendSessionId in the physical iPhone's persisted restore descriptor copied before user unlock. This confirms that device's backend rejoin5.924s after Floor grant. Another resume at18:33:33.467Z matches the same user; exact device attribution of that second event is not established by the saved descriptor. Floor release was18:32:42.718Z.

The synthetic source lasted6.88s; actual injection completed in7.201s and began3.141s after gesture start. No end-to-end audible latency is inferred from these clocks. The evidence narrows investigation to the post-push receive/runtime recovery path, rather than blaming only APNs delivery. It does not establish the root cause of missing sound or prove playback. The later JSON includes PCM timeouts at259/800/4281/5330ms, but divergence events lack absolute timestamps and runtime generation, so they cannot safely be assigned to this wake versus the subsequent foreground reconnect. The diagnostic dedup fix82ffb7d prevents event flooding but is not yet distributed. Further tracing should retain per-event time/runtime generation and completedRTP receive evidence across a foreground runtime reset. Raw logs and restore identifiers remain private.


### Generation-scoped iOS recovery event metadata (2026-11-09 03:47 JST)

Added observedAt, runtimeGeneration, receiveGeneration and appLifecycleState to each bounded rxDivergence diagnostic entry. Values are captured when the event is appended, rather than obtained from current state when exporting later; a foreground runtime replacement can therefore be distinguished from the original background recovery. Existing event count cap20, no audio/credentials/participant identifiers added. This improves future evidence and cannot recover missing metadata from0901.

Validation: iOS317total/315passed/2skipped, parityPASS, diffcheckPASS. Existing recovery logic and deadlines are unchanged. Combined with82ffb7d's first-PCM-only recovery diagnostic, this is implemented/automatically tested but not distributed or physically verified. It does not claim the locked-first-receive defect is fixed. The fourAndroidAVDs were normally stopped with data retained for the regression run; physical devices were untouched.


## Paused at user usage threshold (2026-11-09 03:55 JST)

Codex weekly10080-minute window reports96%used/4%remaining, below the user's5%stop threshold. New development/testing stopped; the objective is not complete and must not auto-resume. No release claim beyond observed Apple state.

- Latest code9eacc803fbe9a794f09d452163fb55b8a4a475e3 includes receive-event context and82ffb7d dedup; iOS317total/315passed/2skipped, parityPASS.
- iOS1.0(2026110902) was signed/exported/uploaded successfully from that exact commit, tree86391d536ed1025784788abb6f81393ce9a97f66. IPA SHA256 fff7fe4dab8bc81a62d72101d7d48ee9e49abb4730cf18be60ca91bc0ce78483. Last App Store Connect lookup was NOT_INDEXED. Processing, beta review/group assignment and distribution remain unverified/unperformed. Do not re-upload merely because indexing has not been observed.
- Physical iPhone remains0901; newest export18:37:17Z was collected after the user unlocked. Locked-first-RX defect remains open. OPPO/moto retain candidate17/e7cf936, natural2h recovery and subsequentPTT control verified as documented; normal/public Android release unchanged.
- Stopped helper runs and allfourAndroidAVDs with userdata retained. iOS labSimulator stopped. Existing UI sessions returned404 on cleanup (already absent). No test replay remains scheduled by this work.
- Restored OPPO andmoto USB stay-awake to their original0 and verified reads; OPPO used the observed developer-settings toggle. iPhone auto-lock was not changed. Removed the twoAndroid diagnostic helper apps. Network/povo configuration unchanged.
- Next authorized resumption: first check0902 Apple processing and existing-group access; inspect devices/build hashes before testing. Capture per-runtime/time-scoped recovery diagnostics and completedRTP evidence before foreground resets. Continue low-bandwidth/locked-first-RX/8-device audibility/recovery acceptance; emulatorAPI36 audio/SystemUI instability must be separated from product failures. CarPlay/AndroidAuto/Bluetooth blockers remain in the earlier section. PR#55 stays unmerged and partially resolvedIssues stay open.


## Autonomous physical Bluetooth smoke test (2026-11-09 06:09 JST)

User connected the iPhone Bluetooth headset and requested autonomous testing bounded before usage remaining reaches1%. Started at3%remaining and stopped at2%remaining, leaving room for handoff. No user speech/listening/re-pairing operation was requested after the user's autonomous-only clarification. PhysicaliPhone1.0(2026110902), OPPO/moto1.0.16(17); exact installedAndroid source hashes not reverified. No emulator boot or software installation.

The first Appium runner startup timed out; Apple devicectl successfully launched the installed runner and a bounded reconnect succeeded. iPhone foreground showedBluetooth/CONNECTED/READY. A finite12s iPhonePTT caused bothAndroidsBUSY REMOTE; iPhone andOPPO returnedREADY. The first after-snapshot onmoto was blocked by its screen lock, so that whole initial script was not counted as fully passed. Waking/dismissing the PIN-lessAndroid screen allowed the remaining trials without POWER resets. OPPO thenmoto each heldPTT12s; iPhone showedBUSY_REMOTE during each and allthree returnedREADY after each.

Fresh iPhone JSON confirmsBluetoothA2DPOutput44100Hz at final idle, inputPortTypes empty while idle, firstPCM generation7/active, READY/CONNECTED/RX_IDLE. TX had Floor/ready ACK/mic unmute/TALKING records and completed after12s; selected12kbps profile. These prove control transitions and some decodedPCM observation, not known-speech waveform or audibility, nor the headset microphone's HFP route duringTX. The shared liveKitEngineReadyAt was later than the completedTX and must not be treated as thatTX's startup latency. No human audio was recorded.

Not covered: headset hardware button, disconnect/re-pair, repeated shortPTT, long lock/background recovery, measured speech quality/edge loss and directional acoustic proof. Resource-bounded smoke testing is not fullBluetooth acceptance. User's1%limit took precedence over expanding scenarios. Private evidence: bt-trial-*.xml, bt-three-device-results.json, bt-final-iphone.json, bt-android-versions.json. Closed the UI test session; no screen-timeout/network/povo/registration settings changed. #38/#39/#54 remain subject to their outstanding acceptance conditions.


## Morning eight-device control matrix (2026-11-09 06:23 JST)

User reset usage and authorized autonomous Bluetooth/AndroidAuto/CarPlay investigation and fixes until09:00 JST, explicitly retaining8-device scope. Physical OPPO/moto USB stay-awake changed from0 to15/2 with original values saved. Physical iPhone already hadNever selected in Auto-Lock at this restart; no change made. FourAVDs use temporary stay-awake7 with originals saved. Existing registrations were preserved. iOS Simulator started in explicit foreground transport mode and POWER ON reachedREADY; it does not emulate Apple background PTT/APNs.

All8 senders were exercised once: physicaliPhone withBluetooth headset, iOS Simulator, OPPO, moto, API34/35/36/37. Each20s finite gesture observed the other7 devicesBUSY_REMOTE while the gesture was still active, then all8READY after release.8/8 cases,56receiver observations, no errors. Raw UI/state evidence is private in morning-eight-control. No known-audio injection or acoustic measurement was used; this is a control consistency acceptance, not proof of audible speech or microphone routing.

Added user-requested follow-up after communication/car tests: compare dynamic input gain against documented OFF/MANUAL/AUTO behavior, route isolation, fixed gain within an utterance, normal-end-only bounded learning, silence rejection and limiter behavior. Current product spec retainsAUTO+12dB versusMANUAL+24dB; do not silently reinterpret that as continuous mid-speech AGC. Android headset-specific behavior needs actual hardware distinct from the physicaliPhone headset. Preserve09:00 deadline and restore this morning's original screen settings at completion.


## Morning audio capture isolation and gain follow-up

After the eight-way control pass, API34 sent a known synthetic utterance with normal finite PTT. API37 matched the known signal (correlation0.181, ordered segments passed); API35/36 did not (correlation0). Whole audio trial failed. Independent AudioTrack output of660Hz for10s then reproduced bad capture on both API35/36:480000 frames written/played without player error, but only49809/49707 captured samples, dominant frequency about5647Hz and RMS2.76/2.79. This isolates a capture infrastructure failure; it does not prove KOEON audio acceptance on those receivers. Raw audio was not saved.

During the synthetic utterance, fresh physicaliPhone0902 diagnostics showed RX_ACTIVE, BluetoothHFP input/output at16kHz, firstPCM generation matching the current receive generation. iOS Simulator showed RX_ACTIVE and matching generation with built-in48kHz. Neither metadata observation proves acoustic audibility or headset microphoneTX.

AVDs and the enrolled iOS Simulator were shut down without wiping data for resource-isolated gain regression builds. The newly reproduced iOS AUTO overload discrepancy, fix, automated verification and remaining cross-platform differences are recorded in [input gain verification](INPUT_GAIN_VERIFICATION_20261109.md). The eight-endpoint lab must be restored before further mixed-device trials.


## Vehicle-route follow-up (2026-11-09 morning)

The official Android Auto DHU was reconnected to the physical moto with USB accessory transport. Protocol1.7 and TLS1.2 negotiated successfully, but the phone again displayed the first-run welcome/consent screen describing notification, contact, message and location sharing. No new data-sharing consent was accepted. Existing Android runtime grants were inspected read-only; they are not evidence that setup or audio routing completed. DHU was stopped and KOEON brought forward. Vehicle audio/PTT acceptance remains untested.

A fresh search still found no standalone CarPlay Simulator executable or Additional Tools disk image in the installed-app/download locations. Xcode includes a CarPlay device plugin, which alone does not establish a usable physical-CarPlay simulator. [Apple's CarPlay page](https://developer.apple.com/carplay/) identifies the Additional Tools distribution; [Google's DHU documentation](https://developer.android.com/training/cars/testing/dhu) describes the Android tool used here.

Code review found a separate CarPlay route-safety gap: `carAudio` was classified as Unknown, and external route-loss detection covered only Bluetooth, wired and USB routes. Consequently the existing PTT safety-stop gate did not recognize carAudio disconnects. The regression test failed before the fix with two assertions (Unknown classification and false disconnect detection). After mapping carAudio to CarPlay and including it in external-route loss, all321 iOS tests completed with319 passed/2 dedicated tests skipped, no failures; parity/diff checks passed. Category changes and built-in speaker loss remain excluded. This change is not yet distributed or device-verified. This is not a reproduction or resolution of the user's unspecified CarPlay audio failure (#58); physical connection and acoustic verification remain required.

## One-vCPU retest and Android Auto focus recovery failure

All four AVDs were restarted with1vCPU/1536MB, keeping audio enabled and app data. API37 encountered System UI ANR; Wait was selected. The independent API35/36 tone captures still failed despite480000 AudioTrack frames written/played:48075/49911 captured samples, dominant≈5647Hz, RMS≈2.86/2.79. Detailed API35 capture returned48kHz/S16 but packets contained33–35 samples, amplitude−4…+4. Reducing virtual CPU count did not fix capture. Do not accept those media measurements as product audio quality results.

API37 briefly showed enrollment UI. Its installedAPK matchede7cf936 (SHA25646b44fb00a49a14a5c6bfde805174079cde42b3a2c44684f6cb856c680bb0ca9). Updating in place to published6711527 restored the existingtest7/channel screen without entering an invite code; POWER ON then reachedREADY. The initial UI alone does not prove credential deletion.

The iPhone initially showedRX_END_PENDING on foreground activation, but the saved21:55:15Z diagnostic hadRX_IDLE/CONNECTED/READY/PTT eligible. No persistent pending-state failure is established from that observation.

The eight-participant list was confirmed after restoration. Repeated finite20s control trials passed for physicaliPhone, iOSsim andOPPO (seven receiversBUSY_REMOTE and all eightREADY afterward). The moto trial failed: all receivers remainedREADY while the finite gesture was active. Testing stopped at that failure; remaining four senders were not tested in this run.

Motos UI actually displayedAUDIO INTERRUPTED and disabledPTT despite aREADY label. OS audio focus was still owned by Android Auto after DHU exit. Ending the test-started Android Auto process emptied the OS focus stack, but KOEON remainedINTERRUPTED withPTT disabled. Field diagnostics incorrectly reportedpttEligible=true/READY withaudio.focus=Lost. InstalledmotoAPK also matchese7cf936/1.0.16(17). No POWER reset was used. This is tracked as [Issue #63](https://github.com/dennomusooffice/koeon-client/issues/63), currently reproduced and unresolved; private evidence includes one-core-moto-tx-failure.json and moto-after-dhu-stop audio/UI snapshots. Do not force audio focus away from a real call or another active audio owner while fixing recovery.

## 2026-11-09 07:31 JST — focus candidate eight-endpoint control retest

Android physical2 + AVD4 now run signed local1.0.17(18), source45176b1695047b061673de25db8db2b2867a1f80, APK SHA25672e946a17e672b22b0d00585f9ecb961561fde25b7af2b4fe4d261fb8ff6c085. PhysicaliPhone remains1.0(2026110902), actualBluetooth attached; enrollediOSsim remains its existing foreground-only build. OPPOpovo network configuration unchanged.

Preflight checks bothREADY and enabledPTT. First attempt stopped before transmitting because API37's emulator process disappeared; host emulator log reported QEMU main/CPU threads hanging for15s. Restarted only that AVD without wiping data, recovered its enrolled account andREADY. This is recorded as test infrastructure failure, not a KOEON network failure.

Retest completed all8senders with finite20s gestures. Each sender producedBUSY_REMOTE on all7receivers while the gesture was active; all8returnedREADY afterward:8/8control scenarios,56receiver observations. The moto sender that failed before the audio-focus fix now passed. No synthetic or human audio was injected in this control matrix; it does not establish eight-endpoint audibility, acoustic quality, or post-interruption media correctness. Known-speech capture is a separate subsequent trial.

Private evidence: focus-fixed-eight-control/results.json and timestamped XML snapshots. No identifiers or raw audio published. Latest source/docsHEAD before this retest3b2527b; physical installedbuild provenance remains as above, not inferred from current workingtree.

Known-speech follow-up (same installedbuilds, A14sender):6.88s synthetic source injected only afterTALKING; injectionfinished and senderREADYafterward. API37capture matched knownspeech(correlation0.219649), whereasAPI35/36 remained correlation0 with only98,702/98,701samples in the capture window. Their earlier standaloneAudioTrack/outputprobe failures remain relevant; this does not isolate KOEON as their cause. API37samplecount1,530,368. No rawreceiveraudio saved.

Freshphysical diagnostics at22:30:54Z/22:31:07Z: iPhoneCONNECTED/IDLE/RX_IDLE/eligible; firstPCM generation32 matched Appleactivationgeneration32, foreground. Atpost-trialcapture its idleoutput wasBluetoothA2DP44.1kHz with noactiveinput; do not describe that idle snapshot as proof ofHFP during the utterance. MotoCONNECTED/IDLE/RX_IDLE/eligible, focusGranted/RXvalidated, audioavailabilityREADY, recovery success, roomaggregatePCMcallbacks present. RoomaggregatePCM and iPhonegenerationmetadata are not a per-utterance acoustic recording or audibility verdict. PhysicalBluetooth acousticquality remains unverified while the owner is asleep.

## Capture-infrastructure follow-up after the0903build

After stoppingAVDs forXcode, booting the enrollediOSsim/WDA first, thenbooting4AVDs sequentially, independent660Hz AudioTrack probes became measurable again. API35:48kHzstereo660.04Hz,44.1kHzmono660.12Hz,16kHzmono660.00Hz. Those three probes overlapped the generalAVDREADYrestoration script, so they do not isolate format as the cause. AfterAPI35READY wasconfirmed, original48kHzmono recovered768,511samples/16s, dominant660.00Hz. API36original48kHzmono recovered766,822samples/16s, dominant661.70Hz. Bothplayersreported480,000written/playedframes andnoerror. RawPCMnot saved.

This demonstrates recovery of the measurement path afterreboot/reinitialization; it does not establish a stablefix or anapplicationbug. Do not attribute itsolely tostereo/mono, startuporderorload. Repeatknownspeech withall8READY andkeep independentoutputhealthchecks as a prerequisite for interpretingnegativecapture. The earlierfailedcapturesremainrecorded, not retroactivelypassed.

After0903physicalupdateandall8connected, A14→A15/A16/A17 knownspeechtrial passedall3PCMcomparisons. Whole-speechcorrelations0.429039/0.317756/0.148948; orderedsegmentsmatchedall3; samplecounts1,530,368/1,530,368/1,526,197. Source6.88s, injectionafterTALKING, completedinsidefinitegesture, senderREADYafterward, rawreceiveraudio notsaved. FreshiPhone0903diagnostic showedfirstPCM/Appleactivationgenerationmatchwithforegroundlifecycle. This is3validatedAVDmediareceivers plusiPhonePCMmetadata, not8acousticverdicts. PreviousAPI35/36failedrunsremainfailed; underlyingintermittentcaptureinitializationcauseisunresolved.

## 2026-11-09 08:07 JST — suspended iPhone first receive

With all eight endpoints connected, physical iOS 1.0 (2026110903), source `81cba30881545b1512022605ffb550c205e55e14`, remained in the background for 614 seconds. Appium reported suspended state before the single Android 14 synthetic-speech transmission. The iPhone was not passcode-locked; its Bluetooth headset remained connected. The Android 17 control receiver detected the known speech successfully. No resend or POWER operation preceded diagnostic collection.

The iPhone's background receive generation remained unsubscribed with no accepted PCM for about 6.6 seconds, even after RECONNECTING became CONNECTED. Foregrounding later rebuilt the runtime and produced a first-PCM record. The trace does not establish audibility, and foreground restoration overwrites some earlier restore fields. The exact sequence of subscription failure and restoration remains under investigation in #54/#50.

Code inspection found a concrete inconsistency: the room-level mixed-audio renderer unconditionally set `RxSnapshot.rxFirstPcmAt`, while the consistency guard rejected PCM for an unbound subscription. The recovery worker then exited on the non-nil snapshot timestamp. This allows unrelated/stale room callbacks to suppress recovery while diagnostics correctly report no viable media path. The patch requires the current receive generation's subscription to be active and the callback timestamp to be no earlier than RX start before notifying the RX controller, Apple coordinator or wake diagnostics. Legacy buffered audio keeps its independent callback path. Regression tests cover an unbound callback, recovery remaining eligible, a subsequent valid callback, a pre-start callback and idle RX. This addresses the contradictory evidence gate; it is not yet proof that every background failure has the same cause.

The PCM evidence-gate change passed the full iOS regression: **326 executed, 324 passed, two dedicated lab tests skipped, zero failures**. Feature-parity contract and diff checks passed. At this point the change is implemented/automatically tested, not yet distributed or device-verified; the background issue remains open.

## 0905 distribution and foreground baseline

Source `0c5bb16497f7beedf7c6c0874af88ba79b636314`, tree `b16cec18fef9a1a3430282429a5f070148060b1b`, was signed and uploaded as iOS 1.0 (2026110905); IPA SHA256 `67dae2b507c7f0e4869a713ad5718890893085c2a1f834bb4d998f675c64c126`. Fresh Apple reads confirmed VALID, internal/external IN_BETA_TESTING and assignment to two internal groups/one external group. The physical iPhone was updated through TestFlight with enrollment preserved.

All eight endpoints reached READY. A single Android14 known-speech trial produced ordered detections on Android16/17 (correlation 0.233/0.181). The physical iPhone recorded its matching first receive generation/PCM while active. This is transport evidence, not headset listening acceptance.

Android15's QEMU process had terminated after main-loop/CPU-thread hangs during restoration; restarting that AVD preserved enrollment. Its subsequent speech capture remained invalid: 161,363 samples over about 32 seconds and no known speech. Independent 660Hz/10-second AudioTrack output wrote/played 480,000 frames without player error, but 16-second gRPC capture returned only 50,386 samples at 48kHz, near-zero values and no 660Hz. The same failure persisted at 44.1kHz and 16kHz, and with KOEON force-stopped before the independent test (44,981 samples at 48kHz). KOEON was then relaunched and all four AVDs restored to READY. This remains a test infrastructure limitation in #59, not a valid negative acoustic verdict for KOEON. Raw receiver audio was not saved.

## 0905 background repetition and interpretation

Two independent suspended-background waits were exercised with Bluetooth connected and the iPhone unlocked: **323 seconds** and **335 seconds**. Each used one finite Android14 known-speech transmission, no resend or POWER operation, and Android17 detected the known speech in both trials.

| Trial | Incoming push (UTC) | Retained wake PCM completion | Foregrounding only after |
| --- | --- | --- | --- |
| 1 | 23:36:18 | 23:36:20 | 23:36:51 |
| 2 | 23:44:08 | 23:44:09 | 23:44:38 |

The completed wake ledger supports newly accepted PCM during background in both trials. In 0905 the LiveKit callback must pass the current-subscription/start-time check before setting this evidence. Current first-PCM fields were overwritten by later foreground runtime restoration (23:36:53 / 23:44:40). The first quick interpretation of trial 1 incorrectly used that overwritten current field to say background PCM was absent; the completed ledger corrected the interpretation, and the correction is recorded on #54/#50/#55. Do not repeat that mistake or interpret PCM callbacks as subjective Bluetooth listening acceptance. Completed per-receive/runtime/lifecycle evidence still needs clearer retention in #50.

At 08:46 JST all eight endpoints were READY. USB stay-awake was restored to recorded originals: physical OPPO/moto 0, four AVDs 1. Temporary field/output/focus probe helpers were removed where installed. The iPhone's original Auto-Lock Never was preserved, as were enrollment, gains and OPPO's povo network. Four AVDs were then shut down without wiping data for the final simulator-only code regression; no further physical-device operations are planned in this window.

## Final simulator-only subscription-order regression

After physical-device release, code review found that `activateRemoteAudioSubscription` awaits the SDK before assigning the active generation. An older request can therefore complete after a newer one and replace the generation gate. A deterministic regression against 0905 source reproduced four failed assertions: generation 2 was replaced by generation 1, the newer discard failed, and the old generation could reactivate after completion.

The fix keeps the latest generation fence after drain, rejects older activation completions, preserves explicit same-generation recovery after a decoder flush, and resets the fence only on runtime reset. SDK completions also verify their original Room identity before modifying the current gate or continuing a discard against a replacement Room. This is a separately reproduced ordering defect; it is not established as the initiating cause of the physical background symptom. Full automated validation and any distribution are recorded separately from the 0905 device trials.

The first fixed run passed 327 tests (325 passed, two dedicated lab skips). A final strengthening explicitly binds the SDK operation itself to the captured source Room, in addition to fencing completion. The final-source rerun is required before publishing that addition. The ordering regression covers newer active state, newer drained state, explicit same-generation recovery, and reset for a new runtime; a live SDK completion race has not been reproduced on hardware.

Final source also passed **327 executed / 325 passed / two dedicated lab skips / zero failures**, with parity and diff checks successful. The subscription-order fix is automatically tested; its additional Room-identity fencing has not been exercised in a physical completion race. No physical-device test was restarted after restoration.

Subscription-order commit `e68565f46a161599659d9387cb4b99b5196ccf5c` (tree `98f02e0c6500f8a2d2fe01d60c5d40d03a2e7c5c`) was signed/uploaded as iOS 1.0 (2026110906), IPA SHA256 `01cc279f4b1f67d76a6a3b1e72479c560c69ebb0c0bacd91bc63ebb95e781baa`. Apple processing and external tester availability require the final read recorded below. The physical iPhone was last verified on 0905; do not attribute its device trials to 0906.

Final Apple re-read at approximately 08:56 JST confirmed 0906 VALID, non-exempt encryption false, internal/external IN_BETA_TESTING, and two internal/one external groups assigned. This is distribution verification, not 0906 device acceptance. The requested 09:00 pause remains in force; no automatic device-test restart is scheduled.
