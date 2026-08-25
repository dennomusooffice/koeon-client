export const PTT_CONTROL_TOPIC = "koeon.ptt.control";
export const PTT_CONTROL_FAST_START_TOPIC = "koeon.ptt.control.fast-start.v1";
export const PTT_CONTROL_VERSION = 1 as const;

export type PttControlType = "start" | "end";

export interface PttControlEvent {
  version: typeof PTT_CONTROL_VERSION;
  type: PttControlType;
  channelId: string;
  speakerUserId: string;
  sessionId: string;
  leaseId: string;
  sequence: number;
  sentAt: number;
}

export function encodePttControlEvent(event: PttControlEvent): Uint8Array<ArrayBuffer> {
  const encoded = new TextEncoder().encode(JSON.stringify(event));
  const copy = new Uint8Array(new ArrayBuffer(encoded.byteLength));
  copy.set(encoded);
  return copy;
}

export function decodePttControlEvent(data: Uint8Array): PttControlEvent | null {
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(data));
    if (!value || typeof value !== "object") return null;
    const event = value as Partial<PttControlEvent>;
    if (
      event.version !== PTT_CONTROL_VERSION
      || (event.type !== "start" && event.type !== "end")
      || !nonEmpty(event.channelId)
      || !nonEmpty(event.speakerUserId)
      || !nonEmpty(event.sessionId)
      || !nonEmpty(event.leaseId)
      || !Number.isSafeInteger(event.sequence)
      || (event.sequence ?? -1) < 0
      || !Number.isFinite(event.sentAt)
      || (event.sentAt ?? -1) < 0
    ) return null;
    return event as PttControlEvent;
  } catch {
    return null;
  }
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 256;
}
