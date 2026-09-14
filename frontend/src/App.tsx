import { useState } from 'react';
import ConnectBar from './components/ConnectBar.tsx';
import CreateGame from './components/CreateGame.tsx';
import Player from './components/Player.tsx';
import type { Signer } from './eth.ts';

export default function App() {
  const [signer, setSigner] = useState<Signer | null>(null);
  const [game, setGame] = useState<`0x${string}` | null>(null);
  const [refreshKey, setRefreshKey] = useState<number>(0);

  return (
    <div className="app">
      <header>
        <h1>solidity-gameboy</h1>
        <p className="muted">
          Game Boy (DMG) emulator on the EVM — slim build, factory clones, step-loop frames
        </p>
      </header>
      <ConnectBar signer={signer} onSigner={setSigner} />
      <main className="grid">
        <CreateGame
          signer={signer}
          onSelect={setGame}
          refreshKey={refreshKey}
          onCreated={() => setRefreshKey((k) => k + 1)}
        />
        <Player signer={signer} game={game} />
      </main>
    </div>
  );
}
