# 外観カスタマイズと補助キーの実装状況

2026-11-13、#88/PR #90、[TASK](../development/CONSOLE_CUSTOMIZATION_TASK.md)。添付画像は配置・形状のみの参考とし、表示文字/利用者/CH/音声値は製品データを維持。

## 実装

- Androidは既存SharedPreferences、iOSは既存AppStorageに本体4色・キー2色・LCD2色を独立保存。旧dark設定を新しい本体値が未設定のとき引き継ぎ、LCD初期値はアンバー。
- LCDディープブルーは濃紺グラデーションと白文字。ボタン色は本体色から独立し、明暗の面/文字を共通トークンから描画。
- ※/＃は数字キーの左右端、既存3操作は中央に維持。LOG/AI/MODE/FnはPTT領域の四隅に凹形状で配置。6個のモックは空ハンドラーと個別IDを持ち、PTT/CH/通信に接続しない。
- 可変の音声再接続メッセージを固定LCD内へ移し、再接続操作はSettingsへ移した。ACTION罫線の位置をメッセージで変動させない。

## 検証と停止

- 最終キー面・PTT配置調整と旧設定移行後のAndroid Kotlin compile、Android testDebugUnitTest、iOS Simulator Debug build、iOS Simulator test（arm64限定）、機能同等性契約は成功。iOS testをx86_64込みで実行すると依存LiveKitのx86_64リンクで失敗したためarm64限定で再実行した。16組の実UI保存/復元、4隅の当たり判定、縦画面キャプチャ、実機確認は**未実施**。
- 所有者はCodex利用枠の停止値を3%から1%に変更。配布用署名候補とTestFlight/GitHubリリースは現時点で未実施。現行公開Android1.0.27(28)/iOS2026111301には今回の変更を含まない。
- 次回は全16組の設定即時反映・再起動復元、異なる画面幅でのキー/円PTTの当たり判定、CH変更/PTT既存動作、署名候補の順に確認し、問題がなければ新番号で限定配布する。
