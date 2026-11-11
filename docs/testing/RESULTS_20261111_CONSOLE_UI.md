# 2026-11-11 共通Console UI・USB限定受入れ

関連: [#88](https://github.com/dennomusooffice/koeon-client/issues/88)、[復元CH一覧 #89](https://github.com/dennomusooffice/koeon-client/issues/89)、[実装TASK](../development/UNIFIED_CONSOLE_UI_IMPLEMENTATION_TASK.md)、[採用設計](../development/UNIFIED_CONSOLE_UI_DESIGN.md)。担当Codex、所有者による実声・外観レビューへ引継ぎ。

## 対象と状態

- ソース: `9e3452e6ec941e8631040c67bc60984995da482a`、`codex/unified-console-ui`。UI本体/CH一覧補完は`16b8834e7ed8342c2e4a955d11819d08d5b40212`、後続でメーターの失効/表示条件・Android共有buffer cursorの扱いを修正。
- iPhone 17 Pro Max: **1.0 (2026111124)**、署名Debug USB候補。
- OPPO A79 5G: **1.0.19-ui09 (20)**、署名Release USB候補。APK SHA256 `8196b1dfc2829ddc85ac1ebb0121c2ae187bb20457450618d2696a25e14b059a`。
- 指定2台へ登録保持で更新インストールし、LCDから両ビルド番号を確認。公開配信/TestFlight/mainマージなし。中間候補の結果は以下で区別する。
- 実機操作許可: 2026-11-11 18:02:20–20:02:20 JST。対象以外の端末は操作しない。個人名・ID・接続先・生の診断/画面を公開しない。音声を保存しない。

## 自動検証

最終ソースでAndroid **218成功/失敗0**、Lint・Debugビルド成功。iOS **277件中276成功/専用SFU1skip/失敗0**、Simulator試験成功。両OS署名候補ビルド成功。`feature-parity-contract.py`成功。追加回帰はCH番号解析/衝突、CH一覧応答のscope拒否、TX最新フレーム/停止/失効、RX既知RMS/無音/形式/長さ/旧track/失効/共有cursor不変を含む。全SDK/OS条件の証明ではない。

## 実機で確認した範囲

| 項目 | 観測と判定 |
| --- | --- |
| 非スクロール・PTT全体 | PASS。標準文字サイズ/縦持ち。Android1080×2400でPTT `[210,1655]–[870,2315]`、220dp。iPhone440×956ptでx110/y633/220×221pt。通常/CH入力中で同一位置、接続メインのスクロール領域0。ui04/1121以降の同一レイアウト、最終候補でもPTTを操作可能 |
| LCD内CH入力 | PASS。CH12のFROM/TO/候補/確定待ち、取消では移動なし、確定後にCH12。iOSの無効99は確定不可、5秒無操作で元のCHを保持。入力中に画面外へ新しい入力欄を追加しない |
| 一覧・前後 | PASS。iOS1122以降の一覧オーバーレイ、Androidで前のCHを選んでも確定待ちとなり、取消でCH12を保持。1桁を含む実際のswitchChannel呼出しは両OSとも確定操作だけ。有効1桁CHを使う実機切替は未実施 |
| ライト/ダーク | PASS（限定）。両方向切替とライト設定の更新インストール後保持。白/黒の本体、アンバーLCD、6pt/dpリング。暗所での人による視認性・全色コントラスト測定は未実施 |
| 版/設定/診断 | PASS。LCDに実インストール版、Settings/Diagnosticsオーバーレイを開閉。既存音声/外部PTT/診断導線は維持。全設定組合せの実機回帰ではない |
| POWER誤操作防止 | PASS。最終候補の両OSで明示終了確認を表示し、取消してCH12/READYを保持。iOSは背景タップ、Androidは取消ボタン。終了確定を伴う再接続試験は別条件 |
| iOS復元CH一覧 | PASS（限定）。初回1118で追加CHが選択不能だった問題を#89で修正。1120以降で復元後の追加CH12選択と他CH一覧を確認。音声Sessionの再接続で一覧を更新しない |
| Android TX IN | PASS（限定）。ui05でsnapshot通知を修正、最終ui09の有限PTTで実測-96dBFSを確認。送信終了後は未取得。無音の入力計測であり人声の到達保証ではない |
| iOS RX | PASS（限定）。Android→iOSで中間1123は-48dBFS等、最終1124は-96dBFSを確認。SDKの無音PCMが続く場合は待受でも実測-96を表示。受信LEDの待受消灯と分離 |
| Android RX | PASS（限定）。最終ui09、iPhone1124の12秒PTT中にRX **-56dBFS・青いメーター1セグメント**を匿名化したメーター画像で確認。待受の新鮮なSDK無音PCMは-96dBFS。音声聴取・音量設定とは別の証拠 |

自動UI取得は受信中の更新/端末の自動ロック等で一部失敗した。更新直後の準備/切断状態が混在した試行も、安定した送受信成功には算入しない。両端末READYとCH12を確認した有限PTT試行および限定画像を根拠にし、一般的な接続安定性を主張しない。

## メーターの最終契約と調査結果

TX INは既存処理のゲイン前フレームRMS。RXはSDKデコード後・端末音量前のPCM RMS（iOS混合、Android新鮮な各trackの最大）。-96〜0dBFS、最大10Hz、300ms失効、数値のみRAM。無音は-96、未取得/不正形式/期限切れ/切断は「—」。待受中にSDKが無音PCMを供給しても、その数値を表示する。RX制御状態でメーターを隠す中間案は撤回し、LEDの意味とは分離した。

Android共有ByteBufferが末尾cursorの場合に有効フレームを拒否するケースを合成テストで再現し、duplicateのrewindで修正。元bufferを変更しない。実機入力は16bit/mono/480frames/pos0/limit960であり、このcursor問題を実機未取得の確定原因とはしない。RTC統計による補完試作は改善確認できず最終版から除去。追加ポーリング/サーバー依存/録音は導入しない。

## 残件と次の受入れ

- 所有者が両方向で実声の音量・明瞭さ・欠けを確認する。今回は人による聴取なし。
- 他端末/横向き/極端な文字拡大/スクリーンリーダー/長時間・背景・再接続・Bluetooth全条件は未受入れ。iOSの既存外部PTTやAndroid背景音量PTTの全回帰を今回のUI試験で代替しない。
- 警告は赤、通常BUSY/準備はアンバーのマッピングを実装。実機の赤リング表示は観測したが、全警告の故障注入試験は未実施。
- サーバー側の独立CH番号/名前は[server #42](https://github.com/dennomusooffice/koeon/issues/42)、RX/API契約は[server #43](https://github.com/dennomusooffice/koeon/issues/43)へ登録。現行クライアントは認可済み名前内の明示CH番号に対応し、番号不明/100以上は一覧から確定。
- 許可されたテスト2名にCH12の所属を追加済み。既存所属を維持。ユーザー名/IDは公開しない。
- USB候補のレビュー後に公開配信を別途判断する。旧候補へ戻す場合も既存登録保持の更新インストールを用い、登録消去やサーバー所属削除を切戻し手段にしない。

終了確認: 両端末CH12/READY、PTT保持なし、オーバーレイ閉鎖。AndroidのUSB接続時画面維持設定は作業前と同値。UI取得用一時ファイルと自分の自動操作セッションを後片付けし、ユーザーによる実声レビューへ引き継ぐ。
