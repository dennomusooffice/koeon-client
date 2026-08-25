import { describe, expect, it, vi } from "vitest";
import {
  decodePttRxReadyEvent,
  encodePttRxReadyEvent,
  PTT_RX_READY_TOPIC,
  RX_READY_MULTI_ABSOLUTE_MAX_MS,
  RX_READY_SINGLE_MAX_WAIT_MS,
  RxReadyBarrier,
  type PttRxReadyEvent,
} from "./ptt-rx-ready";

const baseEvent: PttRxReadyEvent = {
  version: 1,
  type: "rx_ready",
  channelId: "stage",
  speakerSessionId: "speaker",
  receiverSessionId: "receiver-a",
  leaseId: "lease-a",
  readyAt: 1_000,
};

describe("RX Ready protocol v1", () => {
  it("round trips the exact reliable topic payload", () => {
    expect(PTT_RX_READY_TOPIC).toBe("koeon.ptt.rx-ready.v1");
    expect(decodePttRxReadyEvent(encodePttRxReadyEvent(baseEvent))).toEqual(baseEvent);
  });

  it("rejects malformed and stale-shaped payloads", () => {
    expect(decodePttRxReadyEvent(new TextEncoder().encode("{}"))).toBeNull();
    expect(decodePttRxReadyEvent(new TextEncoder().encode(JSON.stringify({
      ...baseEvent,
      version: 2,
    })))).toBeNull();
  });
});

describe("adaptive RX Ready barrier", () => {
  it("does not wait when no APNs wake Session is expected", async () => {
    const barrier = createBarrier([]);
    expect(await barrier.wait()).toMatchObject({ reason: "no_expectations", waitMs: 0 });
  });

  it("unlocks a single expected receiver only for its trusted LiveKit identity", async () => {
    const barrier = createBarrier(["receiver-a"]);
    expect(barrier.accept(baseEvent, "other")).toBe(false);
    expect(barrier.accept(baseEvent, "receiver-a")).toBe(true);
    expect(await barrier.wait()).toMatchObject({
      reason: "all_ready",
      expectedCount: 1,
      receivedCountAtMicOn: 1,
    });
  });

  it("keeps waiting for every expected receiver and never completes on first ACK plus settle", async () => {
    vi.useFakeTimers();
    try {
      const barrier = createBarrier(["receiver-a", "receiver-b", "receiver-c"]);
      barrier.accept(baseEvent, "receiver-a");
      let completed = false;
      void barrier.wait().then(() => { completed = true; });
      await vi.advanceTimersByTimeAsync(2_799);
      expect(completed).toBe(false);
      barrier.accept({ ...baseEvent, receiverSessionId: "receiver-b" }, "receiver-b");
      expect(completed).toBe(false);
      barrier.accept({ ...baseEvent, receiverSessionId: "receiver-c" }, "receiver-c");
      expect(await barrier.wait()).toMatchObject({ reason: "all_ready", receivedCountAtMicOn: 3 });
    } finally {
      vi.useRealTimers();
    }
  });

  it("bounds single and multi waits and timeout is not an error", async () => {
    vi.useFakeTimers();
    try {
      const single = createBarrier(["receiver-a"]);
      await vi.advanceTimersByTimeAsync(RX_READY_SINGLE_MAX_WAIT_MS);
      expect(await single.wait()).toMatchObject({ reason: "single_timeout", timedOut: true });

      const multi = createBarrier(["receiver-a", "receiver-b"]);
      await vi.advanceTimersByTimeAsync(RX_READY_MULTI_ABSOLUTE_MAX_MS);
      expect(await multi.wait()).toMatchObject({ reason: "multi_timeout", timedOut: true });
    } finally {
      vi.useRealTimers();
    }
  });

  it("rejects stale lease ACK and cancellation aborts ghost TX", async () => {
    const barrier = createBarrier(["receiver-a"]);
    expect(barrier.accept({ ...baseEvent, leaseId: "old-lease" }, "receiver-a")).toBe(false);
    barrier.cancel();
    expect(await barrier.wait()).toMatchObject({ reason: "cancelled", receivedCountAtMicOn: 0 });
  });

  it("uses Backend-signed stable device identity and rejects forged or duplicate device ACK", async () => {
    const barrier = new RxReadyBarrier({
      expectedSessionIds: [],
      expectedDeviceIds: ["device-a", "device-b"],
      channelId: "stage",
      speakerSessionId: "speaker",
      leaseId: "lease-a",
    });
    expect(barrier.accept({ ...baseEvent, receiverDeviceId: "device-b" }, "receiver-a", "device-a")).toBe(false);
    expect(barrier.accept({ ...baseEvent, receiverDeviceId: "device-a" }, "receiver-a", "device-a")).toBe(true);
    expect(barrier.accept({ ...baseEvent, receiverDeviceId: "device-a" }, "receiver-a", "device-a")).toBe(false);
    expect(barrier.accept({
      ...baseEvent,
      receiverSessionId: "receiver-b",
      receiverDeviceId: "device-b",
    }, "receiver-b", "device-b")).toBe(true);
    expect(await barrier.wait()).toMatchObject({ reason: "all_ready", receivedCountAtMicOn: 2 });
  });
});

function createBarrier(expectedSessionIds: string[]) {
  return new RxReadyBarrier({
    expectedSessionIds,
    channelId: "stage",
    speakerSessionId: "speaker",
    leaseId: "lease-a",
  });
}
