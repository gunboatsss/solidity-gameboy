// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GameBoy.sol";

/// @title GameBoyHelper — external (off-chain / test) reader for GameBoy state
/// @notice The core contract exposes state ONLY via getState(). This companion
///         projects convenient views out of that single snapshot, so one
///         staticcall serves any read. All functions are views.
contract GameBoyHelper {
    function fullState(GameBoy gb) external view returns (GbState memory) {
        return gb.getState();
    }

    function regs(GameBoy gb)
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
        GbState memory s = gb.getState();
        return (s.a, s.f, s.b, s.c, s.d, s.e, s.h, s.l, s.sp, s.pc);
    }

    function cpuState(GameBoy gb) external view returns (uint16 pc, uint64 cycles, uint32 frame) {
        GbState memory s = gb.getState();
        return (s.pc, s.totalCycles, s.frameCount);
    }

    function serialText(GameBoy gb) external view returns (bytes memory) {
        return gb.getState().serialOut;
    }

    function frameState(GameBoy gb)
        external
        view
        returns (uint8 ly, uint8 mode, uint32 clock, bool booted)
    {
        GbState memory s = gb.getState();
        return (s.ly, s.mode, s.frameClock, s.booted);
    }

    function ioState(GameBoy gb)
        external
        view
        returns (
            uint8 sb,
            uint8 sc,
            uint8 divReg,
            uint8 tima,
            uint8 tma,
            uint8 tac,
            uint8 iff,
            uint8 ie
        )
    {
        GbState memory s = gb.getState();
        return (s.sb, s.sc, s.divReg, s.tima, s.tma, s.tac, s.iff, s.ie);
    }

    /// @dev Read `len` bytes starting at GB address `start` (ROM/RAM only;
    ///      IO region returns 0xFF — use ioState() for live IO).
    function readMem(
        GameBoy gb,
        uint16 start,
        uint256 len
    ) external view returns (bytes memory out) {
        require(len <= 0x10000, "too long");
        GbState memory s = gb.getState();
        out = new bytes(len);
        unchecked {
            for (uint256 i = 0; i < len; i++) {
                out[i] = bytes1(_byteAt(gb, s, uint256(start) + i));
            }
        }
    }

    function _byteAt(
        GameBoy gb,
        GbState memory s,
        uint256 a
    ) internal view returns (uint8) {
        unchecked {
            if (a < 0x4000) {
                return _romByte(gb, s, a);
            } else if (a < 0x8000) {
                uint256 bank = s.romBank;
                if (s.mbcType == 0) bank = 1;
                else if (s.mbcType == 1 && bank == 0) bank = 1;
                return _romByte(gb, s, bank * 0x4000 + (a - 0x4000));
            } else if (a < 0xA000) {
                return uint8(s.vram[a - 0x8000]);
            } else if (a < 0xC000) {
                if (!s.ramEnabled) return 0xFF;
                uint256 b;
                if (s.mbcType == 1) {
                    b = s.bankingMode ? s.ramBank : 0;
                } else if (s.mbcType == 3) {
                    if (s.ramBank > 3) return 0xFF;
                    b = s.ramBank;
                } else if (s.mbcType == 5) {
                    b = s.ramBank;
                } else {
                    b = 0;
                }
                uint256 off = b * 0x2000 + (a - 0xA000);
                return off < s.eram.length ? uint8(s.eram[off]) : 0xFF;
            } else if (a < 0xE000) {
                return uint8(s.wram[a - 0xC000]);
            } else if (a < 0xFE00) {
                return uint8(s.wram[a - 0xE000]); // echo
            } else if (a < 0xFEA0) {
                return uint8(s.oam[a - 0xFE00]);
            } else if (a < 0xFF80) {
                return 0xFF; // live IO: use ioState()
            } else if (a < 0xFFFF) {
                return uint8(s.hram[a - 0xFF80]);
            } else {
                return s.ie;
            }
        }
    }

    /// @dev ROM byte from the snapshot or SSTORE2 stores (single extcodecopy).
    function _romByte(
        GameBoy gb,
        GbState memory s,
        uint256 off
    ) internal view returns (uint8) {
        if (s.useSstore2) {
            if (off >= s.romLen) return 0xFF;
            uint256 idx = off / 0x4000;
            if (idx >= s.stores.length) return 0xFF;
            address store = s.stores[idx];
            if (store == address(0)) return 0xFF;
            bytes memory b = new bytes(1);
            assembly {
                extcodecopy(store, add(b, 32), add(mod(off, 0x4000), 1), 1)
            }
            return uint8(b[0]);
        }
        if (off >= s.rom.length) return 0xFF;
        return uint8(s.rom[off]);
    }
}
