# PTT開始レイテンシ

この文書は、PTT押下から送信開始までのPublic client側の境界と、実機で確認すべき指標を定義します。

## 安全境界

- UIは押下を直ちに`preparing` / `REQUESTING_FLOOR`として表示します。
- microphone publicationは有効なfloor grantより前には開始しません。
- RX_READYはcold-wake receiverを保護するbest-effort barrierです。現在の4,000ms上限を、レイテンシだけを理由に短縮しません。
- iOSのApple PushToTalk activationはfloor grant後にRX_READYと並列で準備します。microphone publicationはRX_READY完了とApple activationの両方が成立するまで開始しません。
- Room、track、audio engineはintercom session中にwarm状態を維持し、PTT押下ごとのreconnect、rejoin、track再生成を行いません。

## 計測境界

client diagnosticsでは、少なくとも次を相関できます。

```text
ptt_down
local_ui_feedback
floor_acquire_request_start
floor_granted
control_start_sent
ready_barrier_start
ready_barrier_complete
apple_begin_requested (iOS)
apple_audio_session_activated (iOS)
track_publish_ready
talking
```

raw audio、token、credential、endpoint値は診断へ記録しません。`first_outbound_pcm`、`remote_first_pcm`、`remote_audible_ready`はSDK内部または受信実機との相関が必要なため、Public clientだけの自動テストで推測しません。

## 実機受入

以下は最終signed buildでHumanが測定します。

```text
PTT_DOWN_TO_UI_P95_MS <= 100
HUMAN_SPEAK_TO_REMOTE_AUDIBLE_P95_MS <= 700
HUMAN_SPEAK_TO_REMOTE_AUDIBLE_MAX_MS <= 1000
LEADING_CLIP = 0
LAG_CONVERGE_P95_MS <= 250
REMOTE_END_TO_NEXT_PTT_P95_MS <= 500
```

既存のprepared audio pathとSDK prewarmを維持します。現在のBATv1には上限6秒のPCMバッファがあります。leading clipおよびcatch-up値は実機受入で確定し、未計測値をPASSとして扱いません。

## Androidの短い発話（2026-10-31修正、未配信）

Floor取得済み・RX_READY待ち中にUPした場合、BATv1では取得済みPCMを凍結し、準備完了または従来の4,000ms上限まで待って送信します。UP後の新たなPCMは保持せず、最後の不完全な20msフレームはゼロ埋めします。凍結後にhangover録音を追加しません。音声final marker、control END、Floor releaseの順に終了します。

Floor取得前のUPや、安全停止・準備待ち中のFloor更新失敗は保留音声を破棄します。非バッファ経路は従来どおり準備待ちをキャンセルします。iOS送信側と実機受入は別途確認が必要です。詳細は[オフライン調査記録](OFFLINE_FIELD_RELIABILITY_20261031.md)、[Issue #37](https://github.com/dennomusooffice/koeon-client/issues/37)を参照してください。
