import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  formatEther,
  http,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import type { Account, Chain, PublicClient, WalletClient } from 'viem';
import { ANVIL_BURNER_KEY, CHAIN_ID, RPC_URL, ACTIVE } from './config';

export const chain: Chain = defineChain({
  id: CHAIN_ID,
  name: ACTIVE.name,
  nativeCurrency: { name: ACTIVE.currency, symbol: ACTIVE.currency, decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

export const publicClient: PublicClient = createPublicClient({
  chain,
  transport: http(RPC_URL),
});

export interface Signer {
  kind: 'burner' | 'injected';
  address: `0x${string}`;
  account: Account;
  wallet: WalletClient;
}

declare global {
  interface Window {
    ethereum?: any;
  }
}

/** Local-dev signer: Anvil key #0 over HTTP. No browser wallet needed. */
export function connectBurner(): Signer {
  const account = privateKeyToAccount(ANVIL_BURNER_KEY);
  const wallet = createWalletClient({ account, chain, transport: http(RPC_URL) });
  return { kind: 'burner', address: account.address, account, wallet };
}

/** Browser wallet (MetaMask/Rabby) pointed at the same RPC. */
export async function connectInjected(): Promise<Signer> {
  if (!window.ethereum) throw new Error('No injected wallet found (window.ethereum is missing).');
  const wallet = createWalletClient({ chain, transport: custom(window.ethereum) });
  const addresses = await wallet.getAddresses();
  if (addresses.length === 0) throw new Error('Wallet returned no accounts.');
  const account = { address: addresses[0], type: 'json-rpc' } as const;
  return { kind: 'injected', address: addresses[0], account, wallet };
}

export async function getBalance(address: `0x${string}`): Promise<string> {
  const wei = await publicClient.getBalance({ address });
  return formatEther(wei);
}

export async function getChainId(): Promise<number> {
  return publicClient.getChainId();
}
