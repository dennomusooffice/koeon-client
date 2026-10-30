# iOS復帰・送信再準備の修正（2026-10-31）

## 実機で確認したこと

1.0 (2026103101)の診断では、受信APIから93フレームを取得して終端まで処理した一方、送信ゲートがREARMINGに残り、次のPTTを開始できない状態を確認した。AppleのstopエラーはPTChannelErrorのrawValue 5。受信データの取得・drain完了は、利用者が正常に音を聞けたことの証明ではなく、利用者からは送受信とも不安定との報告がある。

Apple SDKと[公式仕様](https://developer.apple.com/documentation/pushtotalk/ptchannelerror-swift.struct/code/transmissionnotfound)では、これはtransmissionNotFound（停止する送信が存在しない）である。従来はString(describing:)の結果を文字列transmissionNotFoundと比較していたため、rawValue形式になるとApple側の停止完了フラグが立たなかった。

## 変更

- エラー表示文字列から制御を分離し、Appleのエラードメインと型付きコードで停止完了を判定する。未知のエラーや別ドメインの同じ数値は停止完了として扱わない。
- Apple側の終了に伴う旧送信の後始末を手配してから、待機していた次の押下を再開する。
- 復帰前のPTT処理が後から戻っても新しいコントローラーを停止・更新しないよう、開始時のコントローラーと実行世代を保持する。
- フロア状態の取得中に受信世代・送信試行・セッションが変化した場合は、古い応答を適用しない。受信開始後に遅着したavailable応答で受信を終了する競合を防ぐ。

## 検証と限界

- 修正前の動作で、transmissionNotFound後にREARMINGから戻れない回帰テストが失敗（通常の次押下・待機中の押下の両方）。
- 修正後はiOS Simulatorの全224テスト成功。遅延フロア応答が新しい受信を終了しないこと、別端末エラー相当の別ドメインや未知のstopエラーが停止完了扱いにならないことも検証。
- 旧ビルドで今回の送受信不安定が再報告されているため、修正版の実機確認は必須。自動テストで音声品質・バックグラウンド動作の解決を断定しない。

## 実機確認

新ビルドへ更新して両端末をPOWER OFF→ONする。iPhone→Android、Android→iPhone、ロック・復帰後の両方向、短い押下と連続押下を確認する。不具合があればPOWER OFF前にField Diagnostic JSONを取得し、ビルド番号、送信ゲート、送信試行、受信世代、復帰世代を照合する。

2026-10-31に1.0 (2026103102)をTestFlightへ配信済み。配信ソースは9b92f000ca35a014b38b5851c3328529b0216d5f。署名付きアーカイブ・export・uploadが成功し、App Store ConnectのprocessingState=VALID、internalBuildState=IN_BETA_TESTINGを確認した。前回と同じ内部グループdefault/MTOYに関連付け済み。実機での更新後テスト結果は待機中。
