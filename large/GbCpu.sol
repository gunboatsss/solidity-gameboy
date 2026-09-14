// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GbPpu.sol";

/// @title GbCpu — Sharp LR35902 core, z80-style x/y/z decode
/// @notice Cycle counts are T-cycles (4 per M-cycle).
abstract contract GbCpu is GbPpu {
    // ---------- register file helpers (r index: 0=B 1=C 2=D 3=E 4=H 5=L 6=(HL) 7=A) ----------

    function _getR(Frame memory fr, uint8 idx, uint16 hl) internal view returns (uint8) {
        unchecked {
            if (idx == 0) return fr.b;
            if (idx == 1) return fr.c;
            if (idx == 2) return fr.d;
            if (idx == 3) return fr.e;
            if (idx == 4) return fr.h;
            if (idx == 5) return fr.l;
            if (idx == 7) return fr.a;
            return _readByte(fr, hl); // idx 6
        }
    }

    function _setR(Frame memory fr, uint8 idx, uint16 hl, uint8 v) internal {
        unchecked {
            if (idx == 0) fr.b = v;
            else if (idx == 1) fr.c = v;
            else if (idx == 2) fr.d = v;
            else if (idx == 3) fr.e = v;
            else if (idx == 4) fr.h = v;
            else if (idx == 5) fr.l = v;
            else if (idx == 7) fr.a = v;
            else _writeByte(fr, hl, v); // idx 6
        }
    }

    function _hl(Frame memory fr) internal pure returns (uint16) {
        return (uint16(fr.h) << 8) | fr.l;
    }

    function _fetch(Frame memory fr) internal returns (uint8) {
        unchecked {
            uint8 v;
            if (fr.haltBug) {
                fr.haltBug = false;
                v = _readByte(fr, fr.pc); // re-fetch without increment
            } else {
                v = _readByte(fr, fr.pc);
                fr.pc += 1;
            }
            return v;
        }
    }

    function _cond(Frame memory fr, uint8 cc) internal pure returns (bool) {
        unchecked {
            if (cc == 0) return (fr.f & F_Z) == 0; // NZ
            if (cc == 1) return (fr.f & F_Z) != 0; // Z
            if (cc == 2) return (fr.f & F_C) == 0; // NC
            return (fr.f & F_C) != 0; // C
        }
    }

    // ---------- ALU ----------

    function _aluAdd(Frame memory fr, uint8 v, bool withCarry) internal pure {
        unchecked {
            uint16 c = (withCarry && (fr.f & F_C) != 0) ? 1 : 0;
            uint16 res = uint16(fr.a) + v + c;
            uint8 r = uint8(res);
            uint8 fl = 0;
            if (r == 0) fl |= F_Z;
            if (((fr.a & 0xF) + (v & 0xF) + uint8(c)) > 0xF) fl |= F_H;
            if (res > 0xFF) fl |= F_C;
            fr.a = r;
            fr.f = fl;
        }
    }

    function _aluSub(Frame memory fr, uint8 v, bool withCarry, bool store) internal pure {
        unchecked {
            uint16 c = (withCarry && (fr.f & F_C) != 0) ? 1 : 0;
            uint16 res = uint16(fr.a) - v - c;
            uint8 r = uint8(res);
            uint8 fl = F_N;
            if (r == 0) fl |= F_Z;
            if ((fr.a & 0xF) < ((v & 0xF) + uint8(c))) fl |= F_H;
            if (uint16(fr.a) < uint16(v) + c) fl |= F_C;
            if (store) fr.a = r;
            fr.f = fl;
        }
    }

    /// @dev Shared ALU dispatch: 0=ADD 1=ADC 2=SUB 3=SBC 4=AND 5=XOR 6=OR 7=CP
    function _alu(Frame memory fr, uint8 op, uint8 v) internal pure {
        unchecked {
            if (op == 0) _aluAdd(fr, v, false);
            else if (op == 1) _aluAdd(fr, v, true);
            else if (op == 2) _aluSub(fr, v, false, true);
            else if (op == 3) _aluSub(fr, v, true, true);
            else if (op == 4) {
                fr.a &= v;
                fr.f = (fr.a == 0 ? F_Z : 0) | F_H;
            } else if (op == 5) {
                fr.a ^= v;
                fr.f = fr.a == 0 ? F_Z : 0;
            } else if (op == 6) {
                fr.a |= v;
                fr.f = fr.a == 0 ? F_Z : 0;
            } else {
                _aluSub(fr, v, false, false);
            }
        }
    }

    function _daa(Frame memory fr) internal pure {
        unchecked {
            uint8 a = fr.a;
            uint8 fl = fr.f;
            uint8 adj = 0;
            bool c = (fl & F_C) != 0;
            if ((fl & F_N) == 0) {
                if ((fl & F_H) != 0 || (a & 0x0F) > 0x09) adj |= 0x06;
                if (c || a > 0x99) {
                    adj |= 0x60;
                    c = true;
                }
                a += adj;
            } else {
                if ((fl & F_H) != 0) adj |= 0x06;
                if (c) adj |= 0x60;
                a -= adj;
            }
            fl &= ~(F_H | F_Z);
            if (a == 0) fl |= F_Z;
            if (c) fl |= F_C;
            else fl &= ~F_C;
            fr.a = a;
            fr.f = fl;
        }
    }

    // ---------- CB-prefixed ----------

    function _stepCB(Frame memory fr) internal returns (uint32) {
        unchecked {
            uint8 op = _fetch(fr);
            uint8 x = op >> 6;
            uint8 y = (op >> 3) & 7;
            uint8 z = op & 7;
            uint16 hl = _hl(fr);
            bool isHL = (z == 6);
            uint8 v = _getR(fr, z, hl);
            if (x == 0) {
                // rotates / shifts
                uint8 res;
                uint8 c;
                if (y == 0) {
                    // RLC
                    c = v >> 7;
                    res = (v << 1) | c;
                } else if (y == 1) {
                    // RRC
                    c = v & 1;
                    res = (v >> 1) | (c << 7);
                } else if (y == 2) {
                    // RL
                    c = v >> 7;
                    res = (v << 1) | ((fr.f & F_C) != 0 ? 1 : 0);
                } else if (y == 3) {
                    // RR
                    c = v & 1;
                    res = (v >> 1) | ((fr.f & F_C) != 0 ? 0x80 : 0);
                } else if (y == 4) {
                    // SLA
                    c = v >> 7;
                    res = v << 1;
                } else if (y == 5) {
                    // SRA
                    c = v & 1;
                    res = (v >> 1) | (v & 0x80);
                } else if (y == 6) {
                    // SWAP
                    res = (v << 4) | (v >> 4);
                    _setR(fr, z, hl, res);
                    fr.f = res == 0 ? F_Z : 0;
                    return isHL ? 16 : 8;
                } else {
                    // SRL
                    c = v & 1;
                    res = v >> 1;
                }
                _setR(fr, z, hl, res);
                fr.f = (res == 0 ? F_Z : 0) | (c != 0 ? F_C : 0);
                return isHL ? 16 : 8;
            } else if (x == 1) {
                // BIT y,z
                bool bit = ((v >> y) & 1) != 0;
                fr.f = (fr.f & F_C) | F_H | (bit ? 0 : F_Z);
                return isHL ? 12 : 8;
            } else if (x == 2) {
                // RES y,z
                _setR(fr, z, hl, v & ~(uint8(1 << y)));
                return isHL ? 16 : 8;
            } else {
                // SET y,z
                _setR(fr, z, hl, v | (uint8(1 << y)));
                return isHL ? 16 : 8;
            }
        }
    }

    // ---------- main step: returns T-cycles consumed by the instruction ----------

    function _step(Frame memory fr) internal returns (uint32) {
        unchecked {
            if (fr.halted) return 4; // wait out the halt
            uint8 op = _fetch(fr);
            uint8 x = op >> 6;
            uint8 y = (op >> 3) & 7;
            uint8 z = op & 7;
            uint8 p = y >> 1;
            uint8 q = y & 1;

            if (x == 0) {
                if (z == 0) {
                    if (y == 0) return 4; // NOP
                    if (y == 1) {
                        // LD (nn),SP
                        uint8 lo = _fetch(fr);
                        uint8 hi = _fetch(fr);
                        _writeWord(fr, (uint16(hi) << 8) | lo, fr.sp);
                        return 20;
                    }
                    if (y == 2) {
                        _fetch(fr); // STOP: skip next byte
                        return 4;
                    }
                    // JR / JR cc
                    int8 d = int8(_fetch(fr));
                    bool take = (y == 3) || _cond(fr, y - 4);
                    if (take) {
                        fr.pc = uint16(int16(fr.pc) + d);
                        return 12;
                    }
                    return 8;
                }
                if (z == 1) {
                    // LD rr,nn / ADD HL,rr ; rp = p: BC DE HL SP
                    if (q == 0) {
                        uint8 lo = _fetch(fr);
                        uint8 hi = _fetch(fr);
                        if (p == 0) {
                            fr.b = hi;
                            fr.c = lo;
                        } else if (p == 1) {
                            fr.d = hi;
                            fr.e = lo;
                        } else if (p == 2) {
                            fr.h = hi;
                            fr.l = lo;
                        } else {
                            fr.sp = (uint16(hi) << 8) | lo;
                        }
                        return 12;
                    } else {
                        uint16 rr = p == 0
                            ? (uint16(fr.b) << 8) | fr.c
                            : p == 1
                                ? (uint16(fr.d) << 8) | fr.e
                                : p == 2
                                    ? _hl(fr)
                                    : fr.sp;
                        uint32 hlv = _hl(fr);
                        uint32 res = hlv + rr;
                        uint8 fl = fr.f & F_Z;
                        if (((hlv & 0xFFF) + (rr & 0xFFF)) > 0xFFF) fl |= F_H;
                        if (res > 0xFFFF) fl |= F_C;
                        fr.h = uint8(res >> 8);
                        fr.l = uint8(res);
                        fr.f = fl;
                        return 8;
                    }
                }
                if (z == 2) {
                    // LD (rr),A (y even) / LD A,(rr) (y odd) ; p=y>>1: 0 BC,1 DE,2 HL+,3 HL-
                    uint16 hlv = _hl(fr);
                    uint8 p2 = y >> 1;
                    uint16 addr = p2 == 0
                        ? (uint16(fr.b) << 8) | fr.c
                        : p2 == 1
                            ? (uint16(fr.d) << 8) | fr.e
                            : hlv;
                    if ((y & 1) == 0) {
                        _writeByte(fr, addr, fr.a);
                    } else {
                        fr.a = _readByte(fr, addr);
                    }
                    if (p2 == 2) {
                        hlv += 1;
                        fr.h = uint8(hlv >> 8);
                        fr.l = uint8(hlv);
                    } else if (p2 == 3) {
                        hlv -= 1;
                        fr.h = uint8(hlv >> 8);
                        fr.l = uint8(hlv);
                    }
                    return 8;
                }
                if (z == 3) {
                    // INC rr / DEC rr
                    uint16 rr = p == 0
                        ? (uint16(fr.b) << 8) | fr.c
                        : p == 1
                            ? (uint16(fr.d) << 8) | fr.e
                            : p == 2 ? _hl(fr) : fr.sp;
                    rr = q == 0 ? rr + 1 : rr - 1;
                    if (p == 0) {
                        fr.b = uint8(rr >> 8);
                        fr.c = uint8(rr);
                    } else if (p == 1) {
                        fr.d = uint8(rr >> 8);
                        fr.e = uint8(rr);
                    } else if (p == 2) {
                        fr.h = uint8(rr >> 8);
                        fr.l = uint8(rr);
                    } else {
                        fr.sp = rr;
                    }
                    return 8;
                }
                if (z == 4 || z == 5) {
                    // INC r / DEC r (preserves C)
                    uint16 hlv = _hl(fr);
                    uint8 v = _getR(fr, y, hlv);
                    uint8 r;
                    uint8 fl = fr.f & F_C;
                    if (z == 4) {
                        r = v + 1;
                        if (r == 0) fl |= F_Z;
                        if ((v & 0xF) == 0xF) fl |= F_H;
                    } else {
                        r = v - 1;
                        fl |= F_N;
                        if (r == 0) fl |= F_Z;
                        if ((v & 0xF) == 0) fl |= F_H;
                    }
                    _setR(fr, y, hlv, r);
                    fr.f = fl;
                    return y == 6 ? 12 : 4;
                }
                if (z == 6) {
                    uint8 n = _fetch(fr);
                    _setR(fr, y, _hl(fr), n);
                    return y == 6 ? 12 : 8;
                }
                // z == 7: rotates / DAA / CPL / SCF / CCF
                if (y == 0) {
                    // RLCA
                    uint8 c = fr.a >> 7;
                    fr.a = (fr.a << 1) | c;
                    fr.f = c != 0 ? F_C : 0;
                } else if (y == 1) {
                    // RRCA
                    uint8 c = fr.a & 1;
                    fr.a = (fr.a >> 1) | (c << 7);
                    fr.f = c != 0 ? F_C : 0;
                } else if (y == 2) {
                    // RLA
                    uint8 c = fr.a >> 7;
                    fr.a = (fr.a << 1) | ((fr.f & F_C) != 0 ? 1 : 0);
                    fr.f = c != 0 ? F_C : 0;
                } else if (y == 3) {
                    // RRA
                    uint8 c = fr.a & 1;
                    fr.a = (fr.a >> 1) | ((fr.f & F_C) != 0 ? 0x80 : 0);
                    fr.f = c != 0 ? F_C : 0;
                } else if (y == 4) {
                    _daa(fr);
                } else if (y == 5) {
                    fr.a = ~fr.a;
                    fr.f |= (F_N | F_H);
                } else if (y == 6) {
                    fr.f = (fr.f & F_Z) | F_C;
                } else {
                    // CCF
                    fr.f = (fr.f & F_Z) | (((fr.f & F_C) != 0) ? 0 : F_C);
                }
                return 4;
            }

            if (x == 1) {
                if (y == 6 && z == 6) {
                    // HALT
                    uint8 pend = fr.iff & fr.ie & 0x1F;
                    if (!fr.ime && pend != 0) {
                        fr.haltBug = true; // HALT bug: next fetch duplicated
                    } else {
                        fr.halted = true;
                    }
                    return 4;
                }
                uint16 hlv = _hl(fr);
                uint8 v = _getR(fr, z, hlv);
                _setR(fr, y, hlv, v);
                return (y == 6 || z == 6) ? 8 : 4;
            }

            if (x == 2) {
                uint16 hlv = _hl(fr);
                _alu(fr, y, _getR(fr, z, hlv));
                return z == 6 ? 8 : 4;
            }

            // x == 3
            if (z == 0) {
                if (y < 4) {
                    // RET cc
                    if (_cond(fr, y)) {
                        fr.pc = _pop(fr);
                        return 20;
                    }
                    return 8;
                }
                if (y == 4) {
                    // LDH (n),A
                    uint8 n = _fetch(fr);
                    _writeByte(fr, 0xFF00 | n, fr.a);
                    return 12;
                }
                if (y == 5) {
                    // ADD SP,d
                    int8 d = int8(_fetch(fr));
                    uint16 sp = fr.sp;
                    uint8 ud = uint8(d);
                    uint16 res = uint16(int16(sp) + d);
                    uint8 fl = 0;
                    if (((sp & 0xF) + (ud & 0xF)) > 0xF) fl |= F_H;
                    if (((sp & 0xFF) + ud) > 0xFF) fl |= F_C;
                    fr.sp = res;
                    fr.f = fl;
                    return 16;
                }
                if (y == 6) {
                    // LDH A,(n)
                    uint8 n = _fetch(fr);
                    fr.a = _readByte(fr, 0xFF00 | n);
                    return 12;
                }
                // LD HL,SP+d
                int8 d2 = int8(_fetch(fr));
                uint16 sp2 = fr.sp;
                uint8 ud2 = uint8(d2);
                uint16 res2 = uint16(int16(sp2) + d2);
                uint8 fl2 = 0;
                if (((sp2 & 0xF) + (ud2 & 0xF)) > 0xF) fl2 |= F_H;
                if (((sp2 & 0xFF) + ud2) > 0xFF) fl2 |= F_C;
                fr.h = uint8(res2 >> 8);
                fr.l = uint8(res2);
                fr.f = fl2;
                return 12;
            }
            if (z == 1) {
                if (q == 0) {
                    // POP rr (p: BC DE HL AF)
                    uint16 v = _pop(fr);
                    if (p == 0) {
                        fr.b = uint8(v >> 8);
                        fr.c = uint8(v);
                    } else if (p == 1) {
                        fr.d = uint8(v >> 8);
                        fr.e = uint8(v);
                    } else if (p == 2) {
                        fr.h = uint8(v >> 8);
                        fr.l = uint8(v);
                    } else {
                        fr.a = uint8(v >> 8);
                        fr.f = uint8(v) & 0xF0;
                    }
                    return 12;
                }
                if (y == 1) {
                    fr.pc = _pop(fr); // RET (0xC9)
                    return 16;
                }
                if (y == 3) {
                    fr.pc = _pop(fr); // RETI (0xD9)
                    fr.ime = true;
                    return 16;
                }
                if (y == 5) {
                    fr.pc = _hl(fr); // JP HL (0xE9)
                    return 4;
                }
                if (y == 7) {
                    fr.sp = _hl(fr); // LD SP,HL (0xF9)
                    return 8;
                }
                return 4; // invalid
            }
            if (z == 2) {
                if (y < 4) {
                    // JP cc,nn
                    uint8 lo = _fetch(fr);
                    uint8 hi = _fetch(fr);
                    if (_cond(fr, y)) {
                        fr.pc = (uint16(hi) << 8) | lo;
                        return 16;
                    }
                    return 12;
                }
                if (y == 4) {
                    // LD (C),A
                    _writeByte(fr, 0xFF00 | fr.c, fr.a);
                    return 8;
                }
                if (y == 5) {
                    // LD (nn),A
                    uint8 lo = _fetch(fr);
                    uint8 hi = _fetch(fr);
                    _writeByte(fr, (uint16(hi) << 8) | lo, fr.a);
                    return 16;
                }
                if (y == 6) {
                    // LD A,(C)
                    fr.a = _readByte(fr, 0xFF00 | fr.c);
                    return 8;
                }
                // LD A,(nn)
                uint8 lo = _fetch(fr);
                uint8 hi = _fetch(fr);
                fr.a = _readByte(fr, (uint16(hi) << 8) | lo);
                return 16;
            }
            if (z == 3) {
                if (y == 0) {
                    // JP nn
                    uint8 lo = _fetch(fr);
                    uint8 hi = _fetch(fr);
                    fr.pc = (uint16(hi) << 8) | lo;
                    return 16;
                }
                if (y == 1) return _stepCB(fr); // 0xCB prefix
                if (y == 6) {
                    fr.ime = false; // DI (also clears pending EI)
                    fr.eiPending = false;
                    return 4;
                }
                if (y == 7) {
                    fr.eiPending = true; // EI (delayed)
                    return 4;
                }
                return 4; // invalid D3/DB/E3/EB/F3-gap: NOP
            }
            if (z == 4) {
                if (y < 4) {
                    // CALL cc,nn
                    uint8 lo = _fetch(fr);
                    uint8 hi = _fetch(fr);
                    if (_cond(fr, y)) {
                        _push(fr, fr.pc);
                        fr.pc = (uint16(hi) << 8) | lo;
                        return 24;
                    }
                    return 12;
                }
                return 4; // invalid E4/EC/F4/FC: NOP
            }
            if (z == 5) {
                if (q == 0) {
                    // PUSH rr
                    uint16 v = p == 0
                        ? (uint16(fr.b) << 8) | fr.c
                        : p == 1
                            ? (uint16(fr.d) << 8) | fr.e
                            : p == 2
                                ? _hl(fr)
                                : (uint16(fr.a) << 8) | (fr.f & 0xF0);
                    _push(fr, v);
                    return 16;
                }
                if (y == 1) {
                    // CALL nn
                    uint8 lo = _fetch(fr);
                    uint8 hi = _fetch(fr);
                    _push(fr, fr.pc);
                    fr.pc = (uint16(hi) << 8) | lo;
                    return 24;
                }
                return 4; // invalid DD/ED/FD: NOP
            }
            if (z == 6) {
                // ALU n
                uint8 n = _fetch(fr);
                _alu(fr, y, n);
                return 8;
            }
            // RST vec
            _push(fr, fr.pc);
            fr.pc = uint16(y) * 8;
            return 16;
        }
    }
}
