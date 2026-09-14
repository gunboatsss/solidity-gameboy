// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GbCpu.sol";
import "./Sstore2.sol";

error NotOwner();
error Locked();
error BadChunk();
error BadStore();
error NoRom();
error BadBudget();
error TooLong();

/// @title GameBoy (slim 24KiB-deployable build)
/// @notice SSTORE2 ROM only, runFrame + step. ROM loads at deployment
///         (constructor, deployer becomes owner) or via chunked stores +
///         finalize (owner only, once). Play is owner-only until renounce,
///         then open to everyone (crowdplay mode).
///         State reads: regs(), readMem(), romStore()/romSize(), events.
contract GameBoy is GbCpu {
    event OwnershipRenounced();

    /// @dev Upload paths: owner only, and only before first boot.
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

    /// @dev Unowned sink: direct deploys are born bricked (implementation-only).
    ///      Cloning never runs the constructor, so clones stay bootable via
    ///      initialize while the implementation is dead on arrival — no second
    ///      tx, no front-run window, no deploy-time footgun.
    address internal constant DEAD = address(0xfeEFEEfeefEeFeefEEFEEfEeFeefEEFeeFEEFEeF);

    /// @dev Deploy: bricks the instance on arrival (owner = DEAD sink).
    ///      Direct deploys are implementation-only; ALL games are factory
    ///      clones booted via initialize()/chunked stores.
    constructor() {
        owner = DEAD;
    }

    /// @dev Claim a pristine clone: set the owner (curator). Allowed when
    ///      state is pristine, by the owner if set (fresh clones are
    ///      ownerless: anyone may claim them). Reverts on live/partial
    ///      state. ROM ingress is chunked stores only
    ///      (loadRomStoreChunk + finalizeSstore2Load).
    function initialize(address _owner) external {
        if (booted || romLen != 0) revert Locked();
        if (owner != address(0) && msg.sender != owner) revert NotOwner();
        owner = _owner;
    }

    /// @dev Chunked SSTORE2 upload: one 16KB-max store per tx. Stores before
    ///      the last must be full banks (bank alignment). Finish with finalizeSstore2Load().
    function loadRomStoreChunk(bytes calldata chunk) external onlyOwnerOnce {
        if (chunk.length == 0 || chunk.length > 0x4000) revert BadChunk();
        uint256 n = romStores.length;
        if (n > 0) {
            if (romStores[n - 1].code.length != 0x4001) revert BadStore();
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

    /// @dev Renounce ownership -> play opens to everyone (crowdplay mode).
    ///      Uploads stay locked forever.
    function renounceOwnership() external {
        if (msg.sender != owner) revert NotOwner();
        owner = address(0);
        emit OwnershipRenounced();
    }

    /// @dev ROM storefront for client-side EXTCODECOPY reads.
    function romStore(uint256 i) external view returns (address) {
        return romStores[i];
    }

    function romSize() external view returns (uint256) {
        return romLen;
    }

    /// @dev Input bit=1 means pressed.
    ///      bit0 A, bit1 B, bit2 Select, bit3 Start,
    ///      bit4 Right, bit5 Left, bit6 Up, bit7 Down.
    function runFrame(uint8 buttons) external canPlay returns (bytes memory fb) {
        if (!booted) revert NoRom();
        uint8 pressed = buttons;
        uint8 prev = joyButtons;
        joyButtons = ~pressed;
        Frame memory fr;
        _loadFrame(fr);
        fr.statLine = _statLineNow(fr);
        if ((pressed & prev) != 0) fr.iff |= 0x10;
        fb = new bytes(23040);
        bool done = false;
        while (!done) {
            uint32 c = _serviceInterrupts(fr);
            if (c == 0) c = _step(fr); // _step waits 4 cycles while halted
            _tickTimer(fr, c);
            _tickPpu(fr, c, fb, false);
            unchecked {
                fr.frameCycles += c;
            }
            done = _crossed(fr);
        }
        _flushFrame(fr);
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
        if (!booted) revert NoRom();
        if (maxCycles > 20000) revert BadBudget();
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
        _flushFrame(fr);
        executed = done;
    }

    /// @dev CPU registers (batched single call).
    function regs()
        external
        view
        returns (
            uint8 a,
            uint8 f,
            uint8 b,
            uint8 c,
            uint8 d,
            uint8 e,
            uint8 h,
            uint8 l,
            uint16 sp,
            uint16 pc
        )
    {
        return (regA, regF, regB, regC, regD, regE, regH, regL, regSP, regPC);
    }

    /// @dev PPU registers for off-chain renderers (readMem blanks IO, so the
    ///      framebuffer cannot be reconstructed from readMem alone).
    function ppuRegs()
        external
        view
        returns (
            uint8 lcdc,
            uint8 scy,
            uint8 scx,
            uint8 bgp,
            uint8 obp0,
            uint8 obp1,
            uint8 wy,
            uint8 wx
        )
    {
        return (regLCDC, regSCY, regSCX, regBGP, regOBP0, regOBP1, regWY, regWX);
    }

    /// @dev Read `len` RAM bytes (VRAM/WRAM/OAM/HRAM/ERAM/IE). ROM: use
    ///      romStore()/romSize() + client EXTCODECOPY. IO returns 0xFF.
    function readMem(uint16 addr, uint256 len) external view returns (bytes memory out) {
        if (!booted) revert NoRom();
        if (len > 0x10000) revert TooLong();
        out = new bytes(len);
        unchecked {
            for (uint256 i = 0; i < len; i++) {
                out[i] = bytes1(_readMemByte(uint16(uint256(addr) + i)));
            }
        }
    }

    function _readMemByte(uint16 addr) internal view returns (uint8) {
        unchecked {
            if (addr < 0x8000) return 0xFF; // ROM via romStore + extcodecopy
            if (addr < 0xA000) return uint8(vram[addr - 0x8000]);
            if (addr < 0xC000) {
                if (!ramEnabled) return 0xFF;
                uint256 b;
                if (mbcType == 1) {
                    b = bankingMode ? ramBank : 0;
                } else if (mbcType == 3) {
                    if (ramBank > 3) return 0xFF;
                    b = ramBank;
                } else if (mbcType == 5) {
                    b = ramBank;
                } else {
                    b = 0;
                }
                uint256 off = b * 0x2000 + (addr - 0xA000);
                if (off >= eram.length) return 0xFF;
                return uint8(eram[off]);
            }
            if (addr < 0xE000) return uint8(wram[addr - 0xC000]);
            if (addr < 0xFE00) return uint8(wram[addr - 0xE000]);
            if (addr < 0xFEA0) return uint8(oam[addr - 0xFE00]);
            if (addr < 0xFF00) return 0xFF;
            if (addr < 0xFF80) return 0xFF;
            if (addr < 0xFFFF) return uint8(hram[addr - 0xFF80]);
            return regIE;
        }
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
