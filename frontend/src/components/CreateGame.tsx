import { useCallback, useEffect, useState } from 'react';
import type { Signer } from '../eth';
import { factoryAddress, implAddress, isConfigured } from '../config';
import { createGame, cacheGame, explainError, fetchRomTitle, listGames, uploadRom } from '../gb';
import type { GameInfo } from '../gb';
import { parseRomMeta } from '../rom';
import type { RomMeta } from '../rom';

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
  const [meta, setMeta] = useState<RomMeta | null>(null);
  const [phase, setPhase] = useState<string>('');
  const [progress, setProgress] = useState<[number, number]>([0, 0]);
  const [busy, setBusy] = useState<boolean>(false);
  const [err, setErr] = useState<string>('');

  const refresh = useCallback(() => {
    if (!isConfigured) return;
    listGames()
      .then((list) => {
        setGames(list);
        for (const g of list) {
          if (g.title) continue;
          fetchRomTitle(g.game)
            .then((t) => {
              if (!t) return;
              cacheGame(g.game, g.creator, t);
              setGames((cur) => cur.map((c) => (c.game === g.game ? { ...c, title: t } : c)));
            })
            .catch(() => {});
        }
      })
      .catch((e) => setErr(explainError(e)));
  }, []);

  useEffect(refresh, [refresh, refreshKey]);

  async function deploy(): Promise<void> {
    setErr('');
    if (!signer) {
      setErr('Connect first.');
      return;
    }
    if (!file) {
      setErr('Pick a ROM file first.');
      return;
    }
    const buf = new Uint8Array(await file.arrayBuffer());
    if (buf.length <= 0x147) {
      setErr(`ROM too small. Got ${buf.length} bytes, need more than 0x147.`);
      return;
    }
    setBusy(true);
    try {
      setPhase('Creating game…');
      const { game } = await createGame(signer);
      cacheGame(game, signer.address, meta?.title ?? '');
      setPhase(`Uploading ${buf.length} bytes in 16KB chunks…`);
      await uploadRom(signer, game, buf, (d, t) => setProgress([d, t]));
      setPhase('Finalizing. Done.');
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
        <p className="muted small">
          factory <code className="mono">0x0000000000000000000000000000000000000000</code>
          <br />
          impl <code className="mono">0x0000000000000000000000000000000000000000</code>
        </p>
        <p className="muted">Nothing deployed on this chain yet. Deploy first, then come back.</p>
      </section>
    );
  }

  return (
    <section className="card">
      <h2>games</h2>
      <p className="muted small">
        factory <code className="mono">{factoryAddress()}</code>
        <br />
        impl <code className="mono">{implAddress()}</code>
      </p>
      <div className="row">
        <input
          type="file"
          accept=".gb,.bin,application/octet-stream"
          disabled={busy}
          onChange={(e) => {
            const f = e.target.files?.[0] ?? null;
            setFile(f);
            setMeta(null);
            if (f) {
              f.arrayBuffer()
                .then((b) => setMeta(parseRomMeta(new Uint8Array(b))))
                .catch(() => setMeta(null));
            }
          }}
        />
        <button disabled={busy || !signer} onClick={() => void deploy()}>
          {busy ? 'Working…' : 'Create game'}
        </button>
        <button disabled={busy} onClick={refresh}>
          refresh
        </button>
      </div>
      {file &&
        (meta ? (
          <p className="muted small">
            {meta.title || file.name}, {meta.mapper}, {meta.romSize} ROM, {meta.ramSize} RAM (
            {Math.ceil(file.size / 16384)} chunks)
          </p>
        ) : (
          <p className="muted small">
            {file.name}, {file.size} bytes, {Math.ceil(file.size / 16384)} chunks
          </p>
        ))}
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
            <button
              className="linklike mono"
              title={g.game}
              onClick={() => {
                cacheGame(g.game, g.creator, g.title ?? '');
                onSelect(g.game);
              }}
            >
              {g.title || g.game}
            </button>
          </li>
        ))}
        {games.length === 0 && <li className="muted">Nothing here yet.</li>}
      </ul>
    </section>
  );
}
