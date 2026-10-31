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
