# SIM5標準ランナー

[運用標準](../../docs/testing/STANDARD.md)を先に読む。`config.example.json`を`.secret/test-lab/config.json`へコピーし、登録済みiOS SimulatorのUDIDと実際のAVD名を設定する。認証情報は不要。Python3標準ライブラリ、ADB、Xcode、起動済みAppium＋XCUITestが必要。

```sh
python3 scripts/test-lab/lab.py inventory --output .secret/test-lab/runs/example-001
python3 scripts/test-lab/lab.py boot --output .secret/test-lab/runs/example-001
# 全台の登録、候補build、同一チャンネルを事前に確認
python3 scripts/test-lab/lab.py ready --output .secret/test-lab/runs/example-001
python3 scripts/test-lab/lab.py control --rounds 3 --output .secret/test-lab/runs/example-001
python3 scripts/test-lab/lab.py shutdown --output .secret/test-lab/runs/example-001
```

bootはiOS→Android順、AVDはAPI34–36で1536MiB、API37では最低4096MiB、各2cores・cold boot・音声有効。configのAndroid端末ごとの`memoryMb`で増量できる。Android17はEmulator自体が4GiBへ増量するため、1.5GiBで収まると見積もらない。inventoryは起動時指定量とゲストMemTotalを区別して記録する。登録リセット/アプリ自動更新/実機操作は行わない。bootは停止済みアプリを起動する。明示的なreadyコマンドは登録済み画面のPOWER ONだけを押し、30秒のREADYゲートを確認する。登録・招待コード入力・POWER OFFは代行しない。ビルド・署名確認・インストールは先に行う。

controlは各送信元の有限20秒PTT、他4台のBUSY_REMOTE、終了後5台READYを観測する。3roundなら送信15/受信60観測。これは制御UIの検証であり音声合格ではない。最初の失敗で反復終了し、XML/結果を非公開保存する。結果のstartedAt/endedAtでjournal/serverの同時間帯を照合する。Android入力は有限swipe、iOSは有限W3C actionsとfinally releaseを使う。

対象はAPI34–37のemulator-serialとsimctl一覧で検証したiOS Simulatorだけ。MIX7/8やNEW6は本書の端末別手順を組み合わせ、実機操作枠・復元記録を別に用意する。自動runnerへ実機serialを紛れ込ませない。

音声・帯域・復旧: [EMULATOR_AUDIO.md](../mixed-lab/EMULATOR_AUDIO.md)、`emulator-audio-probe.py --help`、`emulator-network-recovery.py --help`。制御runnerと同じprivate runディレクトリへ保存し、capture基盤を先に検証。これらは任意の環境で無条件に全行列を自動実行するものではない。

iOSの起動には既存のDebug Simulator専用 `SIMCTL_CHILD_KOEON_SIMULATOR_FOREGROUND=1` を渡す（bootに組込み済み）。Apple PTChannelManagerはSimulatorでは生成できず、無指定だと`pushtotalk.instantiation error 1`になる。画面の専用モード表示を確認する。これは実バックエンド/LiveKitの前面通信を通すアダプターで、実機APNs/PTTの背景wake試験ではない。bootはこの環境変数を反映するため対象SimulatorのKOEONプロセスを再起動する。試験途中の証拠採取にbootを使わない。

切り分け時は `control --senders ios,a14 --rounds 3` のように部分行列を指定できる。部分行列の成功を5送信者全体の成功にしない。

## 台数を減らす切り分け

`--senders`は送信元だけを絞る。起動・受信・停止対象も減らす場合は、すべてのコマンドで同じ`--only`を使う。既に起動済みの除外端末を自動停止する機能ではないため、前の試験を終了してから開始する。

```sh
python3 scripts/test-lab/lab.py boot --only a14,a15 --output .secret/test-lab/runs/reduced-001
python3 scripts/test-lab/lab.py ready --only a14,a15 --output .secret/test-lab/runs/reduced-001
python3 scripts/test-lab/lab.py inventory --only a14,a15 --output .secret/test-lab/runs/reduced-001
python3 scripts/test-lab/lab.py control --only a14,a15 --rounds 3 --output .secret/test-lab/runs/reduced-001
python3 scripts/test-lab/lab.py shutdown --only a14,a15 --output .secret/test-lab/runs/reduced-001
```

この構成はAndroid2台でありSIM5成功とは表記しない。iOSを除外するとiOS SimulatorもAppiumも起動・停止しない。`selection.json`と異なる対象を同じrunへ指定すると拒否し、終了時の対象拡大を防ぐ。1台でのboot/ready/inventoryは可能だが、受信相手のないcontrolは拒否する。既定値は従来のSIM5。

音声異常はまず1台アイドル→2台音声3回→短い通信断からの新規送信で比較し、ビルドは同時実行しない。各段階の`vm_stat`、`sysctl vm.swapusage`、`memory_pressure`と実際の起動台数を保護領域に保存する。スワップ使用量は履歴を含み、現在のメモリ不足の証拠とは限らない。HAL入力読み取りエラーだけで再生不良と判定せず、出力書き込みエラー・信号検出・接続状態を照合する。根因未確定時にアプリを修正済みとしない。

選択・停止範囲の回帰確認: `python3 -m unittest discover -s scripts/test-lab -p test_lab.py -v`。
