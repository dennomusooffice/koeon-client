# Client-safe protocol notes

The canonical machine-readable subset is in `protocol/src/` and the corresponding native implementations/tests.

- PTT control topic: `koeon.ptt.control`, version 1
- fast-start control topic: `koeon.ptt.control.fast-start.v1`
- RX_READY topic: `koeon.ptt.rx-ready.v1`, version 1
- Floor lease TTL: 3000 ms; renewal interval: 1000 ms; maximum continuous TX: 60000 ms
- current single and multi RX_READY maximum wait: 4000 ms

RX_READY accepts only the expected participant/session or backend-signed stable device identity for the active channel, speaker session and lease. Duplicate, stale, malformed or mismatched acknowledgements are rejected. A timeout is a bounded readiness outcome, not authorization to bypass Floor control.

`P1_PROTOCOL_DOCUMENTATION_DRIFT`: older canonical documents state 1200 ms / 600 ms while current implementation is 4000 ms. This export preserves current code and records the discrepancy; it does not change the timeout.
