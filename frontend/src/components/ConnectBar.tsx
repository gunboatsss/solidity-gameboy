import { useEffect, useState } from 'react';
import { connectBurner, connectInjected, getBalance, getChainId } from '../eth';
import type { Signer } from '../eth';
import { CHAIN_ID, RPC_URL } from '../config';
import { explainError } from '../gb';

export default function ConnectBar({
  signer,
  onSigner,
}: {
  signer: Signer | null;
  onSigner: (s: Signer | null) => void;
}) {
  const [balance, setBalance] = useState<string>('');
  const [nodeChain, setNodeChain] = useState<number | null>(null);
  const [err, setErr] = useState<string>('');

  useEffect(() => {
    getChainId()
      .then(setNodeChain)
      .catch(() => setNodeChain(null));
  }, []);

  useEffect(() => {
    if (!signer) {
      setBalance('');
      return;
    }
    getBalance(signer.address)
      .then(setBalance)
      .catch(() => setBalance('?'));
  }, [signer]);

  async function go(fn: () => Signer | Promise<Signer>): Promise<void> {
    setErr('');
    try {
      onSigner(await fn());
    } catch (e) {
      setErr(explainError(e));
    }
  }

  return (
    <div className="bar">
      <div className="bar-row">
        <span className="dot" data-ok={nodeChain === CHAIN_ID} />
        <code className="mono">{RPC_URL}</code>
        <span className="muted">chain {nodeChain ?? '…'} (want {CHAIN_ID})</span>
        {nodeChain !== null && nodeChain !== CHAIN_ID && <span className="warn">wrong chain</span>}
      </div>
      <div className="bar-row">
        {signer ? (
          <>
            <code className="mono">{signer.address}</code>
            <span className="muted">
              {signer.kind} · {balance} ETH
            </span>
            <button onClick={() => onSigner(null)}>disconnect</button>
          </>
        ) : (
          <>
            <button onClick={() => void go(connectBurner)}>use burner (anvil key 0)</button>
            <button onClick={() => void go(connectInjected)}>connect wallet</button>
          </>
        )}
      </div>
      {err !== '' && <div className="error">{err}</div>}
    </div>
  );
}
