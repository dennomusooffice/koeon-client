# SO-52Cの送信音量調査（2026-10-31）

追跡: [Issue #40](https://github.com/dennomusooffice/koeon-client/issues/40)。iOSのBluetooth受信問題 #39とは区別する。

## 実機・利用者の確認

- SO-52C、Android版1.0.9 (10)。内蔵マイクと有線イヤフォンの両方で送信が非常に小さい。受信は良好。
- 11:31 JSTの利用者による送信は626フレームを送出、final marker accepted、通常終了、READY復帰。相手iPhoneで受信自体は確認できたが、声が非常に小さい。
- ゲインOFF・0dB。入力／処理後RMS・peakはすべて未取得。値がないことを「入力が無音」と扱わない。
- パッケージ情報、音声サービス状態、logcat、Field Diagnostic JSONを保護されたローカル保存先へ採取。生の識別子・音声・秘密情報は公開しない。

## 確認できたコード上の欠陥

LiveKit 2.28.0のLocalAudioTrack.addSinkはAudioRecordSamplesDispatcherへ登録され、録音サンプルを受け取る。一方、既存のInputGainProcessorはWebRTC APM capturePostProcessorだけに登録されていた。BATv1は前者からPCM16を直接送るため、MIC GAINとレベル測定を迂回していた。

さらにWebRTC m144のAPM後処理はFloatS16を渡すが、既存コードはInt16として読み書きしていた。独自ゲインOFFではバッファを変更しないので、これだけで今回の音量不足の原因を断定しない。

参照する公式実装:

- [LocalAudioTrack 2.28.0](https://github.com/livekit/client-sdk-android/blob/v2.28.0/livekit-android-sdk/src/main/java/io/livekit/android/room/track/LocalAudioTrack.kt)
- [AudioRecordSamplesDispatcher 2.28.0](https://github.com/livekit/client-sdk-android/blob/v2.28.0/livekit-android-sdk/src/main/java/io/livekit/android/audio/AudioRecordSamplesDispatcher.kt)
- [WebRTC JNI float buffer](https://github.com/webrtc-sdk/webrtc/blob/m144_release/sdk/android/src/jni/pc/external_audio_processing_factory.cc)
- [WebRTC FloatS16 conversion](https://github.com/webrtc-sdk/webrtc/blob/m144_release/modules/audio_processing/audio_buffer.cc)

## 修正・検証範囲

BATv1の所有するPCMコピーに、既存のゲイン・リミッター・レベル測定を接続する。SDKの共有バッファは変更せず、未arm・不正形式では処理せず、送出終了後の待機音を送信レベルへ混ぜない。OFFはbit exact。従来RTP経路はFloatS16として処理する。診断へmeterSourceとmeterSampleCountを追加し、WebRTCの設定値とBATv1の実処理を区別する。

Android 1.0.10 (11)を検証用にビルドする。155件の自動テスト成功。実機の入力レベル、適正なゲイン、相手での可聴性は引き続き検証が必要。既定OFFを根拠なく全端末で増幅する変更は行っていない。

## 1.0.10の実機比較

1.0.10 (11)、dc65467をSO-52Cへ上書き導入し、版をADBで確認。

| 条件 | 入力RMS / peak | 処理後RMS / peak | limiter hits | 聴取 |
| --- | --- | --- | --- | --- |
| OFF、11:49 JST採取 | -41.02 / -22.43 dBFS | -41.02 / -22.43 dBFS | 0 | 基準の小さい音声 |
| MANUAL +12dB、11:53 JST採取 | -37.15 / -18.07 dBFS | -25.15 / -6.07 dBFS | 0 | 利用者「大きくなったが、まだ小さい」 |

両方でmeterSource=BATV1_PCM16、READY復帰。実際の送信PCMで正確に12dB増幅できたが、可聴性の改善は不足。別々の発話なので声量の差をゲイン効果に含めず、各発話の処理前後を比較する。

1.0.11 (12)、17b696dでは手動上限を+18dBへ拡張（AUTO上限と既定OFFは維持）し、モードをアプリ再起動後も保存する。ソフトリミッターは維持。+18dBの増幅と大入力時の上限保護を含む156件のテスト、Lint、parity gateに成功。次は+18dBの実測・聴取と有線ルートを確認する。

## 1.0.11の実機比較・設定保存

| マイク / ゲイン | 入力RMS / peak | 処理後RMS / peak | limiter hits / samples | 聴取 |
| --- | --- | --- | --- | --- |
| 内蔵 / +18dB | -29.90 / -8.90 dBFS | -15.12 / -1.00 dBFS | 17596 / 712320 | 十分な音量で明瞭 |
| 有線 / 0dB | -34.58 / -15.88 dBFS | -34.58 / -15.88 dBFS | 0 / 264000 | 小さい |
| 有線 / +18dB | -38.07 / -9.74 dBFS | -20.67 / -1.00 dBFS | 1550 / 747840 | まだ小さい |

有線用ゲインを設定後にアプリを意図的に停止・再起動し、MANUAL +18dBとREADYを再確認した。停止は試験操作であり自然発生クラッシュではない。内蔵と有線は独立プロファイル。Android AudioFlingerでも、稼働中の録音入力がAUDIO_DEVICE_IN_WIRED_HEADSET、PCM16・48kHz、VOICE_COMMUNICATIONであることを確認し、内蔵マイクの誤選択という仮説は今回の状態では否定した。

内蔵の発話は以前の試験より入力自体も大きい。試験間の差すべてをゲイン増加に帰属させない。ピーク保護の動作と利用者の聴取を併記する。有線は改善未達のため1.0.12 (13)で手動上限を+24dBへ拡張し、同じリミッターを維持して再比較する。内蔵の保存済み+18dBは変更しない。

## 1.0.12の実機結果と終了

- ソースe420208、Android 1.0.12 (13)の正式署名APKをSO-52Cへ導入し、版をADBで確認。156テスト、Lint、parity gate、正式署名・APK版検証成功。
- APK SHA-256: `e813e0d19372e7e1cf3d4fbd02738d90a5e1e56cb2caa6d15c91549a944807f0`。
- 有線+24dBを利用者がiPhoneで「十分な音量で明瞭」と確認。
- 12:16:56 JSTの診断: 入力RMS -42.60 / peak -16.23、処理後RMS -18.70 / peak -1.00 dBFS。リミッター1564 / 1010880サンプル（約0.155%）。CONNECTED、PTT IDLE、READY、RX_IDLEへ復帰。
- これまでの確認結果は、内蔵+18dB、有線+24dBで可聴性改善。端末やマイクによって必要ゲインは異なり、この設定を全機種に固定していない。
- 利用者の12:18解放指定に従い、12:17:04 JSTに実機操作終了。USB接続中の画面消灯設定を元の0へ復元・照合、一時診断アプリ削除、端末上の一時UIダンプ削除、logcat採取を停止。KOEONは接続・READYを維持。
- 生ログ・診断JSONは保護されたローカル保存先に保管。GitHubには集計値のみ記録。実機の聴取改善は確認済みだが、PR #41は未マージ、GitHub Releaseへの1.0.12公開は未実施。

## 後続のオフライン調査で判明した測定範囲

`a963f708dae7c15ecd9735651de71ca492b88a79`で、BATv1のゲイン測定開始をPTTのTRANSMITTING遷移からcaptureの開始へ移した。旧版は準備待ち中に録音した区間を測定リセットで失っていた。上表の数値は当時の観測値であり、録音全体のRMSとして新版と直接比較しない。内蔵+18dB・有線+24dBの聴取改善は利用者が確認済み。新しい測定区間とルート別学習の修正は未配信・実機未検証。[後続調査](OFFLINE_FIELD_RELIABILITY_20261031.md)、[Issue #43](https://github.com/dennomusooffice/koeon-client/issues/43)で追跡する。
