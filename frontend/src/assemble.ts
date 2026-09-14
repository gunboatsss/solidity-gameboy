import { hexToBytes } from 'viem';

export const FB_W = 160;
export const FB_H = 144;
export const FB_LEN = FB_W * FB_H; // 23040, shades 0 (white)..3 (black)

export interface Decoded {
  eventName?: string;
  args?: any;
}

/** Reassembles frames from Scanline/FrameDone events across step() receipts.
 *  Rows missing from a completed frame (e.g. LCD was off for part of it —
 *  the chain legitimately emits nothing then) hold over from the previous
 *  frame, like a real display; only truly rendered rows overwrite. */
export class FrameAssembler {
  private frames = new Map<string, { lines: Map<number, Uint8Array>; done: boolean }>();
  private lastFb: Uint8Array | null = null;

  /** Returns serial bytes seen in these logs. */
  ingest(decoded: Decoded[]): number[] {
    const serial: number[] = [];
    for (const log of decoded) {
      if (log.eventName === 'Scanline') {
        const key = String(log.args.frame);
        let e = this.frames.get(key);
        if (!e) {
          e = { lines: new Map(), done: false };
          this.frames.set(key, e);
        }
        e.lines.set(Number(log.args.ly), hexToBytes(log.args.px as `0x${string}`));
      } else if (log.eventName === 'FrameDone') {
        const key = String(log.args.frame);
        let e = this.frames.get(key);
        if (!e) {
          e = { lines: new Map(), done: false };
          this.frames.set(key, e);
        }
        e.done = true;
      } else if (log.eventName === 'SerialByte') {
        serial.push(Number(log.args.b));
      }
    }
    return serial;
  }

  takeCompleted(): { frame: bigint; fb: Uint8Array } | null {
    for (const [key, e] of this.frames) {
      if (!e.done) continue;
      this.frames.delete(key);
      const fb = this.lastFb ? this.lastFb.slice() : new Uint8Array(FB_LEN);
      for (const [ly, px] of e.lines) {
        if (ly < FB_H) fb.set(px.slice(0, FB_W), ly * FB_W);
      }
      this.lastFb = fb.slice();
      return { frame: BigInt(key), fb };
    }
    return null;
  }

  reset(): void {
    this.frames.clear();
    this.lastFb = null;
  }
}
