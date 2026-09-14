// Frontend config: all values come from `frontend/.env`, which the
// `script/Deploy.s.sol` forge script writes after deploying impl + factory.
export const RPC_URL: string = import.meta.env.VITE_RPC_URL ?? 'http://127.0.0.1:8545';
export const CHAIN_ID: number = Number(import.meta.env.VITE_CHAIN_ID ?? 31337);
export const FACTORY_ADDRESS: `0x${string}` = (import.meta.env.VITE_FACTORY_ADDRESS ?? '') as `0x${string}`;
export const IMPL_ADDRESS: `0x${string}` = (import.meta.env.VITE_IMPL_ADDRESS ?? '') as `0x${string}`;

// Burner signer for local dev: must be a funded key on the target Anvil.
// Override with VITE_BURNER_KEY if your `anvil` prints different dev keys
// (key #0 below matches the pinned foundry build; verify against startup log).
export const ANVIL_BURNER_KEY = (import.meta.env.VITE_BURNER_KEY ??
  '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80') as `0x${string}`;

export const isConfigured: boolean =
  FACTORY_ADDRESS.length === 42 && FACTORY_ADDRESS !== '0x0000000000000000000000000000000000000000';
