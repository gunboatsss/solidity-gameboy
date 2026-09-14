import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { ReactElement } from 'react';
import type { Log } from 'viem';
import type { Signer } from '../eth';
import { publicClient } from '../eth';
import { activePreset } from '../config';
import GameBoyAbi from '../abi/GameBoy.json';
import {
  BTN,
  FB_H,
  FB_W,
  FrameAssembler,
  advanceFrame,
  decodeGameLogs,
  explainError,
  fetchRomTitle,
  getOwner,
  getRegs,
  getRomSize,
  previewFrame,
  removeGameCache,
  renounce,
  stepBudget,
  stepOnce,
} from '../gb';
import type { Regs } from '../gb';
import { PALETTES, applyPageTheme, drawFrame, serialToText } from '../palette';
import { readPpuState } from '../render/storage.ts';
import { renderFrame } from '../render/ppu.ts';

const KEYMAP: Record<string, number> = {
  ArrowRight: BTN.RIGHT,
  ArrowLeft: BTN.LEFT,
  ArrowUp: BTN.UP,
  ArrowDown: BTN.DOWN,
  KeyX: BTN.A,
  KeyZ: BTN.B,
  ShiftLeft: BTN.SELECT,
  ShiftRight: BTN.SELECT,
  Enter: BTN.START,
};

export default function Player({
  signer,
  game,
  chainId,
  onGameRemoved,
}: {
  signer: Signer | null;
  game: `0x${string}` | null;
  chainId: number;
  onGameRemoved: () => void;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const serialBoxRef = useRef<HTMLDivElement>(null);
  const asm = useMemo(() => new FrameAssembler(), [game]);
  const [fb, setFb] = useState<Uint8Array | null>(null);
  const [frameNo, setFrameNo] = useState<bigint | null>(null);
  const [serial, setSerial] = useState<number[]>([]);
  const [regs, setRegs] = useState<Regs | null>(null);
  const [owner, setOwner] = useState<`0x${string}` | null>(null);
  const [romSize, setRomSize] = useState<bigint | null>(null);
  const [held, setHeld] = useState<number>(0);
  const [busy, setBusy] = useState<boolean>(false);
  const [auto, setAuto] = useState<boolean>(false);
  const [palette, setPalette] = useState<string>(() => activePreset().theme);

  // pin the theme to the chain; gameboy/gray stay pickable everywhere
  const themeOptions = [activePreset().theme, 'gameboy', 'gray'].filter(
    (t, i, a) => a.indexOf(t) === i && PALETTES[t] !== undefined,
  );
  useEffect(() => {
    setPalette(activePreset().theme);
  }, [chainId]);
  const [steps, setSteps] = useState<number>(0);
  const [txs, setTxs] = useState<`0x${string}`[]>([]);
  const [deadGame, setDeadGame] = useState<boolean>(false);
  const [title, setTitle] = useState<string>('');
  const [err, setErr] = useState<string>('');
  const [note, setNote] = useState<string>('');
  const heldRef = useRef<number>(0);
  // Single-painter rule: the advance path paints from receipts immediately;
  // the log watcher only ever paints frames NEWER than this, so a lagging
  // poll can never repaint a stale frame over a current one.
  const paintedRef = useRef<bigint | null>(null);
  // Taps between slow frames would vanish (mask is read at frame start), so
  // every press also latches here until some frame/step consumes it.
  const pendingRef = useRef<number>(0);
  const busyRef = useRef<boolean>(false);
  const autoRef = useRef<boolean>(false);
  autoRef.current = auto;

  // reset per-game state on switch + compute the current framebuffer from
  // on-chain state (instant, no txs)
  useEffect(() => {
    setFb(null);
    setFrameNo(null);
    setSerial([]);
    setRegs(null);
    setOwner(null);
    setRomSize(null);
    setErr('');
    setNote('');
    setTxs([]);
    setDeadGame(false);
    paintedRef.current = null;
    asm.reset();
    if (!game) return;
    let live = true;
    // A saved game may point at nothing (chain was reset since). Check code
    // first so everything downstream doesn't fail one by one on a dead address.
    publicClient
      .getCode({ address: game })
      .then((code) => {
        if (!live) return;
        if (!code || code === '0x') {
          setDeadGame(true);
          setErr('No contract here. The chain was probably reset since this game was saved.');
          return;
        }
        getOwner(game).then(setOwner).catch(() => setOwner(null));
        getRomSize(game)
          .then(setRomSize)
          .catch(() => setRomSize(null));
        readPpuState(game)
          .then((st) => {
            if (!live) return;
            setFb(renderFrame(st));
            setNote('Drawn from chain data. New frames show up as they land.');
          })
          .catch(() => {
            if (live) setNote('Upload a ROM and finalize first.');
          });
      })
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [game, asm]);

  // ROM title from the header (file bytes at upload, chain stores after)
  useEffect(() => {
    setTitle('');
    if (!game) return;
    let live = true;
    fetchRomTitle(game)
      .then((t) => {
        if (live) setTitle(t);
      })
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [game]);

  // listen to emitted logs: repaint whenever any frame completes on-chain
  useEffect(() => {
    if (!game) return;
    const sub = new FrameAssembler();
    const unwatch = publicClient.watchContractEvent({
      address: game,
      abi: GameBoyAbi,
      pollingInterval: 500,
      onLogs: (logs: Log[]) => {
        sub.ingest(decodeGameLogs(logs));
        const done = sub.takeCompleted();
        if (done && (paintedRef.current === null || done.frame > paintedRef.current)) {
          setFb(done.fb);
          setFrameNo(done.frame);
          paintedRef.current = done.frame;
          getRegs(game)
            .then(setRegs)
            .catch(() => {});
        }
      },
    });
    return () => unwatch();
  }, [game]);

  // paint framebuffer
  useEffect(() => {
    const cv = canvasRef.current;
    if (!cv || !fb) return;
    const ctx = cv.getContext('2d');
    if (!ctx) return;
    drawFrame(ctx, fb, FB_W, FB_H, PALETTES[palette] ?? PALETTES.gameboy);
  }, [fb, palette]);

  // theme the whole page from the palette
  useEffect(() => {
    applyPageTheme(palette);
  }, [palette]);

  // serial autoscroll
  useEffect(() => {
    const el = serialBoxRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [serial]);

  function press(bit: number): void {
    heldRef.current |= bit;
    pendingRef.current |= bit;
    setHeld(heldRef.current);
  }

  function release(bit: number): void {
    heldRef.current &= ~bit;
    setHeld(heldRef.current);
  }

  /** Mask for the next tx: live holds + latched taps (taps consumed). */
  function takeMask(): number {
    const mask = heldRef.current | pendingRef.current;
    pendingRef.current = 0;
    return mask;
  }

  // keyboard controls
  useEffect(() => {
    function down(e: KeyboardEvent): void {
      const bit = KEYMAP[e.code];
      if (bit === undefined) return;
      e.preventDefault();
      press(bit);
    }
    function up(e: KeyboardEvent): void {
      const bit = KEYMAP[e.code];
      if (bit === undefined) return;
      release(bit);
    }
    window.addEventListener('keydown', down);
    window.addEventListener('keyup', up);
    return () => {
      window.removeEventListener('keydown', down);
      window.removeEventListener('keyup', up);
    };
  }, []);

  async function refreshRegs(g: `0x${string}`): Promise<void> {
    try {
      setRegs(await getRegs(g));
    } catch {
      setRegs(null);
    }
  }

  const doAdvance = useCallback(async () => {
    if (!signer || !game || busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    setErr('');
    setNote('');
    try {
      const r = await advanceFrame(
        signer,
        game,
        takeMask(),
        asm,
        stepBudget(),
        (bytes) => setSerial((s) => [...s, ...bytes]),
        setSteps,
      );
      setFb(r.fb);
      setFrameNo(r.frame);
      paintedRef.current = r.frame;
      setTxs(r.txs);
      await refreshRegs(game);
    } catch (e) {
      setErr(explainError(e));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }, [signer, game, asm]);

  // autoplay loop
  useEffect(() => {
    if (!auto) return;
    const id = window.setInterval(() => {
      if (!busyRef.current) void doAdvance();
    }, 400);
    return () => window.clearInterval(id);
  }, [auto, doAdvance]);

  async function doStepOnce(): Promise<void> {
    if (!signer || !game || busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    setErr('');
    try {
      const r = await stepOnce(signer, game, takeMask(), asm, stepBudget(), (bytes) =>
        setSerial((s) => [...s, ...bytes]),
      );
      setTxs((t) => [...t.slice(-7), r.hash]);
      if (r.completed) {
        setFb(r.completed.fb);
        setFrameNo(r.completed.frame);
        paintedRef.current = r.completed.frame;
        await refreshRegs(game);
      } else {
        setNote('Step sent. Waiting on the rest of the frame.');
      }
    } catch (e) {
      setErr(explainError(e));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }

  async function doPreview(): Promise<void> {
    if (!game || !signer) return;
    setErr('');
    try {
      setFb(await previewFrame(signer, game, takeMask()));
      setNote('Preview only. Nothing was sent.');
    } catch (e) {
      setErr(explainError(e));
    }
  }

  async function doRenderState(): Promise<void> {
    if (!game) return;
    setErr('');
    try {
      setFb(renderFrame(await readPpuState(game)));
      setNote('Redrawn from chain data.');
    } catch (e) {
      setErr(explainError(e));
    }
  }

  async function doRenounce(): Promise<void> {
    if (!signer || !game) return;
    setErr('');
    try {
      await renounce(signer, game);
      setOwner(await getOwner(game));
      setNote('Done. Anyone can play now.');
    } catch (e) {
      setErr(explainError(e));
    }
  }

  function padButton(label: string, bit: number): ReactElement {
    const on = (held & bit) !== 0;
    return (
      <button
        className={on ? 'pad on' : 'pad'}
        onMouseDown={() => press(bit)}
        onMouseUp={() => release(bit)}
        onMouseLeave={() => release(bit)}
        onTouchStart={(e) => {
          e.preventDefault();
          press(bit);
        }}
        onTouchEnd={() => release(bit)}
      >
        {label}
      </button>
    );
  }

  if (!game) {
    return (
      <section className="card">
        <h2>player</h2>
        <p className="muted">No game selected. Create one first.</p>
      </section>
    );
  }

  const isOwner = signer !== null && owner !== null && signer.address.toLowerCase() === owner.toLowerCase();
  const openPlay = owner === '0x0000000000000000000000000000000000000000';

  return (
    <section className="card">
      <h2>player</h2>
      {title !== '' && <p>{title}</p>}
      <code className="mono small">{game}</code>
      {deadGame && game && (
        <div className="row">
          <button
            onClick={() => {
              removeGameCache(game);
              onGameRemoved();
            }}
          >
            forget this game
          </button>
        </div>
      )}
      <p className="muted small">
        Owner <code className="mono">{owner ?? '…'}</code>
        {openPlay ? ' (open)' : isOwner ? ' (you)' : ''}. Rom{' '}
        {romSize === null ? '…' : `${romSize.toString()} bytes`}.
        {frameNo !== null ? ` Frame ${frameNo.toString()}.` : ''}
      </p>
      <div className="stagerow">
        <canvas ref={canvasRef} width={FB_W} height={FB_H} className="screen" />
        <div className="sidecontrols">
          <div className="dpad">
            <div />
            {padButton('▲', BTN.UP)}
            <div />
            {padButton('B', BTN.B)}
            {padButton('A', BTN.A)}
            {padButton('◀', BTN.LEFT)}
            {padButton('▼', BTN.DOWN)}
            {padButton('▶', BTN.RIGHT)}
            {padButton('sel', BTN.SELECT)}
            {padButton('start', BTN.START)}
          </div>
          <p className="muted small">
            Arrows move. X is A and Z is B. Shift selects. Enter starts. Held 0x
            {held.toString(16)}
          </p>
        </div>
      </div>
      <div className="row">
        <button disabled={!signer || busy} onClick={() => void doAdvance()}>
          {busy ? `Sending… (${steps})` : 'next frame'}
        </button>
        <button disabled={!signer || busy} onClick={() => void doStepOnce()}>
          step once
        </button>
        <button disabled={busy || !signer} onClick={() => void doPreview()}>
          preview
        </button>
        <button disabled={busy} onClick={() => void doRenderState()}>
          redraw from chain
        </button>
        <button disabled={!signer} onClick={() => setAuto((a) => !a)}>
          {auto ? 'stop' : 'auto'}
        </button>
        <select value={palette} onChange={(e) => setPalette(e.target.value)} disabled={busy}>
          {themeOptions.map((name) => (
            <option key={name} value={name}>
              {name}
            </option>
          ))}
        </select>
      </div>
      <div className="small">
        <span className="muted">transactions ({txs.length}):</span>
        <ul className="mono txbox">
          {txs.slice(-8).map((h) => (
            <li key={h} title={h}>
              {h.slice(0, 10)}…{h.slice(-8)}
            </li>
          ))}
        </ul>
      </div>
      {note !== '' && <p className="muted">{note}</p>}
      {err !== '' && <div className="error">{err}</div>}
      <div className="row">
        <button disabled={!signer || !isOwner} onClick={() => void doRenounce()} title="Let anyone play">
          open to everyone
        </button>
      </div>
      <h3>serial</h3>
      <div ref={serialBoxRef} className="serial">
        {serialToText(serial) || <span className="muted">Nothing printed yet.</span>}
      </div>
      <h3>regs</h3>
      <div className="row">
        <button disabled={!game} onClick={() => game && void refreshRegs(game)}>
          refresh
        </button>
      </div>
      {regs ? (
        <table className="regs mono small">
          <tbody>
            <tr>
              <td>A {regs.a.toString(16).padStart(2, '0')}</td>
              <td>F {regs.f.toString(16).padStart(2, '0')}</td>
              <td>B {regs.b.toString(16).padStart(2, '0')}</td>
              <td>C {regs.c.toString(16).padStart(2, '0')}</td>
            </tr>
            <tr>
              <td>D {regs.d.toString(16).padStart(2, '0')}</td>
              <td>E {regs.e.toString(16).padStart(2, '0')}</td>
              <td>H {regs.h.toString(16).padStart(2, '0')}</td>
              <td>L {regs.l.toString(16).padStart(2, '0')}</td>
            </tr>
            <tr>
              <td colSpan={2}>SP {regs.sp.toString(16).padStart(4, '0')}</td>
              <td colSpan={2}>PC {regs.pc.toString(16).padStart(4, '0')}</td>
            </tr>
          </tbody>
        </table>
      ) : (
        <p className="muted small">Advance a frame to see registers.</p>
      )}
    </section>
  );
}
