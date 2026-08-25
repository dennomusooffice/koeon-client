import { describe, expect, it } from "vitest";
import { rxReadyParticipantMetadata } from "./ptt-rx-ready-capability";

describe("RX_READY signed participant capability", () => {
  it("accepts only explicit protocol v1 with a stable device identity", () => {
    expect(rxReadyParticipantMetadata(JSON.stringify({
      deviceId: "device-a",
      rxReadyProtocolVersion: 1,
    }))).toEqual({ deviceId: "device-a", rxReadyProtocolVersion: 1 });
    expect(rxReadyParticipantMetadata(JSON.stringify({ deviceId: "legacy" }))).toBeNull();
    expect(rxReadyParticipantMetadata(JSON.stringify({
      deviceId: "future",
      rxReadyProtocolVersion: 2,
    }))).toBeNull();
    expect(rxReadyParticipantMetadata("not-json")).toBeNull();
  });
});
