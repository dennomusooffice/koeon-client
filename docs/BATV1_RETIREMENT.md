# BATv1退役 / LiveKit専用クライアント

追跡: [Issue #66](https://github.com/dennomusooffice/koeon-client/issues/66)。
2026-11-09。配信済み基準は `bc735ba`（Android 1.0.18 / versionCode 19、iOS 1.0 / 2026110909）。本変更は後続候補であり、同じバージョン番号の公開済みバイナリに含まれるとは扱わない。

## 実装

- 両OSのBATv1 publish/subscribe/resolve API、HTTP polling、PCM timeline/cursor/catch-up、録音済み発話の送信、final marker、専用playerと診断項目を削除。旧方式を選ぶ設定やfallbackはない。
- 音声はLiveKit Opusのみ。Floor grant後のマイク公開、既存Roomの再利用、公開後の開始音、最大500ms RX_READY、アプリ操作の180ms tailを維持。安全停止はtailを待たない。短い発話は準備完了前のUPで送信しない。過去の音声を後から再送しない。
- TX OFFでマイクのみ止める。RX subscription、runtime generation fence、復帰処理、Apple PTT所有権とUI/sessionの分離は維持。RX viabilityは実際のparticipant解決・track subscription・PCMで評価する。
- 入力ゲインはLiveKit APMのFloatS16処理に一度だけ適用。手動/OFF/AUTO、ルート別の保存値、limiter、送信中固定、取消・ルート変更時の学習除外を維持。Opus 12/24/48kbps設定は変更しない。
- 非nullの `bufferedGenerationId` を持つ旧START/ENDは状態遷移・sequence更新前に拒否。フィールドは拒否判定のためだけにdecodeし、値を送信しない。null/省略の既存LiveKit制御とは互換。
- `AudioLifecycleBreadcrumbs` へ汎用診断を改名。既存の `batv1.*` / `koeon_batv1_crash_breadcrumbs` 保存キーは過去の診断履歴を失わないため維持する。音声経路ではない。24時間journalと入力ゲイン保存キーは維持。
- 診断JSON v2の旧 `bufferedAudio` / `lastBufferedReceive` / BAT専用playoutフィールドは出力しない。解析側は任意フィールドの不在を許容すること。過去ログ・過去試験記録は削除しない。
- 旧HTTP合成PCMの混在fixtureと専用テストを撤去。HTTP取消回帰は現行Floor status APIへ移し、ゲイン回帰はLiveKit処理へ移す。現行のRTP・帯域制限・復旧試験ツールは残す。

## サーバー・Webとの境界

Issue #66の契約では旧publish/subscribeは `410 BATV1_RETIRED` / `Cache-Control: no-store`。Join/token/Floor/PTT pushの契約は変えない。本クライアントには旧endpointを呼ぶコード自体がなく、410を契機とするretryや別音声経路へのfallbackもない。

サーバーのローカル作業ツリーを読み取り監査した結果、Web `src/components/koeon-app.tsx` はLiveKitを使用し、`src` のBATv1参照は退役endpointを検証するテストに限られていた。サーバーには未コミット変更があるため、これはローカル状態の監査であり、公開HEADや本番環境の確認ではない。クライアントrepoにはWebアプリ本体がない。共有protocol decoderにも旧制御拒否を追加した。

## 検証（2026-11-09）

| 項目 | 結果 |
| --- | --- |
| Android JVM | 193件、失敗0 |
| Android lint / debug APK / androidTest APK | 成功 |
| iOS実機向けunsigned build | 成功（端末導入・署名・配信なし） |
| iOS Simulator 27.2 / arm64 | 254件中253成功、1件はopt-in LiveKit labのためskip、失敗0 |
| 共有TypeScript protocol | 14件成功、tsc成功 |
| feature-parity contract / diff whitespace | 成功 |
| 本変更での実SFU fanout・128kbpsの12/24/48品質比較 | 未実施。以前の結果を本変更の合格扱いにしない |
| 実機ロック・復帰・Bluetooth・省電力・長時間反復 | 未実施 |

旧BAT専用テストの削除によりテスト総数は減少している。数の減少をカバレッジ向上とは扱わない。旧START/END拒否、LiveKitの安全停止/lease所有権/短い発話/語尾、受信復旧、ゲイン、journalなど現行動作の回帰を実行した。Android journalの再起動・TTLテストは、仕様で保証していないファイル列挙順ではなくイベント集合を検証するよう修正した。

## 切替・リリースゲート

1. 候補を新しいAndroid versionCode / iOS build番号で配信する。**本変更の最低必須配信番号は未確定**。上記の既存配信番号をBAT撤去済みとして指定しない。
2. SIM5のnative相互通信・Web fanout・切断再接続と、上下128kbpsを実測した12/24/48設定を検証。HTTP旧endpoint呼び出し0、Floor renew/release、初回PCM、次PTT復帰を記録する。
3. 許可された実機試験枠で長時間ロック、Bluetooth再接続、割込み、省電力を検証。#52/#54/#57を本リファクタだけで完了にしない。
4. 利用者へ新しい最低バージョンを通知し、更新状況を確認してからサーバー退役を別途反映する。旧BAT送信クライアントは410で送信不能となり、自動でLiveKitへ移行する保証はない。更新が必要。
5. ロールバック時もHTTP音声を自動再有効化しない。クライアント候補は配信停止できるが、最低版・サーバー410の組合せを確認し、LiveKit対応版へ戻す。旧BAT版を戻すだけでは410を解消できない。サーバー側復元は別途の判断と検証を要する。

本変更のmain merge、配信、本番切替、実機受入れはそれぞれ別の状態としてIssue/PRに追記する。
