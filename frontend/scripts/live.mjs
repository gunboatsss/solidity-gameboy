// Live end-to-end for check-goldens.mjs --live (needs Anvil + frontend/.env).
// For golden states [1, 8, 10]: deploy a game, poke the state on-chain via
// anvil_setStorageAt, verify the slot reader assumptions (slot numbers +
// packing), step a real frame and compare its Scanline output to the JS
// render and to the captured golden hash.
import { readFileSync } from 'node:fs';
import {
  createPublicClient, createWalletClient, http, bytesToHex, hexToBytes,
  keccak256, encodeAbiParameters, toHex, decodeEventLog,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import GameBoyAbi from '../src/abi/GameBoy.json' with { type: 'json' };
import FactoryAbi from '../src/abi/GameBoyFactory.json' with { type: 'json' };
import { renderFrame } from '../src/render/ppu.ts';

// Anvil key #0 for the pinned foundry build (must match the node's dev keys).
const BURNER = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const IO_OFF = { lcdc: 10, scy: 12, scx: 13, bgp: 16, obp0: 17, obp1: 18, wy: 19, wx: 20 };

export default async function runLive(CASES, hash, expected) {
  const env = Object.fromEntries(
    readFileSync(new URL('../.env', import.meta.url), 'utf8')
      .split('\n').filter(Boolean).map((l) => l.split('=')),
  );
  const account = privateKeyToAccount(BURNER);
  const chain = {
    id: 31337, name: 'Anvil',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [env.VITE_RPC_URL] } },
  };
  const pub = createPublicClient({ chain, transport: http(env.VITE_RPC_URL) });
  const wal = createWalletClient({ account, chain, transport: http(env.VITE_RPC_URL) });
  const base = (s) => BigInt(keccak256(encodeAbiParameters([{ type: 'uint256' }], [BigInt(s)])));

  // NOTE on method: window-active frames MUST be read via a single eth_call
  // runFrame. Stepping a frame across multiple txs restarts the contract's
  // winLine counter on every call (it lives in call memory, not storage),
  // so step-assembled window content repeats rows per tx boundary and can
  // never match single-call output. Window-off states match either way.
  const JOBS = [
    { id: 1, via: 'steps' },
    { id: 8, via: 'call' },
    { id: 10, via: 'steps' },
  ];
  for (const { id, via } of JOBS) {
    const { st, writes, name } = CASES[id];
    const h0 = await wal.writeContract({ address: env.VITE_FACTORY_ADDRESS, abi: FactoryAbi, functionName: 'create', args: [], account, chain });
    const r0 = await pub.waitForTransactionReceipt({ hash: h0 });
    const game = r0.logs.map((l) => {
      try { return decodeEventLog({ abi: FactoryAbi, data: l.data, topics: l.topics }); } catch { return null; }
    }).find((l) => l?.eventName === 'GameCreated').args.game;
    const rom = new Uint8Array(0x8000);
    rom[0x100] = 0x00;
    for (let off = 0; off < rom.length; off += 0x4000) {
      const h = await wal.writeContract({ address: game, abi: GameBoyAbi, functionName: 'loadRomStoreChunk', args: [bytesToHex(rom.slice(off, off + 0x4000))], account, chain });
      await pub.waitForTransactionReceipt({ hash: h });
    }
    const hf = await wal.writeContract({ address: game, abi: GameBoyAbi, functionName: 'finalizeSstore2Load', args: [], account, chain });
    await pub.waitForTransactionReceipt({ hash: hf });

    // poke: bytes arrays (slots 7/9, big-endian words) + IO slot 11 (little-endian)
    for (const [slot, map] of [[7, writes.vram], [9, writes.oam]]) {
      const byWord = new Map();
      for (const [off] of map) {
        const k = base(slot) + BigInt(Math.floor(off / 32));
        if (!byWord.has(k)) {
          byWord.set(k, BigInt(await pub.getStorageAt({ address: game, slot: toHex(k, { size: 32 }) }) ?? '0x0'));
        }
      }
      for (const [off, b] of map) {
        const k = base(slot) + BigInt(Math.floor(off / 32));
        const shift = BigInt((31 - (off % 32)) * 8);
        byWord.set(k, (byWord.get(k) & ~(0xffn << shift)) | (BigInt(b) << shift));
      }
      for (const [k, v] of byWord) {
        await pub.request({ method: 'anvil_setStorageAt', params: [game, toHex(k, { size: 32 }), toHex(v, { size: 32 })] });
      }
    }
    let io = BigInt(await pub.getStorageAt({ address: game, slot: '0xb' }) ?? '0x0');
    for (const [k, v] of Object.entries(writes.io)) {
      const shift = BigInt(IO_OFF[k] * 8);
      io = (io & ~(0xffn << shift)) | (BigInt(v) << shift);
    }
    await pub.request({ method: 'anvil_setStorageAt', params: [game, toHex(11n, { size: 32 }), toHex(io, { size: 32 })] });

    // verify the reader assumptions: raw slot math + readMem round-trip,
    // cross-checked against the ppuRegs() view the app actually uses
    const ioBack = BigInt(await pub.getStorageAt({ address: game, slot: '0xb' }) ?? '0x0');
    const regs = await pub.readContract({ address: game, abi: GameBoyAbi, functionName: 'ppuRegs', args: [] });
    const viaView = { lcdc: regs[0], scy: regs[1], scx: regs[2], bgp: regs[3], obp0: regs[4], obp1: regs[5], wy: regs[6], wx: regs[7] };
    for (const [k, v] of Object.entries({ lcdc: st.lcdc, scy: st.scy, scx: st.scx, bgp: st.bgp, obp0: st.obp0, obp1: st.obp1, wy: st.wy, wx: st.wx })) {
      const got = Number((ioBack >> BigInt(IO_OFF[k] * 8)) & 0xffn);
      if (got !== v) throw new Error(`id ${id}: io ${k} slot-read ${got}, want ${v}`);
      if (viaView[k] !== v) throw new Error(`id ${id}: ppuRegs ${k} returned ${viaView[k]}, want ${v}`);
    }
    const vramBack = hexToBytes(await pub.readContract({ address: game, abi: GameBoyAbi, functionName: 'readMem', args: [0x8000, 0x2000] }));
    const oamBack = hexToBytes(await pub.readContract({ address: game, abi: GameBoyAbi, functionName: 'readMem', args: [0xfe00, 0xa0] }));
    for (let i = 0; i < 0x2000; i++) if (vramBack[i] !== st.vram[i]) throw new Error(`id ${id}: vram[${i}] mismatch`);
    for (let i = 0; i < 0xa0; i++) if (oamBack[i] !== st.oam[i]) throw new Error(`id ${id}: oam[${i}] mismatch`);

    // render on-chain: single call (runFrame semantics) or step-assembled
    let hChain;
    if (via === 'call') {
      const { encodeFunctionData } = await import('viem');
      const data = encodeFunctionData({ abi: GameBoyAbi, functionName: 'runFrame', args: [0] });
      const { data: ret } = await pub.call({ account, to: game, data });
      // strip the ABI envelope (offset + length words) to reach the 23040 px
      const fb = hexToBytes(`0x${ret.slice(2 + 128)}`);
      if (fb.length !== 23040) throw new Error(`id ${id}: bad call payload len ${fb.length}`);
      hChain = keccak256(bytesToHex(fb));
    } else {
      const lines = new Map();
      let doneCt = 0;
      for (let n = 0; n < 12 && doneCt === 0; n++) {
        const hs = await wal.writeContract({ address: game, abi: GameBoyAbi, functionName: 'step', args: [16000, 0], account, chain, gas: 16000000n });
        const rr = await pub.waitForTransactionReceipt({ hash: hs });
        for (const l of rr.logs) {
          try {
            const d = decodeEventLog({ abi: GameBoyAbi, data: l.data, topics: l.topics });
            if (d.eventName === 'Scanline') lines.set(d.args.frame.toString() + ':' + d.args.ly, hexToBytes(d.args.px));
            if (d.eventName === 'FrameDone') doneCt++;
          } catch {}
        }
      }
      const fb = new Uint8Array(23040);
      for (const [k, px] of lines) {
        const [f, ly] = k.split(':').map(Number);
        if (f === 0) fb.set(px.slice(0, 160), ly * 160);
      }
      hChain = keccak256(bytesToHex(fb));
    }
    const hJs = hash(renderFrame(st));
    const ok = hChain === hJs && hJs === expected[id];
    console.log(`${ok ? 'PASS' : 'FAIL'} live ${id} ${name} chain=${hChain} js=${hJs}`);
    if (!ok) throw new Error(`live mismatch on golden ${id}`);
  }
  console.log('live E2E ok (slots + reader + scanlines agree on 3 states)');
}
