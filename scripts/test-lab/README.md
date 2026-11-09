# SIM5標準ランナー

[運用標準](../../docs/testing/STANDARD.md)を先に読む。`config.example.json`を`.secret/test-lab/config.json`へコピーし、登録済みiOS SimulatorのUDIDと実際のAVD名を設定する。認証情報は不要。Python3標準ライブラリ、ADB、Xcode、起動済みAppium＋XCUITestが必要。

```sh
python3 scripts/test-lab/lab.py inventory --output .secret/test-lab/runs/example-001
python3 scripts/test-lab/lab.py boot --output .secret/test-lab/runs/example-001
# 全台の登録・POWER ON・READY、候補build、同一チャンネルを事前に確認
python3 scripts/test-lab/lab.py control --rounds 3 --output .secret/test-lab/runs/example-001
python3 scripts/test-lab/lab.py shutdown --output .secret/test-lab/runs/example-001
```

bootはiOS→Android順、AVDは1536MiB/2cores・cold boot・音声有効。登録リセット/アプリ自動更新/実機操作は行わない。停止済みアプリは起動するがPOWER ONは勝手に代行しない。ビルド・署名確認・インストールは先に行う。

controlは各送信元の有限20秒PTT、他4台のBUSY_REMOTE、終了後5台READYを観測する。3roundなら送信15/受信60観測。これは制御UIの検証であり音声合格ではない。最初の失敗で反復終了し、XML/結果を非公開保存する。結果のstartedAt/endedAtでjournal/serverの同時間帯を照合する。Android入力は有限swipe、iOSは有限W3C actionsとfinally releaseを使う。

対象はAPI34–37のemulator-serialとsimctl一覧で検証したiOS Simulatorだけ。MIX7/8やNEW6は本書の端末別手順を組み合わせ、実機操作枠・復元記録を別に用意する。自動runnerへ実機serialを紛れ込ませない。

音声・帯域・復旧: [EMULATOR_AUDIO.md](../mixed-lab/EMULATOR_AUDIO.md)、`emulator-audio-probe.py --help`、`emulator-network-recovery.py --help`。制御runnerと同じprivate runディレクトリへ保存し、capture基盤を先に検証。これらは任意の環境で無条件に全行列を自動実行するものではない。
