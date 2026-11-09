# BATv1撤去版の配信・本番反映・SIM5（2026-11-09）

追跡: client #66 / #68 / #56、client PR #67、server PR #39。
今回の配信・本番反映とSIM5試験の完了記録。合格・未合格を併記し、mainへのマージ・実機受入れとは別に扱う。

## 配信

- Android **1.0.19 (20)**: GitHub prerelease `android-v1.0.19-20`。source `d38a07db65483387d582f686aee91eee0f5de491`。SHA256 `537bf0f08d97de5aeef3f3215c4c863f96ade950e8d75074f3ca50c40874236a`。
- iOS **1.0 (2026110910)**: source `0239039b5a910454f07655c6d69b24f3c77d83fe`。Apple processing VALID、internal/external IN_BETA_TESTING、既存内部2・外部1グループ割当確認。Android専用の後続END待機修正はiOSに該当しない。
- Android194 unit tests/lint/debug/正式署名検証、iOS254件中253成功・専用SFU1skip、共有protocol14件/tsc成功。

## 本番

2026-11-09 **21:14 JST**、SQLite online backupと旧releaseを保存後、KOEONのみ再起動。実DB・.envを維持。Caddy・他サービスは変更しない。

サーバー変更 `2749ff2bcbbcd9e996997e1fa30373729a0c31a9` の対象差分を、稼働中ソースの隔離stageへ適用。対象15パスのbefore/after hashを検証し、VPS上でnpm ci・223 tests・本番build成功。無関係なサーバー作業ツリーの変更は持ち込んでいない。

旧publish/subscribe/**resolve**の3 APIが410 `BATV1_RETIRED` / no-storeを返すこと、LPのバージョン・APK hash、koeon/caddy active・failed unitなしを確認。最低更新対象は上記配信版。ロールバック用の旧release/DBバックアップの実パスは私有実行記録に保持する。

## 検出した問題（失敗を含む履歴）

1. 未公開の初期Android候補 `2ddad3d` では、Android14の20秒PTTを離した後、RELEASING→IDLEに**20,348ms**。受信4台のBUSY表示も残った。最初の失敗で停止して両OSのjournalを保存。
2. ENDを20秒遅延させるunit testで速やかなFloor解放の期待を再現（赤）。`d38a07d`でEND待ちを500ms/回へ制限（緑）。マイク停止を先行し、ENDの停滞でFloorを保持し続けない。SDK側の接続待ちが発生した理由自体は未確定（#68）。
3. 修正後の5送信者×4受信者、**5送信/20受信UI**は全件成功。
4. 次の巡のAndroid15送信終了時、Android17だけOFFLINE。journalではRECONNECTING→CONNECTEDが**1,017ms**で自動復旧。失敗runは停止・保存しており、合格に置き換えない。アプリ再起動/POWER操作は不要だったが、瞬断原因は未確定（#56）。

## 判定の範囲

SIM5はAndroid14/15/16/17のARM64 AVD＋iOS27.0 Simulator、既存登録を上書き更新。Androidは公開APK、iOSは同じ製品ソース・版番号の署名済みDebug Simulator adapter。TestFlight IPAそのものをSimulatorで実行したわけではない。

UIのBUSY/READYは可聴音声の証明ではない。PCM、合成音検出、128kbps計測、切断復旧を別に集計する。実機のロック/APNs/Bluetooth/車載/キャリア回線は今回操作していない。#52/#54/#57の全面解決とは扱わない。

## 本番反映後の結果

- CTRL: 5台×3巡、**15送信/60受信UI、全件PASS**。各送信終了後に5台READYへ復帰。実施時のAndroid全台はAPI34/35/36/37、1.0.19(20)。iOS27.0は1.0(2026110910)、Keychainに必要なリンク時entitlementsを確認。
- iOS journal: 同じ試験時間帯のAndroid送信12回について、**12受信世代すべて初回PCM**。初回PCMは受信開始から4–799ms。runtimeGenerationは同じで、Room全体の再構築は観測されなかった。5回で購読待ちに伴うlevel1/2復旧が発生。初回PCMは可聴性や口元→耳の遅延の証明ではない。
- ジャーナル回収: iOS437件、Android685件（いずれも過去24hの履歴を含む）。サーバー319件のadapterと合わせて**1,441件/51 lease、拒否0**を突合。すべてが今回の15送信のイベントという意味ではない。Androidに過去からの破損行除外累計1件があり、今回のI/O失敗は0。

- SHORT: 5台それぞれ0.2/0.5/1/3秒押下、**20ケースPASS**。終了2秒後の全台READYを確認。短い発話の可聴性を保証する結果ではない。
- 音響基盤: Android17の独立660Hz AudioTrackをgRPCで16秒取得。767,488 samples（期待768,000）、dominant 660.003Hz、player 480,000 frames完了、音声原本保存なし。試験基盤の校正成功。過去に不正なサンプル数となったAPI35/36は今回の音響受入れ先に採用しない。
- 帯域基盤: Android14のeth0/wlan0送信および共通IFB受信に128kbit/s上限。10.0.2.2への256KiB合成TCP測定でpayload下り92.94／上り114.57kbps、校正範囲内。アプリのFloor/Join/LiveKitも同じインターフェース制限対象。Android14以外の端末自身にはこの制限を掛けていない。設定・filterの復元成功。実キャリア速度やRTT/loss再現ではない。

## 128kbps・品質別音声

Android14の回線制限を継続したまま、Android14→17でLOW 12 / STANDARD 24 / HIGH 48kbpsを各1回試験。診断JSONの実効設定値を照合し、全3ケースで合成発話の注入完了・受信検出・4区間の順序一致を確認。各取得サンプル数は1,528,157 / 1,530,368 / 1,530,879。設定は元のSTANDARDへ復元、各回の帯域設定cleanup失敗0。

逆方向の事前校正としてAndroid14でも独立660Hzを取得し、767,999 samples/期待768,000、dominant 660.001Hz、再生完了を確認。帯域上限だけの試験は実LTEのRTT・ジッタ・損失・ハンドオーバーを含まず、高音質のキャリア制限下での一般的な安定性を保証しない。

逆方向Android17→14（帯域制限は受信側Android14）もLOW12/STANDARD24/HIGH48kbpsの全3ケースで合成発話の到達・区間順序一致。各サンプル数1,530,879 / 1,530,879 / 1,530,368。合計**3品質×双方向=6ケース成功**。各品質は単回であり長時間耐久の証明ではない。両端末の音質設定および全6回の帯域設定を復元した。

## 通信断・復旧（未合格を含む）

4 Androidを約12秒ネットワーク断にし、全台OFFLINE/RECONNECTINGを観測。ネットワークを復元するとAPI34/36/37は12秒後poll、API35は30秒後pollでCONNECTED/READY。これらは上限付き観測時点であり、正確な復旧所要時間ではない。

直後の5台送信試験はAndroid15だけBUSY_REMOTEのため、送信前にBLOCKED。約1分後の診断はPOWER/再起動なしでREADY。証拠保存後に別runで再試験したが、Android14送信の受信4台BUSYは成功し、終了2秒後もAndroid15だけBUSY_REMOTEのためPRODUCT_FAILで停止。失敗を成功へ置き換えない。復旧後5台巡回は**未合格**。

#60へ関連証拠を追記。Android15の一時BUSY寿命・原因は未確定。今回の撤去版配信は完了したが、通信復旧を含む全面安定性は確認できていない。原本journal・UI XML・サーバーログは非公開保存。

## 終了時の復元

両AVDの音質を元のSTANDARDへ復元。帯域制限の全cleanup成功。4 Androidすべて機内モードdisabled/Wi-Fi enabledを確認し、Android14のADB rootを解除。試験補助アプリを停止・今回追加分を除去し、専用UIセッションを終了してSIM5をshutdown。登録情報は維持、実機は操作していない。
