# MIX8 公開版とBUSY修正候補の検証（2026-11-09）

追跡: #56、#60、PR #67。R3の通話・復旧受入れ。実機許可枠は2026-11-09 23:29〜11-10 00:29 JST（60分）。担当Codex（実装/検証兼務）。終了記録。途中の成功・基盤停止・未検証を併記する。

## 範囲と基準

Android14〜17 AVD＋iOS27.0 Simulator＋iPhone実機＋OPPO A79 5G＋moto g64 5G。既存登録を保持。OPPOのpovo回線設定を変更しない。PIN解除・認可回避・音声保存は行わない。期限・安全条件違反・新規失敗で操作を止め証拠保存。新機能/本番変更は対象外。

開始時Android実機2台は1.0.17(18)だったため、公開APKのhashを検証し1.0.19(20)/d38a07dへ上書き。iPhoneは利用者がTestFlight更新、Macで1.0(2026110910)を再確認。

## 公開版の基準試験

OPPO→iPhone→moto→Android14→15→16→17→iOS Simulatorの順に20秒有限PTT。**8送信/56受信UIすべて成功**、全台READY復帰。音声注入なし。可聴性・明瞭さ・欠け・口元から耳までの遅延を証明する結果ではない。

準備時にAndroid17の登録確認が失敗、診断を保存し再試行で復帰。登録を再作成していない。8並列UI取得の基盤エラーはBLOCKEDとして保存し、並列数2へ抑えた別runで成功。製品不具合と基盤エラーを混同しない。

画面設定: iPhone自動ロック「なし」（変更前のチェックも「なし」を保存）、moto USB常時点灯・画面オフ30分、OPPOはADB設定書込みが拒否されたため正規設定画面から30秒→30分。終了時に元へ戻す。

## #60 修正候補

`currentSpeaker = it.currentSpeaker ?: liveKit.activeSpeaker` が古い話者を保持し、解消をFloor pollingへ依存する。Floor由来の話者/期限を分離し、期限内Floorまたは稼働中RXのSDK話者だけを表示へ使う。毎秒・snapshot・Floor更新で再評価する。送信Floor取得による認可は維持。

修正 `b38ebdfe69909b7bd14a63d155807a7a50429b4c`。旧保持動作を模した単体回帰は失敗し、修正後は新規4件を含む198件/0失敗、lint/debug build成功。正式署名候補ビルド成功。

候補は公開版と同じ1.0.19(20)だが別成果物。SHA256 **8b8f689773ac8fb6d53230c75f068485298e6ecade4291ceb78fbcbdf6f5a8df**、source b38ebdf。GitHub releaseのd38a07d成果物を差し替えていない。実機再検証・配信・mainマージは個別判定。

## 修正候補の途中結果と基盤障害

Android6台へ署名候補を上書きし全8台READY。Android15を約12秒通信断にし、復元12秒後pollでCONNECTED/READY。後続巡回は送信前のAndroid17 UI取得timeoutでBLOCKED。直後にAndroid14/17のQEMU終了を確認。Macの23:51/23:52クラッシュ記録はEXC_BAD_ACCESS/SIGSEGV。KOEONのクラッシュとは判定しない。私有原本を保存しAVDを再起動、登録を保持して別runで再検証する。

再起動後の修正候補1巡目は**8送信/56受信UIすべて成功**、全台READY復帰。前の基盤BLOCKEDを成功へ上書きせず別runに保存。引き続き2/3巡目を実施中。

修正候補2巡目も**8送信/56受信UI成功**、全台READY復帰。3巡目と、再度の通信断→新規送信を実施して最終判定する。

修正候補3巡目も成功。再起動後の合計は**24送信/168受信UI、全件PASS**。毎回全8台READY復帰。公開版の8送信/56受信とは別集計。後続の車載修正b35d6d5が並行作業で同じブランチへ追加されたが、今回のAPKはb38ebdfに固定しており、b35d6d5の検証結果とはしない。記録は隔離worktreeで扱う。

## 最終の通信復旧・音声・履歴

Android15を再度約12秒通信断にし、ネットワーク復元12秒後pollでCONNECTED/READY。続けてAndroid15→他7台、OPPO→他7台の有限PTTが成功し、全台READY。追加**2送信/14受信UI成功**。前回のBUSY残留条件はこの限定試験では再発なし。

Android17から合成発話を送信し、Android14のgRPC取得は1,529,125 samples、既知発話検出・区間順序一致、注入完了、cleanup失敗0。実機側で聞こえたことの証明には使わない。

iPhone/OPPO/moto/Android15の24h journalを回収。iPhone528件中、今回時間帯414件・RX_PCM31件。サーバーは同時間帯Floor acquire/release各35件。renew not_foundが2件あり、解放直後の更新競合の可能性を残す（ログのlease照合キーはないため同leaseと断定しない）。原本・識別子は非公開。

画面をロックせずiPhoneをHomeへ戻して120秒待ち、Android17から合成音を送信。前面復帰前の区間にRX_PCMを確認。初回PCMは受信開始から1,232ms、level1 RX_PCM_TIMEOUT復旧を経由、当該背景区間のruntimeGenerationは1。前面復帰後にはruntimeGeneration 3の別受信も記録されており、背景/復帰の一般安定性やRoom再生成なしを保証しない（#65継続）。実音の聴取、長時間画面ロック、Bluetooth/実車は未実施。

## 終了と引継ぎ

00:19 JSTまでに設定復元・今回のUIセッション終了・SIM5 shutdown完了。Android実機2台は画面オフ30,000ms、stay-awake 0へ復元。iPhoneは元から自動ロックなしで、その値を維持。登録情報を保持し、Android実機には未公開の署名候補b38ebdfが残る。原本と復元確認は私有manifestへ保存。公開APKの差替え、mainマージは行わない。

この後、所有者が別途、車載対応実装と実機枠07:00 JSTまでを許可。次の車載TASKは別run・別source/buildで扱い、本記録の実車未検証を変更しない。
