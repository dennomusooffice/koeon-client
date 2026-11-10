# Xiaomi NEW6: 自動PTT・Bluetooth受入れ途中結果

2026-11-10。追跡 [#79](https://github.com/dennomusooffice/koeon-client/issues/79)、操作ツール [PR #81](https://github.com/dennomusooffice/koeon-client/pull/81)。

## 要求・範囲・停止条件

Xiaomiの自動PTT不成立を切り分け、操作ツールを修正し、環境③のBluetooth送受信・音量・ゲイン等を進める。実機1台とSIM5を使用。実機操作は所有者指定の2026-11-11 00:45まで、利用量残り5%未満でも停止する。登録・権限・Floor・LiveKitのみの輸送を維持し、実音声を保存しない。OSの入力権限を回避しない。

操作ツールの完了条件は有限PTTの受理と解放、5相手の受信状態、期限・例外時の解放検証とGitHub記録。端末全体の受入れは別で、可聴性・必須ケースの証拠が揃うまでACCEPTEDにしない。

## 構成・配信の区別

- 対象: Redmi Note 13 Pro+ 5G / Android 16、公開Android **1.0.19(20)**。
- アプリソース: `d38a07db65483387d582f686aee91eee0f5de491`。
- APK SHA-256: `537bf0f08d97de5aeef3f3215c4c863f96ade950e8d75074f3ca50c40874236a`。インストール済みbase APKと照合済み。
- Bluetoothヘッドセット接続、通常のスタッフ登録・チャンネル所属を保持。
- 比較: Android 14/15/16は1.0.21(22)、Android 17は1.0.19(20)、iOSシミュレーターは1.0(2026111001)。ビルド混在。相手側ソースSHAの同一性は今回未確定。
- 今回は試験ツールの変更。アプリ変更・再配信・mainマージは行っていない。PRのbaseは既存開発ブランチ`codex/remove-batv1`。

## 操作ツールの原因切り分けと修正

通常のADB swipeは終了コード0でもアプリのDOWNを記録しないことがあり、OSの入力注入失敗ログもあった。所有者が指で押すとTALKINGになる。DOWN/sleep/UPだけの候補も2回中1回しか成立せず、最終ツールから除外した。

scrcpyの制御のみを持続接続しても、新規接続で最初のPTTが失われ、続く2回は成立する比較を反復した。UIAutomatorなしでも同じだったため、UIAutomatorだけが原因という仮説は採用しない。操作のない領域でDOWN/UPを一度送ってからPTTを行うと3/3成立した。MIUI内部の原因は未確定であり、観測に基づく回避策として扱う。

公式5.0.1サーバーをSHA検証し、音声・動画・クリップボード自動同期を無効化。明示したシリアル・画面サイズ・試験期限を要求し、PTTは1〜10秒。観測が終わらなくてもUPを送るタイマーとfinally解放を設けた。接続と一時ファイルはその実行が所有するものだけ削除する。詳細は[PHYSICAL_PTT.md](../../scripts/test-lab/PHYSICAL_PTT.md)。

## 実測

| ケース | 結果・証拠 | 判定の限界 |
| --- | --- | --- |
| 初期化後の8秒PTT、5回 | 5/5 TALKING→READY、全5相手BUSY_REMOTE→READY。DOWN/UP/CANCEL 16/16/0→21/21/0 | 制御のみ。可聴性ではない |
| MANUAL +6dB、1回 | 全5相手の制御成立、350400 samples、pre/post RMS -10.57/-6.40dBFS、post peak -1.00dBFS、limiter77958 | 強い入力で制限器が作用。線形+6dB・音質良好とはしない |
| AUTO、3回 | 全5相手の制御成立。最終pre/post RMS -46.87/-48.87dBFS、limiter0、次送信用effective -1dB | 最終送信の-2dBと次値-1dBは正常終了後学習の仕様と区別。音場未校正 |
| Bluetooth OFF→ON | ON・Bluetooth経路・READY復帰 | ペアリング登録は保持 |
| 再接続後Xiaomi→SIM5 | 1/1、全5相手の制御成立、DOWN/UP/CANCEL 26/26/0 | 可聴性未確認 |
| 再接続後SIM5→Xiaomi | 各相手1回、全5回BUSY_REMOTE→READY | マイク入力・可聴性は別 |
| アプリ音量 | OS基準8/15→7/15→8/15を確認 | 初回UIは8/11で古い可能性。初回OS値未採取のため、その実音量の厳密復元は未証明 |
| 合成音声 | 投入前にAndroid15 QEMU無応答・gRPC切断。音声注入未実施 | ENV_BLOCKED。受信音声不良とは扱わない |

OFFではpre/post RMS同値。AUTO・MANUALの数値はWebRTC FloatS16メーターであり、実音声は保存していない。Mac出力は元からミュートで変更なし。相手の復号PCM診断はROOM全体の累積値なので、その値だけで今回の単一発話の可聴性を証明しない。

## 環境障害・残件

Android16/17はQEMU CPU/main-loopの15秒無応答後に終了した。再起動・通常POWER ON後、上記5回は通った。Android15も合成音声の準備中に停止し、音声注入前に失敗した。ホストメモリ不足やKOEONの不具合とは未確定。仮想マイク設定の復元RPCも失敗したため、該当AVDを再起動した。停止前ランタイム値の厳密復元は未証明で、所有AVDは試験終了時に停止する。

音量表示の同期不一致は別の製品課題 [#82](https://github.com/dennomusooffice/koeon-client/issues/82) として記録。アプリ初期化時と音量操作直後以外の表示更新、経路変化とOEMの段階換算を調べる必要がある。今回のツールPRへ製品修正を混在させない。

実Bluetoothの聞こえ方、弱音/過大音を校正したマイク性能、実物のボタン、画面ロック/Doze、実測128kbpsで12/24/48kbpsの可聴性は未検証。単なるエミュレーターの速度設定表示を帯域制限の証拠にしない。全必須条件を満たしていないため、NEW6全体のACCEPTED判定は出さない。
