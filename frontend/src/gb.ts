import {
  bytesToHex,
  decodeEventLog,
  decodeFunctionResult,
  encodeFunctionData,
  hexToBytes,
  parseAbiItem,
} from 'viem';
import type { Log } from 'viem';
import type { Signer } from './eth';
import { chain, publicClient } from './eth';
import { activeChainId, activePreset, factoryAddress, GAMES_FROM_BLOCK } from './config';
import GameBoyAbi from './abi/GameBoy.json';
import FactoryAbi from './abi/GameBoyFactory.json';
import { parseRomMeta } from './rom';

export const CHUNK = 0x4000;
export function stepBudget(): number {
  return activePreset().stepBudget;
}
// Fixed step gas (Anvil/Ethereum default): 16M covers the worst-measured
// ~10M step with headroom while staying under the 16.7M EIP-7825 cap.
// Steps are atomic (full budget or revert), so the limit only needs to
// exceed the worst case, not match it exactly.
export const GAS_STEP = 16_000_000n;
// Upper bound for estimated step gas: stays clear of per-tx caps with margin.
const GAS_CAP = 29_000_000n;
export { FB_H, FB_W, FB_LEN, FrameAssembler } from './assemble.ts';
export type { Decoded } from './assemble.ts';
import type { Decoded, FrameAssembler } from './assemble.ts';

// bit0 A, bit1 B, bit2 Select, bit3 Start, bit4 Right, bit5 Left, bit6 Up, bit7 Down
export const BTN = { A: 1, B: 2, SELECT: 4, START: 8, RIGHT: 16, LEFT: 32, UP: 64, DOWN: 128 } as const;

/** Decode receipt logs against an ABI, skipping foreign logs. */
export function decodeLogs(abi: any, logs: Log[]): Decoded[] {
  const out: Decoded[] = [];
  for (const log of logs) {
    try {
      out.push(decodeEventLog({ abi, data: log.data, topics: log.topics }) as Decoded);
    } catch {
      /* foreign event */
    }
  }
  return out;
}

/** Decode receipt logs against the GameBoy ABI, skipping foreign logs. */
export function decodeGameLogs(logs: Log[]): Decoded[] {
  return decodeLogs(GameBoyAbi, logs);
}

const GAME_CREATED = parseAbiItem(
  'event GameCreated(address indexed game, address indexed creator, bytes32 romHash)',
);

export interface GameInfo {
  game: `0x${string}`;
  creator: `0x${string}`;
  romHash: `0x${string}`;
  title?: string;
}

const LS_GAMES = 'sgb.games';

function cacheKey(): string {
  return `${LS_GAMES}.${activeChainId()}`;
}

function readGameCache(): GameInfo[] {
  try {
    const raw = JSON.parse(localStorage.getItem(cacheKey()) ?? '[]') as unknown;
    if (!Array.isArray(raw)) return [];
    return raw.filter(
      (g): g is GameInfo =>
        typeof g === 'object' && g !== null && typeof (g as GameInfo).game === 'string',
    );
  } catch {
    return [];
  }
}

export function cacheGame(game: `0x${string}`, creator: `0x${string}`, title = ''): void {
  try {
    const cur = readGameCache().filter((g) => g.game.toLowerCase() !== game.toLowerCase());
    cur.push({ game, creator, romHash: '0x0000000000000000000000000000000000000000000000000000000000000000', title });
    localStorage.setItem(cacheKey(), JSON.stringify(cur.slice(-50)));
  } catch {
    /* private mode etc: list stays on-chain only */
  }
}

/** Read a booted game's title from its first ROM store (SSTORE2 code read).
 *  Empty string when unavailable (unbooted game, storage-path ROM). */
export async function fetchRomTitle(game: `0x${string}`): Promise<string> {
  try {
    const store = (await publicClient.readContract({
      address: game,
      abi: GameBoyAbi,
      functionName: 'romStore',
      args: [0],
    })) as `0x${string}`;
    const code = await publicClient.getCode({ address: store });
    if (!code || code.length < 2 + (0x144 + 1) * 2) return '';
    return parseRomMeta(hexToBytes(code).slice(1)).title;
  } catch {
    return '';
  }
}

export function removeGameCache(game: `0x${string}`): void {
  try {
    const cur = readGameCache().filter((g) => g.game.toLowerCase() !== game.toLowerCase());
    localStorage.setItem(cacheKey(), JSON.stringify(cur));
  } catch {
    /* ignore */
  }
}

export async function listGames(): Promise<GameInfo[]> {
  const seen = new Map<string, GameInfo>();
  for (const g of readGameCache()) seen.set(g.game.toLowerCase(), g);
  try {
    const logs = await publicClient.getLogs({
      address: factoryAddress(),
      event: GAME_CREATED,
      fromBlock: GAMES_FROM_BLOCK ?? 0n,
      toBlock: 'latest',
    });
    for (const l of logs) {
      const g = {
        game: l.args.game as `0x${string}`,
        creator: l.args.creator as `0x${string}`,
        romHash: l.args.romHash as `0x${string}`,
      };
      seen.set(g.game.toLowerCase(), g);
    }
  } catch {
    /* history unavailable (e.g. Monad full-node limits): cache stands in */
  }
  return [...seen.values()];
}

const ARB_GAS_INFO = '0x000000000000000000000000000000000000006c' as const;
const ARB_MAX_TX_GAS = parseAbiItem('function getMaxTxGasLimit() view returns (uint256)');

const maxTxCache = new Map<number, bigint>();

/** Max tx gas limit on Arbitrum Orbit chains, via the ArbGasInfo precompile.
 *  Cached per chain; null when unavailable (non-Orbit chains, RPC limits). */
export async function maxTxGasLimit(): Promise<bigint | null> {
  if (!activePreset().arbOrbit) return null;
  const id = activeChainId();
  const hit = maxTxCache.get(id);
  if (hit !== undefined) return hit;
  try {
    const v = (await publicClient.readContract({
      address: ARB_GAS_INFO,
      abi: [ARB_MAX_TX_GAS],
      functionName: 'getMaxTxGasLimit',
      args: [],
    })) as bigint;
    maxTxCache.set(id, v);
    return v;
  } catch {
    return null;
  }
}

/** Step gas for one tx. Fixed chains send the deterministic budget; chains
 *  that charge gas_limit x price (Monad) estimate + 25% buffer instead, so
 *  idle-heavy steps don't pay for unused headroom. On Arbitrum Orbit chains
 *  the buffer is capped against the on-chain max tx gas limit (ArbGasInfo).
 *  Falls back to fixed. */
export async function resolveStepGas(
  signer: Signer,
  game: `0x${string}`,
  budget: number,
  buttons: number,
): Promise<bigint> {
  if (activePreset().gasStrategy !== 'estimate') return GAS_STEP;
  try {
    const est = await publicClient.estimateGas({
      account: signer.account,
      to: game,
      data: encodeFunctionData({ abi: GameBoyAbi, functionName: 'step', args: [budget, buttons] }),
    });
    const bumped = (est * 5n) / 4n;
    if (activePreset().arbOrbit) {
      const maxTx = await maxTxGasLimit();
      if (maxTx !== null) {
        // leave 1M headroom under the protocol cap
        const cap = maxTx > 1000000n ? maxTx - 1000000n : maxTx;
        return bumped > cap ? cap : bumped;
      }
    }
    return bumped > GAS_CAP ? GAS_CAP : bumped;
  } catch {
    return GAS_STEP;
  }
}

export async function createGame(signer: Signer): Promise<{ game: `0x${string}`; hash: `0x${string}` }> {
  const hash = await signer.wallet.writeContract({
    address: factoryAddress(),
    abi: FactoryAbi,
    functionName: 'create',
    args: [],
    account: signer.account,
    chain,
  });
  const rcpt = await publicClient.waitForTransactionReceipt({ hash });
  const created = decodeLogs(FactoryAbi, rcpt.logs).find((l) => l.eventName === 'GameCreated');
  if (!created?.args?.game) throw new Error('GameCreated not found in receipt.');
  return { game: created.args.game as `0x${string}`, hash };
}

export async function uploadRom(
  signer: Signer,
  game: `0x${string}`,
  rom: Uint8Array,
  onProgress?: (doneChunks: number, totalChunks: number) => void,
): Promise<void> {
  const total = Math.ceil(rom.length / CHUNK);
  for (let i = 0; i < total; i++) {
    const chunk = rom.slice(i * CHUNK, Math.min(rom.length, (i + 1) * CHUNK));
    const hash = await signer.wallet.writeContract({
      address: game,
      abi: GameBoyAbi,
      functionName: 'loadRomStoreChunk',
      args: [bytesToHex(chunk)],
      account: signer.account,
      chain,
    });
    await publicClient.waitForTransactionReceipt({ hash });
    onProgress?.(i + 1, total);
  }
  const fin = await signer.wallet.writeContract({
    address: game,
    abi: GameBoyAbi,
    functionName: 'finalizeSstore2Load',
    args: [],
    account: signer.account,
    chain,
  });
  await publicClient.waitForTransactionReceipt({ hash: fin });
  onProgress?.(total, total);
}

export interface AdvanceResult {
  frame: bigint;
  fb: Uint8Array;
  txs: `0x${string}`[];
}

export interface StepOnceResult {
  hash: `0x${string}`;
  completed: { frame: bigint; fb: Uint8Array } | null;
}

/** Fire a single step() tx (one of the ~5 needed per frame). Ingests its
 *  Scanline/FrameDone/SerialByte logs into the assembler. */
export async function stepOnce(
  signer: Signer,
  game: `0x${string}`,
  buttons: number,
  asm: FrameAssembler,
  budget = stepBudget(),
  onSerial?: (bytes: number[]) => void,
): Promise<StepOnceResult> {
  const hash = await signer.wallet.writeContract({
    address: game,
    abi: GameBoyAbi,
    functionName: 'step',
    args: [budget, buttons],
    account: signer.account,
    chain,
    gas: await resolveStepGas(signer, game, budget, buttons),
  });
  const rcpt = await publicClient.waitForTransactionReceipt({ hash });
  const serial = asm.ingest(decodeGameLogs(rcpt.logs));
  if (serial.length > 0) onSerial?.(serial);
  return { hash, completed: asm.takeCompleted() };
}

/** Advance one full 70224-cycle frame via step() txs (EIP-7825 safe). Persists state.
 *  Fires optimistic bursts: up to BURST step txs are submitted back-to-back
 *  with explicit consecutive nonces (same-sender txs execute in nonce order,
 *  so pipelining is safe), then receipts are reconciled in order. Overshoot
 *  steps simply start the next frame — their scanlines stay buffered in the
 *  assembler for the next call. */
export async function advanceFrame(
  signer: Signer,
  game: `0x${string}`,
  buttons: number,
  asm: FrameAssembler,
  budget = stepBudget(),
  onSerial?: (bytes: number[]) => void,
  onStep?: (n: number) => void,
): Promise<AdvanceResult> {
  const BURST = 8;
  const MAX_BURSTS = 3;
  const txs: `0x${string}`[] = [];
  const data = encodeFunctionData({ abi: GameBoyAbi, functionName: 'step', args: [budget, buttons] });
  const gas = await resolveStepGas(signer, game, budget, buttons);
  let sent = 0;
  for (let b = 0; b < MAX_BURSTS; b++) {
    let nonce = await publicClient.getTransactionCount({ address: signer.address, blockTag: 'pending' });
    const burst: Promise<`0x${string}`>[] = [];
    for (let i = 0; i < BURST; i++) {
      burst.push(
        signer.wallet.sendTransaction({
          account: signer.account,
          to: game,
          data,
          chain,
          gas,
          nonce: nonce++,
        }),
      );
    }
    const hashes = await Promise.all(burst);
    for (const hash of hashes) {
      txs.push(hash);
      sent++;
      const rcpt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
      if (rcpt.status !== 'success') throw new Error(`step tx reverted: ${hash}`);
      const serial = asm.ingest(decodeGameLogs(rcpt.logs));
      if (serial.length > 0) onSerial?.(serial);
      onStep?.(sent);
      const done = asm.takeCompleted();
      if (done) return { frame: done.frame, fb: done.fb, txs };
    }
  }
  throw new Error('Frame never completed after 24 steps.');
}

/** Simulate one frame without persisting (eth_call as your account, so owned
 *  games simulate too). For preview only. Needs a node whose call gas cap
 *  covers ~40M (run anvil with --gas-limit 100000000). */
export async function previewFrame(
  signer: Signer,
  game: `0x${string}`,
  buttons: number,
): Promise<Uint8Array> {
  const data = encodeFunctionData({ abi: GameBoyAbi, functionName: 'runFrame', args: [buttons] });
  const { data: ret } = await publicClient.call({ account: signer.account, to: game, data });
  if (!ret) throw new Error('empty simulation result');
  const fb = decodeFunctionResult({
    abi: GameBoyAbi,
    functionName: 'runFrame',
    data: ret,
  }) as `0x${string}`;
  return hexToBytes(fb);
}

export interface Regs {
  a: number;
  f: number;
  b: number;
  c: number;
  d: number;
  e: number;
  h: number;
  l: number;
  sp: number;
  pc: number;
}

export async function getRegs(game: `0x${string}`): Promise<Regs> {
  const [a, f, b, c, d, e, h, l, sp, pc] = (await publicClient.readContract({
    address: game,
    abi: GameBoyAbi,
    functionName: 'regs',
    args: [],
  })) as unknown as number[];
  return { a, f, b, c, d, e, h, l, sp, pc };
}

export async function getOwner(game: `0x${string}`): Promise<`0x${string}`> {
  return (await publicClient.readContract({
    address: game,
    abi: GameBoyAbi,
    functionName: 'owner',
    args: [],
  })) as `0x${string}`;
}

export async function getRomSize(game: `0x${string}`): Promise<bigint> {
  return (await publicClient.readContract({
    address: game,
    abi: GameBoyAbi,
    functionName: 'romSize',
    args: [],
  })) as bigint;
}

export async function renounce(signer: Signer, game: `0x${string}`): Promise<`0x${string}`> {
  const hash = await signer.wallet.writeContract({
    address: game,
    abi: GameBoyAbi,
    functionName: 'renounceOwnership',
    args: [],
    account: signer.account,
    chain,
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return hash;
}

const HINTS: Record<string, string> = {
  NotOwner: 'not the game owner. Renounced games are open to all.',
  Locked: 'already booted or uploading. Init is locked.',
  BadChunk: 'chunks must be 1 to 16384 bytes.',
  BadStore: 'every chunk but the last must be a full 16KB bank.',
  NoRom: 'not booted yet. Upload and finalize first.',
  BadBudget: 'step budget tops out at 20000 cycles.',
  TooLong: 'read too long.',
  RomTooSmall: 'ROM is smaller than its header, or nothing was uploaded.',
  NoStores: 'no ROM stores uploaded.',
  BadMbc: 'mapper not supported. MBC1, MBC3, MBC5 and plain ROM only.',
  BadBlob: 'SSTORE2 blob empty or over 16KB.',
  DeployFailed: 'SSTORE2 store deploy failed.',
};

export function explainError(e: unknown): string {
  const raw = e instanceof Error ? ((e as any).shortMessage as string | undefined) ?? e.message : String(e);
  const found = Object.keys(HINTS).find((n) => raw.includes(n));
  if (found) return `${found}: ${HINTS[found]}`;
  return raw.split('\n')[0].slice(0, 300);
}
