import { hexToBytes } from 'viem';
import { publicClient } from '../eth';
import GameBoyAbi from '../abi/GameBoy.json';
import type { PpuState } from './ppu';

// PPU-visible state reader. Everything comes through contract views —
// VRAM/OAM via readMem, registers via ppuRegs (readMem blanks IO, so the
// regs need their own getter). No storage-slot coupling: this keeps working
// across recompiles. scripts/check-goldens.mjs --live cross-checks ppuRegs
// against the raw slot layout as a backstop.
async function memBytes(game: `0x${string}`, addr: number, len: number): Promise<Uint8Array> {
  const ret = (await publicClient.readContract({
    address: game,
    abi: GameBoyAbi,
    functionName: 'readMem',
    args: [addr, len],
  })) as `0x${string}`;
  return hexToBytes(ret);
}

/** Read the full PPU-visible state (rendered still is exact for ly=0 states:
 *  fresh boots and post-FrameDone games; see renderFrame docs). */
export async function readPpuState(game: `0x${string}`): Promise<PpuState> {
  const [regs, vram, oam] = await Promise.all([
    publicClient.readContract({
      address: game,
      abi: GameBoyAbi,
      functionName: 'ppuRegs',
      args: [],
    }) as unknown as Promise<number[]>,
    memBytes(game, 0x8000, 0x2000),
    memBytes(game, 0xfe00, 0xa0),
  ]);
  const [lcdc, scy, scx, bgp, obp0, obp1, wy, wx] = regs;
  return { lcdc, bgp, obp0, obp1, scx, scy, wy, wx, vram, oam };
}
