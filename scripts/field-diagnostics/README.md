# フィールド診断の回収・突合

仕様は [FIELD_JOURNAL.md](../../docs/testing/FIELD_JOURNAL.md)。Python3標準ライブラリのみ。

1. 症状後にPOWER操作せず、Diagnostics → **Export 24-hour Field Journal**。
2. Androidは保存先を選択。iOSは完了後 **Share Field Journal** → Files/AirDrop等で管理者Macへ保存。
3. 自動回収可能な開発接続は `fetch.py`。これは**既に作成されたexport**だけを回収する。返るexportedAtMsが対象試験後か確認。ロック解除やアプリのexport操作を代行したと扱わない。

```sh
python3 scripts/field-diagnostics/fetch.py ios-sim --device "$SIM_UDID" --output .secret/field-input/ios.json
python3 scripts/field-diagnostics/fetch.py android-debug --device emulator-5554 --app com.dennomuso.koeon --output .secret/field-input/android.json
# releaseはrun-as不可。例は利用者がDownloadsへ保存した場合のみ。
python3 scripts/field-diagnostics/fetch.py android-file --device "$ANDROID_SERIAL" --remote /sdcard/Download/KOEON-field-journal.json --output .secret/field-input/android-release.json
python3 scripts/field-diagnostics/collect.py --device ios=.secret/field-input/ios.json --device android=.secret/field-input/android.json --server server=.secret/field-input/server-adapter.jsonl --offset ios=-20 --output .secret/field-runs/example-001
python3 -m unittest discover -s scripts/field-diagnostics -v
```

実際のAndroid applicationIdはbuild設定を確認する。`fetch.py --app`で指定する。実機は有効な操作許可枠内だけ使用する。署名releaseの私有領域へ侵入するroot/providerは設けない。

サーバーadapterは1行1JSON。例（架空値）:

```json
{"wallTimeMs":1794182400000,"event":"FLOOR_GRANTED","sessionId":"fixture-session","leaseId":"fixture-lease","channelId":"fixture-channel"}
```

実サーバーのログ形式に合わせ、対象時間帯をこの契約へ変換する。任意の生ログを丸ごと渡してよいツールではない。adapter入力の生IDはSHA256化され、自由文・認証情報は結合出力へ転送しない。サーバー入力はアーカイブコピーしない。

出力: 各端末bundle原本、SHA256 `manifest.json`、正規化時系列/lease別集合/欠落指標の `correlation.json`。ディレクトリ0700・新規ファイル0600。重複exportはinstallationId/runId/sequenceで排除。clock offsetは手動測定値を加算、元時刻は保持。同時刻だけでは同発話と推定しない。欠落はパケット損失や可聴失敗と同義ではない。AndroidのPCMカウンタはRoom集計、iOS RX_PCMは検証済み受信世代の最初のcallbackで、いずれも可聴成功の証明ではない。

原本/ハッシュ/installationIdも公開資料ではない。GitHubへはケース名・匿名化集計・SHA/build・未検証事項だけを転記する。実際のサーバーログとの照合は対象時間帯のadapterがある場合に限る。
