// Frontend config: values come from `frontend/.env` (written by
// `script/Deploy.s.sol`), falling back to the active chain preset.
import { selectChain } from './chains';

export const CHAIN_ID: number = Number(import.meta.env.VITE_CHAIN_ID ?? 31337);
export const ACTIVE = selectChain(CHAIN_ID);
export const RPC_URL: string = import.meta.env.VITE_RPC_URL ?? ACTIVE.rpcUrl;
export const FACTORY_ADDRESS: `0x${string}` = (import.meta.env.VITE_FACTORY_ADDRESS ?? '') as `0x${string}`;
export const IMPL_ADDRESS: `0x${string}` = (import.meta.env.VITE_IMPL_ADDRESS ?? '') as `0x${string}`;

// Game-list log scan start (Monad full nodes limit history access; set this
// to the factory deployment block to bound the range).
const GFB = import.meta.env.VITE_GAMES_FROM_BLOCK as string | undefined;
export const GAMES_FROM_BLOCK: bigint | null = GFB ? BigInt(GFB) : null;

// Burner signer for local dev: must be a funded key on the target Anvil.
// Override with VITE_BURNER_KEY if your `anvil` prints different dev keys
// (key #0 below matches the pinned foundry build; verify against startup log).
export const ANVIL_BURNER_KEY = (import.meta.env.VITE_BURNER_KEY ??
  '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80') as `0x${string}`;

export const isConfigured: boolean =
  FACTORY_ADDRESS.length === 42 && FACTORY_ADDRESS !== '0x0000000000000000000000000000000000000000';
