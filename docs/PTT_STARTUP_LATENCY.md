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

Floor取得前のUPや、安全停止・準備待ち中のFloor更新失敗は保留音声を破棄します。非バッファ経路は従来どおり準備待ちをキャンセルします。詳細は[オフライン調査記録](OFFLINE_FIELD_RELIABILITY_20261031.md)、[Issue #37](https://github.com/dennomusooffice/koeon-client/issues/37)を参照してください。

## iOSの短い発話（2026-10-31修正、3109内部テスト配信・実機未確認）

Apple音声セッション有効化後・RX_READY待ち中のUPでは、PCMを凍結しローカル録音を停止してから準備完了を待ちます。取得済みの音声を送るためにApple音声セッションを再有効化しません。既存の4秒上限とFloor更新、final marker→control END→Floor releaseの順序を維持します。

安全停止・準備待ち中のFloor失効・RX_READYキャンセルでは保留音声を破棄します。Apple音声有効化前・準備待ち開始前のUPは中止します。両OSとも、新しい修正の実機受入・先頭末尾・ロック中の聴取は未検証です。

## 遅いHTTPでの送信蓄積（Issue #46）

両OSで送信要求の上限を10フレームからサーバー上限の32フレームへ拡大する。蓄積した場合の追い上げを改善し、少数フレームでも待たずに送る。150/250/500msの要求時間、4秒の初期蓄積と追加録音で、PCM順序・末尾・終了期限を自動検証済み。この変更はiOS3109内部配信・2cfff78由来のAndroid1.0.13候補へ収録済み。AndroidのGitHub公開はIssue #47で保留。RX_READY待ちと実機受入基準の達成は別の残件であり、この自動試験から可聴遅延の改善値を推定しない。

準備通知の追加対策として、iOSでSDK参加者IDの確認済み通知だけをメタデータ到着まで保留し、SDK端末情報と一致したときに再評価する。4秒の期限と本人確認は維持する。自動テスト済み・iOS3109内部配信済みで、フィールド遅延との因果関係は未確定。

Androidの準備通知はSDKのResult成功を確認してから成功と記録し、送信失敗時だけ150ms間隔・最大10回・全体4秒以内で再試行する。切断、受信終了、世代交代で止める。これは受信準備待ちの上限を伸ばす処理ではない。原因判別用にセッション不一致の分類別件数を診断へ追加する。自動検証・Android署名候補作成済み、公開保留。
