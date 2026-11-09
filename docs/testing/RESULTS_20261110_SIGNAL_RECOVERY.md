# LiveKit接続タイムアウト・復旧の照合（2026-11-10）

関連: [server #40](https://github.com/dennomusooffice/koeon/issues/40)、[client #57](https://github.com/dennomusooffice/koeon-client/issues/57)。[ログ採取方法](../operations/LIVEKIT_LOG_COLLECTION.md)。

## 対象と確認事実

既存のAndroid 1.0.21 (22)、ソース `3b916970d6c3dd1ea2c1a2f762186bbb58822bc3` の3台AVD試験と、LiveKit server v1.13.11ログを突合した。SDKはAndroid 2.28.0 / OkHttp 4.12.0。実機試験期限07:00以降に端末操作をしていない。

JST 06:43:14.858に送受信セッションがSERVER_LEAVE_CONNECTION_TIMEOUTを受信。サーバーは06:43:19.453に同じ参加者をPEER_CONNECTION_DISCONNECTEDで削除。06:43:25.465のresumeは参加者がないため失敗し、クライアントは25.870にSTATE_MISMATCHを受け取る。新規参加者は27.325にactiveになる。STATE_MISMATCHは初回障害と別の認証不具合だとは断定できない。

LiveKit v1.13.11 `participant.go` はtransport failure後5秒で参加者を削除する。SDK 2.28.0の`onLeave(RESUME)`はsignal close通知を待つ。`SignalClient.onFailure`は、その通知より先に`/rtc/validate`への同期HTTPを実行する。既定のHTTP待ちが復旧開始を遅らせ得る。また`onClosing`がclose frameへ応答せず、正常なclose handshakeが完了しない経路もある。

当該ログの3500はSDKのWebSocket failure分類であり、サーバーから送られたclose codeではない。採取済みログにはvalidation HTTPの時間計測がないため、実障害の約11秒すべてをHTTP検査に起因すると断定しない。close handshake不足も実障害の直接原因と断定しない。

LiveKitコンテナは10月31日起動のまま、RestartCount=0、OOMKilled=false。採取時のホスト利用可能メモリ約10GiB、swap使用0。過去の一時的圧迫を完全に否定するものではない。前段プロキシ同時刻帯のTLS拒否256件は、active参加者ログに現れる接続元アドレスと一致しなかったため、今回の端末障害の原因とは扱わない。

## 修正

SDK公開の`LiveKitOverrides.okHttpClient`を利用し、以下を補う。

- サーバー起点close frameに応答して、SDKのonClosedを遅らせない。callbackのWebSocketインスタンス、code/reasonを維持する。空closeの1005は送信禁止なので応答は1000。
- 障害後診断専用の`/rtc/validate` HTTPだけ全体1秒に制限する。通常接続・token取得・WebSocket・音声RTPには適用しない。TLS/認証検証は維持し、SDKの通常のエラー・復旧処理へ戻す。
- HTTP pool/dispatcherをRoom再生成ごとに作らず再利用する。強制TCP化、UDP無効化、PTT自動送信、サーバーの参加者保持時間変更は行わない。

## 検証

実際のSDK 2.28.0 `SignalClient`とMockWebServerの実HTTP/WebSocketを使用。

- 旧クライアント: close受信後2秒でもhandshake完了なし。修正後:2秒以内に双方のclose完了。
- 3秒遅延するvalidation HTTP:旧SDKの復旧通知は2.8秒以上待つ。修正後は2.5秒未満で通知し、接続状態もDISCONNECTEDになる。テスト内だけreflectionで障害前の接続状態を設定しており、WebRTC参加・ICE復旧全体の試験ではない。
- 通常HTTPのcall timeoutは元の値を維持し、validationだけ1秒。
- 追加回帰4件を含むAndroid全209件成功（失敗・スキップ0）。`testDebugUnitTest lintDebug assembleDebug`成功。

## 残件・状態

初回ICE断の根本要因は未確定。保存ログだけではNAT／経路変更、エミュレータ側の停止、サーバー側transport状態を十分に区別できない。Android16の合成マイク無音・再起動後の音声不一致、CarPlay接続エラー、iOS背景経路もこの修正で解決したとは扱わない。

実装・ローカル回帰のみ。配信、実機確認、mainマージ、本番変更は未実施。ソース上のバージョン番号は親診断ブランチ1.0.21(22)を継承しているが、この差分のAPKは既存ビルド22の配信物と別物であり配信しない。受入試験・配信時に新番号を割り当てる。
