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

128kbps試験は、元の`emu network status`を保存してから`emu network speed 128:128`を設定し、例外時も元の設定へ戻す。設定確認と実効帯域測定は別。LTEの損失・ジッター・ハンドオーバーを再現したとは言わない。
