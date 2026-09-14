import { useCallback, useEffect, useState } from 'react';
import type { Signer } from '../eth';
import { FACTORY_ADDRESS, IMPL_ADDRESS, isConfigured } from '../config';
import { createGame, explainError, listGames, uploadRom } from '../gb';
import type { GameInfo } from '../gb';

export default function CreateGame({
  signer,
  onSelect,
  refreshKey,
  onCreated,
}: {
  signer: Signer | null;
  onSelect: (game: `0x${string}`) => void;
  refreshKey: number;
  onCreated: () => void;
}) {
  const [games, setGames] = useState<GameInfo[]>([]);
  const [file, setFile] = useState<File | null>(null);
  const [phase, setPhase] = useState<string>('');
  const [progress, setProgress] = useState<[number, number]>([0, 0]);
  const [busy, setBusy] = useState<boolean>(false);
  const [err, setErr] = useState<string>('');

  const refresh = useCallback(() => {
    if (!isConfigured) return;
    listGames()
      .then(setGames)
      .catch((e) => setErr(explainError(e)));
  }, []);

  useEffect(refresh, [refresh, refreshKey]);

  async function deploy(): Promise<void> {
    setErr('');
    if (!signer) {
      setErr('connect a signer first');
      return;
    }
    if (!file) {
      setErr('pick a .gb ROM file first');
      return;
    }
    const buf = new Uint8Array(await file.arrayBuffer());
    if (buf.length <= 0x147) {
      setErr(`ROM too small (${buf.length} bytes, need > 0x147)`);
      return;
    }
    setBusy(true);
    try {
      setPhase('factory.create()…');
      const { game } = await createGame(signer);
      setPhase(`uploading ${buf.length} bytes in 16KB chunks…`);
      await uploadRom(signer, game, buf, (d, t) => setProgress([d, t]));
      setPhase('finalizing… done');
      onSelect(game);
      onCreated();
    } catch (e) {
      setErr(explainError(e));
      setPhase('');
    } finally {
      setBusy(false);
      setProgress([0, 0]);
    }
  }

  if (!isConfigured) {
    return (
      <section className="card">
        <h2>games</h2>
        <p className="muted">
          no factory configured — run <code className="mono">script/Deploy.s.sol</code> to write{' '}
          <code className="mono">frontend/.env</code>, then restart vite.
        </p>
      </section>
    );
  }

  return (
    <section className="card">
      <h2>games</h2>
      <p className="muted small">
        factory <code className="mono">{FACTORY_ADDRESS}</code>
        <br />
        impl <code className="mono">{IMPL_ADDRESS}</code>
      </p>
      <div className="row">
        <input
          type="file"
          accept=".gb,.bin,application/octet-stream"
          disabled={busy}
          onChange={(e) => setFile(e.target.files?.[0] ?? null)}
        />
        <button disabled={busy || !signer} onClick={() => void deploy()}>
          {busy ? 'working…' : 'create + upload'}
        </button>
        <button disabled={busy} onClick={refresh}>
          refresh list
        </button>
      </div>
      {file && (
        <p className="muted small">
          {file.name} · {file.size} bytes · {Math.ceil(file.size / 16384)} chunk(s)
        </p>
      )}
      {phase !== '' && <p className="muted">{phase}</p>}
      {progress[1] > 0 && (
        <progress value={progress[0]} max={progress[1]}>
          {progress[0]}/{progress[1]}
        </progress>
      )}
      {err !== '' && <div className="error">{err}</div>}
      <ul className="gamelist">
        {games.map((g) => (
          <li key={g.game}>
            <button className="linklike mono" onClick={() => onSelect(g.game)}>
              {g.game}
            </button>
          </li>
        ))}
        {games.length === 0 && <li className="muted">no games yet</li>}
      </ul>
    </section>
  );
}
