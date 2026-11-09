# 有限AudioFocus試験用アプリ

通信・マイク・録音権限を持たないdebug helper。前面Activityで500ms後にMEDIA/SPEECHのfocusを取得し、10秒後に必ずabandon/finishする。destroy時もabandon。`permanent`はGAIN、`transient`はGAIN_TRANSIENT。結果は私有`files/result.json`、releaseされるまでreleasedAt=0。

```sh
bash scripts/test-lab/android-focus-probe/build.sh
adb -s emulator-5558 install -r .build/test-lab/focus-probe/focus-probe.apk
adb -s emulator-5558 shell am start -n com.dennomuso.koeon.focusprobe/.MainActivity --es mode transient
# 10秒のfocus期間と復帰後を別々に観測。KOEONのjournalを保存する。
adb -s emulator-5558 exec-out run-as com.dennomuso.koeon.focusprobe cat files/result.json
adb -s emulator-5558 shell am start -n com.dennomuso.koeon/.MainActivity
# 試験終了後は、このhelperだけを削除する。
adb -s emulator-5558 uninstall com.dennomuso.koeon.focusprobe
```

KOEONがREADY→割込み→再初期化/READYとなり、次の有限PTTが成功することを別に確認する。focus requestのresult=1とreleasedAt>0を必須とする。フォーカス取得できなかったrunは不合格音声ではなく環境無効。これは車載アプリとの割込みに相当するOS API試験であり、Android Auto投影/USBルート/車載マイクの代替ではない。
