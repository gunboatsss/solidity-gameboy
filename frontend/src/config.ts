// Frontend config. The active chain is selectable at runtime (persisted in
// localStorage); contract addresses come from per-chain env vars written by
// the deploy scripts, e.g. VITE_FACTORY_10143 / VITE_IMPL_10143. The legacy
// VITE_FACTORY_ADDRESS / VITE_IMPL_ADDRESS names still work for chain 31337.
import { selectChain } from './chains';

const env = import.meta.env as unknown as Record<string, string | undefined>;
const LS_CHAIN = 'sgb.chain';

export const CHAIN_ID: number = Number(env.VITE_CHAIN_ID ?? 31337);

function initialId(): number {
  try {
    const s = localStorage.getItem(LS_CHAIN);
    if (s && Number.isFinite(Number(s))) return Number(s);
  } catch {
    /* no storage: env default */
  }
  return CHAIN_ID;
}

let currentId: number = initialId();

export function activeChainId(): number {
  return currentId;
}

export function setActiveChainId(id: number): void {
  currentId = id;
  try {
    localStorage.setItem(LS_CHAIN, String(id));
  } catch {
    /* private mode: selection lasts the session */
  }
}

export function activePreset() {
  return selectChain(currentId);
}

// RPC: explicit per-chain override wins, then the local .env default for
// Anvil, then the preset default.
export function rpcUrl(): string {
  const perChain = env[`VITE_RPC_${currentId}`];
  if (perChain) return perChain;
  if (currentId === 31337 && env.VITE_RPC_URL) return env.VITE_RPC_URL;
  return selectChain(currentId).rpcUrl;
}

function addrVar(prefix: string, id: number): `0x${string}` {
  const v =
    env[`${prefix}_${id}`] ??
    (id === 31337
      ? env[prefix === 'VITE_FACTORY' ? 'VITE_FACTORY_ADDRESS' : 'VITE_IMPL_ADDRESS']
      : undefined) ??
    '';
  return v as `0x${string}`;
}

export function factoryAddress(id: number = currentId): `0x${string}` {
  return addrVar('VITE_FACTORY', id);
}

export function implAddress(id: number = currentId): `0x${string}` {
  return addrVar('VITE_IMPL', id);
}

export function isConfigured(id: number = currentId): boolean {
  const a = factoryAddress(id);
  return a.length === 42 && a !== '0x0000000000000000000000000000000000000000';
}

// Game-list log scan start (chains with history limits need this bounded;
// set to the factory deployment block).
const GFB = env.VITE_GAMES_FROM_BLOCK;
export const GAMES_FROM_BLOCK: bigint | null = GFB ? BigInt(GFB) : null;

// Default burner key for local dev (overridable). The UI-generated burner in
// localStorage takes precedence; see eth.ts.
export const ANVIL_BURNER_KEY = (env.VITE_BURNER_KEY ??
  '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80') as `0x${string}`;
