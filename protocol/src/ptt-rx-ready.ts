export const PTT_RX_READY_TOPIC = "koeon.ptt.rx-ready.v1";
export const PTT_RX_READY_VERSION = 1 as const;
export const RX_READY_SINGLE_MAX_WAIT_MS = 4_000;
export const RX_READY_MULTI_ABSOLUTE_MAX_MS = 4_000;

export interface PttRxReadyEvent {
  version: typeof PTT_RX_READY_VERSION;
  type: "rx_ready";
  channelId: string;
  speakerSessionId: string;
  receiverSessionId: string;
  receiverDeviceId?: string;
  leaseId: string;
  readyAt: number;
}

export type RxReadyBarrierReason =
  | "no_expectations"
  | "all_ready"
  | "single_timeout"
  | "multi_timeout"
  | "cancelled";

export interface RxReadyBarrierResult {
  reason: RxReadyBarrierReason;
  expectedCount: number;
  receivedCountAtMicOn: number;
  ratioAtMicOn: number;
  lateCount: number;
  waitMs: number;
  timedOut: boolean;
  firstReadyAt: number | null;
  allReadyAt: number | null;
}

interface RxReadyBarrierOptions {
  expectedSessionIds: readonly string[];
  expectedDeviceIds?: readonly string[];
  channelId: string;
  speakerSessionId: string;
  leaseId: string;
  now?: () => number;
  schedule?: (callback: () => void, milliseconds: number) => ReturnType<typeof setTimeout>;
  cancelSchedule?: (timer: ReturnType<typeof setTimeout>) => void;
}

export class RxReadyBarrier {
  private readonly expected: Set<string>;
  private readonly expectedDevices: Set<string>;
  private readonly effectiveExpected: Set<string>;
  private readonly received = new Set<string>();
  private readonly startedAt: number;
  private readonly now: () => number;
  private readonly schedule: NonNullable<RxReadyBarrierOptions["schedule"]>;
  private readonly cancelSchedule: NonNullable<RxReadyBarrierOptions["cancelSchedule"]>;
  private readonly completion: Promise<RxReadyBarrierResult>;
  private resolveCompletion!: (result: RxReadyBarrierResult) => void;
  private absoluteTimer: ReturnType<typeof setTimeout> | null = null;
  private completed: RxReadyBarrierResult | null = null;
  private firstReadyAt: number | null = null;
  private allReadyAt: number | null = null;

  constructor(private readonly options: RxReadyBarrierOptions) {
    this.expected = new Set(options.expectedSessionIds.filter(nonEmpty));
    this.expectedDevices = new Set((options.expectedDeviceIds ?? []).filter(nonEmpty));
    this.effectiveExpected = this.expectedDevices.size > 0 ? this.expectedDevices : this.expected;
    this.now = options.now ?? Date.now;
    this.schedule = options.schedule ?? setTimeout;
    this.cancelSchedule = options.cancelSchedule ?? clearTimeout;
    this.startedAt = this.now();
    this.completion = new Promise((resolve) => { this.resolveCompletion = resolve; });

    if (this.effectiveExpected.size === 0) {
      this.finish("no_expectations");
    } else {
      const timeout = this.effectiveExpected.size === 1
        ? RX_READY_SINGLE_MAX_WAIT_MS
        : RX_READY_MULTI_ABSOLUTE_MAX_MS;
      this.absoluteTimer = this.schedule(() => {
        this.finish(this.effectiveExpected.size === 1 ? "single_timeout" : "multi_timeout");
      }, timeout);
    }
  }

  wait(): Promise<RxReadyBarrierResult> {
    return this.completion;
  }

  accept(
    event: PttRxReadyEvent,
    participantIdentity: string | undefined,
    participantDeviceId?: string,
  ): boolean {
    if (
      !participantIdentity
      || event.channelId !== this.options.channelId
      || event.speakerSessionId !== this.options.speakerSessionId
      || event.leaseId !== this.options.leaseId
      || event.receiverSessionId !== participantIdentity
    ) return false;

    const readyIdentity = this.expectedDevices.size > 0
      ? event.receiverDeviceId === participantDeviceId && participantDeviceId
        ? participantDeviceId
        : null
      : participantIdentity;
    if (!readyIdentity || !this.effectiveExpected.has(readyIdentity) || this.received.has(readyIdentity)) {
      return false;
    }
    this.received.add(readyIdentity);
    const now = this.now();
    this.firstReadyAt ??= now;
    if (this.received.size === this.effectiveExpected.size) {
      this.allReadyAt = now;
      if (!this.completed) this.finish("all_ready");
      else this.completed = { ...this.completed, lateCount: this.lateCount() };
      return true;
    }
    if (this.completed) this.completed = { ...this.completed, lateCount: this.lateCount() };
    return true;
  }

  cancel(): void {
    this.finish("cancelled");
  }

  snapshot(): RxReadyBarrierResult | null {
    return this.completed ? { ...this.completed, lateCount: this.lateCount() } : null;
  }

  private finish(reason: RxReadyBarrierReason): void {
    if (this.completed) return;
    if (this.absoluteTimer !== null) this.cancelSchedule(this.absoluteTimer);
    this.absoluteTimer = null;
    const receivedCountAtMicOn = this.received.size;
    this.completed = {
      reason,
      expectedCount: this.effectiveExpected.size,
      receivedCountAtMicOn,
      ratioAtMicOn: this.effectiveExpected.size === 0 ? 1 : receivedCountAtMicOn / this.effectiveExpected.size,
      lateCount: 0,
      waitMs: reason === "no_expectations" ? 0 : Math.max(0, this.now() - this.startedAt),
      timedOut: reason === "single_timeout" || reason === "multi_timeout",
      firstReadyAt: this.firstReadyAt,
      allReadyAt: this.allReadyAt,
    };
    this.resolveCompletion(this.completed);
  }

  private lateCount(): number {
    return Math.max(0, this.received.size - (this.completed?.receivedCountAtMicOn ?? this.received.size));
  }
}

export function encodePttRxReadyEvent(event: PttRxReadyEvent): Uint8Array<ArrayBuffer> {
  const encoded = new TextEncoder().encode(JSON.stringify(event));
  const copy = new Uint8Array(new ArrayBuffer(encoded.byteLength));
  copy.set(encoded);
  return copy;
}

export function decodePttRxReadyEvent(data: Uint8Array): PttRxReadyEvent | null {
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(data));
    if (!value || typeof value !== "object") return null;
    const event = value as Partial<PttRxReadyEvent>;
    if (
      event.version !== PTT_RX_READY_VERSION
      || event.type !== "rx_ready"
      || !nonEmpty(event.channelId)
      || !nonEmpty(event.speakerSessionId)
      || !nonEmpty(event.receiverSessionId)
      || !nonEmpty(event.leaseId)
      || !Number.isFinite(event.readyAt)
      || (event.readyAt ?? -1) < 0
    ) return null;
    return event as PttRxReadyEvent;
  } catch {
    return null;
  }
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 256;
}
