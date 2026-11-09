# 試験結果テンプレート

生ログ・識別子・接続先は非公開runディレクトリへ保存する。GitHubには以下を匿名化して転記する。

- Run ID / 開始・終了UTC / 操作可能な実機時間帯:
- 構成: SIM5 / MIX7 / MIX8 / NEW6
- Source SHA / dirty差分の有無 / アプリのversion・build・成果物SHA256:
- 各aliasのOS/API・実機またはSimulator・音声経路:
- ツール版 / Mac負荷 / 登録・READYゲート:
- 原本設定 / 一時変更 / 復元結果:

| Case | 送信→受信alias | 条件・回数 | 期待 | 実測 | 判定 | 非公開証拠の相対名 |
| --- | --- | --- | --- | --- | --- | --- |
| CTRL | | | | | NOT_RUN | |
| RTP | | | | | NOT_RUN | |
| RECOVER | | | | | NOT_RUN | |
| JOURNAL | | | | | NOT_RUN | |

判定はPASS / PRODUCT_FAIL / ENV_FAIL / BLOCKED / NOT_RUN。制御UI、購読、PCM、既知発話検出、聴取を別行にする。失敗時は直後のjournalとsnapshotを保存し、POWER操作/再送を行ったか明記する。時計offsetの測定有無、サーバー側の採取範囲と欠落も書く。

- 新規発見 / 既知Issue / 確認事実 / 仮説 / 否定できた仮説:
- 変更SHA / 赤→緑回帰 / 同条件反復 / 未確認の経路:
- 実装済み / 自動テスト済み / 配信済み / 実機確認済み / merged:
- 残件と次の具体的手順:

再現できなかった結果も、最初の失敗を上書きせず別case/runにする。全ケース未実施を空欄のまま合格としない。
