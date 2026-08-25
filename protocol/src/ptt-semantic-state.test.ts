import { describe, expect, it } from "vitest";
import { pttSemanticState } from "./ptt-semantic-state";

const base = { listener: false, connected: true, recovering: false, remoteTalking: false, pttState: "IDLE" as const, error: false };

describe("PTT semantic state", () => {
  it("returns BUSY_REMOTE to READY after remote RX ends", () => {
    expect(pttSemanticState({ ...base, remoteTalking: true })).toBe("BUSY_REMOTE");
    expect(pttSemanticState(base)).toBe("READY");
  });

  it("keeps listener neutral and exposes preparing and errors", () => {
    expect(pttSemanticState({ ...base, listener: true })).toBe("RX_ONLY");
    expect(pttSemanticState({ ...base, pttState: "REQUESTING" })).toBe("PREPARING");
    expect(pttSemanticState({ ...base, error: true })).toBe("ERROR");
    expect(pttSemanticState({ ...base, connected: false })).toBe("OFFLINE");
    expect(pttSemanticState({ ...base, recovering: true })).toBe("RECOVERING");
    expect(pttSemanticState({ ...base, pttState: "TRANSMITTING" })).toBe("TALKING");
    expect(pttSemanticState({ ...base, pttState: "BUSY" })).toBe("BUSY_REMOTE");
  });
});
