# solidity-gameboy frontend

Vite + React + TS + viem UI for the slim (24KiB) build. Talks to local Anvil
out of the box.

## Quickstart

```sh
# 1. start a local chain (raised cap: runFrame-as-call needs ~40M;
#    fixed price: sustained full blocks would otherwise spiral the base fee
#    until the burner can't pay — this bit us once at 2800 gwei)
anvil --network monad --gas-limit 100000000 --gas-price 1000000000 &

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
  confirm. Rows missing from a completed frame (the game legitimately emits
  nothing while LCD is off) hold over from the previous frame, like a real
  display, instead of flashing blank.
- Opening a game paints instantly: the framebuffer is computed from on-chain
  state (`ppuRegs` + `readMem`, see below), no transactions. A log
  subscription then repaints whenever any frame completes — including frames
  advanced by other players in crowdplay.
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
instead of event logs: VRAM/OAM come from `readMem`, the 8 PPU registers
from the `ppuRegs()` view (readMem blanks IO, hence the getter), rendered
by a JS port of the Yul scanliner (`render/ppu.ts`). No storage-slot
coupling — this survives recompiles. Proven pixel-exact against all 20 PPU
goldens; `npm run check:goldens:live` replays states on Anvil and compares
chain output, cross-checking `ppuRegs()` against the raw slot layout
(slot 11) as a backstop.

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
contract change (the live golden check fails loudly if they drift).

## Notes

- **Step txs carry explicit gas (16M on Anvil).** That covers the
  worst-measured ~10M step with headroom under the 16.7M cap, independent
  of estimator variance. Steps are atomic — full budget or revert — by
  contract design.
- Default Anvil (30M block gas) fits every tx: steps ~10M, chunks ~3.5M.
  `preview (call)` simulates `runFrame` (~40M), so start Anvil with
  `--gas-limit 100000000`. The step loop is the way to actually play.
- Burner keys: "use burner key" signs with the funded local default;
  "new burner" generates a random key, stores it in this browser, and
  uses it. It starts empty, so fund it before spending anywhere public.
- ABIs in `src/abi/` are extracted from forge artifacts; refresh with
  `jq .abi out-slim/GameBoy.sol/GameBoy.json > frontend/src/abi/GameBoy.json`
  (same for the factory) after contract changes.

## Deployment matrix

| Target | Chain ID | Build (code limit) | Deploy with |
| --- | --- | --- | --- |
| Local Anvil | 31337 | slim (24KB) | `Deploy.s.sol` |
| ETH Mainnet | 1 | slim (24KB) | `Deploy.s.sol` + funded key |
| Base | 8453 | slim (24KB) | `Deploy.s.sol` + funded key |
| Monad | 143 | large (128KB) | `DeployLarge.s.sol` + funded key |
| Monad Testnet | 10143 | large (128KB) | `DeployLarge.s.sol`, faucet MON |
| Robinhood Chain | 4663 | large (96KB fits 30.7KB) | `DeployLarge.s.sol` + bridged ETH |
| Robinhood Testnet | 46630 | large (96KB) | `DeployLarge.s.sol`, faucet ETH |

Robinhood notes: per-tx cap is queried live from the ArbGasInfo
precompile (`getMaxTxGasLimit`, verified 32M on testnet) and shown in the
connect bar; step gas is estimate + 25% capped against it. `runFrame`
(~41M) still exceeds it, so stepping stays mandatory at `step(20000)`.

After deploying to a chain, put its addresses in `.env` as
`VITE_FACTORY_<id>` / `VITE_IMPL_<id>` (see `.env.example`) and pick the
network in the UI dropdown. Switching networks disconnects the signer —
reconnect on the new chain. Games are cached per chain in localStorage;
`VITE_GAMES_FROM_BLOCK` bounds the on-chain scan where history is limited.

## Monad

- Local Monad-rule dev needs nightly Foundry: `anvil --network monad
  --gas-limit 100000000`, and the `monad` foundry profile sets
  `network = "monad"` for builds/tests/scripts.
- Chain preset built in: set `VITE_CHAIN_ID=10143` (testnet RPC + MON
  currency default in), deploy the factory there, fund via the faucet.
  `VITE_GAMES_FROM_BLOCK` bounds the game-list log scan (Monad full nodes
  limit history access); created/selected games are also cached in
  localStorage, which stands in when history is unavailable.
- `runFrame` (~41M measured) still exceeds per-tx caps, so stepping stays
  mandatory — but the budget rises to `step(20000)` (~4 txs/frame).
- Monad charges `gas_limit x price`, so steps use estimate + 25% (capped
  29M) instead of Anvil's flat 16M — idle-heavy steps stop paying for
  unused headroom. Reverted txs still pay the full limit, so the buffer
  and the 20000-cycle contract cap both matter; estimation falls back to
  16M if it ever fails.
- Free wins, no code needed: hot Frame state is sequential packed slots,
  so Monad warms one 128-slot storage page per tx instead of ~25 cold
  slots; linear memory pricing favors the 32KB prefetch + 23KB framebuffer;
  same-sender txs still execute in nonce order, so the pipelined bursts
  stay correct. No precompiles used, nothing repriced against us.
- The 128KB code limit fits the *full* (non-slim) build — but the
  factory/crowdplay flow is slim-only (`GameBoy` there has `initialize`;
  the full build's clones would be ownerless and unloadable). Port
  `initialize` over or deploy single full games via `loadRom` chunks.
