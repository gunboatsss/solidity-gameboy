// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GbStorage.sol";
import "./Sstore2.sol";

/// @title GbMemory — MMU with MBC1, IO side effects, DMA, serial capture
abstract contract GbMemory is GbStorage {
    // ---------- ROM loading (SSTORE2 only) ----------

    /// @dev ROM lives in code blobs + prefetch buffer. Allocates memories,
    ///      detects MBC, resets CPU.
    function _initSstore2() internal {
        if (romLen <= 0x149) revert RomTooSmall();
        if (romStores.length == 0) revert NoStores();
        bytes memory b = Sstore2.read(romStores[0], 0x147, 3);
        _allocAndReset(uint8(b[0]), uint8(b[2])); // cartType @0x147, ramSize @0x149
        useSstore2 = true;
    }

    /// @dev MBC detect (0=ROM, 1=MBC1, 3=MBC3, 5=MBC5; else revert),
    ///      header-sized ERAM, then full state reset.
    ///      RAM header 0x149: 0/1=none, 2=8KB, 3=32KB, 4=128KB(MBC5)/32KB, 5=64KB.
    function _allocAndReset(uint8 cartType, uint8 ramSize) internal {
        if (cartType == 0x00 || cartType == 0x08 || cartType == 0x09) {
            mbcType = 0;
        } else if (cartType >= 0x01 && cartType <= 0x03) {
            mbcType = 1;
        } else if (cartType >= 0x0F && cartType <= 0x13) {
            mbcType = 3;
        } else if (cartType >= 0x19 && cartType <= 0x1E) {
            mbcType = 5;
        } else {
            revert BadMbc();
        }
        uint256 ramBanks;
        if (ramSize == 0x02) ramBanks = 1;
        else if (ramSize == 0x03) ramBanks = 4;
        else if (ramSize == 0x04) ramBanks = mbcType == 5 ? 16 : 4;
        else if (ramSize == 0x05) ramBanks = 8;
        else if (cartType == 0x08 || cartType == 0x09) ramBanks = 1;
        else ramBanks = 0;
        if (mbcType == 1 && ramBanks > 4) ramBanks = 4;
        if (mbcType == 3 && ramBanks > 4) ramBanks = 4;
        if (mbcType == 5 && ramBanks > 16) ramBanks = 16;
        eram = new bytes(ramBanks * 0x2000);
        vram = new bytes(0x2000);
        wram = new bytes(0x2000);
        oam = new bytes(0xA0);
        hram = new bytes(0x7F);
        romBank = 1;
        ramEnabled = (cartType == 0x08 || cartType == 0x09); // ROM+RAM carts: always on
        ramBank = 0;
        bankingMode = false;
        // reset CPU
        regA = 0x01;
        regF = 0xB0;
        regB = 0x00;
        regC = 0x13;
        regD = 0x00;
        regE = 0xD8;
        regH = 0x01;
        regL = 0x4D;
        regSP = 0xFFFE;
        regPC = 0x0100;
        ime = false;
        halted = false;
        eiPending = false;
        regSB = 0;
        regSC = 0;
        regDIV = 0;
        regTIMA = 0;
        regTMA = 0;
        regTAC = 0;
        regIF = 0;
        regIE = 0;
        divCounter = 0;
        regLCDC = 0x91;
        regSTAT = 0;
        regSCY = 0;
        regSCX = 0;
        regLY = 0;
        regLYC = 0;
        regBGP = 0xFC;
        regOBP0 = 0xFF;
        regOBP1 = 0xFF;
        regWY = 0;
        regWX = 0;
        ppuMode = 0;
        ppuCycles = 0;
        joypad = 0xFF;
        joyButtons = 0xFF;
        frameCount = 0;
        frameClock = 0;
        booted = true;
    }

    // ---------- frame load / flush (storage <-> memory) ----------

    function _loadFrame(Frame memory fr) internal view {
        fr.a = regA;
        fr.f = regF & 0xF0;
        fr.b = regB;
        fr.c = regC;
        fr.d = regD;
        fr.e = regE;
        fr.h = regH;
        fr.l = regL;
        fr.sp = regSP;
        fr.pc = regPC;
        fr.ime = ime;
        fr.halted = halted;
        fr.eiPending = eiPending;
        fr.divc = divCounter;
        fr.tima = regTIMA;
        fr.tma = regTMA;
        fr.tac = regTAC;
        fr.sb = regSB;
        fr.sc = regSC;
        fr.iff = regIF;
        fr.ie = regIE;
        fr.lcdc = regLCDC;
        fr.stat = regSTAT;
        fr.scy = regSCY;
        fr.scx = regSCX;
        fr.ly = regLY;
        fr.lyc = regLYC;
        fr.bgp = regBGP;
        fr.obp0 = regOBP0;
        fr.obp1 = regOBP1;
        fr.wy = regWY;
        fr.wx = regWX;
        fr.mode = ppuMode;
        fr.ppuCycles = ppuCycles;
        fr.joy = joypad;
        fr.romBank = romBank;
        fr.ramEn = ramEnabled;
        fr.ramBank = ramBank;
        fr.bankMode = bankingMode;
        fr.frameCycles = frameClock;
        fr.frameNo = frameCount;
        fr.romBuf = _fetchRom();
    }

    /// @dev EXTCODECOPY the whole ROM into memory (one cold touch per store
    ///      per tx, then 3 gas/word). Bank-aligned 16KB stores.
    function _fetchRom() internal view returns (bytes memory buf) {
        uint256 len = romLen;
        uint256 n = romStores.length;
        buf = new bytes(len);
        assembly {
            mstore(0, romStores.slot)
            let base := keccak256(0, 0x20)
            let dest := add(buf, 32)
            let remaining := len
            for { let k := 0 } lt(k, n) { k := add(k, 1) } {
                let take := 0x4000
                if gt(take, remaining) { take := remaining }
                if gt(take, 0) {
                    // +1 skips the STOP prefix byte; extcodecopy zero-pads past code end
                    extcodecopy(sload(add(base, k)), add(dest, mul(k, 0x4000)), 1, take)
                }
                remaining := sub(remaining, take)
            }
        }
    }

    function _flushFrame(Frame memory fr) internal {
        regA = fr.a;
        regF = fr.f & 0xF0;
        regB = fr.b;
        regC = fr.c;
        regD = fr.d;
        regE = fr.e;
        regH = fr.h;
        regL = fr.l;
        regSP = fr.sp;
        regPC = fr.pc;
        ime = fr.ime;
        halted = fr.halted;
        eiPending = fr.eiPending;
        divCounter = fr.divc;
        regDIV = uint8(fr.divc >> 8);
        regTIMA = fr.tima;
        regTMA = fr.tma;
        regTAC = fr.tac;
        regSB = fr.sb;
        regSC = fr.sc;
        regIF = fr.iff;
        regIE = fr.ie;
        regLCDC = fr.lcdc;
        regSTAT = fr.stat;
        regSCY = fr.scy;
        regSCX = fr.scx;
        regLY = fr.ly;
        regLYC = fr.lyc;
        regBGP = fr.bgp;
        regOBP0 = fr.obp0;
        regOBP1 = fr.obp1;
        regWY = fr.wy;
        regWX = fr.wx;
        ppuMode = fr.mode;
        ppuCycles = fr.ppuCycles;
        joypad = fr.joy;
        romBank = fr.romBank;
        ramEnabled = fr.ramEn;
        ramBank = fr.ramBank;
        bankingMode = fr.bankMode;
        // frameClock/frameCount track sub-frame progress across step() calls;
        // _crossed() bumps frameNo + carries the remainder at each boundary.
        frameClock = fr.frameCycles;
        frameCount = fr.frameNo;
    }

    /// @dev Detect 70224-cycle frame boundary crossings: emit FrameDone,
    ///      bump the frame number, carry the remainder. Returns crossing(s).
    function _crossed(Frame memory fr) internal returns (bool crossed) {
        unchecked {
            while (fr.frameCycles >= CYCLES_PER_FRAME) {
                fr.frameCycles -= uint32(CYCLES_PER_FRAME);
                emit FrameDone(fr.frameNo);
                fr.frameNo += 1;
                crossed = true;
            }
        }
    }

    // ---------- mapped ROM byte (prefetch buffer; SSTORE2-only build) ----------

    function _romByte(Frame memory fr, uint256 off) internal view returns (uint8) {
        bytes memory buf = fr.romBuf;
        if (off >= buf.length) return 0xFF;
        return uint8(buf[off]);
    }

    // ---------- mapped read ----------

    function _readByte(Frame memory fr, uint16 addr) internal view returns (uint8) {
        unchecked {
            if (addr < 0x4000) {
                return _romByte(fr, addr);
            } else if (addr < 0x8000) {
                uint256 bank = fr.romBank;
                if (mbcType == 0) bank = 1;
                else if (mbcType == 1 && bank == 0) bank = 1; // MBC1 never maps 0
                // (MBC3/MBC5 may map bank 0)
                uint256 off = bank * 0x4000 + (addr - 0x4000);
                return _romByte(fr, off);
            } else if (addr < 0xA000) {
                return uint8(vram[addr - 0x8000]);
            } else if (addr < 0xC000) {
                if (!fr.ramEn) return 0xFF;
                uint256 b;
                if (mbcType == 1) {
                    b = fr.bankMode ? fr.ramBank : 0;
                } else if (mbcType == 3) {
                    if (fr.ramBank > 3) return 0xFF; // RTC select: stubbed
                    b = fr.ramBank;
                } else if (mbcType == 5) {
                    b = fr.ramBank;
                } else {
                    b = 0; // ROM+RAM carts: fixed bank
                }
                uint256 off = b * 0x2000 + (addr - 0xA000);
                if (off >= eram.length) return 0xFF;
                return uint8(eram[off]);
            } else if (addr < 0xE000) {
                return uint8(wram[addr - 0xC000]);
            } else if (addr < 0xFE00) {
                return uint8(wram[addr - 0xE000]); // echo
            } else if (addr < 0xFEA0) {
                return uint8(oam[addr - 0xFE00]);
            } else if (addr < 0xFF00) {
                return 0xFF;
            } else if (addr < 0xFF80) {
                return _readIO(fr, uint8(addr));
            } else if (addr < 0xFFFF) {
                return uint8(hram[addr - 0xFF80]);
            } else {
                return fr.ie;
            }
        }
    }

    function _readIO(Frame memory fr, uint8 lo) internal view returns (uint8) {
        unchecked {
            if (lo == 0x00) {
                // P1 joypad: upper nibble reflects selected buttons (active low)
                uint8 sel = fr.joy;
                uint8 btns = joyButtons; // active low pressed mask in low 8 bits? stored 0=pressed
                uint8 res = 0xC0 | (sel & 0x30);
                bool selButtons = (sel & 0x20) == 0;
                bool selDpad = (sel & 0x10) == 0;
                uint8 nib = 0x0F;
                if (selButtons && selDpad) {
                    nib = (btns & 0x0F) & (btns >> 4);
                    nib &= 0x0F;
                } else if (selButtons) {
                    nib = btns & 0x0F;
                } else if (selDpad) {
                    nib = (btns >> 4) & 0x0F;
                }
                res |= nib;
                return res;
            } else if (lo == 0x01) {
                return fr.sb;
            } else if (lo == 0x02) {
                return fr.sc | 0x7E;
            } else if (lo == 0x04) {
                return uint8(fr.divc >> 8);
            } else if (lo == 0x05) {
                return fr.tima;
            } else if (lo == 0x06) {
                return fr.tma;
            } else if (lo == 0x07) {
                return 0xF8 | fr.tac;
            } else if (lo == 0x0F) {
                return 0xE0 | fr.iff;
            } else if (lo == 0x40) {
                return fr.lcdc;
            } else if (lo == 0x41) {
                uint8 s = fr.stat;
                // lower 3 bits computed: bit2 LYC match, bits1-0 mode
                s &= 0xF8;
                if (fr.ly == fr.lyc) s |= 0x04;
                s |= (fr.mode & 0x03);
                return s;
            } else if (lo == 0x42) {
                return fr.scy;
            } else if (lo == 0x43) {
                return fr.scx;
            } else if (lo == 0x44) {
                return fr.ly;
            } else if (lo == 0x45) {
                return fr.lyc;
            } else if (lo == 0x46) {
                return 0xFF; // DMA write-only
            } else if (lo == 0x47) {
                return fr.bgp;
            } else if (lo == 0x48) {
                return fr.obp0;
            } else if (lo == 0x49) {
                return fr.obp1;
            } else if (lo == 0x4A) {
                return fr.wy;
            } else if (lo == 0x4B) {
                return fr.wx;
            } else {
                return 0xFF;
            }
        }
    }

    function _readWord(Frame memory fr, uint16 addr) internal view returns (uint16) {
        unchecked {
            uint8 lo = _readByte(fr, addr);
            uint8 hi = _readByte(fr, addr + 1);
            return (uint16(hi) << 8) | lo;
        }
    }

    // ---------- mapped write ----------

    function _writeByte(Frame memory fr, uint16 addr, uint8 v) internal {
        unchecked {
            if (addr < 0x2000) {
                if (mbcType != 0) fr.ramEn = ((v & 0x0F) == 0x0A);
                return;
            } else if (addr < 0x4000) {
                if (mbcType == 1) {
                    uint8 b = v & 0x1F;
                    if (b == 0) b = 1;
                    if (!fr.bankMode) {
                        fr.romBank = (fr.romBank & 0x60) | b;
                    } else {
                        fr.romBank = b;
                    }
                    if (fr.romBank == 0 || fr.romBank == 0x20 || fr.romBank == 0x40 || fr.romBank == 0x60) {
                        fr.romBank += 1;
                    }
                } else if (mbcType == 3) {
                    fr.romBank = v & 0x7F; // 7 bits, bank 0 legal
                } else if (mbcType == 5) {
                    if (addr < 0x3000) fr.romBank = (fr.romBank & 0x100) | v;
                    else fr.romBank = (fr.romBank & 0xFF) | ((uint16(v) & 0x01) << 8);
                }
                return;
            } else if (addr < 0x6000) {
                if (mbcType == 1) {
                    if (!fr.bankMode) {
                        fr.romBank = (fr.romBank & 0x1F) | ((v & 0x03) << 5);
                        if (fr.romBank == 0 || fr.romBank == 0x20 || fr.romBank == 0x40 || fr.romBank == 0x60) {
                            fr.romBank += 1;
                        }
                    } else {
                        fr.ramBank = v & 0x03;
                    }
                } else if (mbcType == 3) {
                    if (v <= 0x03) fr.ramBank = v;
                    // 0x08-0x0C select RTC registers (stubbed; ramBank>=8 gates eram)
                    else if (v <= 0x0C) fr.ramBank = v;
                } else if (mbcType == 5) {
                    fr.ramBank = v & 0x0F; // bit 3 = rumble motor on some carts (ignored)
                }
                return;
            } else if (addr < 0x8000) {
                if (mbcType == 1) fr.bankMode = (v & 0x01) != 0;
                // MBC3 RTC latch + MBC5: nothing latched here (ignored)
                return;
            } else if (addr < 0xA000) {
                vram[addr - 0x8000] = bytes1(v);
                return;
            } else if (addr < 0xC000) {
                if (!fr.ramEn) return;
                uint256 b;
                if (mbcType == 1) {
                    b = fr.bankMode ? fr.ramBank : 0;
                } else if (mbcType == 3) {
                    if (fr.ramBank > 3) return; // RTC select: stubbed
                    b = fr.ramBank;
                } else if (mbcType == 5) {
                    b = fr.ramBank;
                } else {
                    b = 0;
                }
                uint256 off = b * 0x2000 + (addr - 0xA000);
                if (off >= eram.length) return;
                eram[off] = bytes1(v);
                return;
            } else if (addr < 0xE000) {
                wram[addr - 0xC000] = bytes1(v);
                return;
            } else if (addr < 0xFE00) {
                wram[addr - 0xE000] = bytes1(v);
                return;
            } else if (addr < 0xFEA0) {
                oam[addr - 0xFE00] = bytes1(v);
                return;
            } else if (addr < 0xFF00) {
                return;
            } else if (addr < 0xFF80) {
                _writeIO(fr, uint8(addr), v);
                return;
            } else if (addr < 0xFFFF) {
                hram[addr - 0xFF80] = bytes1(v);
                return;
            } else {
                fr.ie = v;
                return;
            }
        }
    }

    function _writeIO(Frame memory fr, uint8 lo, uint8 v) internal {
        unchecked {
            if (lo == 0x00) {
                fr.joy = (fr.joy & 0xCF) | (v & 0x30);
                joypad = fr.joy;
            } else if (lo == 0x01) {
                fr.sb = v;
            } else if (lo == 0x02) {
                fr.sc = v;
                if (v == 0x81) {
                    // instant serial transfer: log only (slim has no capture buffer)
                    emit SerialByte(fr.sb);
                }
            } else if (lo == 0x04) {
                fr.divc = 0;
            } else if (lo == 0x05) {
                fr.tima = v;
            } else if (lo == 0x06) {
                fr.tma = v;
            } else if (lo == 0x07) {
                fr.tac = v & 0x07;
            } else if (lo == 0x0F) {
                fr.iff = v & 0x1F;
            } else if (lo == 0x40) {
                bool wasOn = (fr.lcdc & 0x80) != 0;
                fr.lcdc = v;
                if (wasOn && (v & 0x80) == 0) {
                    fr.ly = 0;
                    fr.mode = 0;
                    fr.ppuCycles = 0;
                }
            } else if (lo == 0x41) {
                fr.stat = (fr.stat & 0x07) | (v & 0xF8);
            } else if (lo == 0x42) {
                fr.scy = v;
            } else if (lo == 0x43) {
                fr.scx = v;
            } else if (lo == 0x44) {
                // LY read-only
            } else if (lo == 0x45) {
                fr.lyc = v;
            } else if (lo == 0x46) {
                _dma(fr, v);
            } else if (lo == 0x47) {
                fr.bgp = v;
            } else if (lo == 0x48) {
                fr.obp0 = v;
            } else if (lo == 0x49) {
                fr.obp1 = v;
            } else if (lo == 0x4A) {
                fr.wy = v;
            } else if (lo == 0x4B) {
                fr.wx = v;
            }
            // other IO ignored
        }
    }

    function _dma(Frame memory fr, uint8 hi) internal {
        unchecked {
            uint16 src = uint16(hi) << 8;
            for (uint16 i = 0; i < 0xA0; i++) {
                uint8 b = _readByte(fr, src + i);
                oam[i] = bytes1(b);
            }
        }
    }

    function _writeWord(Frame memory fr, uint16 addr, uint16 v) internal {
        unchecked {
            _writeByte(fr, addr, uint8(v));
            _writeByte(fr, addr + 1, uint8(v >> 8));
        }
    }

    function _push(Frame memory fr, uint16 v) internal {
        unchecked {
            fr.sp -= 2;
            _writeWord(fr, fr.sp, v);
        }
    }

    function _pop(Frame memory fr) internal returns (uint16) {
        unchecked {
            uint16 v = _readWord(fr, fr.sp);
            fr.sp += 2;
            return v;
        }
    }
}
