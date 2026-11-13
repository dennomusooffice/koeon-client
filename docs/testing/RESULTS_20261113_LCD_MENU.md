# LCD設定/電源メニューの検証

2026-11-13、#88/PR #90、[TASK](../development/LCD_HARDWARE_MENU_TASK.md)。LCDメニュー実装`98cd607`を含むソース`bbc9d42d706a28745f529398a947bd0d2aceacb0`からAndroid1.0.29(30)/iOS1.0(2026111303)を配信。

| 項目 | 結果 |
| --- | --- |
| Android Kotlinビルド・223 unit tests・lintDebug | PASS |
| iOS Simulator Debugビルド・arm64 Simulator test | PASS（279成功・1スキップ） |
| メニュー中のPTT入力と通常送信入力の排他 | ソース構造を確認。メニュー時は通常PTT部を描画しない。実タッチ未確認 |
| 電源既定NO・明示YESの確認 | 状態初期化と分岐を確認。実タッチ未確認 |
| CW/CCW、中心/確定/取消、各設定値の画面操作 | NOT_RUN。登録済みのシミュレータ/有効な実機操作枠がない |
| 設定の再起動後復元、回復操作、OSダイアログ | NOT_RUN。既存保存経路を再利用、動作実測なし |
| 配信 | Android署名候補のSHA256を照合して[GitHub prerelease](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.29-30)に公開。APK SHA256 `5db2bac13f4a0a3b5402502e5e1393c75d9078437a62bb9cd25559c84256f0ce`。iOSはTestFlightへアップロードし、Apple処理`VALID`、内部/外部`IN_BETA_TESTING`、内部2/外部1グループすべてでビルド割り当てを確認 |
| 実機・mainマージ | 実機未確認、main未マージ |

前回のiOS Simulatorは利用登録画面のままで接続メインに到達できなかった。所有者は今回TestFlight/GitHubへのテスト配信を明示許可した。利用登録前は従来の設定オーバーレイを維持しており、LCD統一の範囲外として明記する。PTT送信・CH変更・音声の実操作が維持されたかは所有者の実機確認を待つ。自動テスト成功や配信完了を実機安定動作の証拠とは扱わない。
