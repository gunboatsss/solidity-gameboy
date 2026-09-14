import { hexToBytes } from 'viem';
import { publicClient } from '../eth';
import GameBoyAbi from '../abi/GameBoy.json';
import type { PpuState } from './ppu';

// PPU-visible state reader. Register slots verified against
// `FOUNDRY_PROFILE=deploy forge inspect GameBoy storage-layout` for the
// current slim build (matches VSLOT/OSLOT/IOSLOT in PpuGoldens.t.sol):
//   vram bytes -> slot 7, oam bytes -> slot 9 (read via readMem instead),
//   IO uint8s pack little-endian in slot 11.
// WARNING: slot numbers are compiler-output-specific. Re-verify after any
// contract change; test_SlotSanity guards the map on-chain and
// `npm run check:goldens` guards this reader end-to-end.
const IO_SLOT = '0xb';
const O_LCDC = 10;
const O_SCY = 12;
const O_SCX = 13;
const O_BGP = 16;
const O_OBP0 = 17;
const O_OBP1 = 18;
const O_WY = 19;
const O_WX = 20;

async function ioByte(game: `0x${string}`, n: number): Promise<number> {
  const w = await publicClient.getStorageAt({ address: game, slot: IO_SLOT });
  if (!w) throw new Error('empty IO storage slot');
  return Number((BigInt(w) >> BigInt(n * 8)) & 0xffn);
}

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
  const [lcdc, scy, scx, bgp, obp0, obp1, wy, wx, vram, oam] = await Promise.all([
    ioByte(game, O_LCDC),
    ioByte(game, O_SCY),
    ioByte(game, O_SCX),
    ioByte(game, O_BGP),
    ioByte(game, O_OBP0),
    ioByte(game, O_OBP1),
    ioByte(game, O_WY),
    ioByte(game, O_WX),
    memBytes(game, 0x8000, 0x2000),
    memBytes(game, 0xfe00, 0xa0),
  ]);
  return { lcdc, bgp, obp0, obp1, scx, scy, wy, wx, vram, oam };
}
