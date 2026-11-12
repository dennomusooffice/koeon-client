# TASK: 最新Console UIの限定配布

2026-11-12、所有者依頼、#88/PR #90。担当Codex、レビュー所有者。基準0fd6fb7。Androidの固定LCD/CH切替・透明キーとiOS透明キーをTestFlight内部/外部とGitHub Android prereleaseへ配布する。

受入れ: Android1.0.24(25)、iOS1.0(2026111136)の未使用番号、Android署名/非debuggable/ハッシュ、iOS外部候補署名/アップロード・Apple処理/既存テスター群の利用可能状態を検証する。ソースを固定し、候補から公開へ。同一版の追加実機試験は期限終了により対象外。App Store/Play一般公開、mainマージ、サーバー変更は対象外。

STOP CONDITION: 正確なSHA、ビルド番号、成果物hash、配布状態、未検証と音声試験の失敗をIssue/PR/配布記録へ記載。失敗時は配布を進めず原因を記録する。端末操作の許可時間は終了済み。
