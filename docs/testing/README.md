# KOEON 自動試験の標準手順

対象: Android 14/15/16/17、iOS Simulator、iPhone、OPPO A79 5G、必要時moto g64 5G。2026-11-09までの検証を基にした運用仕様。入口はこの文書、履歴はIssue #50/#54/#56/#58/#59/#63。新しい実行結果は過去の合格を流用せず、そのソースSHA・ビルドに紐付ける。

- [構成・準備・自動試験](STANDARD.md)
- [新規端末の4時間受入れ](NEW_DEVICE_ACCEPTANCE.md)
- [24時間診断履歴・回収・照合仕様](FIELD_JOURNAL.md)
- [過去の8台試験と限界](../EIGHT_DEVICE_LAB_20261108.md)

現在の基点: iOS 0906/source e68565f、Android 1.0.17(18)/source45176b。新規実装のビルド/検証状態は結果記録を参照する。シミュレーターのプロファイル名は実メーカーのファームウェア・マイク特性を再現しない。

標準ツール: [SIM5ランナー](../../scripts/test-lab/README.md)、[診断回収・突合](../../scripts/field-diagnostics/README.md)。今回の結果は [RESULTS_20261109.md](RESULTS_20261109.md)。

車載のOS割込み試験用に [有限AudioFocus helper](../../scripts/test-lab/android-focus-probe/README.md) を用意。CarPlay/Autoの投影・車載音響とは別判定とする。
