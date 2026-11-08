# Client-safe protocol notes（クライアント向けprotocol仕様）

canonicalなmachine-readable subsetは`protocol/src/`と、それに対応するnative implementation / testにあります。

- PTT control topic: `koeon.ptt.control`、version 1
- fast-start control topic: `koeon.ptt.control.fast-start.v1`
- RX_READY topic: `koeon.ptt.rx-ready.v1`、version 1
- Floor lease TTL: 3000 ms、renewal interval: 1000 ms、maximum continuous TX: 60000 ms
- standard single / multi RX_READY maximum wait: 500 ms (iOS OFF=0 / FAST=250 remain available)

RX_READYが受理するのは、activeなChannel、speaker session、leaseに対して期待されるparticipant / session、またはbackend-signed stable device identityだけです。duplicate、stale、malformed、不一致のacknowledgementは拒否します。timeoutはreadinessに関するbounded outcomeであり、Floor controlを迂回する許可ではありません。

2026-11-08、利用者の明示要件でリアルタイム性を優先し、標準TXをLiveKit Opusへ復帰した。旧4,000ms待ちと保持PCMの全量送信は標準経路から外す。遅いreceiverの途中参加、多少の語頭・語尾欠けを許容する。旧BATv1送信者からの受信互換は維持する。

PTT開始レイテンシの安全境界と実機計測項目は[PTT_STARTUP_LATENCY.md](PTT_STARTUP_LATENCY.md)を参照してください。iOSではfloor grant後のApple PushToTalk activation preparationをbarrierと並列化します。開始音はRTP track有効化後、アプリtouch UPでは180msの語尾保護後にmuteします。system/headset終了・OS割込みは即時停止を優先します。
