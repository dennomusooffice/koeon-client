# 不具合・修正の追跡

GitHub Issueを不具合の入口、PRを変更の入口とする。会話やローカルログだけを引き継ぎ資料にしない。

## 更新するタイミング

1. 不具合発見・報告時: 重複を検索し、症状、影響するOS／ビルド、再現手順、期待結果と実際の結果を記録する。
2. 調査で新しい証拠が得られた時: 確認事実と仮説を分け、日時・条件・測定値・関連コードを追記する。否定された仮説も結論が変わった理由がわかる範囲で残す。
3. 修正時: 原因、変更内容、PR、コミットSHA、回帰テストを紐づける。未解決の項目は残す。
4. ビルド・配信時: プラットフォーム、バージョン、ビルド番号、ソースSHA、配信先、実際に確認した処理状態を記録する。
5. 検証時: 使用ビルド、送受信方向、待機時間、ロック／省電力／Bluetooth等の条件、実測値、音声の聴取確認、失敗と未実施項目を記録する。
6. 終了・中断時: 現在の状態、残件、次に実行する手順、利用者への確認事項を更新する。解決条件を満たした後にIssueを閉じる。

Issue本文には現在の要約を維持し、経過は日付付きの追記またはコメントとして残す。PRは最終変更を説明し、関連Issueと検証結果へリンクする。「実装済み」「自動テスト済み」「配信済み」「実機確認済み」「mainへマージ済み」は別の状態として扱う。

## 公開する証拠

認証情報、署名鍵、接続先の秘密情報、端末／利用者／チャンネル識別子、生の音声や診断JSONを公開しない。共有可能な数値・時刻・エラー分類を要約する。生の証拠は管理者の保護された保存先に保持し、必要時は管理者へ確認する。セキュリティ問題は[SECURITY.md](../SECURITY.md)に従う。

## 2026-10-31の追跡一覧

以下はこの日付時点の索引。最新の状態は各Issueを確認する。

| Issue | 内容 | 状態の要約 |
| --- | --- | --- |
| [#34](https://github.com/dennomusooffice/koeon-client/issues/34) | 受信・復帰後のPTT送信準備が戻らない | 3102で修正・改善確認、PR未マージ |
| [#35](https://github.com/dennomusooffice/koeon-client/issues/35) | 復帰時の発話発見・バッファ再生終端 | 修正・限定条件で改善確認、反復検証が残る |
| [#36](https://github.com/dennomusooffice/koeon-client/issues/36) | ロック中のOS強制終了 | 3104で再現、3106の単回試験では再発なし、原因確定は残る |
| [#37](https://github.com/dennomusooffice/koeon-client/issues/37) | 準備待ち中に短い発話が失われる | Androidで短発話保持を修正・自動テスト済み、未配信。iOS送信側・実機検証が残る |
| [#38](https://github.com/dennomusooffice/koeon-client/issues/38) | Bluetoothイヤフォンで送信不能 | 3107へ修正配信、Bluetooth送信と再接続後の送信を実機確認 |
| [#39](https://github.com/dennomusooffice/koeon-client/issues/39) | Bluetooth受信のログと聴取結果が不一致 | 3107で利用者が受信音声を聞けず、原因未確定 |
| [#40](https://github.com/dennomusooffice/koeon-client/issues/40) | SO-52Cの送信音声が非常に小さい | 1.0.12へ修正導入、内蔵+18dB・有線+24dBの聴取改善確認、PR未マージ |
| [#42](https://github.com/dennomusooffice/koeon-client/issues/42) | 別利用者のiPhoneで11:00頃クラッシュ | 実ビルド・新しいクラッシュ記録は未取得、初期化競合を修正・自動テスト済み、因果関係未確定 |
| [#43](https://github.com/dennomusooffice/koeon-client/issues/43) | AUTOが目標到達後・無音でも増加 | iOS/Androidの計算を修正・自動テスト済み、未配信・実機未検証 |
| [#45](https://github.com/dennomusooffice/koeon-client/issues/45) | 再生待ちのキャンセル無視で停止・次の受信が戻らない | 修正・実AVAudioEngineを使うSimulatorテスト済み、未配信・実機未検証 |

実機接続なしで進めた修正、機種差と自動ゲインの検討、残件は[OFFLINE_FIELD_RELIABILITY_20261031.md](OFFLINE_FIELD_RELIABILITY_20261031.md)を参照。

関連変更は[PR #33](https://github.com/dennomusooffice/koeon-client/pull/33)、詳しい時系列・ビルドと実測値は[IOS_RECOVERY_20261031.md](IOS_RECOVERY_20261031.md)。サーバー変更はクライアント変更と混同せず、同記録の別リポジトリPRへ辿る。

## 引き継ぎ時の確認

- Issue／PRと現在のブランチ・HEAD・作業ツリーを読み、記録後の変更がないか確認する。
- 実機のインストール済みビルドを確認し、配信済みビルドと同一だと推測しない。
- 前回の結果、未検証の条件、検証時間枠を確認して次の作業を決める。
- 最新の利用者の指示を優先する。期限終了後に端末操作を自動再開しない。
