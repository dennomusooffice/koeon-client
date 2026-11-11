# TASK: 本体ボタンPTTの既定ON配信

2026-11-11、所有者依頼、担当Codex/所有者レビュー。Issue #80。基準08aaab3、Bluetooth未解決試作は除外。iOS1.0(2026111107)、Android1.0.22(23)。

## 要求・設計

未保存のiOS Action button設定をtrue、Android音量PTTをTOGGLE、背景設定をtrueにする。既存の明示OFFは保持。iOSはUserDefaults registration domain、AndroidはSharedPreferences fallbackを使い、OS割当/Accessibility権限は変更しない。不正なAndroid保存modeは従来どおりOFFへfail closed。接続/Floor/送信上限/LiveKit/OS音声所有権は変更しない。

配信済みiOS1103基準を隔離worktreeで使用。Bluetoothコード0a726e3/591bdc6、他の未コミット作業を混入させない。既存内部/外部TestFlightグループとGitHub prereleaseへの配信。App Store/Play公開/main mergeは対象外。機器試験枠は失効しており実機は操作しない。

## 検証・STOP CONDITION

差分/未保存と保存済みOFFの意味を確認。既存iOS回帰、Androidunit/lint、署名候補、exact SHA/tree、IPA/APKハッシュを記録する。既存ローカル配信経路を使用。iOSは同一SHA再構築後upload、Apple処理と既存groups照合。Androidは署名済APKとchecksumのみGitHubへ公開しasset digest確認。配信完了または具体的外部障害で停止し未完了を明記。既知の消灯不可/背景受信課題を引き継ぎ、デフォルト変更で解決と扱わない。

## 結果

配信ソース0c1c9e5065e00142d52331810010ec71b58e901b。iOS268件中267成功/1skip、Android212件とLint成功。署名候補後にiOS1107を同一SHAから再構築しアップロード、Apple VALID・内部/外部IN_BETA_TESTING・既存3グループ関係を確認。Android1.0.22(23)をGitHub prerelease公開、asset digest一致。詳細は[配信記録](../RELEASE_20261111_HARDWARE_PTT_DEFAULTS.md)。実機未実施・main未マージ。既知制限のIssueは開いたまま。
