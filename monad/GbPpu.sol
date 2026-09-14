// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GbTimer.sol";

/// @title GbPpu — DMG picture processing unit, 160x144x2bpp framebuffer
abstract contract GbPpu is GbTimer {
    /// @dev Advance PPU by `cycles` T-cycles. Finished scanlines go to `out`
    ///      (full 23040B framebuffer, row at ly*160) or, when `emitLine`,
    ///      to a fresh 160B buffer emitted as Scanline (base 0).
    function _tickPpu(
        Frame memory fr,
        uint32 cycles,
        bytes memory out,
        bool emitLine
    ) internal {
        unchecked {
            if ((fr.lcdc & 0x80) == 0) return; // LCD off
            uint32 left = cycles;
            while (left > 0) {
                uint16 need;
                if (fr.ly >= 144) {
                    need = 456 - fr.ppuCycles; // VBlank lines
                } else if (fr.mode == 2) {
                    need = 80 - fr.ppuCycles;
                } else if (fr.mode == 3) {
                    need = 172 - fr.ppuCycles;
                } else {
                    need = 204 - fr.ppuCycles;
                }
                if (left < need) {
                    fr.ppuCycles += uint16(left);
                    break;
                }
                left -= need;
                fr.ppuCycles = 0;
                _ppuAdvance(fr, out, emitLine);
            }
        }
    }

    function _ppuAdvance(
        Frame memory fr,
        bytes memory out,
        bool emitLine
    ) internal {
        unchecked {
            if (fr.ly >= 144) {
                // end of a VBlank line
                fr.ly += 1;
                _lycCheck(fr);
                if (fr.ly > 153) {
                    fr.ly = 0;
                    fr.winLine = 0;
                    fr.mode = 2;
                    _statCheck(fr, true); // OAM int at new line start
                }
                return;
            }
            if (fr.mode == 2) {
                fr.mode = 3;
            } else if (fr.mode == 3) {
                if (emitLine) {
                    fr.lineBuf = new bytes(160);
                    fr.lineBase = 0;
                } else {
                    fr.lineBuf = out;
                    fr.lineBase = uint256(fr.ly) * 160;
                }
                fr.emitLine = emitLine;
                _renderLine(fr, fr.ly);
                fr.mode = 0;
                _statCheck(fr, false);
            } else {
                // end of HBlank: next line
                fr.ly += 1;
                _lycCheck(fr);
                if (fr.ly == 144) {
                    fr.mode = 1;
                    fr.iff |= 0x01; // VBlank interrupt
                    _statCheck(fr, false);
                } else {
                    fr.mode = 2;
                    _statCheck(fr, true);
                }
            }
        }
    }

    function _lycCheck(Frame memory fr) internal pure {
        unchecked {
            // LYC match only affects STAT; interrupt raised in _statCheck
            _statCheck(fr, false);
        }
    }

    /// @dev Recompute STAT line; on rising edge request LCD interrupt.
    /// @param oamStart true when entering mode 2 (OAM STAT fires at line start)
    function _statCheck(Frame memory fr, bool oamStart) internal pure {
        unchecked {
            bool lyMatch = (fr.ly == fr.lyc);
            uint8 en = fr.stat;
            bool line = false;
            if (((en >> 6) & 1) != 0 && lyMatch) line = true;
            if (((en >> 5) & 1) != 0 && oamStart && fr.ly < 144) line = true;
            if (((en >> 4) & 1) != 0 && fr.mode == 1) line = true;
            if (((en >> 3) & 1) != 0 && fr.mode == 0 && fr.ly < 144) line = true;
            if (line && !fr.statLine) fr.iff |= 0x02;
            fr.statLine = line;
        }
    }

    /// @dev Scanline renderer in Yul: OAM scan + BG/window/sprite pixels.
    ///      Params packed to respect the 16-slot EVM stack (unpacked once/line):
    ///      pA = bgp[0:8] obp0[8:16] obp1[16:24] scx[24:32] scy[32:40] winRow[40:48]
    ///      pB = wy[0:8] wx[8:16] ly[16:24] lcdc[24:32]
    ///      All memory reads are bounds-safe by construction (same guarantees
    ///      as the Solidity version this replaces): vram offs < 0x2000,
    ///      oam offs < 0xA0, fb index = ly*160+x < 23040 (ly < 144).
    function _renderLine(Frame memory fr, uint8 ly) internal {
        uint256 pA = uint256(fr.bgp)
            | (uint256(fr.obp0) << 8)
            | (uint256(fr.obp1) << 16)
            | (uint256(fr.scx) << 24)
            | (uint256(fr.scy) << 32)
            | (uint256(fr.winLine) << 40);
        uint256 pB = uint256(fr.wy)
            | (uint256(fr.wx) << 8)
            | (uint256(ly) << 16)
            | (uint256(fr.lcdc) << 24);
        bytes memory lineBuf = fr.lineBuf;
        uint256 rowPtr;
        {
            uint256 base = fr.lineBase;
            assembly {
                rowPtr := add(add(lineBuf, 32), base)
            }
        }
        uint256 winInc;
        assembly {
            // ---- scratch layout (words): ----
            // 0:bgBase 1:winBase 2:bgp 3:scx 4:rowBase 5:winRow 6:winActive
            // 7:wx 8:signed 9:bgOn 10:sprH 11:obp0 12:obp1 13:ckey 14:cpx
            // 15:nSpr 16:sprMem -- sprite data (10 words) follows at +576
            function mst(st, i, v) {
                mstore(add(st, mul(i, 32)), v)
            }
            function mld(st, i) -> v {
                v := mload(add(st, mul(i, 32)))
            }
            function memByte(base, off) -> b {
                b := byte(mod(off, 32), sload(add(base, div(off, 32))))
            }
            function palOf(pal, idx) -> s {
                s := and(shr(mul(idx, 2), pal), 3)
            }
            // ---- setup: unpack pA/pB, decode lcdc, fill scratch ----
            let scratch := mload(0x40)
            mstore(0x40, add(scratch, 1024))
            let bgp_ := and(pA, 0xff)
            mst(scratch, 2, bgp_)
            mst(scratch, 11, and(shr(8, pA), 0xff))
            mst(scratch, 12, and(shr(16, pA), 0xff))
            mst(scratch, 3, and(shr(24, pA), 0xff))
            let scy_ := and(shr(32, pA), 0xff)
            mst(scratch, 5, and(shr(40, pA), 0xff))
            let wy_ := and(pB, 0xff)
            let wx_ := and(shr(8, pB), 0xff)
            let lyv := and(shr(16, pB), 0xff)
            let lcdc := and(shr(24, pB), 0xff)
            let bgOn_ := and(lcdc, 1)
            mst(scratch, 9, bgOn_)
            if and(lcdc, 8) { mst(scratch, 0, 0x9C00) }
            if iszero(and(lcdc, 8)) { mst(scratch, 0, 0x9800) }
            mst(scratch, 8, iszero(and(lcdc, 0x10)))
            if and(lcdc, 0x40) { mst(scratch, 1, 0x9C00) }
            if iszero(and(lcdc, 0x40)) { mst(scratch, 1, 0x9800) }
            let sprH_ := 8
            if and(lcdc, 4) { sprH_ := 16 }
            mst(scratch, 10, sprH_)
            mst(scratch, 6, and(and(iszero(iszero(and(lcdc, 0x20))), iszero(iszero(bgOn_))), and(iszero(lt(lyv, wy_)), lt(wx_, 167))))
            mst(scratch, 4, and(add(lyv, scy_), 0xff))
            mst(scratch, 7, wx_)
            mst(scratch, 13, 0xFFFFFFFF)
            mst(scratch, 15, 0)
            mst(scratch, 16, add(scratch, 576))
            mst(scratch, 17, iszero(iszero(and(lcdc, 2))))
            mstore(0, vram.slot)
            let vbase := keccak256(0, 0x20)
            // ---- oam scan (first 10 qualifying, OAM order) ----
            // sprite word pack: ox[24:32] tile[16:24] attr[8:16] srow[0:8]
            function yScan(st, obase, lyv_) {
                let nSpr_ := 0
                let sprMem_ := mload(add(st, 512))
                let sh_ := mload(add(st, 320))
                let lyy := add(lyv_, 16)
                for { let s := 0 } and(lt(s, 40), lt(nSpr_, 10)) { s := add(s, 1) } {
                    let o := mul(s, 4)
                    let oy := byte(mod(o, 32), sload(add(obase, div(o, 32))))
                    if and(iszero(lt(lyy, oy)), lt(lyy, add(oy, sh_))) {
                        let o1 := add(o, 1)
                        let o2 := add(o, 2)
                        let o3 := add(o, 3)
                        let w :=
                            or(
                                shl(24, byte(mod(o1, 32), sload(add(obase, div(o1, 32))))),
                                or(
                                    shl(16, byte(mod(o2, 32), sload(add(obase, div(o2, 32))))),
                                    or(
                                        shl(8, byte(mod(o3, 32), sload(add(obase, div(o3, 32))))),
                                        sub(lyy, oy)
                                    )
                                )
                            )
                        mstore(add(sprMem_, mul(nSpr_, 32)), w)
                        nSpr_ := add(nSpr_, 1)
                    }
                }
                mstore(add(st, 480), nSpr_)
            }
            // ---- pixel helpers (scratch-backed; tiny frames) ----
            function yBg(st, vb, x) -> shade, bgIdx {
                shade := 0
                bgIdx := 0
                if iszero(mload(add(st, 288))) {
                    shade := and(mload(add(st, 64)), 3)
                    leave
                }
                let useWin := 0
                let px := 0
                let row := mload(add(st, 128))
                let mapBase := mload(add(st, 0))
                if mload(add(st, 192)) {
                    let wx2 := mload(add(st, 224))
                    if iszero(slt(x, sub(wx2, 7))) {
                        useWin := 1
                        px := and(add(sub(x, wx2), 7), 0xff)
                        row := mload(add(st, 160))
                        mapBase := mload(add(st, 32))
                    }
                }
                if iszero(useWin) {
                    px := and(add(mload(add(st, 96)), x), 0xff)
                }
                let mapAddr := add(add(mapBase, shl(5, shr(3, row))), shr(3, px))
                let key := or(shl(3, mapAddr), and(row, 7))
                let lo := 0
                let hi := 0
                if eq(key, mload(add(st, 416))) {
                    let cpx := mload(add(st, 448))
                    lo := and(shr(8, cpx), 0xff)
                    hi := and(cpx, 0xff)
                }
                if iszero(eq(key, mload(add(st, 416)))) {
                    let maddr := sub(mapAddr, 0x8000)
                    let tileIdx := byte(mod(maddr, 32), sload(add(vb, div(maddr, 32))))
                    let troff := 0
                    if mload(add(st, 256)) {
                        troff :=
                            add(
                                add(0x1000, mul(signextend(0, tileIdx), 16)),
                                mul(and(row, 7), 2)
                            )
                    }
                    if iszero(mload(add(st, 256))) {
                        troff := add(mul(tileIdx, 16), mul(and(row, 7), 2))
                    }
                    lo := byte(mod(troff, 32), sload(add(vb, div(troff, 32))))
                    hi := byte(mod(add(troff, 1), 32), sload(add(vb, div(add(troff, 1), 32))))
                    mstore(add(st, 416), key)
                    mstore(add(st, 448), or(shl(8, lo), hi))
                }
                let bit := sub(7, and(px, 7))
                bgIdx := or(shl(1, and(shr(bit, hi), 1)), and(shr(bit, lo), 1))
                shade := and(shr(mul(bgIdx, 2), mload(add(st, 64))), 3)
            }
            function yWin(st, x) -> bi {
                bi := 10
                let wBest := 300
                let wnS := mld(st, 15)
                let wnM := mld(st, 16)
                for { let j := 0 } lt(j, wnS) { j := add(j, 1) } {
                    let wox := shr(24, mload(add(wnM, mul(j, 32))))
                    let wxx := add(x, 8)
                    if and(iszero(lt(wxx, wox)), lt(wxx, add(wox, 8))) {
                        if lt(wox, wBest) {
                            wBest := wox
                            bi := j
                        }
                    }
                }
            }
            function yPix(st, vb2, bi, x, bgIdx) -> shade, hit {
                shade := 0
                hit := 0
                let pw := mload(add(mld(st, 16), mul(bi, 32)))
                let pox := shr(24, pw)
                let tile := and(shr(16, pw), 0xff)
                let attr := and(shr(8, pw), 0xff)
                let srow := and(pw, 0xff)
                let sprH2 := mld(st, 10)
                if and(attr, 0x40) { srow := sub(sub(sprH2, 1), srow) }
                if eq(sprH2, 16) {
                    if lt(srow, 8) { tile := and(tile, 0xFE) }
                    if iszero(lt(srow, 8)) { tile := or(tile, 1) }
                    if iszero(lt(srow, 8)) { srow := sub(srow, 8) }
                }
                let toff := add(mul(tile, 16), mul(srow, 2))
                let plo := memByte(vb2, toff)
                let phi := memByte(vb2, add(toff, 1))
                let pdx := sub(add(x, 8), pox)
                let pbit := sub(7, pdx)
                if and(attr, 0x20) { pbit := pdx }
                let spIdx := or(shl(1, and(shr(pbit, phi), 1)), and(shr(pbit, plo), 1))
                if iszero(spIdx) { leave }
                // behind iff attr bit7 set AND bg color nonzero (logical, not bitwise!)
                if and(iszero(iszero(and(attr, 0x80))), iszero(iszero(bgIdx))) { leave }
                let pal := mld(st, 11)
                if and(attr, 0x10) { pal := mld(st, 12) }
                shade := palOf(pal, spIdx)
                hit := 1
            }
            // ---- run scan + pixels ----
            mstore(0, oam.slot)
            if mld(scratch, 17) { yScan(scratch, keccak256(0, 0x20), lyv) }
            let nSpr0 := mld(scratch, 15)
            for { let x := 0 } lt(x, 160) { x := add(x, 1) } {
                let sh, bgi := yBg(scratch, vbase, x)
                if nSpr0 {
                    let wi := yWin(scratch, x)
                    if iszero(eq(wi, 10)) {
                        let sps, sph := yPix(scratch, vbase, wi, x, bgi)
                        if sph { sh := sps }
                    }
                }
                mstore8(add(rowPtr, x), sh)
            }
            winInc := mld(scratch, 6)
        }
        unchecked {
            if (winInc != 0) fr.winLine += 1;
        }
        if (fr.emitLine) emit Scanline(fr.frameNo, ly, lineBuf);
    }


}
