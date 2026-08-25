export type PttSemanticState =
  | "READY" | "TALKING" | "BUSY_REMOTE" | "PREPARING"
  | "ERROR" | "RECOVERING" | "OFFLINE" | "RX_ONLY";

export function pttSemanticState(input: {
  listener: boolean;
  connected: boolean;
  recovering: boolean;
  remoteTalking: boolean;
  pttState: "IDLE" | "REQUESTING" | "TRANSMITTING" | "BUSY" | "RELEASING";
  error: boolean;
}): PttSemanticState {
  if (input.listener) return "RX_ONLY";
  if (input.error) return "ERROR";
  if (!input.connected) return "OFFLINE";
  if (input.recovering) return "RECOVERING";
  if (input.remoteTalking || input.pttState === "BUSY") return "BUSY_REMOTE";
  if (input.pttState === "TRANSMITTING") return "TALKING";
  if (input.pttState === "REQUESTING" || input.pttState === "RELEASING") return "PREPARING";
  return "READY";
}
