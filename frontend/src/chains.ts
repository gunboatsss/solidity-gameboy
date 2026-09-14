// Chain presets: execution economics per network.
// - stepBudget: cycles per step tx (fits the chain's per-tx cap with margin).
// - gasStrategy: 'fixed' sends a deterministic limit; 'estimate' uses
//   estimate + 25% (for chains like Monad that charge gas_limit x price).
export interface ChainPreset {
  id: number;
  name: string;
  rpcUrl: string;
  currency: string;
  explorer: string;
  stepBudget: number;
  gasStrategy: 'fixed' | 'estimate';
  /** Arbitrum Orbit family: per-tx cap is queryable via ArbGasInfo (0x6c). */
  arbOrbit?: boolean;
  /** Pinned color theme for this chain. gameboy/gray stay available everywhere. */
  theme: string;
}

export const PRESETS: ChainPreset[] = [
  {
    id: 31337,
    name: 'Local Anvil',
    rpcUrl: 'http://127.0.0.1:8545',
    currency: 'ETH',
    explorer: '',
    stepBudget: 16000,
    gasStrategy: 'fixed',
    theme: 'gameboy',
  },
  {
    id: 1,
    name: 'Ethereum',
    rpcUrl: 'https://eth.llama-rpc.com',
    currency: 'ETH',
    explorer: 'https://etherscan.io',
    stepBudget: 16000,
    gasStrategy: 'fixed',
    theme: 'ethereum',
  },
  {
    id: 8453,
    name: 'Base',
    rpcUrl: 'https://mainnet.base.org',
    currency: 'ETH',
    explorer: 'https://basescan.org',
    stepBudget: 16000,
    gasStrategy: 'fixed',
    theme: 'base',
  },
  {
    id: 143,
    name: 'Monad',
    rpcUrl: 'https://rpc.monad.xyz',
    currency: 'MON',
    explorer: 'https://monadvision.com',
    stepBudget: 20000,
    gasStrategy: 'estimate',
    theme: 'monad',
  },
  {
    id: 10143,
    name: 'Monad Testnet',
    rpcUrl: 'https://testnet-rpc.monad.xyz',
    currency: 'MON',
    explorer: 'https://testnet.monadvision.com',
    stepBudget: 20000,
    gasStrategy: 'estimate',
    theme: 'monad',
  },
  {
    id: 4663,
    name: 'Robinhood Chain',
    rpcUrl: 'https://rpc.mainnet.chain.robinhood.com',
    currency: 'ETH',
    explorer: 'https://robinhoodchain.blockscout.com',
    stepBudget: 20000,
    gasStrategy: 'estimate',
    arbOrbit: true,
    theme: 'robinhood',
  },
  {
    id: 46630,
    name: 'Robinhood Testnet',
    rpcUrl: 'https://rpc.testnet.chain.robinhood.com',
    currency: 'ETH',
    explorer: 'https://explorer.testnet.chain.robinhood.com',
    stepBudget: 20000,
    gasStrategy: 'estimate',
    arbOrbit: true,
    theme: 'robinhood',
  },
];

export function selectChain(id: number): ChainPreset {
  return (
    PRESETS.find((p) => p.id === id) ?? {
      id,
      name: `Chain ${id}`,
      rpcUrl: 'http://127.0.0.1:8545',
      currency: 'ETH',
      explorer: '',
      stepBudget: 16000,
      gasStrategy: 'fixed' as const,
      theme: 'gameboy',
    }
  );
}
