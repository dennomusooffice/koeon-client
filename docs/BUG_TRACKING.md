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
| [#37](https://github.com/dennomusooffice/koeon-client/issues/37) | 準備待ち中に短い発話が失われる | Android500ms・iOS1/1.5秒のPCM輸送を実機確認、iOS500msは0。旧録音確認の競合を追加修正・275テスト成功、iOS3110内部配信・停止診断と1.5秒輸送確認、1秒以下は未解決 |
| [#38](https://github.com/dennomusooffice/koeon-client/issues/38) | Bluetoothイヤフォンで送信不能 | 3107へ修正配信、Bluetooth送信と再接続後の送信を実機確認 |
| [#39](https://github.com/dennomusooffice/koeon-client/issues/39) | Bluetooth受信のログと聴取結果が不一致 | 初回engine.start対策後の3111でも無音。通知登録喪失を#49で修正し、3112で7分33秒ロック後の聴取と再接続後の双方向を限定条件で確認。再接続後184/184・136/136、利用者が両方向の音量・明瞭さ良好・欠けなしを確認。長時間反復・電池単独は未検証、診断保持の不足は#50 |
| [#40](https://github.com/dennomusooffice/koeon-client/issues/40) | SO-52Cの送信音声が非常に小さい | SO-52C内蔵+18dB・有線+24dB、A303OP1.0.13内蔵+6dBで聴取改善確認、PR未マージ |
| [#42](https://github.com/dennomusooffice/koeon-client/issues/42) | 別利用者のiPhoneで11:00頃クラッシュ | 実ビルド・新しい.ips未取得。内部配信した対策との因果関係は未確定。終了原因の診断誤分類も修正、後続修正込み291件・3112内部配信済み。接続実機で診断取得済みだが、別利用者のクラッシュ解消の検証ではない |
| [#43](https://github.com/dennomusooffice/koeon-client/issues/43) | AUTOが目標到達後・無音でも増加 | 両OSを修正。A303OP1.0.13内蔵AUTOの段階更新・聴取を確認、収束・他ルートは未検証、Android公開保留 |
| [#45](https://github.com/dennomusooffice/koeon-client/issues/45) | 再生待ちのキャンセル無視で停止・次の受信が戻らない | 再生待ち修正は3109内部配信。停止完了が次世代を消す競合も修正、278テスト成功、後続修正込み282件。3111内部配信・実機導入済み。#39の無音は残り、停止競合対策の実機受入れは未完了 |
| [#46](https://github.com/dennomusooffice/koeon-client/issues/46) | 前面でも双方向の音声到達が遅い | iOS3109・A303OP1.0.13の前面ACK約394/397ms、フレーム一致。iOS押下→TALKING1552ms等は残り、全面改善とは扱わない |
| [#47](https://github.com/dennomusooffice/koeon-client/issues/47) | GitHub Actions開始前失敗でAndroid公開不可 | アカウント側の復旧待ち。所有者は現時点で対応不可。署名候補を保存し、公開ゲートを維持 |
| [#48](https://github.com/dennomusooffice/koeon-client/issues/48) | Android録音済み音声へのライブ音声の割込み | 原子的な受渡しへ修正、184件・Lint・ビルド成功。A303OPに導入し通常送信と500ms保持を確認、競合の実機再現未確認・公開保留 |
| [#49](https://github.com/dennomusooffice/koeon-client/issues/49) | 復帰失敗が通知登録を消して次の背景受信を阻害 | 6fe000fで修正・291件成功・3112内部配信。7分33秒ロック後の聴取、通知先維持、明示OFFの解除とONの再登録を実機確認。元の接続失敗を今回通ったかは未確定、電池単独・長時間反復は未検証、main未マージ |
| [#50](https://github.com/dennomusooffice/koeon-client/issues/50) | 復帰後に受信履歴・再生統計が失われる | 3112実機で正常ポーリングが64件の履歴を占有し、前面復帰で直近の受信統計も初期化されることを確認。両OSの正常ポーリング重複抑制を実装。iOS294件・Android187件成功、未配信。直近受信統計保持はiOSに実装・295ケース成功（最終結果収集中）、Android対応・JSON契約検証が残る |

実機接続なしで進めた修正、機種差と自動ゲインの検討、残件は[OFFLINE_FIELD_RELIABILITY_20261031.md](OFFLINE_FIELD_RELIABILITY_20261031.md)を参照。

関連変更は[PR #33](https://github.com/dennomusooffice/koeon-client/pull/33)、詳しい時系列・ビルドと実測値は[IOS_RECOVERY_20261031.md](IOS_RECOVERY_20261031.md)。サーバー変更はクライアント変更と混同せず、同記録の別リポジトリPRへ辿る。

## 引き継ぎ時の確認

- Issue／PRと現在のブランチ・HEAD・作業ツリーを読み、記録後の変更がないか確認する。
- 実機のインストール済みビルドを確認し、配信済みビルドと同一だと推測しない。
- 前回の結果、未検証の条件、検証時間枠を確認して次の作業を決める。
- 最新の利用者の指示を優先する。期限終了後に端末操作を自動再開しない。
