# 外観カスタマイズと補助キーの実装状況

2026-11-13、#88/PR #90、[TASK](../development/CONSOLE_CUSTOMIZATION_TASK.md)。添付画像は配置・形状のみの参考とし、表示文字/利用者/CH/音声値は製品データを維持。

## 実装

- Androidは既存SharedPreferences、iOSは既存AppStorageに本体4色・キー2色・LCD2色を独立保存。旧dark設定を新しい本体値が未設定のとき引き継ぎ、LCD初期値はアンバー。
- LCDディープブルーは濃紺グラデーションと白文字。ボタン色は本体色から独立し、明暗の面/文字を共通トークンから描画。
- ※/＃は数字キーの左右端、既存3操作は中央に維持。LOG/AI/MODE/FnはPTT領域の四隅に凹形状で配置。6個のモックは空ハンドラーと個別IDを持ち、PTT/CH/通信に接続しない。
- 可変の音声再接続メッセージを固定LCD内へ移し、再接続操作はSettingsへ移した。ACTION罫線の位置をメッセージで変動させない。

## 検証と停止

- 最終キー面・PTT配置調整と旧設定移行後のAndroid Kotlin compile、Android testDebugUnitTest（223件成功）、Android lintDebug、iOS Simulator Debug build、iOS Simulator test（arm64、279件成功・1件スキップ）、機能同等性契約は成功。iOS testをx86_64込みで実行すると依存LiveKitのx86_64リンクで失敗したためarm64限定で再実行した。
- iOS Simulatorは利用登録画面で止まるため、メイン画面の16組の実UI保存/復元、四隅キーの当たり判定、縦画面キャプチャ、PTT/CHの実操作は**未確認**。実機操作の有効な許可時間枠もないため実機確認は未実施。これらは自動テスト成功から推定しない。
- ソースSHA `f5e973535d199dab579dadc9e6f93c33544eb57a`。Android `1.0.28 (29)` 署名候補のAPK SHA256 `7fe4bd8f8f6be45b7beae96bcad68b43cb7863418135a70f58c5fc00bb3ca1f3`を照合し、[GitHub prerelease](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.28-29)へ公開。iOS `1.0 (2026111302)`をTestFlightへアップロードし、Apple処理`VALID`、内部・外部`IN_BETA_TESTING`、内部2/外部1グループすべてのビルド割り当てをAPIで確認。
- 所有者はCodex利用枠の停止値を3%から1%に変更。次回は登録済みテスト環境で全16組の即時反映・再起動復元、異なる画面幅でのキー/PTT当たり判定、CH変更/PTT既存動作を確認する。グループ通話の合成音声可聴再生は従来の未合格のまま。
