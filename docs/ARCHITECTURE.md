# Client architecture（クライアント構成）

このtreeには2つのnative clientと、範囲を限定したprotocol referenceが含まれます。backendは外部のprivate trust boundaryであり、このrepositoryには実装しません。

```text
iOS client ─┐
            ├─ HTTPS client contract ── private authorization/Floor service
Android ────┘                └───────── short-lived LiveKit session token

iOS/Android ── LiveKit room ── control data + realtime audio
```

UI lifecycleとintercom-session lifecycleは分離します。viewが非表示になっただけでRoomを切断してはいけません。PTT操作ごとにRoomを再接続せず、TX前にFloor controlを取得します。TXがoffでもRXは利用可能な状態を維持し、reconnectでは自動復旧を優先します。audioは録音しません。

repository boundaryからは、membership / auth implementation、Floor arbitration、token signing、APNs provider、persistent-listening backend、database、deployment、signed release workflowを意図的に除外しています。
