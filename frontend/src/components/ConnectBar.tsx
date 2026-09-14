import { useEffect, useState } from 'react';
import {
  connectBurner,
  connectInjected,
  connectMnemonic,
  getBalance,
  getChainId,
  newBurner,
} from '../eth';
import type { Signer } from '../eth';
import { activePreset, rpcUrl } from '../config';
import { PRESETS } from '../chains';
import { explainError } from '../gb';

export default function ConnectBar({
  signer,
  onSigner,
  chainId,
  onChainChange,
}: {
  signer: Signer | null;
  onSigner: (s: Signer | null) => void;
  chainId: number;
  onChainChange: (id: number) => void;
}) {
  const [balance, setBalance] = useState<string>('');
  const [nodeChain, setNodeChain] = useState<number | null>(null);
  const [err, setErr] = useState<string>('');
  const [showKey, setShowKey] = useState<boolean>(false);
  const [copied, setCopied] = useState<boolean>(false);
  const preset = activePreset();

  useEffect(() => {
    getChainId()
      .then(setNodeChain)
      .catch(() => setNodeChain(null));
  }, [chainId]);

  useEffect(() => {
    if (!signer) {
      setBalance('');
      return;
    }
    getBalance(signer.address)
      .then(setBalance)
      .catch(() => setBalance('?'));
  }, [signer]);

  async function copyKey(): Promise<void> {
    setCopied(false);
    if (!signer?.secret) {
      setErr('Nothing to export for this signer.');
      return;
    }
    try {
      await navigator.clipboard.writeText(signer.secret);
      setCopied(true);
    } catch {
      setErr('Copy failed. Select the text manually.');
    }
  }

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
        <select value={chainId} onChange={(e) => onChainChange(Number(e.target.value))} title="network">
          {PRESETS.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
            </option>
          ))}
        </select>
        <span className="dot" data-ok={nodeChain === chainId} />
        <code className="mono">{rpcUrl()}</code>
        <span className="muted">chain {nodeChain ?? '…'}</span>
        {nodeChain !== null && nodeChain !== chainId && <span className="warn">wrong network</span>}
      </div>
      <div className="bar-row">
        {signer ? (
          <>
            <code className="mono">{signer.address}</code>
            <span className="muted">
              {signer.kind} · {balance} {preset.currency}
            </span>
            {signer.kind === 'burner' && (
              <button onClick={() => void go(async () => newBurner())} title="new random key, stored here">
                new burner
              </button>
            )}
            {signer.kind === 'burner' && (
              <button onClick={() => setShowKey((s) => !s)}>{showKey ? 'hide key' : 'export key'}</button>
            )}
            <button onClick={() => onSigner(null)}>disconnect</button>
          </>
        ) : (
          <>
            <button onClick={() => void go(connectBurner)}>use burner key</button>
            {chainId === 31337 && (
              <button
                onClick={() => void go(async () => connectMnemonic())}
                title="test test ... junk, account 0"
              >
                use recovery phrase
              </button>
            )}
            <button onClick={() => void go(async () => newBurner())} title="random key, stored in this browser">
              new burner
            </button>
            <button onClick={() => void go(connectInjected)}>connect wallet</button>
          </>
        )}
      </div>
      {signer?.kind === 'burner' && (
        <p className="muted small">Burner key lives in this browser only. Fund it before spending on public chains.</p>
      )}
      {signer?.kind === 'burner' && showKey && signer.secret && (
        <div>
          <code className="mono small">{signer.secret}</code>{' '}
          <button onClick={() => void copyKey()}>{copied ? 'copied' : 'copy'}</button>
          <p className="muted small">Anyone with this spends these funds. Dev only.</p>
        </div>
      )}
      {err !== '' && <div className="error">{err}</div>}
    </div>
  );
}
