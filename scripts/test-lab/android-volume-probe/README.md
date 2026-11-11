# 背景音量キー配送プローブ

内部試験専用。ネットワーク/マイク/録音権限なし。AccessibilityServiceのkey filterだけを要求し、window内容とAccessibilityEventは取得しない。非音量キーは記録せず通過。固定件数のcounterと最後の単調時刻・音量key codeだけを私有`files/state.json`へ上書きする。counterは100万で飽和する。

`Observe for 10 minutes`はvolume入力を観測して非消費、`Consume for 10 minutes`は通常音量操作を一時抑止する。いずれも10分の単調時刻期限後は監視・消費を停止する。`Disarm`で即時解除。音声を送信する機能はない。

```sh
bash scripts/test-lab/android-volume-probe/build.sh
adb -s <許可されたOPPO> install .build/test-lab/volume-probe/volume-probe.apk
adb -s <許可されたOPPO> shell am start -n com.dennomuso.koeon.volumeprobe/.MainActivity
# 通常の設定UIでサービスを有効化し、probe画面で有限時間armする。
adb -s <許可されたOPPO> exec-out run-as com.dennomuso.koeon.volumeprobe cat files/state.json
# サービスを設定UIで無効化し、このhelperだけ削除する。
adb -s <許可されたOPPO> uninstall com.dennomuso.koeon.volumeprobe
```

前面/別アプリ/ロック点灯/消灯を分け、DOWN/UP、repeat、cancel、interactive、lockedのcounter差分を記録する。ADBのキー注入は実物のキー押下の証拠ではない。OSが配送しない入力を許可書換え/rootで迂回しない。元の音量・ユーザー補助設定を非公開で保全し、終了後に復元する。既存同名helperを無確認で上書きしない。

受入れ・制限は[背景PTT TASK](../../../docs/development/HARDWARE_PTT_BACKGROUND_TASK.md)。このAPKを公開リリースに含めない。
