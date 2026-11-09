import { describe, expect, it } from "vitest";
import { decodePttControlEvent, encodePttControlEvent, type PttControlEvent } from "./ptt-control";
const event: PttControlEvent = {
  version: 1, type: "start", channelId: "test", speakerUserId: "speaker",
  sessionId: "session", leaseId: "lease", sequence: 1, sentAt: 1000,
};
describe("LiveKit-only control", () => {
  it("round trips current START and END without a retired marker", () => {
    for (const type of ["start", "end"] as const) {
      const current = { ...event, type };
      expect(decodePttControlEvent(encodePttControlEvent(current))).toEqual(current);
    }
  });
  it("rejects retired START and END rather than interpreting them as RTP", () => {
    for (const type of ["start", "end"] as const) {
      for (const bufferedGenerationId of ["old", "", 123, {}]) {
        const bytes = new TextEncoder().encode(JSON.stringify({ ...event, type, bufferedGenerationId }));
        expect(decodePttControlEvent(bytes)).toBeNull();
      }
    }
  });
  it("accepts null marker from previous LiveKit-only senders", () => {
    const bytes = new TextEncoder().encode(JSON.stringify({ ...event, bufferedGenerationId: null }));
    expect(decodePttControlEvent(bytes)?.leaseId).toBe(event.leaseId);
  });
});
