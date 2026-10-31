# 実機接続なしでのフィールド不具合調査（2026-10-31）

実機操作は12:17:04 JSTに終了した。以後は保存済み証拠、ソース、Simulator／単体テスト、GitHub、App Store Connectの読み取りで調査する。端末を再接続・操作していない。

## 今回のiPhoneクラッシュを既存記録と分離

利用者の追加回答は「別の利用者」「11:00頃」「現在公開されているバージョン」。[Issue #42](https://github.com/dennomusooffice/koeon-client/issues/42)で追跡する。

- Apple APIでは最新ビルド2026103107がVALID / IN_BETA_TESTING。影響端末に実際に入っていた番号は未確認。
- ローカルの09:30・3104・FRONTBOARD / 0xBAADCA11は[Issue #36](https://github.com/dennomusooffice/koeon-client/issues/36)の別件。
- AppleのbetaFeedbackCrashSubmissionsは11件で、取得できた一覧に10/31の提出はなく、8〜9月の記録だった。3101〜3107のdiagnosticSignaturesは404。今回のクラッシュが存在しないという意味ではない。
- 過去のAppleクラッシュには9/1のAVAudioEngineグラフ形式設定時のSIGABRT、8/16のincomingPushResult内MainActor.assumeIsolatedによるSIGTRAPがある。現行コードでは標準Float32グラフと非同期MainActor移送へ変更済み。過去の例外を11:00の原因として転用しない。
- 今回の.ips、実ビルド、直前操作・画面ロック状態は未取得。生ログ・利用者情報・認証情報は公開しない。

Apple API仕様: [Beta feedback crash submissions](https://developer.apple.com/documentation/appstoreconnectapi/beta-feedback-crash-submissions)。テスターから提出された記録を取得するAPIであり、すべてのクラッシュの即時収集を保証するものとして扱わない。

## iOS初期化の競合対策

修正コミット: `cf9d729d982e633c3cd7afbc19bec1f687ad2486`。

`ApplePushToTalkController.initialize()`は、manager生成をawaitする間に再入できた。またmanager代入後の復元設定をawaitしている最中でも、別の呼出しはmanagerが非nilというだけで初期化完了として返っていた。復元設定が失敗した場合も、以降の初期化で設定を再試行しなかった。

初期化と復元設定全体を一つのTaskで共有し、同時呼出しを同じ完了まで待たせる。成功後は再実行せず、失敗後は再試行できる。一つの待機元のキャンセルで共有初期化をキャンセルしない。生成済みmanagerは設定再試行時に再利用する。

同時呼出し、設定失敗後の再試行、待機元キャンセルの3テストを追加。これはコード上の競合対策であり、11:00のクラッシュ原因を確定したものではない。Appleの実サービス・ロック状態での動作は未検証。

## Androidの機種差と自動ゲイン

実測の詳細は[SO-52C調査記録](ANDROID_SO52C_AUDIO_20261031.md)。内蔵+18dB、有線+24dBで利用者が「十分な音量で明瞭」と確認した。別機種A303OPの古い診断はゲイン測定値がnullで、同じ条件の定量比較には使えない。SO-52C固有の故障、または全Android共通の感度不足とは断定しない。

Androidの[AutomaticGainControl](https://developer.android.com/reference/android/media/audiofx/AutomaticGainControl)は端末によって実装・既定有効状態が異なる。[VOICE_COMMUNICATION](https://developer.android.com/reference/android/media/MediaRecorder.AudioSource#VOICE_COMMUNICATION)も、利用可能な場合にAGC等を利用する仕様である。ソフトウェアWebRTC AGCの設定値だけで、BATv1へ渡る録音PCMにその効果が適用されているとは判断できない。ここで「raw AudioRecord」はWebRTC APM前を指し、端末内部の処理まで無効な音声を意味しない。

したがって、機種名による固定増幅より、実際に送るPCMのレベルと入力ルートごとの補正が適する。ただし現在の比較ではマイク距離・声量も統制されておらず、必要補正量を機種だけから決められない。

### 今回修正したAUTOの欠陥

[Issue #43](https://github.com/dennomusooffice/koeon-client/issues/43)、修正 `cf9d729`。iOSにも同じ計算があったため両方を修正した。

- 旧式は入力-24dBFS・現在+6dBで出力が目標-18dBFSになっていても、さらに+1dB加算した。必要な総ゲインとの差に向かって最大1dBずつ調整する式に変更した。
- 無音の送信でもゲインが上がった。-60dBFS以下と非有限値を学習対象から除外した。これは音声と雑音を識別するVADではない。
- Androidでは追加した3テストが修正前に失敗し、修正後に成功した。実PCM経路で8回無音を送ってもゲインが増えないことを含む。
- 既定OFF、ルート別保存、発話中の固定ゲイン、手動上限+24dB、AUTO上限+12dB、既存リミッターを維持した。

### 自動補正の可否と未解決範囲

BATv1の送信直前PCMに補正を掛ける経路は実装・手動の実機検証済みなので、アプリ側の自動レベル補正は可能。今回のAUTOは収束計算を直した限定的な補正であり、SO-52Cの+18/+24dBを自動で補う実装にはまだなっていない。

AUTOの上限を一律+24dBにするだけでは、一定の環境雑音も増幅してしまう。拡張には発話と背景雑音の評価、ルート変更時の学習値、ピーク抑制、声量急変時の追従を合わせて検証する必要がある。現在は実機検証できないため、確認済みのSO-52C手動プロファイルを自動的に置き換えない。

次の検証ではSO-52Cと別機種について、同じ声・距離・受信音量で内蔵／有線／Bluetoothを比較する。測定は入力・処理後RMS/peak、リミッター比率、入力ルート、実際の聴取結果を揃える。音声内容を保存せず集計値で評価する。

## 今回の検証・配信状態

| 項目 | 結果 |
| --- | --- |
| Android単体テスト | 159件成功（追加3件） |
| Android Lint / assembleDebug | 成功 |
| iOS Simulator全テスト | 241件成功（初期化3件・AUTO2件追加） |
| feature-parity-contract / diff whitespace | 成功 |
| 新しい正式署名ビルド・TestFlight／GitHub Release | 今回の変更は未配信 |
| 実機の再検証・11:00クラッシュ再現 | 未実施 |
| mainへのマージ | 未実施 |

保護ログは`.secret/offline-field/`に保持。公開資料へ生のログを転載しない。

## 続けて調べる項目

- #42: 新しいクラッシュ記録から終了理由・スタックを照合する。
- #39: Bluetooth受信時の出力ポート、音量、PCMレベル、エンジン状態を同時に記録できるようにする。終了後のA2DP表示は受信中の経路の証拠にならない。
- #39: Appleの[AVAudioEngineConfigurationChange通知](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification)では、ハードウェアのサンプルレート／チャンネル数変更でエンジンが停止・未初期化になる。現行プレイヤーはこの通知を監視しておらず、Apple音声セッション有効化時にのみ再開する。今回の無音との因果関係は未確認で、ルート変更中の再生・完了扱いを自動テストで調べる。
- #37: 受信準備待ち中にPTTを離す短い発話が破棄される経路を、Floor所有権と録音停止を保ったまま修正する。
- #43: AUTOの雑音判定・補正範囲の拡張は、今回の計算修正とは区別して検証する。
