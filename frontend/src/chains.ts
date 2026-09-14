// Chain presets. stepBudget/gasStrategy encode per-chain execution economics:
// - Anvil/Ethereum: fixed 16M step gas (deterministic; 16000 cycles keeps every
//   step under the 16.7M EIP-7825 cap with headroom over the ~10M worst case).
// - Monad: charges gas_limit x price (so fat limits waste money), supports
//   30M/tx (so step(20000) fits), and has honest step estimation (atomic
//   steps) -> estimate + 25% buffer, capped below per-tx limits.
export interface ChainPreset {
  id: number;
  name: string;
  rpcUrl: string;
  currency: string;
  explorer: string;
  stepBudget: number;
  gasStrategy: 'fixed' | 'estimate';
}

const ANVIL_RPC = 'http://127.0.0.1:8545';

export const PRESETS: ChainPreset[] = [
  {
    id: 31337,
    name: 'Anvil',
    rpcUrl: ANVIL_RPC,
    currency: 'ETH',
    explorer: '',
    stepBudget: 16000,
    gasStrategy: 'fixed',
  },
  {
    id: 10143,
    name: 'Monad Testnet',
    rpcUrl: 'https://testnet-rpc.monad.xyz',
    currency: 'MON',
    explorer: 'https://testnet.monadvision.com',
    stepBudget: 20000,
    gasStrategy: 'estimate',
  },
];

export function selectChain(id: number): ChainPreset {
  return (
    PRESETS.find((p) => p.id === id) ?? {
      id,
      name: `Chain ${id}`,
      rpcUrl: ANVIL_RPC,
      currency: 'ETH',
      explorer: '',
      stepBudget: 16000,
      gasStrategy: 'fixed' as const,
    }
  );
}
