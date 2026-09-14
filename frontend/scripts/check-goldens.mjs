// Golden validation for the JS PPU renderer (src/render/ppu.ts).
//   node scripts/check-goldens.mjs        — render all 20 golden states in JS,
//                                          compare keccak to PpuGoldens.t.sol
//                                          _expected hashes (no chain needed).
//   node scripts/check-goldens.mjs --live — plus end-to-end on Anvil (needs
//                                          .env + factory): poke 3 golden
//                                          states via anvil_setStorageAt,
//                                          verify the slot reader, step a
//                                          frame on-chain and compare its
//                                          Scanline output to the JS render.
import { keccak256, bytesToHex } from 'viem';
import { renderFrame } from '../src/render/ppu.ts';

const W = (n, build) => {
  const o = { vram: new Map(), oam: new Map(), io: {} };
  const st = {
    lcdc: 0x91, bgp: 0xfc, obp0: 0xff, obp1: 0xff, scx: 0, scy: 0, wy: 0, wx: 0,
    vram: new Uint8Array(0x2000), oam: new Uint8Array(0xa0),
  };
  const vw = (off, b) => { st.vram[off] = b; o.vram.set(off, b); };
  const ow = (off, b) => { st.oam[off] = b; o.oam.set(off, b); };
  const io = (k, v) => { st[k] = v; o.io[k] = v; };
  const tile = (n_, r) => r.forEach((b, i) => vw(n_ * 16 + i, b));
  const hex = (off, s, w) => Buffer.from(s, 'hex').forEach((b, i) => w(off + i, b));
  build(st, { vw, ow, io, tile, hex });
  return { st, writes: o, name: n };
};
const R = (...v) => v; // _rows order is already [l0,h0,l1,h1,...]
const F = (n, v) => new Array(n).fill(v);

const CASES = [
  W('01 blank', () => {}),
  W('02 solid1', (_, { tile }) => tile(0, R(0xff, 0x00, ...F(14, 0)))),
  W('03 solid3', (_, { tile }) => tile(0, R(...F(16, 0xff)))),
  W('04 stripes', (_, { tile }) => tile(0, R(0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0))),
  W('05 scroll', (_, { tile, io }) => { tile(0, R(...F(16, 0xf0))); io('scx', 3); io('scy', 5); }),
  W('06 scrollwrap', (_, { tile, io }) => { tile(0, R(...F(16, 0xf0))); io('scx', 250); io('scy', 250); }),
  W('07 signed', (_, { tile, io }) => { io('lcdc', 0x81); tile(0x100, R(0xff, 0x00, ...F(14, 0))); }),
  W('08 signedblank', (_, { tile, io }) => { io('lcdc', 0x81); tile(0, R(0xff, 0xff, ...F(14, 0))); }),
  W('09 window', (_, { tile, io, vw, hex }) => { io('lcdc', 0xb1); io('wx', 20); io('wy', 10); tile(1, R(0xff, 0xff, ...F(14, 0))); hex(0x1800, '01', vw); }),
  W('10 windowclip', (_, { tile, io, vw, hex }) => { io('lcdc', 0xb1); io('wx', 0); io('wy', 0); tile(1, R(0xff, 0xff, ...F(14, 0))); hex(0x1800, '01', vw); }),
  W('11 sprite', (_, { tile, io, ow, hex }) => { io('lcdc', 0x93); tile(1, R(0xff, 0xff, ...F(14, 0))); hex(0, '10080100', ow); }),
  W('12 spriteflip', (_, { tile, io, ow, hex }) => { io('lcdc', 0x93); io('obp0', 0xe4); tile(1, R(0xf0, 0x00, 0x0f, 0x00, ...F(12, 0))); hex(0, '10080120', ow); }),
  W('13 spritepal', (_, { tile, io, ow, hex }) => { io('lcdc', 0x93); io('obp1', 0x1b); tile(1, R(0xff, 0x00, ...F(14, 0))); hex(0, '10080110', ow); }),
  W('14 spritebehind', (_, { tile, io, ow, hex }) => { io('lcdc', 0x93); io('bgp', 0xe4); tile(0, R(0xff, 0x00, ...F(14, 0))); tile(1, R(0xff, 0xff, ...F(14, 0))); hex(0, '10080180', ow); }),
  W('15 sprite816', (_, { tile, io, ow, hex }) => { io('lcdc', 0x97); io('obp0', 0xe4); tile(2, R(0xff, 0x00, ...F(14, 0))); tile(3, R(0x00, 0xff, ...F(14, 0))); hex(0, '10080200', ow); }),
  W('16 sprite10limit', (_, { tile, io, ow, hex }) => {
    io('lcdc', 0x93); io('obp0', 0xe4);
    tile(1, R(0xff, 0xff, ...F(14, 0))); tile(2, R(0xff, 0x00, ...F(14, 0)));
    hex(0, '10100100'.repeat(10), ow); hex(40, '10080200', ow);
  }),
  W('17 bgpal', (_, { io }) => io('bgp', 0x1b)),
  W('18 bgoff', (_, { tile, io, ow, hex }) => { io('lcdc', 0x92); tile(1, R(0xff, 0xff, ...F(14, 0))); hex(0, '10080100', ow); }),
  W('19 altmap', (_, { tile, io, vw, hex }) => { io('lcdc', 0x99); tile(5, R(0xff, 0x00, ...F(14, 0))); hex(0x1c00, '05', vw); }),
  W('20 spriteprio', (_, { tile, io, ow, hex }) => {
    io('lcdc', 0x93); io('obp0', 0xe4);
    tile(1, R(0xff, 0x00, ...F(14, 0))); tile(2, R(0x00, 0xff, ...F(14, 0)));
    hex(0, '100801001008020010100200', ow);
  }),
];

const EXPECTED = [
  '0x3ecf50b9f20c018b6f5f19a49668347bc2699d225d5e5675e7e040239048dfa5',
  '0x9fa7ab5fee7418c90488fbe68ac49d08e688fe498637303c5e66698b7b982b35',
  '0x6911dd0dbbc3c6b842333cbe7fb6e7cef0e4543b621fe6a2262e4415dcdb44da',
  '0x6ce064a147ea723a216902dae6bfd520bc3fcef8d8bf5c33512c9f3e23bd6ae0',
  '0x23bf0164778a04449024b576d51b7f599294b2cffea1c4171c49dbd9caeda2bd',
  '0xc2f89523f47015199e25ba9e9ea5a223f18a3c03fc57b74ed9bae503eddbba63',
  '0x9fa7ab5fee7418c90488fbe68ac49d08e688fe498637303c5e66698b7b982b35',
  '0x3ecf50b9f20c018b6f5f19a49668347bc2699d225d5e5675e7e040239048dfa5',
  '0x71173d091f290fdb2784258a44ea25865268145873c9ebe2aae233270d4b569f',
  '0xec9df87b61619e5ae1b8da08dcdbefc9a4693cdfb2fcaf0ff0f56cd200032184',
  '0xfdf0b55bae081ede839ce03530f9d977dd7422a6b7feefb944736a451b20189c',
  '0xe2f4690cd9f1521c41f5faad3d073e31dcb331400462af0f49cfda1bb96917dd',
  '0x3ca48ecd01f7d623f882c7b4256451348c1d1c0e3cacf4bfe2019202f37d0bc6',
  '0x471167d0dd169c01f96ddba0d043d6f1acc56796359344cb8cd72ed2e107957d',
  '0xbe02f4346b1a238291927981b0ffb3fa951d6d6f486e2ff24a0e236e13755953',
  '0x6a765424f5750870a34daec3fbe7b98d068a4dfb410c1fa6147b36461101d4fa',
  '0x6911dd0dbbc3c6b842333cbe7fb6e7cef0e4543b621fe6a2262e4415dcdb44da',
  '0xfdf0b55bae081ede839ce03530f9d977dd7422a6b7feefb944736a451b20189c',
  '0xfdf0b55bae081ede839ce03530f9d977dd7422a6b7feefb944736a451b20189c',
  '0x0de112d0571f0a29d6bdbd706eaa8b9be91a07e0b9056ecbaa2bd66a489b3a1e',
];

const hash = (fb) => keccak256(bytesToHex(fb));
let fails = 0;
for (let id = 0; id < 20; id++) {
  const fb = renderFrame(CASES[id].st);
  const h = hash(fb);
  const ok = h === EXPECTED[id];
  if (!ok) fails++;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${id} ${CASES[id].name} ${h}`);
}
if (fails > 0) {
  console.log(`${fails}/20 FAILED`);
  process.exit(1);
}
console.log('20/20 golden hashes match');

if (process.argv.includes('--live')) {
  await (await import('./live.mjs')).default(CASES, hash, EXPECTED);
}
