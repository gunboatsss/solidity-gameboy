// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev One-shot snapshot of all persistent emulator state (see getState).
struct GbState {
    uint8 a;
    uint8 f;
    uint8 b;
    uint8 c;
    uint8 d;
    uint8 e;
    uint8 h;
    uint8 l;
    uint16 sp;
    uint16 pc;
    bool ime;
    bool halted;
    bool eiPending;
    uint16 romBank;
    bool ramEnabled;
    uint8 ramBank;
    bool bankingMode;
    uint8 mbcType;
    uint8 sb;
    uint8 sc;
    uint8 divReg;
    uint8 tima;
    uint8 tma;
    uint8 tac;
    uint8 iff;
    uint8 ie;
    uint16 divc;
    uint8 lcdc;
    uint8 stat;
    uint8 scy;
    uint8 scx;
    uint8 ly;
    uint8 lyc;
    uint8 bgp;
    uint8 obp0;
    uint8 obp1;
    uint8 wy;
    uint8 wx;
    uint8 mode;
    uint16 ppuCycles;
    uint8 joy;
    uint8 joyButtons;
    uint32 frameCount;
    uint32 frameClock;
    uint64 totalCycles;
    bool booted;
    bytes rom;
    address[] stores;
    uint256 romLen;
    bool useSstore2;
    bytes eram;
    bytes vram;
    bytes oam;
    bytes hram;
    bytes wram;
    bytes serialOut;
}

/// @title GbStorage — persistent on-chain DMG state
/// @notice Big memories live in storage (`bytes`). Hot CPU/IO state is
///         copied into a memory `Frame` at the start of runFrame() and
///         flushed back at the end, so per-instruction register access
///         costs memory gas instead of SLOAD/SSTORE.
abstract contract GbStorage {
    /// @dev Deployer. Uploads/play gated while set; renounce (zero) opens
    ///      play to everyone (Twitch-Plays-Pokemon mode). Uploads stay locked.
    address public owner;
    // ---- CPU registers (packed by solidity into ~2 slots) ----
    uint8 regA;
    uint8 regF; // Z N H C in upper nibble, lower always 0
    uint8 regB;
    uint8 regC;
    uint8 regD;
    uint8 regE;
    uint8 regH;
    uint8 regL;
    uint16 regSP;
    uint16 regPC;
    bool ime; // interrupt master enable
    bool halted;
    bool eiPending; // EI takes effect after next instruction

    // ---- Cartridge / MBC1 ----
    bytes rom; // full ROM image in storage (storage path)
    // SSTORE2 path: bank-aligned 16KB code blobs (store k = file bytes
    // [k*0x4000, k*0x4000+0x4000)); prefetch into Frame.romBuf per call.
    address[] romStores;
    uint256 romLen;
    bool useSstore2;
    uint16 romBank = 1; // switchable bank, 1 after reset (MBC1/MBC3; MBC5 up to 511)
    bool ramEnabled;
    uint8 ramBank;
    bool bankingMode; // false=ROM banking, true=RAM banking
    bytes eram; // 32KB external RAM
    uint8 mbcType; // 0=ROM-only, 1=MBC1

    // ---- Memories ----
    bytes vram; // 8KB  0x8000-0x9FFF
    bytes wram; // 8KB  0xC000-0xDFFF
    bytes oam; // 160B 0xFE00-0xFE9F
    bytes hram; // 127B 0xFF80-0xFFFE

    // ---- IO / Timer ----
    uint8 regSB; // 0xFF01 serial data
    uint8 regSC; // 0xFF02 serial control
    uint8 regDIV; // 0xFF04
    uint8 regTIMA; // 0xFF05
    uint8 regTMA; // 0xFF06
    uint8 regTAC; // 0xFF07
    uint8 regIF; // 0xFF0F
    uint8 regIE; // 0xFFFF
    uint16 divCounter; // internal 16-bit divider

    // ---- PPU IO ----
    uint8 regLCDC = 0x91;
    uint8 regSTAT;
    uint8 regSCY;
    uint8 regSCX;
    uint8 regLY;
    uint8 regLYC;
    uint8 regBGP = 0xFC;
    uint8 regOBP0 = 0xFF;
    uint8 regOBP1 = 0xFF;
    uint8 regWY;
    uint8 regWX;
    uint8 ppuMode; // 0=HBlank 1=VBlank 2=OAM 3=VRAM
    uint16 ppuCycles; // cycles spent in current mode
    uint8 joypad = 0xFF; // 0xFF00 P1 select latch (bits 4-5)
    uint8 joyButtons = 0xFF; // pressed mask, active-low: bit0..7 = A,B,Sel,Start,Right,Left,Up,Down (0=pressed)

    // ---- Misc ----
    bytes serialOut; // Blargg/test serial capture
    uint32 frameCount;
    uint32 frameClock; // T-cycles elapsed in current frame (persists across step() calls)
    uint64 totalCycles;
    bool booted;

    // Flag masks
    uint8 internal constant F_Z = 0x80;
    uint8 internal constant F_N = 0x40;
    uint8 internal constant F_H = 0x20;
    uint8 internal constant F_C = 0x10;

    // Interrupt bits / vectors
    uint8 internal constant INT_VBLANK = 0x01;
    uint8 internal constant INT_LCD = 0x02;
    uint8 internal constant INT_TIMER = 0x04;
    uint8 internal constant INT_SERIAL = 0x08;
    uint8 internal constant INT_JOYPAD = 0x10;

    uint256 internal constant CYCLES_PER_FRAME = 70224;

    event FrameDone(uint32 indexed frame);
    event Scanline(uint32 indexed frame, uint8 ly, bytes px); // 160 bytes
    event SerialByte(uint8 b);

    /// @dev Hot per-frame state kept in memory during runFrame().
    struct Frame {
        uint8 a;
        uint8 f;
        uint8 b;
        uint8 c;
        uint8 d;
        uint8 e;
        uint8 h;
        uint8 l;
        uint16 sp;
        uint16 pc;
        bool ime;
        bool halted;
        bool eiPending;
        bool haltBug; // HALT with IME=0 and pending IRQ: next fetch skips PC++
        // timer
        uint16 divc;
        uint8 tima;
        uint8 tma;
        uint8 tac;
        uint8 sb;
        uint8 sc;
        uint8 iff;
        uint8 ie;
        // ppu io
        uint8 lcdc;
        uint8 stat;
        uint8 scy;
        uint8 scx;
        uint8 ly;
        uint8 lyc;
        uint8 bgp;
        uint8 obp0;
        uint8 obp1;
        uint8 wy;
        uint8 wx;
        uint8 mode;
        uint16 ppuCycles;
        uint8 joy;
        // ppu transient
        bool statLine; // previous STAT interrupt line state (edge detect)
        uint8 winLine; // current window internal line
        // mbc
        uint16 romBank;
        bool ramEn;
        uint8 ramBank;
        bool bankMode;
        uint32 frameCycles;
        // SSTORE2 path: whole ROM prefetched here per call (empty = storage path)
        bytes romBuf;
        // renderer output: full fb (base=ly*160) or fresh 160B line + emit
        bytes lineBuf;
        uint256 lineBase;
        bool emitLine;
        // framing: FrameDone/Scanline indexing + sub-frame cycle accounting
        uint32 frameNo;
    }
}
