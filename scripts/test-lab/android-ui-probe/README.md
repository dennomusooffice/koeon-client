# サービスを抑止しないUI試験probe

通常の `uiautomator dump` はUiAutomation接続中に既存AccessibilityServiceを抑止するため、背景音量PTT試験の観測を変えてしまう。本helperは公式 `FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES` を使う。製品機能ではない。

ネットワーク・マイク権限なし。UI階層はhelper私有ファイルへ上書き保存し、最大10000node/深さ64/処理15秒、属性4096文字に制限する。UI内容には私的情報が含まれ得る。許可された対象・時間枠だけで実行し、取得内容をAIや公開ログへ丸ごと出さず必要な固定ラベルだけ確認する。保護されたホスト領域へ回収後、端末コピーを削除し、終了時helperをアンインストールする。

```sh
bash scripts/test-lab/android-ui-probe/build.sh
adb -s <authorized-device> install .build/test-lab/ui-probe/ui-probe.apk
adb -s <authorized-device> shell am instrument -w com.dennomuso.koeon.uiprobe/.HierarchyProbe
adb -s <authorized-device> exec-out run-as com.dennomuso.koeon.uiprobe cat files/hierarchy.xml
adb -s <authorized-device> shell run-as com.dennomuso.koeon.uiprobe rm files/hierarchy.xml
adb -s <authorized-device> uninstall com.dennomuso.koeon.uiprobe
```

階層取得が成功しても送信成立の証拠にはしない。FieldJournalの接続/送信と実機音声聴取は別に評価する。
