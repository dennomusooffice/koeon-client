# 実KOEONのAVD音声測定

[結果・限界・未解決事項](../../docs/EIGHT_DEVICE_LAB_20261108.md)とIssue #56を参照。実登録、実Floor、実LiveKit、公開APKの通常PTTを操作する。APIを使うSDK単体試験とは区別する。実機やiOSはこのスクリプトの対象外。

## 準備

隔離Python環境に検証時の依存を入れる（Python3.9で確認）:

```sh
python3 -m venv .build/macos/emulator-audio-venv
.build/macos/emulator-audio-venv/bin/pip install grpcio==1.80.1 grpcio-tools==1.80.1 numpy==2.0.2
mkdir -p .build/macos/emulator-audio-proto
.build/macos/emulator-audio-venv/bin/python -m grpc_tools.protoc \
  -I "$HOME/Library/Android/sdk/emulator/lib" \
  --python_out=.build/macos/emulator-audio-proto \
  --grpc_python_out=.build/macos/emulator-audio-proto \
  "$HOME/Library/Android/sdk/emulator/lib/emulator_controller.proto"
```

対象AVDに`-grpc PORT -grpc-use-token`を指定する。`-no-audio`は使わない。認証付きlocalhostサービスの起動を確認し、ポートを外部公開しない。トークンはSDKのローカルdiscoveryファイルからのみ読む。再起動は既存AVDを正常終了してから行い、登録データを削除しない。アプリは許可されたテストユーザーで同じチャンネルに登録済みであること。

合成音声を1〜15秒・48kHz mono S16LE WAVで準備する。macOSの`say -v Kyoko -o PRIVATE.aiff '合成の試験文'`と`afconvert PRIVATE.aiff PRIVATE.wav -f WAVE -d LEI16@48000 -c 1`で作成できる。人の発話を録音しない。

## 実行

```sh
.build/macos/emulator-audio-venv/bin/python scripts/mixed-lab/emulator-audio-probe.test.py
GRPC_VERBOSITY=ERROR .build/macos/emulator-audio-venv/bin/python \
  scripts/mixed-lab/emulator-audio-probe.py \
  --sender SOURCE_CONSOLE_PORT --receivers RECEIVER_CONSOLE_PORT_1 RECEIVER_CONSOLE_PORT_2 \
  --source PRIVATE_SYNTHETIC.wav --output PRIVATE_RESULT.json
```

ポートはADBの`emulator-NNNN`のNNNN。物理端末は拒否する。各KOEONを前面へ移し、OFFなら既存登録のままONにする。READYを要求し、送信側のPTTは画面全体に表示する。ホストマイク設定を一時OFFにし終了時に戻す。PTTは有限時間の操作とし、TALKINGを確認できなければ音声を注入しない。受信出力はメモリだけで解析し保存しない。結果JSONにはローカルAVD識別子が含まれるため、そのままGitHubへ貼らず数値を要約する。

終了コード0は、その回に選択したAVDで既知信号の到達基準と送信側READY復帰が成立したという意味。全体の製品合格ではない。失敗は入力未到達・PTT操作不成立・検出器の限界も含むため診断で切り分ける。受信時刻の位置には操作準備時間が含まれ、通信遅延の測定値ではない。`DEADLINE_EXCEEDED`は有限時間の出力採取終了として期待する。

128kbps試験で`emu network speed 128:128`の表示だけを合格証拠にしない。2026-11-09の独立転送試験では設定表示に反してホスト宛512KiBが0.12秒以内に到達した。Wi-Fiを無効にした比較でも制限を確認できなかった。既存の音声到達結果は保持するが、その方式だけの帯域制限合格判定は保留する。

デバッグ可能なAVDだけで`adb -s emulator-NNNN root`を実行し、`emulator-bandwidth.py`を使って通常コマンドを包める。物理端末と非標準の既存qdiscは拒否する。egressはeth0/wlan0それぞれ128kbit/s、ingressはIFBに集約して128kbit/s、burst8KiB、queue latency1000ms。既存のAndroid clsact/BPFフィルタは削除せず、専用priority49152だけを追加・撤去する。

```sh
python3 scripts/mixed-lab/emulator-bandwidth.py \
  --serial emulator-NNNN --evidence-dir PRIVATE_SHAPING_DIR --timeout 180 -- \
  COMMAND ARGUMENTS
```

終了・タイムアウト時に追加設定を撤去し、result.jsonのcleanupFailuresが空であることを確認する。両端末を制限するには異なるserialのwrapperを入れ子にする。試験前には同じ経路の合成転送で上下の実効速度を測る。設定後のTCPペイロード速度はヘッダー・再送・待ち行列で128kbpsより低くなり得る。LTEの損失・ジッター・ハンドオーバーを再現したとは言わない。ADB rootも仮想端末の検証終了時にunrootする。


制限の独立検証には合成256KiBの上下TCP転送を使える（ホスト宛、インターネット/UDP測定ではない）:

```sh
python3 scripts/mixed-lab/emulator-bandwidth.py \
  --serial emulator-NNNN --evidence-dir PRIVATE_SHAPING_DIR --timeout 150 -- \
  python3 scripts/mixed-lab/emulator-throughput.py \
  --serial emulator-NNNN --output PRIVATE_RATE_RESULT.json
```

転送が全量完了し、両方向のペイロード速度が校正範囲70〜145kbpsに入らなければ失敗する。この範囲は帯域上限の実効性と極端な過剰制限を検出するためのもので、128kbpsぴったりのペイロード速度を意味しない。試験で用いるqueue/burstも結果に明記する。
