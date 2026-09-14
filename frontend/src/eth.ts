import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  formatEther,
  http,
} from 'viem';
import { generatePrivateKey, mnemonicToAccount, privateKeyToAccount } from 'viem/accounts';
import type { Account, Chain, PublicClient, WalletClient } from 'viem';
import {
  ANVIL_BURNER_KEY,
  activeChainId,
  activePreset,
  rpcUrl,
  setActiveChainId,
} from './config';

const LS_BURNER = 'sgb.burner';

function buildChain(): Chain {
  const p = activePreset();
  return defineChain({
    id: p.id,
    name: p.name,
    nativeCurrency: { name: p.currency, symbol: p.currency, decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl()] } },
    ...(p.explorer
      ? { blockExplorers: { default: { name: 'explorer', url: p.explorer } } }
      : {}),
  });
}

// Live bindings: recreated by setActiveChain, so every importer (gb.ts, UI)
// transparently follows network switches.
export let chain: Chain = buildChain();
export let publicClient: PublicClient = createPublicClient({
  chain,
  transport: http(rpcUrl()),
});

export function setActiveChain(id: number): void {
  setActiveChainId(id);
  chain = buildChain();
  publicClient = createPublicClient({ chain, transport: http(rpcUrl()) });
}

export function currentChainId(): number {
  return activeChainId();
}

export interface Signer {
  kind: 'burner' | 'injected';
  address: `0x${string}`;
  account: Account;
  wallet: WalletClient;
  chainId: number;
  secret?: string;
}

declare global {
  interface Window {
    ethereum?: any;
  }
}

function walletFor(account: Account): WalletClient {
  return createWalletClient({ account, chain, transport: http(rpcUrl()) });
}

/** Burner key stored in this browser (generated on demand, never leaves it). */
export function storedBurnerKey(): `0x${string}` | null {
  try {
    const k = localStorage.getItem(LS_BURNER);
    if (k && k.startsWith('0x') && k.length === 66) return k as `0x${string}`;
    return null;
  } catch {
    return null;
  }
}

/** Generate a fresh burner key, store it in localStorage, return it. */
export function generateBurnerKey(): `0x${string}` {
  const k = generatePrivateKey();
  try {
    localStorage.setItem(LS_BURNER, k);
  } catch {
    /* private mode: key lasts the session */
  }
  return k;
}

function burnerFromKey(key: `0x${string}`): Signer {
  const account = privateKeyToAccount(key);
  return {
    kind: 'burner',
    address: account.address,
    account,
    wallet: walletFor(account),
    chainId: activeChainId(),
    secret: key,
  };
}

/** Burner signer: stored browser key, else the funded local default. */
export function connectBurner(): Signer {
  return burnerFromKey(activeBurnerKey());
}

/** Local-dev signer from the default test mnemonic (account 0).
 *  Public knowledge, funds on Anvil only. */
export const ANVIL_MNEMONIC =
  'test test test test test test test test test test test junk';

export function connectMnemonic(): Signer {
  const account = mnemonicToAccount(ANVIL_MNEMONIC);
  return {
    kind: 'burner',
    address: account.address,
    account,
    wallet: walletFor(account),
    chainId: activeChainId(),
    secret: ANVIL_MNEMONIC,
  };
}

/** The key connectBurner would use right now (stored or default). */
export function activeBurnerKey(): `0x${string}` {
  return storedBurnerKey() ?? ANVIL_BURNER_KEY;
}

/** Fresh burner: generates, stores, and connects in one go. Fund it first
 *  on non-local chains — it starts empty. */
export function newBurner(): Signer {
  return burnerFromKey(generateBurnerKey());
}

/** Browser wallet: switches the wallet to the active chain first (adding it
 *  if unknown), then connects. */
export async function connectInjected(): Promise<Signer> {
  if (!window.ethereum) throw new Error('No injected wallet found (window.ethereum is missing).');
  const p = activePreset();
  const chainHex = `0x${p.id.toString(16)}`;
  try {
    await window.ethereum.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: chainHex }],
    });
  } catch (e: any) {
    if (e?.code === 4902) {
      await window.ethereum.request({
        method: 'wallet_addEthereumChain',
        params: [
          {
            chainId: chainHex,
            chainName: p.name,
            nativeCurrency: { name: p.currency, symbol: p.currency, decimals: 18 },
            rpcUrls: [rpcUrl()],
            ...(p.explorer ? { blockExplorerUrls: [p.explorer] } : {}),
          },
        ],
      });
    } else {
      throw e;
    }
  }
  const wallet = createWalletClient({ chain, transport: custom(window.ethereum) });
  const addresses = await wallet.getAddresses();
  if (addresses.length === 0) throw new Error('Wallet returned no accounts.');
  const account = { address: addresses[0], type: 'json-rpc' } as const;
  return { kind: 'injected', address: addresses[0], account, wallet, chainId: p.id };
}

export async function getBalance(address: `0x${string}`): Promise<string> {
  const wei = await publicClient.getBalance({ address });
  return formatEther(wei);
}

export async function getChainId(): Promise<number> {
  return publicClient.getChainId();
}
