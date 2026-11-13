# TASK: LED両側発光の実機テスト配布

2026-11-13、#88/PR #90。所有者が実機テストのため新UI版の公開を指示。対象ソース1943b79のCH/PTT LED変更をAndroid GitHub prereleaseとiOS内部・外部TestFlightへ配布する。Android1.0.25(26)、iOS1.0(2026111137)。以前の未コミット文書と音声機能変更を含めない。

受入れ: 固定コミットでparity、Android/iOS候補署名、版/entitlement/digestを検証。Android release公開とApple VALID・内部/外部テスター群のbuild関係を確認。実機の操作は今回の配布依頼に含まれず、所有者が実機テストを行う。既存の合成音声可聴再生未合格を配布ノートに残す。App Store/Play一般公開とmainマージは対象外。

STOP CONDITION: SHA、ビルド番号、hash、配布状態、未検証をIssue/PR/配布記録へ記載。候補検証失敗時は公開しない。Codex利用枠残量3%到達時は新規テストを停止し状態を記録する。
