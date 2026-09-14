# solidity-gameboy frontend

Vite + React + TS + viem UI for the slim (24KiB) build. Talks to local Anvil
out of the box.

## Quickstart

```sh
# 1. start a local chain (raised cap: runFrame-as-call needs ~40M)
anvil --gas-limit 100000000 &

# 2. deploy impl + factory (writes frontend/.env with addresses;
#    Anvil dev accounts are unlocked, so no private key is needed)
FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast --unlocked \
  --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# 3. run the UI
cd frontend && npm install && npm run dev
```

Open the printed localhost URL, click **use burner (anvil key 0)**, pick a
`.gb` ROM, **create + upload**, then **advance frame** (or auto-play).

## How it maps to the contracts

- `factory.create()` → bare clone owned by you; ROM uploads as 16KB
  `loadRomStoreChunk` txs with a progress bar, then `finalizeSstore2Load`.
- Frames advance via `step(16000, buttons)` txs (~5/frame, each under the
  16.7M EIP-7825 cap). The UI reassembles the 160×144 framebuffer live from
  `Scanline` receipt logs and stops at `FrameDone` — scanlines paint as txs
  confirm.
- `preview (call)` runs `runFrame` as an `eth_call`: shows a frame without
  persisting state (receipts carry no return data, so `runFrame`-as-tx can't
  display).
- Serial output streams from `SerialByte` events (Blargg ROMs print here).
- `renounce (crowdplay)` opens play to everyone; uploads stay locked.

Buttons: bit0 A, bit1 B, bit2 Select, bit3 Start, bit4 Right, bit5 Left,
bit6 Up, bit7 Down. Keyboard: arrows = d-pad, X = A, Z = B, shift = select,
enter = start.

## Local state rendering (`src/render/` + `npm run check:goldens`)

`render state (local)` reconstructs the framebuffer from on-chain state
instead of event logs: PPU registers come from storage slot 11
(`eth_getStorageAt`), VRAM/OAM via `readMem`, rendered by a JS port of the
Yul scanliner (`render/ppu.ts`). Proven pixel-exact against all 20 PPU
goldens; `npm run check:goldens:live` replays states on Anvil and compares
chain output, including the slot-reader assumptions.

Two things this surfaced, worth knowing:

- **Frame render order is 1..143,0.** A frame entered in PPU mode 0 (boot
  and every steady-state frame) spends its first 204 cycles finishing line
  0's HBlank, so line 0 renders *last*, after the VBlank wrap resets the
  window counter. The JS renderer replicates this; a naive 0..143 loop
  fails the WX=0 window golden.
- **Stepping breaks window continuity (contract quirk).** The window-line
  counter lives in call memory, so every `step()` tx restarts it at 0 —
  multi-tx frames repeat window rows per tx boundary, while single-call
  `runFrame` is correct. Window-off games are unaffected either way. The
  local renderer always shows the `runFrame`-equivalent still.

Slot numbers are compiler-output-specific: re-verify with
`FOUNDRY_PROFILE=deploy forge inspect GameBoy storage-layout` after any
contract change (the golden check fails loudly if they drift).

## Notes

- **Step txs carry explicit gas (16M), never estimation.** `step()` stops at
  1M gas-left instead of reverting, so estimators converge to ~91k (a few
  cycles) and the game would advance at ~0.025% speed. The UI always sends
  `gas: 16_000_000`.
- Default Anvil (30M block gas) fits every tx: steps ~10M, chunks ~3.5M.
  `preview (call)` simulates `runFrame` (~40M), so start Anvil with
  `--gas-limit 100000000`. The step loop is the way to actually play.
- Burner mode uses Anvil key #0 — override with `VITE_BURNER_KEY` if your
  Anvil build prints different dev keys (check its startup log).
- Game list reads `GameCreated` logs from genesis (fine on Anvil).
- ABIs in `src/abi/` are extracted from forge artifacts; refresh with
  `jq .abi out-slim/GameBoy.sol/GameBoy.json > frontend/src/abi/GameBoy.json`
  (same for the factory) after contract changes.
