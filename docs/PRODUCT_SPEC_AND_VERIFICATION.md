# KOEON 共通製品仕様・設計・検証台帳

更新: 2026-10-31。基準ソースは `6fe000f8ac2c6cbc4695399c8025bd60f8b91143`、実機記録は `131d0136114ef171c484493ff7550a84df639668`。これは実装済み機能と目標・未達項目を区別する統合資料であり、すべての受入れ完了を宣言するものではない。

## 製品としての目標

iOSとAndroidで、同じチャンネルへ参加し、押して話し、離して受信へ戻れるインカムを提供する。画面の消灯・復帰や音声経路の変更でPOWER ONの意図を失わない。利用者に見える機能・設定・結果を揃える。OS固有の仕組みは内部の実装差として扱い、同じ機能を一方だけ省略する理由にはしない。

## 共通仕様と現在の到達点

| 機能 | 共通の期待動作・不変条件 | 現在の実装・検証と残件 |
| --- | --- | --- |
| 登録・参加 | 招待から登録し、選択したチャンネルで通信する | 両OSの招待解析・リンク契約を自動検証。画面遷移・エラー文言の網羅的な同等性監査は残る |
| POWER | ON中は受信を維持。明示OFFで離脱・通知登録解除 | iOS3112でOFF/ONの解除・再登録を実機確認。背景復帰失敗時も受信登録を保持する修正は#49 |
| PTT | 押下直後に準備中を表示。有効なFloor取得前に送出しない。離した後に新たな発話を取り込まない | 両OSに準備中PCM保持。iOSの1秒以下で送信0の試行があり、短発話の同等性は未達（#37） |
| 受信と終端 | 声の先頭・末尾を欠かさず再生し、再生後に次のPTTへ戻る | final marker→control END→Floor release。停止・世代交代競合を修正。実機の反復・中断試験は継続（#35/#45/#48） |
| ロック・背景 | POWER ON中の受信をロック後も維持し、復帰後も送受信できる | iOS3112で7分33秒ロック後の聴取成功。Android画面オフ受信も限定確認。電池単独・長時間・OS省電力の受入れは残る（#36/#39/#49） |
| 音声経路 | 内蔵・有線・Bluetoothの利用、切断・再接続後の送受信 | iOS3112 Bluetooth再接続後は両方向聴取良好、184/184・136/136。全機種・経路組合せの同等性は未検証 |
| 入力ゲイン | OFF/手動/AUTO、経路別保存、発話中の固定値、ピーク抑制 | 手動上限+24dB、AUTO上限+12dBを維持。AUTOは必要な総ゲインへ最大1dBずつ追従、−60dBFS以下・非有限値を除外。正常終端時のみ学習。雑音と声の識別、収束・他経路は残る（#40/#43） |
| 音質設定 | 12/24/48kbps、既定24、設定保存・診断を両OSに提供 | parity検査対象。設定表示値とBATv1固定PCM形式、RTP経路での実効値を混同しない |
| 操作機器 | タッチ・ヘッドセット等の入力と状態表示を整合させる | 利用可能なハードウェア差を含め、設定項目と操作結果の画面監査を実施予定。全入力方式の同等性は未確定 |
| 診断 | 原因を辿れる時刻・ビルド・結果を残し、秘密情報や音声は公開しない | 正常ポーリングの重複抑制と、現行統計とは別の直近終端保持を両OSに実装。未配信。JSON契約・再接続統合検証を継続（#50） |

## 内部設計

UIの表示期間とインカムセッションの寿命を分ける。認証・参加資格・Floor仲裁・短命LiveKitトークンの発行はサーバーが所有する。クライアントは受け取った権限と世代を照合し、古い非同期処理の完了で新しい接続・送受信を変更しない。

制御はLiveKitのPTT/RX_READYトピックを使用する。現在のBATv1音声はバッファされたPCMをHTTPSで輸送し、旧RTP経路とは区別する。PCMは48kHz・mono・PCM16LE、20ms単位。送信バッチは最大32フレームで、少量でも待たず送る。準備中に得た音声とライブ音声の順序を維持する。

Floor TTLは3秒、更新は1秒、連続送信上限60秒。RX_READYの上限は4秒で、期限切れをFloor権限の迂回に使わない。iOSはApple PushToTalkの音声所有権に従い、Androidは音声フォーカス・バックグラウンド実行制約に従う。iOSのBluetooth 16kHz等は共通PCM形式へ変換する。受信は実際の再生完了を待つが、中止を成功完了として記録しない。

詳細な契約は[PROTOCOL](PROTOCOL.md)、遅延条件は[PTT_STARTUP_LATENCY](PTT_STARTUP_LATENCY.md)、変更理由・検証履歴は[BUG_TRACKING](BUG_TRACKING.md)から辿る。

## 今後の実装・検証順序

1. #50: 実装した上限付き履歴・直近終端統計について、共通JSON契約とruntime再接続を含む統合検証を完了し、Android実機で確認する。音声や秘密値は保存しない。
2. #37/#46: 両OSの短押下・準備待ち・送信開始の状態遷移を比較する。iOSの短発話欠落を再現テストから修正し、Floor・Apple音声所有権は維持する。
3. #39/#45/#49: 切断、復帰失敗、音声経路変更、受信中断、連続話者交代をシミュレーターで検証し、Android実機でも操作・音声経路を確認する。
4. #43: AUTOの目標収束、無音・雑音、ルート変更、学習保存を比較する。SO-52Cの手動+18/+24dBを理由に、未評価のAUTO上限を自動拡張しない。
5. 両OSの画面・設定・操作結果を項目単位で比較し、ユーザー向け差分を埋める。OS特有の許可操作は共通の機能説明へ対応付ける。
6. 最終署名版の実機受入れと配布条件を確認する。CIブロッカー#47や未検証のiPhone実機条件を、ローカル成功で置き換えない。

## 検証計画・完了条件

| 層 | 手段 | 証明できること／残ること |
| --- | --- | --- |
| 共通契約 | `python3 scripts/feature-parity-contract.py`、protocolのlint/test | 対象契約の存在・値。全機能のUI同等性や可聴性は証明しない |
| iOS | `bash scripts/macos-build.sh ios-test` | 実装の状態遷移・PCM処理・キャンセル等。実機APNs背景起動、Bluetooth実経路、OS強制終了を完全再現できない |
| Android | `bash scripts/macos-build.sh android-check`、接続実機 | unit/Lint/buildと実機操作を分離。実機は登録を保持し、検証用変更を復元する |
| 聴取・遅延 | 最終署名版・実機ペア | UI反応p95≤100ms、声→相手可聴p95≤700ms/max≤1000ms、先頭欠け0、遅延収束p95≤250ms、受信終了→次PTT p95≤500ms。未測定を合格にしない |

各結果にはソースSHA、ビルド、環境、対象、成功・失敗・未実施を付ける。実装、自動検証、配信、実機確認、mainマージを別々に管理する。

## LiveKit更新の互換性監査

現行依存はAndroid SDK 2.28.0、Swift SDK 2.16.0（lock revision `79fb2beee98e45556bffebefa50b5d05c3382af1`）。別プロジェクトKOEONの `docs/07-operations/LIVEKIT_UPDATE_20261031.md` を確認し、別ホストで1.13.5→1.13.11へ更新した記録を発見した。記録には更新後の二者接続・音声publish/subscribe・reliable data・TURN成功がある。このクライアント側調査で稼働版を直接再取得したものではなく、ネイティブ両SDKの全経路の互換性確認とも区別する。

確認事項は、実稼働版・直前版、公式変更履歴、信号接続・再接続、参加者ID/メタデータ到着順、DataPacketとRX_READY、トークン権限、旧RTP音声経路。BATv1のHTTPS音声が正常でも、LiveKit制御の互換性まで証明したことにはしない。必要な変更を特定してからSDK更新を判断する。


[公式1.13.11変更履歴](https://github.com/livekit/livekit/blob/v1.13.11/CHANGELOG.md)には単一PeerConnection時のDataChannel交渉、データチャネルキャッシュ、DTLSロール、購読権限取消時の変更がある。制御パケット・再接続・権限変更の回帰対象とし、SDK更新必須／不要の結論は実装照合と接続試験後に記録する。

## 診断履歴の修正進捗

#50の正常ポーリング重複抑制をiOSで実装。世代とstageの完全一致をRAM上で照合し、正常なBEGIN/ENDを各世代の初回だけ保存する。照合キーは最大64件、永続履歴も64件を維持。エラーは抑制しない。再起動後は新しい最初のポーリングを記録する。古い世代が64キー以上後に再出現すれば再記録される有限窓であり、重要履歴を永久保存する仕組みではない。

大量ポーリング後の背景・失敗履歴の再読込、同じ8文字prefixを持つ別世代の分離、エラー保持を回帰対象とした。Androidにも同じ高頻度記録があり、同じ64キーの有限窓で正常ポーリングを抑制する対応を実装した。保存前に判定し、抑制したイベントではSharedPreferencesへの再保存も行わない。直近完了／失敗受信の統計保持は後続の`d7c8305`／`5a9938f`で両OSに追加した（下記参照）。再接続統合検証・実機確認は残り、#50全体は未完了。

検証: 追加2件は修正前に5 assertions失敗。修正後はiOS Simulator全293件成功（27.7秒）。この変更は未配信・実機未検証で、配信済み3112に含まれない。


Android追加3件は修正前にすべて失敗し、修正後は全187件・Lint・assembleDebug成功。iOSにも有限窓・再起動の追加検証を行い、全294件のテストケース成功を確認した（22:56 JSTにxcodebuildのTEST SUCCEEDED・終了コード0まで確認済み）。両OSとも新修正は未配信。A303OPの接続・認証を読み取り確認したが、本修正の実機導入・検証はまだ実施していない。

LiveKit接続設定の照合では、iOSはRoomOptionsの音声設定だけを上書きし、SDK2.16.0のsinglePeerConnection既定falseを使用している。AndroidもLiveKit.createの音声ハンドラーを上書きする構成である。サーバーのトークンはcanSubscribe=true、canPublishData=canPublishであり、購読権限取消の変更を理由に送信権限を広げない。単一PeerConnection向け変更がiOSの現在の設定へ直接当たるとは考えにくいが、これはコードからの推論であり、両SDKの接続・復帰試験の代替ではない。


### 直近受信統計の保持契約（#50、実装進行中）

現在の受信統計は現在のruntimeだけを示し、過去の値で埋め合わせない。別項目`lastBufferedReceive`は直近の正常終端または失敗の値コピーを最大1件保持する。正常drainと失敗を`outcome`で区別し、採取時刻・アプリビルド・終端理由・カーソル／final sequence・欠落数・drain時刻を照合する。測定できない出力観測やPCMレベルは0ではなくnullとする。アプリ内カウンターは聴取の証明ではない。

iOSは受信オブジェクトが再作成されてもSessionControllerが値コピーを保持する実装を追加した。正常drain／失敗の通知前にコピーし、通知中の世代交代でも証拠を失わない。古いruntimeの通知は採用しない。開始前の取消や空の新runtimeで直近終端を上書きしない。コピーから受信世代IDと再生世代tokenを除き、音声・認証情報を保存しない。保持はプロセス内のRAMだけで、アプリ再起動を越える永続保持は今回の対象外。

新規の交換・停止・識別子除去テスト、既存のdrain失敗テストを検証。iOS295ケース成功（22:58 JST）、23:08 JSTに最終TEST SUCCEEDED・終了コード0を確認。未配信・実機未検証。Androidの同じ`lastBufferedReceive`契約への対応とJSON出力の契約検証は残件であり、両OS対応完了とはしない。既存Android187件の結果はこの新しい保持機能の証明には使わない。


Androidにも同じ直近終端保持を実装した。SessionDiagnosticsに独立した値を保持し、runtime再接続／POWER OFF・ONで作り直す診断にも引き継ぐ。交換済みreceiverからの通知は採用せず、受信世代IDは値コピーから除外する。`lastBufferedReceive`の項目名はiOSと同じとし、Androidのプレイヤーで未測定の出力観測・エンジン失敗回数・PCMレベルはnullとする。異なるOSの0と未測定を同一視しない。

Androidは正常終端・drain失敗・破棄後保持・JSONでの現行値との分離・未測定値・識別子除去を検証し、189件／Lint／assembleDebugが成功（2026-10-31 23:03 JST）。iOSのJSON出力自体の契約テストと両OSでのruntime再接続を含む統合検証は残る。今回のdebug APKは未導入・未公開。配信版はAndroid1.0.13（14）、iOS1.0（2026103112）のまま。


### LiveKit Android接続設定の追加照合

SDK2.28.0の公式[RoomOptions](https://raw.githubusercontent.com/livekit/client-sdk-android/v2.28.0/livekit-android-sdk/src/main/java/io/livekit/android/RoomOptions.kt)・[ConnectOptions](https://raw.githubusercontent.com/livekit/client-sdk-android/v2.28.0/livekit-android-sdk/src/main/java/io/livekit/android/ConnectOptions.kt)とローカルに解決済みのAARを照合した。RoomOptionsにsinglePeerConnection指定はなく、ConnectOptionsはprotocolVersion v13、autoSubscribe trueが既定。ローカルAARのコンストラクターもv13を設定する。KOEONは`nextRoom.connect(url, token)`で既定ConnectOptionsを使っている。

[RTCEngine](https://raw.githubusercontent.com/livekit/client-sdk-android/v2.28.0/livekit-android-sdk/src/main/java/io/livekit/android/room/RTCEngine.kt)にはpublisherとsubscriberを分けた接続経路がある。従って今回のサーバー1.13.11の単一PeerConnection向け変更を使うためだけに、このクライアントの接続設定を変更する根拠は現時点ではない。これはソース／解決済みライブラリーの照合による限定判断であり、サーバー更新全体の互換性合格ではない。Swift SDKの既定v16とAndroidのv13の差は、直ちに製品機能差を意味しない。両SDKの接続・再接続、信頼性付き制御送信、RX_READYを実際に通して比較する必要がある。SDKや権限の変更はまだ行わない。


### 診断JSON契約の検証

直近受信のJSON生成をiOSでも直接呼び出せる値変換へ分離し、実際のJSON encode/decodeで共通17項目、正常／失敗、未測定null、識別子除去を検証した。AndroidのJSONテストにも同じ17項目の完全一致を追加した。iOS296ケース成功（23:09 JST、23:19 JSTにTEST SUCCEEDED・終了0を確認）、Android189件・Lint・build成功。iOSで観測済みのエンジン失敗0と、Androidで未測定のnullは意図した区別である。再接続を通したセッション統合検証と実機確認は引き続き残る。今回も未配信・main未マージ。


### A303OP実機での更新・再接続確認（23:14〜23:19 JST）

ソース`cd74d8dfa2a5b3dc18a7586556f5f60a3e0c81bc`から既存鍵で署名したローカル検証用APKを、アンインストールせず更新導入した。バージョンは1.0.13（14）を維持し、APK SHA-256は`6b6973423841f8f7586814d268431a4b8a1c7502d93a1bd2a33e054f1937c2e3`。GitHub Releaseには公開していない。

登録画面への再入力を要さずPOWER ONでき、診断でCONNECTED・READY・pttEligible=trueを確認。POWER OFF→ONを3回実施して全回READY復帰、20秒画面オフ後もREADY復帰し、再採取した診断でもCONNECTEDを確認した。MANUAL入力ゲイン設定も保持されている。新しい`lastBufferedReceive`キーは存在し、更新後の受信がないので値はnullである。

この実機試験で確認したのは更新時の登録維持・接続・明示再接続・短い画面オフからの状態復帰とJSON出力である。終端統計の非null値を実際の受信後に再接続して保持できるか、双方向音声の聴取、長時間省電力、LiveKit reliable data/RX_READYの互換性までは未検証。iPhone実機は使用していない。診断補助アプリは採取後に削除し、KOEONはREADYへ戻した。生の診断と更新前APKは保護フォルダへ保存し公開しない。


### 接続先バージョンの診断

両OSの`liveKit.serverVersion`に、SDKが接続先から受け取ったバージョンを出す。AndroidはRoom.serverInfo.version、iOSはRoom.serverVersionを参照する。接続済みで未取得ならnull、切断・再接続中もnullとし、前の接続先の値を現在値と誤認しない。バージョンから互換性全体を判定せず、接続・再接続と制御交換を別々に確認する。

Androidで既知値・未取得・古い値を持つ切断／再接続状態のJSONを検証し、190件・Lint・assembleDebug成功。iOS296ケース成功（最終結果収集中）。これは診断実装の検証であり、実際のネイティブ接続先バージョンの採取は続けて行う。SDK更新や接続設定変更は行っていない。


接続先バージョンの実機採取: A303OPへ`da489256832c08b5aecab536c5a438f3aa984575`の署名済みローカル検証APK 1.0.13（14）を更新導入し、POWER ON後にCONNECTED／READYと`liveKit.serverVersion=1.13.11`を確認した。APK SHA-256は`b48d579eb5b2b0e17c474c5c782a0068294a9d119c3b2ddc539d14c594e483d4`。サーバー更新記録とネイティブSDKの接続先報告は一致した。診断補助アプリは削除済み、GitHub Release未公開、iOS未配信。

稼働コンテナへのSSH経由の直接確認は成功していない（一般ユーザーのDockerソケット権限不足、その後のパスワード不要sudoによる取得も未確認）。サーバー／権限設定は変更していない。実機で報告されたバージョンと、この運用上の読み取り制約を混同しない。Androidの初回接続は確認できたが、1.13.11上のreliable data／RX_READY、再接続後の制御交換、iOSネイティブSDKでの接続試験は残る。
