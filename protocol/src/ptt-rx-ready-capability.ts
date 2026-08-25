export const RX_READY_PROTOCOL_VERSION = 1 as const;

export interface RxReadyParticipantMetadata {
  deviceId: string;
  rxReadyProtocolVersion: typeof RX_READY_PROTOCOL_VERSION;
}

/**
 * LiveKit participant metadata is signed by the Backend token and cannot be
 * updated by clients. Unknown or legacy participants are deliberately not
 * treated as RX_READY-capable.
 */
export function rxReadyParticipantMetadata(
  metadata: string | undefined | null,
): RxReadyParticipantMetadata | null {
  if (!metadata) return null;
  try {
    const value: unknown = JSON.parse(metadata);
    if (!value || typeof value !== "object") return null;
    const object = value as { deviceId?: unknown; rxReadyProtocolVersion?: unknown };
    if (
      typeof object.deviceId !== "string"
      || object.deviceId.length === 0
      || object.deviceId.length > 256
      || object.rxReadyProtocolVersion !== RX_READY_PROTOCOL_VERSION
    ) return null;
    return {
      deviceId: object.deviceId,
      rxReadyProtocolVersion: RX_READY_PROTOCOL_VERSION,
    };
  } catch {
    return null;
  }
}
