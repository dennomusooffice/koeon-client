# 24時間フィールド診断ジャーナル仕様 v1

追跡: #50。現在の `koeon.field-diagnostic.v2` の手動snapshotは維持し、別形式の追記履歴を追加する。前面復帰やruntime置換で過去RXを上書きしない。人の操作なしで記録し、後でMacへ回収する。記録は正常動作のために必要な音声/通信処理を待たせない。

## 保存とプライバシー

- JSON Lines、schema `koeon.field-journal.v1`。音声/PCM値/録音、token、認証情報、URL、招待値、ユーザー表示名、自由形式の例外本文は保存しない。
- アプリ私有領域で保存、backup対象外。iOSは初回解除後の背景書込みが可能なfile protection。Androidはapp-private files、外部公開providerを作らない。
- 記録時点から最大24時間をexport対象にする。保存容量32MiB、セグメント256KiB、書込み待ち256件を上限とし、古い分/過負荷の欠落を明示する。容量限界では24時間より短くなる。通常の状態遷移＋30秒heartbeatを想定し、音声callbackごとのディスク書込みはしない。
- OSが停止/終了した間は記録も削除処理も動かない。次の起動/追記/exportで期限切れを除外・掃除する。停止中まで物理削除時刻を保証するサービスを追加しない。
- 連番とrunIdで再起動・取りこぼしを判別。時刻逆行/飛びは隠さず示す。途中書込み/壊れた行は除外数をexportに記載し、ファイル全体を成功扱いで黙って捨てない。

## レコード

| フィールド | 内容 |
| --- | --- |
| schema/platform/build | スキーマ・OS・正確な版番号 |
| installationId | 当該インストールに生成した匿名UUID。人物/広告IDではない |
| runId/sequence | プロセス起動ごとのUUID、起動内連番 |
| wallTimeMs | UTC epoch milliseconds。端末時計の値であり正確性保証なし |
| monotonicMs | 当該起動中の経過時刻。異なる端末/起動間で直接比較しない |
| event | START、STATE、HEARTBEAT、TX、RX、RX_PCM、WAKE、RESTORE、AUDIO、EXPORT等の固定分類 |
| correlation | sessionHash/leaseHash/channelHash。文字列ID UTF-8のSHA256。生値は保存しない |
| data | 許可された状態/世代/成否/時刻/カウンタ/ゲイン値のみ |
| droppedBefore | 当該recordまでの書込み待ち超過による未記録件数 |

端末のsessionHashは自端末join session、受信/送信eventではspeaker sessionとleaseも記録する。同一leaseHashを相関の第一キーにする。ハッシュは匿名化の補助であり公開してよいという意味ではない。サーバーログの生IDはMac側で同じSHA256へ変換して照合し、生値を結合結果へ残さない。

記録ポイント: 起動、状態遷移、TX開始/終端、受信世代開始/最初の有効PCM/終端、push、接続復帰の各段階、音声focus/route/可用性、入力ゲインの学習判断、30秒heartbeat。iOS背景wakeでは新世代のPCMかを確認してからRX_PCMを記録。全ての段階を保存できないOS停止はgapとして残り、可聴成功には変換しない。

## Export / Mac回収

UIに `Export 24-hour diagnostic log` を追加。exportはwriter完了を待つ別作業として実行し、メイン/UI/audio threadで長時間ファイル走査しない。export物はmanifest＋対象JSONLレコードを持つJSON bundle (`koeon.field-journal-export.v1`)。manifestには範囲、対象件数、容量/queue/破損による欠落、buildを含む。

- iOS: export後の共有/Files保存。Macから開発接続可能な場合は app container のexportファイルを`devicectl device copy from`で回収できる。自動最新snapshotと履歴exportを混同しない。
- Android: Storage Access Frameworkでユーザーが保存先を選ぶ。署名releaseアプリのprivate filesは`adb run-as`で読めると仮定しない。debug/emulatorのみrun-as回収可。公開ContentProviderやrootを導入しない。
- iOS Simulator: `simctl get_app_container ... data`からexportを回収。対象UDID/serialを明示し、全接続端末を無差別に操作しない。
- Macは `scripts/field-diagnostics/` の回収/照合ツールを使用。入力bundleを保持しSHA256 manifestを作る。出力は `.secret` 内、permission 0700/0600を標準とする。

## 突合

1. 複数端末のbundle＋当該UTC帯サーバーJSONLを読み、schema/必須型/行上限を検証。破損/重複/欠落をreportに含める。
2. サーバーの専用adapter入力は `wallTimeMs,event,sessionId,leaseId,channelId`（または既にhash化済みcorrelation）のみ採用。生ログ形式が異なれば変換し、全ログ内容をそのまま出力へ混ぜない。
3. `leaseHash`一致を主キー、sessionHash補助、時刻は補助情報。相関キーのない出来事を時間が近いだけで同じ送信と断定しない。
4. 手動測定した端末ごとのclock offsetを指定可能にする。元UTC/補正UTCと起動内monotonicを両方保持し、他端末の単調時刻から遅延を計算しない。
5. reportに「制御許可」「購読」「PCM観測」「復旧」「終端」「missing evidence」を区別して表示。PCMは音声可聴/了解度の保証ではない。

## 必須テスト

両OSで24h境界、再起動継続、容量超過、queue超過、途中行、壊れたJSON、時計逆行、匿名化、export後に次イベントを書けることをテスト。実時間24hのsoakは別ケースであり、時計注入テストだけで実機1日安定と主張しない。Mac側は複数端末の同lease照合、別lease分離、重複、offset、サーバーadapter、秘密/自由文除外をテストする。

この文書は実装の受入れ仕様。未実装/未配布/実機未検証の状態は実行記録で明示する。自動アップロードやサーバーへのログ送信は追加しない。
