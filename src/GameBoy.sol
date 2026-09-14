// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GbCpu.sol";

error NotOwner();
error Locked();

/// @title GameBoy — a Nintendo DMG emulator that runs on the EVM
/// @notice Execution model: one transaction advances one frame
///         (70224 T-cycles) with fresh joypad input, and returns the
///         160x144 2bpp framebuffer (shades 0=white..3=black).
///         ROMs are loaded into contract storage (MBC1 supported).
contract GameBoy is GbCpu {
    event OwnershipRenounced();

    /// @dev Upload/reset paths: owner only, and only before first boot.
    modifier onlyOwnerOnce() {
        if (msg.sender != owner) revert NotOwner();
        if (booted) revert Locked();
        _;
    }

    /// @dev Play paths: owner only while owned; anyone after renounce.
    modifier canPlay() {
        if (owner != address(0) && msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @dev Renounce ownership -> play opens to everyone (crowdplay mode).
    ///      Uploads stay locked forever.
    function renounceOwnership() external {
        if (msg.sender != owner) revert NotOwner();
        owner = address(0);
        emit OwnershipRenounced();
    }

    /// @dev Load a ROM image (up to MBC1 125KB+). Resets all state.
    function loadRom(bytes calldata data) external onlyOwnerOnce {
        _loadRom(data);
    }

    /// @dev Chunked upload for ROMs that don't fit one tx's gas budget.
    ///      Append-only chunks on a fresh contract, then finalizeLoad().
    ///      e.g. 64KB ROM as 8 x 8KB chunks (~3M gas each), then finalize.
    function loadRomChunk(uint256 offset, bytes calldata chunk) external onlyOwnerOnce {
        require(!booted, "unload first");
        require(chunk.length > 0 && chunk.length <= 0x8000, "bad chunk");
        uint256 oldLen = rom.length; // plain read: no manual length writes yet
        require(offset == oldLen, "append-only");
        require(offset % 32 == 0, "word align");
        bytes storage r = rom;
        uint256 n = chunk.length;
        uint256 newLen = offset + n;
        if (newLen < 32 || (oldLen > 0 && oldLen < 32)) {
            // tiny prefix / pathological small-first-chunk: plain pushes
            // (Solidity maintains short/long length encoding correctly).
            unchecked {
                for (uint256 i = 0; i < n; i++) r.push(chunk[i]);
            }
            return;
        }
        // Fast path: oldLen is 0 or >= 32, newLen >= 32, so long-form
        // length encoding (slot = newLen*2+1) applies throughout.
        // NOTE: no Solidity-level array access may follow the raw length
        // sstore in this function (via-IR bounds-check reasoning) — the
        // word blast and tail merge below are pure assembly.
        bytes memory m = chunk; // calldata -> memory (cheap bulk copy)
        uint256 words = n / 32;
        assembly {
            mstore(0, rom.slot)
            sstore(rom.slot, add(mul(newLen, 2), 1))
            let base := keccak256(0, 0x20)
            let src := add(m, 32)
            let first := div(offset, 32)
            for { let w := 0 } lt(w, words) { w := add(w, 1) } {
                sstore(add(base, add(first, w)), mload(add(src, mul(w, 32))))
            }
            // tail bytes (file is big-endian within each word)
            let tailStart := add(offset, mul(words, 32))
            let tailLen := sub(add(offset, n), tailStart)
            if gt(tailLen, 0) {
                let slot := add(base, div(tailStart, 32))
                let val := sload(slot)
                for { let i := 0 } lt(i, tailLen) { i := add(i, 1) } {
                    let f := add(tailStart, i)
                    let sh := mul(sub(31, mod(f, 32)), 8)
                    let b := byte(0, mload(add(add(src, mul(words, 32)), i)))
                    val := or(and(val, not(shl(sh, 0xFF))), shl(sh, b))
                }
                sstore(slot, val)
            }
        }
    }

    /// @dev Finish a chunked upload: pad, detect MBC, reset CPU (same as loadRom tail).
    function finalizeLoad() external onlyOwnerOnce {
        _initState();
    }

    // ---------- SSTORE2 ROM path (data in contract bytecode) ----------

    /// @dev One-shot SSTORE2 upload: deploys 16KB code blobs (one per bank).
    function loadRomSSTORE2(bytes calldata data) external onlyOwnerOnce {
        require(data.length > 0x147, "ROM too small");
        delete romStores;
        romLen = 0;
        unchecked {
            for (uint256 off = 0; off < data.length; off += 0x4000) {
                uint256 len = data.length - off > 0x4000 ? 0x4000 : data.length - off;
                romStores.push(Sstore2.write(data[off:off + len]));
            }
            romLen = data.length;
        }
        _initSstore2();
    }

    /// @dev Chunked SSTORE2 upload: one 16KB-max store per tx. Stores before
    ///      the last must be full banks (bank alignment). Finish with finalizeSstore2Load().
    function loadRomStoreChunk(bytes calldata chunk) external onlyOwnerOnce {
        require(!booted, "unload first");
        require(chunk.length > 0 && chunk.length <= 0x4000, "bad chunk");
        uint256 n = romStores.length;
        if (n > 0) {
            require(romStores[n - 1].code.length == 0x4001, "prev store must be full");
        }
        romStores.push(Sstore2.write(bytes(chunk)));
        unchecked {
            romLen += chunk.length;
        }
    }

    /// @dev Finish a chunked SSTORE2 upload.
    function finalizeSstore2Load() external onlyOwnerOnce {
        _initSstore2();
    }

    /// @dev Input bit=1 means pressed.
    ///      bit0 A, bit1 B, bit2 Select, bit3 Start,
    ///      bit4 Right, bit5 Left, bit6 Up, bit7 Down.
    function runFrame(uint8 buttons) external canPlay returns (bytes memory fb) {
        require(booted, "no ROM");
        uint8 pressed = buttons;
        uint8 prev = joyButtons;
        joyButtons = ~pressed;
        Frame memory fr;
        _loadFrame(fr);
        // init STAT edge detector to current line level (avoid spurious IRQ)
        fr.statLine = _statLineNow(fr);
        // joypad interrupt on freshly pressed button:
        // prev is active-low (1=was released), pressed is active-high
        if ((pressed & prev) != 0) fr.iff |= 0x10;
        fb = new bytes(23040);
        bool done = false;
        uint32 exec;
        while (!done) {
            uint32 c = _serviceInterrupts(fr);
            if (c == 0) c = _step(fr); // _step waits 4 cycles while halted
            _tickTimer(fr, c);
            _tickPpu(fr, c, fb, false);
            unchecked {
                fr.frameCycles += c;
                exec += c;
            }
            done = _crossed(fr);
        }
        _flushFrame(fr, exec);
    }

    /// @dev EIP-7825-compatible stepping: advance up to `maxCycles` T-cycles
    ///      (whole instructions; overshoots by < 1 instruction). Scanlines
    ///      are emitted as Scanline events as they render; FrameDone fires
    ///      at each 70224-cycle boundary (remainder carried, so continued
    ///      stepping stays phase-locked). Keep maxCycles <= ~16000 to stay
    ///      under 16.7M gas per tx. maxCycles == 0 delivers input only.
    ///      Returns (cycles executed, frame completed, current LY).
    function step(uint32 maxCycles, uint8 buttons)
        external
        canPlay
        returns (uint32 executed, bool frameDone, uint8 ly)
    {
        require(booted, "no ROM");
        require(maxCycles <= 20000, "bad budget");
        uint8 pressed = buttons;
        uint8 prev = joyButtons;
        joyButtons = ~pressed;
        Frame memory fr;
        _loadFrame(fr);
        fr.statLine = _statLineNow(fr);
        if ((pressed & prev) != 0) fr.iff |= 0x10;
        uint32 done = 0;
        bytes memory noFb = new bytes(0);
        unchecked {
            while (done < maxCycles) {
                uint32 c = _serviceInterrupts(fr);
                if (c == 0) c = _step(fr);
                _tickTimer(fr, c);
                _tickPpu(fr, c, noFb, true);
                done += c;
                fr.frameCycles += c;
                if (_crossed(fr)) frameDone = true;
            }
        }
        ly = fr.ly;
        _flushFrame(fr, done);
        executed = done;
    }

    /// @dev The ONLY state reader: full snapshot in one call. All state
    ///      vars are internal; clients (including GameBoyHelper) use this.
    function getState() external view returns (GbState memory s) {
        s.a = regA;
        s.f = regF;
        s.b = regB;
        s.c = regC;
        s.d = regD;
        s.e = regE;
        s.h = regH;
        s.l = regL;
        s.sp = regSP;
        s.pc = regPC;
        s.ime = ime;
        s.halted = halted;
        s.eiPending = eiPending;
        s.romBank = romBank;
        s.ramEnabled = ramEnabled;
        s.ramBank = ramBank;
        s.bankingMode = bankingMode;
        s.mbcType = mbcType;
        s.sb = regSB;
        s.sc = regSC;
        s.divReg = regDIV;
        s.tima = regTIMA;
        s.tma = regTMA;
        s.tac = regTAC;
        s.iff = regIF;
        s.ie = regIE;
        s.divc = divCounter;
        s.lcdc = regLCDC;
        s.stat = regSTAT;
        s.scy = regSCY;
        s.scx = regSCX;
        s.ly = regLY;
        s.lyc = regLYC;
        s.bgp = regBGP;
        s.obp0 = regOBP0;
        s.obp1 = regOBP1;
        s.wy = regWY;
        s.wx = regWX;
        s.mode = ppuMode;
        s.ppuCycles = ppuCycles;
        s.joy = joypad;
        s.joyButtons = joyButtons;
        s.frameCount = frameCount;
        s.frameClock = frameClock;
        s.totalCycles = totalCycles;
        s.booted = booted;
        s.rom = rom;
        s.stores = romStores;
        s.romLen = romLen;
        s.useSstore2 = useSstore2;
        s.eram = eram;
        s.vram = vram;
        s.oam = oam;
        s.hram = hram;
        s.wram = wram;
        s.serialOut = serialOut;
    }

    function _statLineNow(Frame memory fr) internal pure returns (bool) {
        unchecked {
            bool lyMatch = (fr.ly == fr.lyc);
            uint8 en = fr.stat;
            if (((en >> 6) & 1) != 0 && lyMatch) return true;
            if (((en >> 5) & 1) != 0 && fr.mode == 2 && fr.ly < 144) return true;
            if (((en >> 4) & 1) != 0 && fr.mode == 1) return true;
            if (((en >> 3) & 1) != 0 && fr.mode == 0 && fr.ly < 144) return true;
            return false;
        }
    }
}
