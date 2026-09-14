# solidity-gameboy — a Nintendo Game Boy (DMG) emulator on the EVM

A cycle-accurate-ish Sharp LR35902 + PPU emulator written in Solidity.
Execution model: **one transaction advances one frame** (70224 T-cycles) with
fresh joypad input, and returns the 160×144 2bpp framebuffer.

```solidity
GameBoy gb = new GameBoy();
gb.loadRom(rom);              // ROM bytes (MBC1 supported), resets state
bytes memory fb = gb.runFrame(buttons); // 23040 bytes, shades 0 (white)..3 (black)
```

## Contract surface

`GameBoy` is intentionally minimal — uploads, execution, events, and one
state reader. All state vars are internal; there are no per-field getters:

- upload: `loadRom`, `beginLoad`/`loadRomChunk`/`finalizeLoad`,
  `loadRomSSTORE2`/`loadRomStoreChunk`/`finalizeSstore2Load`
- execute: `runFrame(buttons)`, `step(maxCycles, buttons)`
  (`step(0, buttons)` delivers input with no cycles)
- read: `getState()` returns the whole `GbState` snapshot (regs, IO, PPU,
  MBC, all memories, serial, counters) in a single call
- events: `FrameDone(frame)`, `Scanline(frame, ly, px)`, `SerialByte(b)`

`GameBoyHelper` (separate contract, `src/GameBoyHelper.sol`) projects
convenient views out of one `getState()` call: `fullState`, `regs`,
`cpuState`, `serialText`, `frameState`, `ioState`, and `readMem(addr, len)`
across ROM/RAM regions (IO returns 0xFF — use `ioState()` for live IO).
All tests read core state exclusively through the helper.
Note: one snapshot per read means polling a single value (e.g. serial every
frame) copies full state — fine off-chain, but poll sparingly in tests.

## Slim build (24KiB-deployable)

`slim/` is a separate copy of the emulator, stripped for EIP-170
deployability. Build/test it with `FOUNDRY_PROFILE=deploy forge build|test`.

- **23,177 → 24,062 bytes** runtime (514 under the limit, step support included).
- SSTORE2 ROM only, chunked 16KB stores + finalize (no direct ROM boot, no
  storage ROM, no storage chunks).
- `runFrame` (one tx = one frame, ~40M gas) AND `step(maxCycles, buttons)`
  with `Scanline`/`FrameDone` events (worst measured step ~10M gas, so the
  SAME contract is both deployable and runnable under EIP-7825).
- No `getState`/helper, serial via `SerialByte` events only.
- Views: `regs()`, `readMem()` (RAM/IE; ROM via `romStore(i)` + client
  `extcodecopy`, size via `romSize()`), `SerialByte` logs.
- Full CPU/PPU/MBC1/timer/interrupts/joypad retained — nothing gameplay-relevant cut.

Validation (separate suite under `slim/test/`, 24 tests): frame/PPU/
interrupts/serial/stepping/gas-cap/input units, chunked-upload + factory
curator flows, all 20 PPU goldens (identical pixels to the full
build), Blargg `01-special` + `02-interrupts` passing.

## Execution under EIP-7825 (16,777,216 gas/tx)

A full frame costs ~55M gas — no single tx can run it on 7825 chains.
Use exact-budget stepping instead (~4–5 txs/frame):

```solidity
(uint32 exec, bool frameDone,) = gb.step(16000, buttons);
```

- `step` executes whole instructions up to the budget (overshoot < 1 instr),
  with fresh joypad input each call. Measured worst `step(16000)` is ~15M gas
  (rendering + CPU-heavy phases), and a `gasleft()` hard stop guarantees the
  tx can never breach the cap regardless of workload density.
- Scanlines stream as `Scanline(frame, ly, px)` events (160 bytes each) as
  they render; `FrameDone(frame)` fires at every 70224-cycle boundary with
  the remainder carried, so continued stepping stays phase-locked.
- `runFrame` remains for uncapped environments (returns the framebuffer;
  emits only `FrameDone`).

## Loading ROMs: one tx or chunked?

`loadRom` works in a single transaction for typical ROMs. Measured costs
(sparse ROM; dense ROMs cost up to ~22k gas per 32 bytes of nonzero data):

| ROM | one-tx gas | fits L1 30M block? |
|---|---|---|
| 32KB (e.g. Tetris, Blargg individuals) | ~7.6M | yes |
| 64KB (e.g. `cpu_instrs.gb`) | ~23M | technically, but impractical |

For bigger/dense ROMs, or strict block limits, use chunked upload
(append-only 8KB chunks are ~1–3M gas each):

```solidity
gb.beginLoad();
gb.loadRomChunk(0, chunk0);
gb.loadRomChunk(0x2000, chunk1);
// ...
gb.finalizeLoad(); // pad, detect MBC, reset CPU — same as loadRom tail
```

`loadRom` also accepts short ROMs (pads to 32KB with zeros).

## SSTORE2 ROM path (cheaper for dense ROMs + cheaper frames)

Alternative: store the ROM in contract bytecode (`SSTORE2` style) instead of
storage slots. Bank-aligned 16KB code blobs, prefetched into memory once per
frame (one cold `EXTCODECOPY` per blob, then 3-gas `MLOAD`s instead of
`SLOAD`s for every ROM fetch):

```solidity
gb.loadRomSSTORE2(rom);       // one-shot (deploys one store per 16KB bank)
// or chunked: one store per tx, then finalize
gb.loadRomStoreChunk(chunk0); // <= 16KB, previous stores must be full banks
gb.loadRomStoreChunk(chunk1);
gb.finalizeSstore2Load();
```

Measured (Blargg ROMs, sparse):

| | storage | SSTORE2 |
|---|---|---|
| one-shot upload 32KB | ~7.6M | ~10.7M |
| one-shot upload 64KB | ~23.3M | ~17.8M |
| chunked upload | 8KB ≈ 2.8M/chunk (word-blast `loadRomChunk`) | 16KB ≈ 7.8M/chunk |
| frame (01-special) | ~62.6M | ~54.6M (~13% cheaper) |

Rule of thumb: storage SSTOREs cost ~690 gas/nonzero-byte vs ~65 gas/zero-byte;
SSTORE2 costs a flat ~200 gas/byte + 32k/store. Break-even is ~26% nonzero
density — sparse homebrew favors storage, dense/commercial ROMs favor
SSTORE2. The frame savings (~8M/frame) dwarf upload differences over
multi-frame runs, so SSTORE2 wins on total cost for anything beyond a few
frames. Both paths are bit-identical (equivalence-tested: framebuffer hash,
pc/cycles/frames, serial).

Caveats: runtime is now ~29.8KB, over the EIP-170 24KB limit — L1
deployment needs the debug helpers (`dbgRead`/`dbgTrace`/`debugStep`)
stripped or split out; fine as-is on L2/testnets. Also: raw `sstore` of a
`bytes` length slot must use long-form encoding (`len*2+1`); writing the raw
length breaks high-level bounds checks under via-IR.

Input byte, bit=1 means pressed:
bit0 A, bit1 B, bit2 Select, bit3 Start, bit4 Right, bit5 Left, bit6 Up, bit7 Down.

## Layout

| File | Contents |
|---|---|
| `src/GbStorage.sol` | Persistent state (regs, MBC1, VRAM/WRAM/OAM/HRAM, IO, serial capture) + transient `Frame` struct |
| `src/GbMemory.sol` | MMU: memory map, MBC1 banking, DMA, joypad, serial capture, frame load/flush |
| `src/GbTimer.sol` | DIV/TIMA (O(1) edge arithmetic) + interrupt servicing (incl. HALT bug, EI delay) |
| `src/GbPpu.sol` | PPU modes/timing, STAT/LYC interrupts, scanline renderer (BG + window + sprites) |
| `src/GbCpu.sol` | LR35902 core: all 512 opcodes via z80-style x/y/z decode |
| `src/GameBoy.sol` | Top contract: `loadRom`, `runFrame`, `runCycles`, `debugStep`, views, debug helpers |

Hot CPU/IO state is copied from storage into a memory `Frame` once per call
and flushed back at the end, so per-instruction register access costs memory
gas instead of SLOAD/SSTORE. Big memories (ROM/VRAM/WRAM/OAM/HRAM/ERAM)
stay storage-backed.

## Validation

- Hand-assembled ROM unit tests: ALU + flags, CB bit ops, CALL/RET, timer +
  timer interrupt, DIV, serial capture, BG tile + sprite rendering
  (`test/GameBoy.t.sol`, 10 tests).
- **Blargg `cpu_instrs`**: all 11 individual test ROMs pass
  (`test/Blargg.t.sol`). The ROMs are fetched, not committed — see
  `test/roms/README.md`.

## Status & limitations

- Per-frame gas is ~35–65M — far above an L1 block. This currently targets
  local/shared testnets with raised gas limits (foundry `gas_limit` in
  `foundry.toml`); fitting production L2 per-tx budgets needs further
  optimization (prefetch buffer, Yul hot loop, packed framebuffer).
- Runtime bytecode is ~23.6KB, just under the EIP-170 24KB limit — keep an
  eye on `forge build --sizes`.
- MBC1 + ROM-only cartridges. No MBC3/5, no RTC, no CGB/SGB features.
- No APU (sound registers ignored). No link cable (serial transfers complete
  instantly and are captured for test output — this is what Blargg uses).
- OAM DMA is instant (should take 640 T-cycles).
- Minor timing approximations: TAC-enable glitch, STAT interrupts enabled
  mid-mode, LYC-match on LYC write, mid-frame WY changes.

## Access control (Twitch-Plays-Pokemon model)

- Deployer is `owner`. ROM uploads (`loadRom*`, chunk/finalize paths) are
  owner-only **and once-only** (`Locked` after first boot — no bait-and-switch).
- `runFrame`/`step` are owner-only while owned; `renounceOwnership()` zeroes
  the owner and opens play to everyone (crowdplay), while uploads stay locked
  forever. All auth uses custom errors (`NotOwner`, `Locked`).

## Onchain factory (slim build)

`slim/GameBoyFactory.sol` (**570 bytes**) spins up trustless crowdplay games
using EIP-1167 minimal-proxy clones (verbatim OpenZeppelin assembly) of one
implementation contract — so per-game deployment costs ~100k gas instead of
~5M, and the factory itself fits anywhere:

- `create()`: deploys an empty clone owned by the caller, who then uploads
  the ROM in 16KB chunks + finalizes + plays/renounces directly on the game
  (no further factory interaction). Chunked upload is the only ROM ingress.
  This is the curator path — direct `GameBoy` deploys are born bricked
  (constructor sets owner to an unowned sink) and serve as implementations
  only.
- Deploy: `impl = new GameBoy(); factory = new GameBoyFactory(impl);` — the
  implementation is dead on arrival (its initialize/upload/play paths revert
  for everyone, deployer included); clones are unaffected (own storage via
  delegatecall). One tx per deploy, no follow-up bricking step to forget.
- Clones boot via chunked upload + finalize, then play. `initialize(owner)`
  only claims ownership on pristine state — it takes no ROM. Init reverts on
  booted or partially-uploaded state, so live games can't be hijacked,
  in-progress uploads can't be wiped, and strangers can't front-run a
  curator's pristine game.

## Frontend (`frontend/`)

Vite + React + TS + viem UI, Anvil-first. `script/Deploy.s.sol` deploys impl
+ factory and writes `frontend/.env`; the UI creates games (chunked upload
with progress), plays them via a `step()` loop that reassembles the
framebuffer live from `Scanline` events, streams `SerialByte` output, and
renounces to crowdplay. See `frontend/README.md`. One gotcha baked in:
`step()` txs carry explicit 16M gas — the contract's 1M early-stop guard
makes estimators converge to ~91k (a few cycles), so estimation is never
used for steps.

## Cartridge mappers (MBC)

- **MBC1**: full support — switchable 16KB banks (up to 125 = 2MB), 32KB
  SRAM over 4 banks, ROM/RAM banking modes, bank-0 skip. Covers Tetris,
  Mario Land, Kirby, Zelda: Link's Awakening, Metroid II.
- **MBC3** (Pokémon R/B/Y): 7-bit ROM banking where bank 0 *is* legal in the
  switchable area, RAM banks 0–3. RTC registers stubbed (return 0xFF) — no
  DMG game uses the clock.
- **MBC5** (Zelda DX, Wario 2, up to 8MB): 9-bit ROM banking (split
  0x2000/0x3000 registers), 4-bit RAM banking up to 128KB.
- External RAM is sized from the header (0x149): none/8KB/32KB/64KB/128KB —
  no-RAM games (e.g. Tetris) skip the ~2M zero-init. Unknown mappers
  (MBC2/MMM01/HuC/…) revert loudly with `unsupported MBC` instead of
  mis-emulating.

## ROMs for tests

Blargg's test ROMs: https://github.com/retrio/gb-test-roms (`cpu_instrs/individual/*.gb`).
Tetris etc. are commercial — bring your own dump.
