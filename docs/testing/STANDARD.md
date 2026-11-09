# テスト環境と実行標準

## 構成

| 構成 | 端末 | 用途 |
| --- | --- | --- |
| ① SIM5 | Android14/API34、15/35、16/36、17/37のARM64 AVD＋iOS Simulator | 毎変更の機能・通信・制御・復旧の反復 |
| ② MIX7 | SIM5＋iPhone＋OPPO A79 5G | APNs/PTT背景、実Bluetooth、実LTE、メーカー差 |
| ② MIX8 | MIX7＋moto g64 5G | 別Android/車載/音声フォーカスの比較 |
| ③ NEW6 | SIM5＋新規端末1台（必要なら基準実機も追加） | 4時間以内の条件付き受入れ |

常設実機の存在は無期限の操作許可を意味しない。実機を含むrunは対象、開始/終了JST、復元値、操作者をmanifestに記録する。終了枠が未確定なら実機を操作せずSIM5を進める。今回の車載/反復実行は①のみを対象とする。

ローカル設定は `.secret/test-lab/config.json`、結果は `.secret/test-lab/runs/<UTC-run-id>/`。招待コード、端末UDID/serial、ユーザー/接続先を公開設定に入れない。既存の5テスト利用者を使い、登録画面に戻っても直ちに再登録/データ消去しない。まず認証/通信失敗・署名・Keychain/Keystoreを確認する。

## Macと準備順

Apple Silicon Mac、対応Xcode/Simulator runtime、JDK17、Android SDK platform-tools/emulator/API34–37 ARM64 images、Python3、Appium2＋XCUITestを使用。各runにOS/Xcode/Java/emulator/SDKバージョンを保存する。試験中にSDKを自動更新しない。既存のランタイムがない場合は事前準備として導入し、導入待ちをアプリ失敗に数えない。

1. `git status --short`、HEAD、APK/APP署名・ハッシュ・バージョンを記録。重いXcode/Gradleビルドは5台起動前に完了させる。
2. iOS SimulatorとそのUIテストランナーを先に起動し、応答を確認。
3. AVDを1台ずつ起動（1536MiB/2cores、cold boot、snapshotを使わない）。各台でboot_completed、UI応答、空き容量を確認して次へ。音声試験に`-no-audio`を使用しない。
4. 署名を検証して既存アプリを上書き更新する。署名不一致でuninstallしない。iOS Simulatorも既存のKeychainアクセス可能な署名で更新する。
5. 設定原本を保存: stay-awake、自動ロック、音量、ゲイン、音質、ネットワーク、権限。実機PINを記録/無効化しない。OPPOのpovo LTEは試験条件として維持する。
6. 全台が同一試験チャンネルのREADY・PTT有効・参加人数一致になったら開始。1台でも不足ならrunは`ENV_BLOCKED`。

標準コマンドの入口は `python3 scripts/test-lab/lab.py --help`。配布用テンプレートは `scripts/test-lab/config.example.json`。ハードコードされた私有serial/招待コードを含む過去の `.secret` スクリプトを標準手順の依存にしない。

## 判定と証拠

`PASS` / `PRODUCT_FAIL` / `ENV_FAIL` / `BLOCKED` / `NOT_RUN`を分ける。UI READY、RTP購読、decoded PCM、既知発話の検出、主観的聴取は別の判定であり相互の代用品にしない。現在のJSONだけでなく履歴を回収する。

- 各ケースにrunId/caseId、SHA/build、送信/受信alias、開始/終了UTC、単調時刻、条件、期待/実測、復元成否を付ける。
- 診断・OSログは非公開。GitHubには匿名化した数値とエラー分類、再現手順、commit、結果、残件を投稿する。
- gRPC音声captureが16秒なのに約5万samplesしかない等は基盤不合格。独立660Hz AudioTrack、無信号/逆順/位相対照、概ねsampleRate×durationのサンプル数を先に確認する。API35で独立出力も失敗した実績がある。KOEON強制終了後も失敗するならアプリの受信不合格に算入しない。
- 合成音は有限。PTTはpointerDown→有限pause→pointerUpを1コマンドにし、例外時もreleaseを試みる。開始音/TALKINGを確認する前に音を注入しない。実ユーザーの会話を録音しない。
- 捕捉した音声の相関offsetはそのまま口元→耳の遅延ではない。時計差、収録開始差、制御待ちを分ける。

## 必須ケース

| ID | 操作/条件 | 合格条件・限界 |
| --- | --- | --- |
| BASE | 全台POWER ON/参加 | 全台READY、期待人数、エラーなし |
| CTRL | 各台から1回送信、他4台を観測 | 各受信台BUSY_REMOTE、release後READY、残存話者なし。SIM5で20受信観測/round |
| RTP | Android各送信→他3Android＋iOS受信 | 有効captureでは既知発話/順序、iOSはPCM/購読履歴を別判定。iOS送信の音響試験がない場合はNOT_RUN |
| SHORT | 0.2/0.5/1/3秒押下、開始前UP、連打10回 | 有限終了、古い音声の後送なし、次PTT可能。準備前の発話は保証外 |
| RECOVER | ネット断10秒/30秒→復帰、端末単独再起動、session再参加 | 登録維持、復旧結果が明示、次の新規PTT成功。標準試験上限30秒超は失敗として解析 |
| FANOUT | 送信1/受信4、途中参加/離脱 | 他受信を阻害しない、旧世代の処理で新受信を停止しない |
| QUALITY | Opus12/24/48kbps、無制限/128kbps上下 | 各条件を別集計。独立帯域計測が通らないshapingを採用しない |
| IMPAIR | 制限＋RTT200/500ms、loss1/3%、再接続 | 制御完了、欠け、音声到達、復旧を個別評価。全条件対応を前提にしない |
| GAIN | OFF/MANUAL/AUTO、弱/通常/過大/無音、cancel/route変更 | 発話中固定、正常終了後のみ学習、±1dB、AUTO−6…+12、MANUAL+24、無音上昇なし |
| JOURNAL | 再起動/24h境界/時計変更/容量/途中行/大量イベント | 履歴復元、欠落明示、上書きされないcompleted RX、秘密/音声なし |
| CAR | 車載表示・音声focus/route/切断 | 下記の能力境界を明示。純粋なroute分類テストを実車合格としない |

①の標準ループはまず3round。1件の新規失敗でそのケースの再送を止め、全台の履歴とサーバー同時間帯を回収する。再現→原因/仮説→修正→赤/緑回帰→同条件3round→他条件の順。無期限反復、合格までの結果隠蔽、失敗履歴をPOWER操作で上書きする運用は禁止する。1round開始前と終了後に全台READYを確認する。

## 車載試験の能力境界

Android Auto（スマートフォン投影）とAndroid Automotive OS（車載OS）は別物。DHUを起動しただけでAudioFocusや車載マイク経路の検証済みとしない。Google公式DHU手順はAndroid Auto対応端末・Play Store/Autoの準備を前提とする。AVDに必要なAuto/Play構成がなければ①の投影試験はBLOCKEDとし、実装のfocus/recovery回帰だけを①で行う。実機の同意画面を回避するため非公式APKを入れない。

AppleはXcodeのiOS Simulator外部CarPlay画面と、Additional ToolsのCarPlay Simulatorを案内している。前者の表示確認と後者/実機の接続・音声経路を区別する。アプリがCarPlay用のカテゴリ/entitlementを持たない場合、車載ホームに表示されないことを通信不具合と断定しない。Apple PTTのAPNs背景起動、実Bluetooth HFP/A2DP、実車mic/割込みは①だけでは受入れできない。模擬できない項目は②へ引き継ぐ。

公式資料（2026-11-09確認）:
- https://developer.android.com/training/cars/testing/dhu
- https://developer.android.com/training/cars/testing
- https://developer.apple.com/documentation/carplay/using-the-carplay-simulator
- https://developer.apple.com/carplay/

## 終了・復元

PTT/tone停止→ログexport→状態/失敗を保存→ネットワーク・ゲイン・音量・画面設定を原本へ復元→自分で導入したprobeだけ削除→自分が起動したAVD/Simulator/runnerのみ停止。登録/Keychain/アプリデータは消さない。復元できない項目と実機期限をhandoffに明記。ハング時は全MacプロセスをkillせずPID/AVDを照合する。

### 登録済みiOS Simulatorの署名とXcode27の注意

単体回帰では署名無効のbuildを使用できるが、登録済みラボへの導入候補は `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=<既存team>` と既存endpointを指定して**リンク時から署名を有効**にする。unsigned buildへの後付けcodesignや「adhoc」の文字列確認だけではKeychain利用を保証しない。実行ファイルの`__entitlements` sectionを確認し、更新後に既存登録が戻ることを確認する。登録画面になった場合も招待の再発行やデータ消去を先に行わない。

Xcode27.2/Device HubではCarPlayはUSB実機接続のみで、iOS Simulatorは非対応（[公式既知問題](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes)、179494052）。旧SimulatorのExternal Displays手順を現行環境へそのまま適用しない。Auto packageの存在だけでも不十分で、stub版ではなく公式Auto本体とHead Unit serverの準備を確認する。
