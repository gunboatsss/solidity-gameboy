import { useState } from 'react';
import ConnectBar from './components/ConnectBar.tsx';
import CreateGame from './components/CreateGame.tsx';
import Player from './components/Player.tsx';
import type { Signer } from './eth.ts';
import { setActiveChain } from './eth.ts';
import { activeChainId } from './config.ts';

export default function App() {
  const [signer, setSigner] = useState<Signer | null>(null);
  const [game, setGame] = useState<`0x${string}` | null>(null);
  const [refreshKey, setRefreshKey] = useState<number>(0);
  const [chainId, setChainId] = useState<number>(() => activeChainId());
  const [sidebarOpen, setSidebarOpen] = useState<boolean>(() => {
    try {
      return localStorage.getItem('sgb.sidebar') !== 'closed';
    } catch {
      return true;
    }
  });

  function toggleSidebar(): void {
    setSidebarOpen((open) => {
      try {
        localStorage.setItem('sgb.sidebar', open ? 'closed' : 'open');
      } catch {
        /* ignore */
      }
      return !open;
    });
  }

  function changeChain(id: number): void {
    if (id === chainId) return;
    setActiveChain(id); // rebuilds clients; persists selection
    setChainId(id);
    setSigner(null); // signers are chain-bound; reconnect on the new network
    setGame(null);
    setRefreshKey((k) => k + 1);
  }

  return (
    <div className="app">
      <header>
        <h1>Gam-EVM-Boy</h1>
      </header>
      <ConnectBar signer={signer} onSigner={setSigner} chainId={chainId} onChainChange={changeChain} />
      <div className="layout">
        {sidebarOpen ? (
          <aside className="sidebar">
            <button className="iconbtn closerow" onClick={toggleSidebar} title="hide games panel">
              « hide
            </button>
            <CreateGame
              signer={signer}
              onSelect={setGame}
              refreshKey={refreshKey}
              onCreated={() => setRefreshKey((k) => k + 1)}
            />
          </aside>
        ) : (
          <button className="iconbtn rail" onClick={toggleSidebar} title="show games panel">
            games »
          </button>
        )}
        <main className="stage">
          <Player
            signer={signer}
            game={game}
            chainId={chainId}
            onGameRemoved={() => {
              setGame(null);
              setRefreshKey((k) => k + 1);
            }}
          />
        </main>
      </div>
    </div>
  );
}
