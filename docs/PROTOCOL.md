# Client-safe protocol notes（クライアント向けprotocol仕様）

canonicalなmachine-readable subsetは`protocol/src/`と、それに対応するnative implementation / testにあります。

- PTT control topic: `koeon.ptt.control`、version 1
- fast-start control topic: `koeon.ptt.control.fast-start.v1`
- RX_READY topic: `koeon.ptt.rx-ready.v1`、version 1
- Floor lease TTL: 3000 ms、renewal interval: 1000 ms、maximum continuous TX: 60000 ms
- current single / multi RX_READY maximum wait: 4000 ms

RX_READYが受理するのは、activeなChannel、speaker session、leaseに対して期待されるparticipant / session、またはbackend-signed stable device identityだけです。duplicate、stale、malformed、不一致のacknowledgementは拒否します。timeoutはreadinessに関するbounded outcomeであり、Floor controlを迂回する許可ではありません。

`P1_PROTOCOL_DOCUMENTATION_DRIFT`: 以前のcanonical documentには1200 ms / 600 msと記載されていますが、current implementationは4000 msです。このexportではcurrent codeを維持して差異を記録し、timeoutは変更しません。

PTT開始レイテンシの安全境界と実機計測項目は[PTT_STARTUP_LATENCY.md](PTT_STARTUP_LATENCY.md)を参照してください。4,000ms barrierはcold-wake correctnessのため維持し、iOSではfloor grant後のApple PushToTalk activation preparationをbarrierと並列化します。
