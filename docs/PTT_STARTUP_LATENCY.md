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

今回の実装は既存のprepared audio pathとSDK prewarmを維持します。独自PCM pre-roll / adaptive replayは、floor authorization、Apple PushToTalk、WebRTC captureの境界を跨ぐため、この変更では未実装です。leading clipおよびcatch-up値は実機受入で確定し、未計測値をPASSとして扱いません。
