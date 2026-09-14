// JS port of the slim build's Yul scanline renderer (slim/GbPpu.sol,
// _renderLine). Used to reconstruct the 160x144 framebuffer from on-chain
// state without relying on Scanline event logs.
//
// Semantics mirror the contract exactly:
// - bg/window tile fetch (unsigned 0x8000 / signed 0x9000 via LCDC bit 4),
//   map select (LCDC bits 3/6), palettes, SCX/SCY, window WX/WY with the
//   hardware WX<7 whole-line rule and the winLine counter starting at 0.
// - sprites: first-10 OAM order, 8x8/8x16, x/y flip, OBP0/1 select,
//   transparent idx0, behind-bg iff (attr bit7 && bg idx != 0) — logical AND.
// - LCD off renders blank (shade 0); the contract emits no lines either.
// Validated pixel-exact against all 20 PPU goldens (scripts/check-goldens.mjs).

export interface PpuState {
  lcdc: number;
  bgp: number;
  obp0: number;
  obp1: number;
  scx: number;
  scy: number;
  wy: number;
  wx: number;
  vram: Uint8Array; // 0x2000 bytes at 0x8000
  oam: Uint8Array; // 0xA0 bytes at 0xFE00
}

export const FB_W = 160;
export const FB_H = 144;

function vb(s: PpuState, i: number): number {
  return s.vram[i] ?? 0;
}

export function renderFrame(s: PpuState): Uint8Array {
  const fb = new Uint8Array(FB_W * FB_H);
  if ((s.lcdc & 0x80) === 0) return fb;
  const bgOn = (s.lcdc & 1) !== 0;
  const bgBase = (s.lcdc & 8) !== 0 ? 0x9c00 : 0x9800;
  const signed = (s.lcdc & 0x10) === 0;
  const winBase = (s.lcdc & 0x40) !== 0 ? 0x9c00 : 0x9800;
  const sprH = (s.lcdc & 4) !== 0 ? 16 : 8;
  const spritesOn = (s.lcdc & 2) !== 0;
  // Render order mirrors the contract's PPU timing: a frame entered in mode 0
  // (boot and every steady-state frame) spends its first 204 cycles finishing
  // line 0's HBlank, so line 0 is skipped, lines 1..143 render, then VBlank
  // wraps (resetting winLine) and line 0 renders last. winLine therefore
  // counts rendered window-active lines in the order 1..143,0.
  const order: number[] = [];
  for (let k = 1; k < FB_H; k++) order.push(k);
  order.push(0);
  let winLine = 0;
  for (const ly of order) {
    if (ly === 0) winLine = 0; // VBlank wrap reset precedes line 0
    const winActive = (s.lcdc & 0x20) !== 0 && bgOn && ly >= s.wy && s.wx < 167;
    const spr: Array<{ ox: number; tile: number; attr: number; srow: number }> = [];
    if (spritesOn) {
      const lyy = ly + 16;
      for (let i = 0; i < 40 && spr.length < 10; i++) {
        const oy = s.oam[i * 4] ?? 0;
        if (lyy >= oy && lyy < oy + sprH) {
          spr.push({
            ox: s.oam[i * 4 + 1] ?? 0,
            tile: s.oam[i * 4 + 2] ?? 0,
            attr: s.oam[i * 4 + 3] ?? 0,
            srow: lyy - oy,
          });
        }
      }
    }
    const rowBg = (ly + s.scy) & 0xff;
    for (let x = 0; x < FB_W; x++) {
      let bgIdx = 0;
      let shade = s.bgp & 3;
      if (bgOn) {
        let px: number;
        let row: number;
        let map: number;
        if (winActive && (s.wx < 7 || x >= s.wx - 7)) {
          px = (x - s.wx + 7) & 0xff;
          row = winLine;
          map = winBase;
        } else {
          px = (s.scx + x) & 0xff;
          row = rowBg;
          map = bgBase;
        }
        const tileIdx = vb(s, map - 0x8000 + (row >> 3) * 32 + (px >> 3));
        let troff: number;
        if (signed) {
          const t = tileIdx > 127 ? tileIdx - 256 : tileIdx;
          troff = 0x1000 + t * 16 + (row & 7) * 2;
        } else {
          troff = tileIdx * 16 + (row & 7) * 2;
        }
        const lo = vb(s, troff);
        const hi = vb(s, troff + 1);
        const bit = 7 - (px & 7);
        bgIdx = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);
        shade = (s.bgp >> (bgIdx * 2)) & 3;
      }
      if (spr.length > 0) {
        let wi = -1;
        let best = 300;
        for (let j = 0; j < spr.length; j++) {
          const ox = spr[j].ox;
          const wxx = x + 8;
          if (wxx >= ox && wxx < ox + 8 && ox < best) {
            best = ox;
            wi = j;
          }
        }
        if (wi >= 0) {
          const sp = spr[wi];
          let srow = (sp.attr & 0x40) !== 0 ? sprH - 1 - sp.srow : sp.srow;
          let tile = sp.tile;
          if (sprH === 16) {
            if (srow < 8) tile &= 0xfe;
            else {
              tile |= 1;
              srow -= 8;
            }
          }
          const toff = tile * 16 + srow * 2;
          const plo = vb(s, toff);
          const phi = vb(s, toff + 1);
          const pdx = x + 8 - sp.ox;
          const pbit = (sp.attr & 0x20) !== 0 ? pdx : 7 - pdx;
          const spIdx = (((phi >> pbit) & 1) << 1) | ((plo >> pbit) & 1);
          if (spIdx !== 0 && !((sp.attr & 0x80) !== 0 && bgIdx !== 0)) {
            const pal = (sp.attr & 0x10) !== 0 ? s.obp1 : s.obp0;
            shade = (pal >> (spIdx * 2)) & 3;
          }
        }
      }
      fb[ly * FB_W + x] = shade;
    }
    if (winActive) winLine++;
  }
  return fb;
}
