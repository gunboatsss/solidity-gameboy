// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GbMemory.sol";

/// @title GbTimer — DIV/TIMA emulation + interrupt servicing
abstract contract GbTimer is GbMemory {
    /// @dev Advance timer by `cycles` T-cycles (O(1) edge arithmetic).
    ///      DIV = upper 8 bits of a 16-bit counter incremented per T-cycle.
    ///      TIMA ticks on the falling edge of a TAC-selected DIV bit:
    ///      sel 00 -> bit 9 (1024 T), 01 -> bit 3 (16 T),
    ///      10 -> bit 5 (64 T), 11 -> bit 7 (256 T).
    function _tickTimer(Frame memory fr, uint32 cycles) internal pure {
        unchecked {
            if (cycles == 0) return;
            uint16 prev = fr.divc;
            uint16 now_ = prev + uint16(cycles);
            fr.divc = now_;
            if ((fr.tac & 0x04) == 0) return;
            uint8 sel = fr.tac & 0x03;
            uint8 bitPos = sel == 0 ? 9 : sel == 1 ? 3 : sel == 2 ? 5 : 7;
            // falling edges of bitPos == crossings of a multiple of 2^(bitPos+1)
            uint32 m = uint32(1) << (bitPos + 1);
            uint32 ticks = ((uint32(prev & uint16(m - 1))) + cycles) / m;
            if (ticks == 0) return;
            uint32 t = uint32(fr.tima) + ticks;
            if (t > 0xFF) {
                fr.iff |= 0x04; // timer interrupt
                // reload from TMA, keep counting the remainder
                uint32 over = t - 0x100;
                fr.tima = uint8((uint32(fr.tma) + over) & 0xFF);
            } else {
                fr.tima = uint8(t);
            }
        }
    }

    /// @dev Service pending interrupts. Returns extra T-cycles consumed (0 or 20).
    /// @return cycles T-cycles consumed by servicing (5 M-cycles = 20 T)
    function _serviceInterrupts(Frame memory fr) internal returns (uint32 cycles) {
        unchecked {
            // EI delay: enable takes effect after the following instruction
            if (fr.eiPending) {
                fr.eiPending = false;
                fr.ime = true;
                return 0;
            }
            // HALT wake-up: even with IME=0, pending IF&IE exits halt
            uint8 pending = fr.iff & fr.ie & 0x1F;
            if (fr.halted) {
                if (pending != 0) fr.halted = false;
            }
            if (!fr.ime || pending == 0) return 0;
            // priority: VBlank, LCD, Timer, Serial, Joypad
            uint8 bit;
            uint16 vec;
            if ((pending & 0x01) != 0) {
                bit = 0x01;
                vec = 0x0040;
            } else if ((pending & 0x02) != 0) {
                bit = 0x02;
                vec = 0x0048;
            } else if ((pending & 0x04) != 0) {
                bit = 0x04;
                vec = 0x0050;
            } else if ((pending & 0x08) != 0) {
                bit = 0x08;
                vec = 0x0058;
            } else {
                bit = 0x10;
                vec = 0x0060;
            }
            fr.ime = false;
            fr.iff &= ~bit;
            fr.halted = false;
            _push(fr, fr.pc);
            fr.pc = vec;
            return 20;
        }
    }
}
