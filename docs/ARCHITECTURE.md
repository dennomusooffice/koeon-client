# Client architecture

This staging tree contains two native clients and a narrow protocol reference. The backend is an external, private trust boundary and is not implemented here.

```text
iOS client ─┐
            ├─ HTTPS client contract ── private authorization/Floor service
Android ────┘                └───────── short-lived LiveKit session token

iOS/Android ── LiveKit room ── control data + realtime audio
```

The UI lifecycle is separate from the intercom-session lifecycle. A view disappearing must not disconnect the room. The room is not reconnected for every PTT gesture; Floor control is acquired before TX; RX remains available when TX is off; reconnect favors automatic recovery; audio is not recorded.

The repository boundary deliberately excludes membership/auth implementation, Floor arbitration, token signing, APNs provider, persistent-listening backend, database, deployment and signed release workflows.
