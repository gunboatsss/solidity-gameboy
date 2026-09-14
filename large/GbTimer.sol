// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GbMemory.sol";

/// @title GbTimer — DIV/TIMA emulation + interrupt servicing
/// @notice _tickTimer/_crossed are inlined into the runFrame/step loops
///         (see GameBoy.sol OPT comments); only _serviceInterrupts remains
///         shared here.
abstract contract GbTimer is GbMemory {
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
