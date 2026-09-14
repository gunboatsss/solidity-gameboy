// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GameBoy.sol";
import "../src/GameBoyHelper.sol";

/// @notice Bring-up tests with hand-assembled ROMs (entry at 0x100).
///         State is read exclusively through GameBoyHelper (external pattern).
contract GameBoyTest is Test {
    GameBoy gb;
    GameBoyHelper helper;

    function setUp() public {
        gb = new GameBoy();
        helper = new GameBoyHelper();
    }

    function _mkRom() internal pure returns (bytes memory rom) {
        rom = new bytes(0x8000);
    }

    function _load(bytes memory rom) internal {
        gb.loadRom(rom);
    }

    function test_LdAddLoop() public {
        bytes memory rom = _mkRom();
        rom[0x100] = bytes1(0x3E); // LD A,0x42
        rom[0x101] = bytes1(0x42);
        rom[0x102] = bytes1(0x06); // LD B,0x10
        rom[0x103] = bytes1(0x10);
        rom[0x104] = bytes1(0x80); // ADD A,B
        rom[0x105] = bytes1(0xC3); // JP 0x0105
        rom[0x106] = bytes1(0x05);
        rom[0x107] = bytes1(0x01);
        _load(rom);

        gb.step(4, 0); // LD A
        gb.step(4, 0); // LD B
        (uint8 a,, uint8 b,,,,,,, uint16 pc) = helper.regs(gb);
        assertEq(a, 0x42);
        gb.step(4, 0); // ADD
        (a,, b,,,,,,,) = helper.regs(gb);
        assertEq(a, 0x52);
        assertEq(b, 0x10);
        (,,,,,,,,, pc) = helper.regs(gb);
        assertEq(pc, 0x0105);
        gb.step(4, 0); // JP -> 0x0105
        (,,,,,,,,, pc) = helper.regs(gb);
        assertEq(pc, 0x0105);
    }

    function test_FlagsHalfCarry() public {
        bytes memory rom = _mkRom();
        rom[0x100] = bytes1(0x3E); // LD A,0x0F
        rom[0x101] = bytes1(0x0F);
        rom[0x102] = bytes1(0xC6); // ADD A,0x01
        rom[0x103] = bytes1(0x01);
        rom[0x104] = bytes1(0xD6); // SUB 0x01
        rom[0x105] = bytes1(0x01);
        rom[0x106] = bytes1(0x00); // NOP
        _load(rom);
        gb.step(4, 0);
        gb.step(4, 0); // A = 0x10, H set
        (, uint8 f,,,,,,,,) = helper.regs(gb);
        assertEq(f & 0x20, 0x20); // H
        assertEq(f & 0x80, 0x00); // not Z
        gb.step(4, 0); // A = 0x0F, N+H set
        (, f,,,,,,,,) = helper.regs(gb);
        assertEq(f & 0x40, 0x40); // N
        assertEq(f & 0x20, 0x20); // H
    }

    function test_CbBitSetRes() public {
        bytes memory rom = _mkRom();
        rom[0x100] = bytes1(0x3E); // LD A,0x01
        rom[0x101] = bytes1(0x01);
        rom[0x102] = bytes1(0xCB); // BIT 0,A (Z=0)
        rom[0x103] = bytes1(0x47);
        rom[0x104] = bytes1(0xCB); // BIT 1,A (Z=1)
        rom[0x105] = bytes1(0x4F);
        rom[0x106] = bytes1(0xCB); // SET 7,A
        rom[0x107] = bytes1(0xFF);
        rom[0x108] = bytes1(0x00);
        _load(rom);
        gb.step(4, 0);
        gb.step(4, 0);
        (, uint8 f,,,,,,,,) = helper.regs(gb);
        assertEq(f & 0x80, 0x00); // bit0 set -> Z clear
        gb.step(4, 0);
        (, f,,,,,,,,) = helper.regs(gb);
        assertEq(f & 0x80, 0x80); // bit1 clear -> Z set
        gb.step(4, 0);
        (uint8 a,,,,,,,,,) = helper.regs(gb);
        assertEq(a, 0x81);
    }

    function test_CallRetPushPop() public {
        bytes memory rom = _mkRom();
        rom[0x100] = bytes1(0xCD); // CALL 0x0105
        rom[0x101] = bytes1(0x05);
        rom[0x102] = bytes1(0x01);
        rom[0x103] = bytes1(0x00); // NOP (return target)
        rom[0x104] = bytes1(0x00);
        rom[0x105] = bytes1(0xC9); // RET
        _load(rom);
        gb.step(4, 0); // CALL
        (,,,,,,,,, uint16 pc) = helper.regs(gb);
        assertEq(pc, 0x0105);
        gb.step(4, 0); // RET
        (,,,,,,,,, pc) = helper.regs(gb);
        assertEq(pc, 0x0103);
    }

    function test_TimerDivIncrements() public {
        bytes memory rom = _mkRom();
        rom[0x100] = bytes1(0x00); // NOP sled
        _load(rom);
        gb.step(256, 0);
        (,, uint8 div1,,,,,) = helper.ioState(gb);
        assertEq(div1, 1);
        gb.step(256, 0);
        (,, uint8 div2,,,,,) = helper.ioState(gb);
        assertEq(div2, 2);
    }

    function test_TimerTimaInterrupt() public {
        bytes memory rom = _mkRom();
        // TAC=0x05 (freq01: tick every 16 T-cycles), TIMA=0xFC, TMA=0x10, then JR-self loop.
        // Ticks at divc=16,32,48 (TIMA->0xFF), overflow at divc=64 -> TIMA=TMA, IF.timer set.
        uint8[] memory prog = new uint8[](14);
        prog[0] = 0x3E;
        prog[1] = 0x05;
        prog[2] = 0xE0;
        prog[3] = 0x07; // LDH (TAC),A
        prog[4] = 0x3E;
        prog[5] = 0xFC;
        prog[6] = 0xE0;
        prog[7] = 0x05; // LDH (TIMA),A
        prog[8] = 0x3E;
        prog[9] = 0x10;
        prog[10] = 0xE0;
        prog[11] = 0x06; // LDH (TMA),A
        prog[12] = 0x18;
        prog[13] = 0xFE; // JR -2 (12 T-cycles)
        for (uint256 i = 0; i < prog.length; i++) rom[0x100 + i] = bytes1(prog[i]);
        _load(rom);
        // setup = 60 cycles; JR iters land divc at 72 (overflow crossed, next tick at 80 not yet)
        gb.step(73, 0);
        (,,, uint8 tima,,, uint8 iff,) = helper.ioState(gb);
        assertEq(tima, 0x10);
        assertEq(iff & 0x04, 0x04);
    }

    function test_FrameAdvancesAndRendersBlank() public {
        bytes memory rom = _mkRom();
        rom[0x100] = bytes1(0x00);
        _load(rom);
        bytes memory fb = gb.runFrame(0);
        assertEq(fb.length, 23040);
        // zeroed VRAM + BGP=0xFC -> all pixels shade 0 (white)
        assertEq(uint8(fb[0]), 0);
        assertEq(uint8(fb[23039]), 0);
        (,, uint32 frame) = helper.cpuState(gb);
        assertEq(frame, 1);
        (uint16 pc,,) = helper.cpuState(gb);
        assertTrue(pc != 0x0100); // NOP sled advanced
    }

    function test_SerialCapture() public {        bytes memory rom = _mkRom();
        // LD A,'H'(0x48); LD (0xFF01),A via LDH; LD A,0x81; LDH (0xFF02),A ; JP self
        rom[0x100] = bytes1(0x3E);
        rom[0x101] = bytes1(0x48);
        rom[0x102] = bytes1(0xE0);
        rom[0x103] = bytes1(0x01);
        rom[0x104] = bytes1(0x3E);
        rom[0x105] = bytes1(0x81);
        rom[0x106] = bytes1(0xE0);
        rom[0x107] = bytes1(0x02);
        rom[0x108] = bytes1(0xC3);
        rom[0x109] = bytes1(0x08);
        rom[0x10A] = bytes1(0x01);
        _load(rom);
        gb.step(100, 0);
        bytes memory s = helper.serialText(gb);
        assertEq(s.length, 1);
        assertEq(uint8(s[0]), 0x48);
    }

    function _tileRom() internal pure returns (bytes memory rom) {
        // build tile0 row0 = solid color idx1, then spin:
        // LD HL,0x8000; LD A,0xFF; LD (HL+),A; LD A,0x00; LD (HL),A; loop: JR loop
        rom = new bytes(0x8000);
        uint8[] memory prog = new uint8[](11);
        prog[0] = 0x21;
        prog[1] = 0x00;
        prog[2] = 0x80;
        prog[3] = 0x3E;
        prog[4] = 0xFF;
        prog[5] = 0x22;
        prog[6] = 0x3E;
        prog[7] = 0x00;
        prog[8] = 0x77;
        prog[9] = 0x18;
        prog[10] = 0xFE;
        for (uint256 i = 0; i < prog.length; i++) rom[0x100 + i] = bytes1(prog[i]);
    }

    function test_PpuRendersTileRow() public {
        _load(_tileRom());
        // LCD on by default (LCDC=0x91: BG on, unsigned tiles @0x8000, map 0x9800=tiles 0).
        // BGP=0xFC maps idx1 -> shade 3.
        bytes memory fb = gb.runFrame(0);
        // map is all tile 0, whose row 0 is solid idx1 -> whole scanline 0 is shade 3
        for (uint256 x = 0; x < 160; x++) assertEq(uint8(fb[x]), 3);
        // second scanline: tile row1 is all zeros -> shade 0
        assertEq(uint8(fb[160]), 0);
    }

    function test_PpuSpriteRenders() public {        bytes memory rom = _mkRom();
        // 0x100: LD HL,0x8010      (21 10 80)
        // 0x103: LD A,0xFF         (3E FF)
        // 0x105: LD (HL+),A        (22)        ; tile1 row0 lo
        // 0x106: LD (HL),A         (77)        ; tile1 row0 hi -> idx3
        // 0x107: LD HL,0xFE00      (21 00 FE)
        // 0x10A: LD A,0x10         (3E 10)     ; y=16 -> screen row 0
        // 0x10C: LD (HL+),A        (22)
        // 0x10D: LD A,0x08         (3E 08)     ; x=8 -> screen col 0
        // 0x10F: LD (HL+),A        (22)
        // 0x110: LD A,0x01         (3E 01)     ; tile 1
        // 0x112: LD (HL+),A        (22)
        // 0x113: LD A,0x00         (3E 00)     ; attr 0
        // 0x115: LD (HL),A         (77)
        // 0x116: LD A,0x93         (3E 93)     ; LCDC: LCD+BG+OBJ on
        // 0x118: LDH (0x40),A      (E0 40)
        // 0x11A: JR -2             (18 FE)
        uint8[] memory prog = new uint8[](28);
        prog[0] = 0x21;
        prog[1] = 0x10;
        prog[2] = 0x80;
        prog[3] = 0x3E;
        prog[4] = 0xFF;
        prog[5] = 0x22;
        prog[6] = 0x77;
        prog[7] = 0x21;
        prog[8] = 0x00;
        prog[9] = 0xFE;
        prog[10] = 0x3E;
        prog[11] = 0x10;
        prog[12] = 0x22;
        prog[13] = 0x3E;
        prog[14] = 0x08;
        prog[15] = 0x22;
        prog[16] = 0x3E;
        prog[17] = 0x01;
        prog[18] = 0x22;
        prog[19] = 0x3E;
        prog[20] = 0x00;
        prog[21] = 0x77;
        prog[22] = 0x3E;
        prog[23] = 0x93;
        prog[24] = 0xE0;
        prog[25] = 0x40;
        prog[26] = 0x18;
        prog[27] = 0xFE;
        for (uint256 i = 0; i < prog.length; i++) rom[0x100 + i] = bytes1(prog[i]);
        _load(rom);
        bytes memory fb = gb.runFrame(0);
        // OBP0=0xFF maps idx3 -> shade 3; sprite covers x=0..7 on scanline 0
        assertEq(uint8(fb[0]), 3);
        assertEq(uint8(fb[7]), 3);
        assertEq(uint8(fb[8]), 0);
    }

    function test_JoypadPressAndRead() public {
        bytes memory rom = _mkRom();
        // LD A,0x20 (select dpad); LDH (0),A; LDH A,(0); NOP
        rom[0x100] = bytes1(0x3E);
        rom[0x101] = bytes1(0x20);
        rom[0x102] = bytes1(0xE0);
        rom[0x103] = bytes1(0x00);
        rom[0x104] = bytes1(0xF0);
        rom[0x105] = bytes1(0x00);
        rom[0x106] = bytes1(0x00);
        _load(rom);
        // no press: no interrupt requested
        gb.step(0, 0);
        (,,,,,, uint8 iff0,) = helper.ioState(gb);
        assertEq(iff0 & 0x10, 0);
        // press Up (bit6) and read P1 with dpad selected -> 0xC0|0x20|0x0B = 0xEB
        gb.step(0, 0x40);
        gb.step(4, 0x40); // LD A,0x20
        gb.step(4, 0x40); // LDH (0),A
        gb.step(4, 0x40); // LDH A,(0)
        (uint8 a,,,,,,,,,) = helper.regs(gb);
        assertEq(a, 0xEB);
        // fresh press requests the joypad interrupt (IME=0, so IF stays set);
        // reloads are once-only, so use a fresh instance
        GameBoy gb2 = new GameBoy();
        gb2.loadRom(rom);
        gb2.runFrame(0x40);
        (,,,,,, uint8 iff1,) = helper.ioState(gb2);
        assertEq(iff1 & 0x10, 0x10);
    }

    function test_IncDecPreserveCarry() public {
        bytes memory rom = _mkRom();
        // LD A,0xFF; ADD A,1 (A=0, Z+H+C); INC B; DEC B; NOP
        rom[0x100] = bytes1(0x3E);
        rom[0x101] = bytes1(0xFF);
        rom[0x102] = bytes1(0xC6);
        rom[0x103] = bytes1(0x01);
        rom[0x104] = bytes1(0x04); // INC B
        rom[0x105] = bytes1(0x05); // DEC B
        rom[0x106] = bytes1(0x00);
        _load(rom);
        gb.step(4, 0);
        gb.step(4, 0); // A=0, F=Z+H+C=0xB0
        (, uint8 f0,,,,,,,,) = helper.regs(gb);
        assertEq(f0, 0xB0);
        gb.step(4, 0); // INC B: B=1, C preserved, Z/N/H clear
        (, uint8 f1,,,,,,,,) = helper.regs(gb);
        assertEq(f1, 0x10);
        gb.step(4, 0); // DEC B: B=0, Z+N+C set, H clear
        (, uint8 f2,,,,,,,,) = helper.regs(gb);
        assertEq(f2, 0xD0);
    }

        function test_VBlankInterruptEndToEnd() public {
        bytes memory rom = _mkRom();
        // EI; LD A,1; LD (0xFFFF),A (IE=VBlank); HALT; JR -2
        rom[0x100] = bytes1(0xFB);
        rom[0x101] = bytes1(0x3E);
        rom[0x102] = bytes1(0x01);
        rom[0x103] = bytes1(0xEA);
        rom[0x104] = bytes1(0xFF);
        rom[0x105] = bytes1(0xFF);
        rom[0x106] = bytes1(0x76);
        rom[0x107] = bytes1(0x18);
        rom[0x108] = bytes1(0xFE);
        rom[0x040] = bytes1(0x04); // INC B
        rom[0x041] = bytes1(0xD9); // RETI
        _load(rom);
        gb.runFrame(0);
        gb.runFrame(0);
        gb.runFrame(0);
        (, , uint8 b,,,,,,,) = helper.regs(gb);
        assertGe(b, 2); // VBlank ISR ran at least twice
    }

    // ---------- chunked ROM loading ----------

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        unchecked {
            for (uint256 i = 0; i < len; i++) out[i] = data[start + i];
        }
    }

    function _loadChunked(GameBoy target, bytes memory rom, uint256 chunkSize) internal {
        unchecked {
            for (uint256 off = 0; off < rom.length; off += chunkSize) {
                uint256 len = off + chunkSize > rom.length ? rom.length - off : chunkSize;
                target.loadRomChunk(off, _slice(rom, off, len));
            }
        }
        target.finalizeLoad();
    }

    function test_ChunkedLoadMatchesOneShot() public {
        bytes memory rom = vm.readFileBinary("./test/roms/01-special.gb");
        GameBoy a = new GameBoy();
        a.loadRom(rom);
        GameBoy b = new GameBoy();
        _loadChunked(b, rom, 0x2000); // 4 x 8KB
        for (uint256 i = 0; i < 5; i++) {
            bytes memory fa = a.runFrame(0);
            bytes memory fb = b.runFrame(0);
            assertEq(keccak256(fa), keccak256(fb));
        }
        (uint16 pa, uint64 ca, uint32 fa_) = helper.cpuState(a);
        (uint16 pb, uint64 cb, uint32 fb_) = helper.cpuState(b);
        assertEq(pa, pb);
        assertEq(ca, cb);
        assertEq(fa_, fb_);
        assertEq(keccak256(helper.serialText(a)), keccak256(helper.serialText(b)));
    }

    function test_ChunkedLoad64k() public {
        bytes memory rom = vm.readFileBinary("./test/roms/cpu_instrs.gb");
        GameBoy a = new GameBoy();
        a.loadRom(rom);
        GameBoy b = new GameBoy();
        uint256 g0 = gasleft();
        _loadChunked(b, rom, 0x2000); // 8 x 8KB
        emit log_named_uint("chunked 64KB total gas", g0 - gasleft());
        for (uint256 i = 0; i < 2; i++) {
            bytes memory fa = a.runFrame(0);
            bytes memory fb = b.runFrame(0);
            assertEq(keccak256(fa), keccak256(fb));
        }
        (uint16 pa,,) = helper.cpuState(a);
        (uint16 pb,,) = helper.cpuState(b);
        assertEq(pa, pb);
        assertTrue(pa != 0x0100);
    }

    function test_ChunkedLoadGuards() public {
        GameBoy t = new GameBoy();
        bytes memory c = new bytes(16);
        // cannot append at nonzero offset on empty rom
        vm.expectRevert("append-only");
        t.loadRomChunk(16, c);
        // empty chunk rejected
        vm.expectRevert("bad chunk");
        t.loadRomChunk(0, new bytes(0));
        // finalize with no data rejected
        vm.expectRevert("ROM too small");
        t.finalizeLoad();
        // happy path (0x200 bytes), then uploads lock forever (once-only)
        bytes memory c2 = new bytes(0x200);
        t.loadRomChunk(0, c2);
        t.finalizeLoad();
        vm.expectRevert(Locked.selector);
        t.loadRomChunk(0x8000, c);
        vm.expectRevert(Locked.selector);
        t.loadRom(c2);
    }

    // ---------- EIP-7825 stepping ----------

    /// @dev One frame via step() must equal runFrame(): reassemble Scanlines,
    ///      compare framebuffer; every step tx must stay under 16,777,216 gas.
    function test_StepFrameEquivalence() public {
        GameBoy a = new GameBoy();
        a.loadRom(_tileRom());
        bytes memory ref = a.runFrame(0);

        GameBoy b = new GameBoy();
        b.loadRom(_tileRom());
        vm.recordLogs();
        uint32 total;
        bool fd;
        uint256 nSteps;
        while (!fd) {
            uint256 g0 = gasleft();
            (uint32 ex, bool f,) = b.step(16000, 0);
            uint256 used = g0 - gasleft();
            assertLt(used, 16777216, "step exceeded EIP-7825 cap");
            total += ex;
            fd = f;
            nSteps++;
            require(nSteps < 20, "frame never completed");
        }
        assertEq(nSteps, 5);
        assertGe(total, 70224);
        assertLt(total, 81000);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory fb = new bytes(23040);
        uint256 nLines;
        bytes32 sig = keccak256("Scanline(uint32,uint8,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length < 2 || logs[i].topics[0] != sig) continue;
            if (logs[i].topics[1] != bytes32(uint256(0))) continue; // next frame's overshoot
            (uint8 ly, bytes memory px) = abi.decode(logs[i].data, (uint8, bytes));
            assertEq(px.length, 160);
            for (uint256 x = 0; x < 160; x++) fb[uint256(ly) * 160 + x] = px[x];
            nLines++;
        }
        assertEq(nLines, 144);
        assertEq(keccak256(fb), keccak256(ref));

        // frame counter advanced exactly once via steps
        (,, uint32 frame) = helper.cpuState(b);
        assertEq(frame, 1);
    }

    /// @dev Worst-case step gas on CPU-heavy workload stays under the cap.
    function test_StepGasCapBlargg() public {
        GameBoy gb2 = new GameBoy();
        gb2.loadRom(vm.readFileBinary("./test/roms/01-special.gb"));
        uint256 worst;
        for (uint256 i = 0; i < 6; i++) {
            uint256 g0 = gasleft();
            (, bool fd,) = gb2.step(16000, 0);
            uint256 used = g0 - gasleft();
            assertLt(used, 16777216, "step exceeded EIP-7825 cap");
            if (used > worst) worst = used;
            if (fd) break;
        }
        emit log_named_uint("worst step(16000) gas", worst);
    }

    // ---------- SSTORE2 ROM path ----------

    function test_Sstore2MatchesStorage() public {
        bytes memory rom = vm.readFileBinary("./test/roms/01-special.gb");
        GameBoy a = new GameBoy();
        uint256 g0 = gasleft();
        a.loadRom(rom);
        emit log_named_uint("storage one-shot 32KB", g0 - gasleft());
        GameBoy b = new GameBoy();
        g0 = gasleft();
        b.loadRomSSTORE2(rom);
        emit log_named_uint("sstore2 one-shot 32KB", g0 - gasleft());
        for (uint256 i = 0; i < 3; i++) {
            g0 = gasleft();
            bytes memory fa = a.runFrame(0);
            uint256 ga = g0 - gasleft();
            g0 = gasleft();
            bytes memory fb = b.runFrame(0);
            uint256 gb_ = g0 - gasleft();
            assertEq(keccak256(fa), keccak256(fb));
            if (i == 0) {
                emit log_named_uint("frame storage-path", ga);
                emit log_named_uint("frame sstore2-path", gb_);
            }
        }
        (uint16 pa, uint64 ca, uint32 fa_) = helper.cpuState(a);
        (uint16 pb, uint64 cb, uint32 fb_) = helper.cpuState(b);
        assertEq(pa, pb);
        assertEq(ca, cb);
        assertEq(fa_, fb_);
        assertEq(keccak256(helper.serialText(a)), keccak256(helper.serialText(b)));
    }

    function test_Sstore2Banking64k() public {
        bytes memory rom = vm.readFileBinary("./test/roms/cpu_instrs.gb");
        GameBoy a = new GameBoy();
        a.loadRom(rom);
        GameBoy b = new GameBoy();
        // chunked store upload: 4 x 16KB (fresh instance needs no beginLoad)
        for (uint256 off = 0; off < rom.length; off += 0x4000) {
            uint256 len = off + 0x4000 > rom.length ? rom.length - off : 0x4000;
            b.loadRomStoreChunk(_slice(rom, off, len));
        }
        b.finalizeSstore2Load();
        // 4 stores expected (bank-aligned)
        GbState memory bst = helper.fullState(b);
        assertEq(bst.stores.length, 4);
        for (uint256 i = 0; i < 2; i++) {
            bytes memory fa = a.runFrame(0);
            bytes memory fb = b.runFrame(0);
            assertEq(keccak256(fa), keccak256(fb));
        }
        (uint16 pa,,) = helper.cpuState(a);
        (uint16 pb,,) = helper.cpuState(b);
        assertEq(pa, pb);
    }

    function test_Sstore2Guards() public {
        GameBoy t = new GameBoy();
        // finalize with no stores rejected
        vm.expectRevert("ROM too small");
        t.finalizeSstore2Load();
        // partial store then append rejected (bank alignment)
        bytes memory part = new bytes(100);
        t.loadRomStoreChunk(part);
        vm.expectRevert("prev store must be full");
        t.loadRomStoreChunk(part);
    }

    /// @dev The helper contract reads everything externally: batch regs,
    ///      cpu state, serial, frame/io state, and memory ranges.
    function test_HelperContract() public {
        bytes memory rom = _tileRom();
        rom[0x150] = bytes1(0x42); // marker in unused area (header check)
        _load(rom);
        gb.runFrame(0);
        // tile ROM ends spinning JR -2 with A=0x00; one frame completed
        (uint8 a0,,,,,,,,,) = helper.regs(gb);
        assertEq(a0, 0x00);
        (uint16 pc, uint64 cyc, uint32 fr) = helper.cpuState(gb);
        assertEq(pc, 0x0109);
        assertEq(fr, 1);
        assertGe(cyc, 70224);
        assertEq(helper.serialText(gb).length, 0);
        (uint8 ly, uint8 mode, uint32 clock, bool booted) = helper.frameState(gb);
        assertEq(ly, 0);
        assertEq(booted, true);
        assertLt(clock, 200); // carried remainder of the completed frame
        assertTrue(mode == 0 || mode == 2); // HBlank or next line's OAM search
        (,,,,,, uint8 iff,) = helper.ioState(gb);
        assertEq(iff & 0x01, 0x01); // VBlank fired during the frame
        // VRAM tile bytes written by the test ROM
        bytes memory row = helper.readMem(gb, 0x8000, 2);
        assertEq(uint8(row[0]), 0xFF);
        assertEq(uint8(row[1]), 0x00);
        // ROM bytes via storage path
        bytes memory hdr = helper.readMem(gb, 0x150, 2);
        assertEq(uint8(hdr[0]), 0x42);
        assertEq(uint8(hdr[1]), 0x00);
    }

    /// @dev Playable demo: HALT-synced loop moves a sprite with dpad input.
    ///      One move per frame, fully deterministic across runFrame calls.
    function test_DemoPlaysFrames() public {
        bytes memory rom = new bytes(0x8000);
        uint8[] memory prog = new uint8[](62);
        uint256 k;
        // setup: tile1 row0 solid; OAM[0] = (y=0x50, x=8, tile=1, attr=0)
        prog[k++] = 0x21; prog[k++] = 0x10; prog[k++] = 0x80; // LD HL,0x8010
        prog[k++] = 0x3E; prog[k++] = 0xFF; // LD A,0xFF
        prog[k++] = 0x22; // LD (HL+),A
        prog[k++] = 0x77; // LD (HL),A
        prog[k++] = 0x21; prog[k++] = 0x00; prog[k++] = 0xFE; // LD HL,0xFE00
        prog[k++] = 0x3E; prog[k++] = 0x50; // LD A,0x50 (y)
        prog[k++] = 0x22; // LD (HL+),A
        prog[k++] = 0x3E; prog[k++] = 0x08; // LD A,0x08 (x)
        prog[k++] = 0x22; // LD (HL+),A
        prog[k++] = 0x3E; prog[k++] = 0x01; // LD A,0x01 (tile)
        prog[k++] = 0x22; // LD (HL+),A
        prog[k++] = 0x3E; prog[k++] = 0x00; // LD A,0x00 (attr)
        prog[k++] = 0x77; // LD (HL),A
        prog[k++] = 0x3E; prog[k++] = 0x93; // LD A,0x93 (LCD+BG+OBJ)
        prog[k++] = 0xE0; prog[k++] = 0x40; // LDH (LCDC),A
        prog[k++] = 0xFB; // EI
        prog[k++] = 0x3E; prog[k++] = 0x01; // LD A,0x01
        prog[k++] = 0xEA; prog[k++] = 0xFF; prog[k++] = 0xFF; // LD (IE),A
        // loop @0x120: HALT; sample dpad; Right->x++, Left->x--
        prog[k++] = 0x76; // HALT
        prog[k++] = 0x3E; prog[k++] = 0x20; // LD A,0x20 (select dpad)
        prog[k++] = 0xE0; prog[k++] = 0x00; // LDH (P1),A
        prog[k++] = 0xF0; prog[k++] = 0x00; // LDH A,(P1)
        prog[k++] = 0x47; // LD B,A
        prog[k++] = 0x1F; // RRA (Right -> carry... NC = pressed)
        prog[k++] = 0x30; prog[k++] = 0x07; // JR NC,+7 -> right
        prog[k++] = 0x78; // LD A,B
        prog[k++] = 0x1F; // RRA
        prog[k++] = 0x1F; // RRA (Left -> carry)
        prog[k++] = 0x30; prog[k++] = 0x08; // JR NC,+8 -> left
        prog[k++] = 0x18; prog[k++] = 0xEE; // JR loop
        prog[k++] = 0x21; prog[k++] = 0x01; prog[k++] = 0xFE; // LD HL,0xFE01 (right)
        prog[k++] = 0x34; // INC (HL)
        prog[k++] = 0x18; prog[k++] = 0xE8; // JR -> HALT
        prog[k++] = 0x21; prog[k++] = 0x01; prog[k++] = 0xFE; // LD HL,0xFE01 (left)
        prog[k++] = 0x35; // DEC (HL)
        prog[k++] = 0x18; prog[k++] = 0xE2; // JR -> HALT
        require(k == 62, "prog len");
        for (uint256 i = 0; i < prog.length; i++) rom[0x100 + i] = bytes1(prog[i]);
        rom[0x040] = bytes1(0xD9); // VBlank ISR: RETI
        GameBoy g = new GameBoy();
        g.loadRom(rom);
        // NOTE: the game samples at VBlank (end of frame), so each framebuffer
        // shows the pre-move position: 1-frame input latency, like real games.
        // sprite OAM x=8 -> screen cols 0..7, row 64, shade 3
        bytes memory fb = g.runFrame(0);
        assertEq(uint8(helper.readMem(g, 0xFE01, 1)[0]), 0x08);
        assertEq(uint8(fb[64 * 160 + 0]), 3);
        assertEq(uint8(fb[64 * 160 + 7]), 3);
        assertEq(uint8(fb[64 * 160 + 8]), 0);
        assertEq(uint8(fb[65 * 160 + 0]), 0);
        fb = g.runFrame(0x10); // Right sampled late: OAM=9, fb still cols 0..7
        assertEq(uint8(helper.readMem(g, 0xFE01, 1)[0]), 0x09);
        assertEq(uint8(fb[64 * 160 + 0]), 3);
        assertEq(uint8(fb[64 * 160 + 8]), 0);
        fb = g.runFrame(0x10); // Right: OAM=10, fb cols 1..8
        assertEq(uint8(helper.readMem(g, 0xFE01, 1)[0]), 0x0A);
        assertEq(uint8(fb[64 * 160 + 0]), 0);
        assertEq(uint8(fb[64 * 160 + 1]), 3);
        assertEq(uint8(fb[64 * 160 + 8]), 3);
        fb = g.runFrame(0x20); // Left: OAM=9, fb cols 2..9
        assertEq(uint8(helper.readMem(g, 0xFE01, 1)[0]), 0x09);
        assertEq(uint8(fb[64 * 160 + 1]), 0);
        assertEq(uint8(fb[64 * 160 + 2]), 3);
        assertEq(uint8(fb[64 * 160 + 9]), 3);
    }

    /// @dev Button input lands mid-frame: poll P1 across two steps in one frame.
    function test_SubFrameButtonInput() public {        bytes memory rom = new bytes(0x8000);
        // LD A,0x20 (select dpad); LDH (0),A; loop: LDH A,(0); LD (0xC000),A; JR loop
        rom[0x100] = bytes1(0x3E);
        rom[0x101] = bytes1(0x20);
        rom[0x102] = bytes1(0xE0);
        rom[0x103] = bytes1(0x00);
        rom[0x104] = bytes1(0xF0);
        rom[0x105] = bytes1(0x00);
        rom[0x106] = bytes1(0xEA);
        rom[0x107] = bytes1(0x00);
        rom[0x108] = bytes1(0xC0);
        rom[0x109] = bytes1(0x18);
        rom[0x10A] = bytes1(0xF9);
        GameBoy g = new GameBoy();
        g.loadRom(rom);
        // first quarter-frame, nothing pressed -> P1 reads 0xEF
        (, bool fd1,) = g.step(8000, 0);
        assertFalse(fd1);
        assertEq(uint8(helper.readMem(g, 0xC000, 1)[0]), 0xEF);
        // press Up mid-frame -> P1 reads 0xEB, still same frame
        (, bool fd2,) = g.step(8000, 0x40);
        assertFalse(fd2);
        assertEq(uint8(helper.readMem(g, 0xC000, 1)[0]), 0xEB);
        // release mid-frame -> back to 0xEF, still same frame
        (, bool fd3,) = g.step(8000, 0);
        assertFalse(fd3);
        assertEq(uint8(helper.readMem(g, 0xC000, 1)[0]), 0xEF);
    }

    // ---------- MBC3 / MBC5 ----------

    /// @dev MBC5 (0x19): ROM bank switch, RAM banks isolation, high-bit OOB.
    function test_Mbc5Switch() public {
        bytes memory rom = new bytes(0xC000); // 3 banks
        rom[0x100] = bytes1(0x00); // NOP
        rom[0x101] = bytes1(0xC3); // JP 0x0150 (over the header)
        rom[0x102] = bytes1(0x50);
        rom[0x103] = bytes1(0x01);
        rom[0x147] = bytes1(0x19);
        rom[0x149] = bytes1(0x03); // 32KB RAM
        rom[0x4000] = bytes1(0x11); // bank1 marker
        rom[0x8000] = bytes1(0x22); // bank2 marker
        uint8[] memory prog = new uint8[](72);
        uint256 k;
        prog[k++] = 0xFA; prog[k++] = 0x00; prog[k++] = 0x40; // LD A,(0x4000)
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0xC0; // LD (0xC000),A (=0x11)
        prog[k++] = 0x3E; prog[k++] = 0x0A; // LD A,0x0A
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x00; // LD (0x0000),A (RAM on)
        prog[k++] = 0x3E; prog[k++] = 0xAA; // LD A,0xAA
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0xA0; // LD (0xA000),A (ram0)
        prog[k++] = 0x3E; prog[k++] = 0x02; // LD A,2
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x20; // LD (0x2000),A (rom bank 2)
        prog[k++] = 0xFA; prog[k++] = 0x00; prog[k++] = 0x40; // LD A,(0x4000)
        prog[k++] = 0xEA; prog[k++] = 0x01; prog[k++] = 0xC0; // LD (0xC001),A (=0x22)
        prog[k++] = 0x3E; prog[k++] = 0x01; // LD A,1
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x40; // LD (0x4000),A (ram bank 1)
        prog[k++] = 0x3E; prog[k++] = 0xBB; // LD A,0xBB
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0xA0; // LD (0xA000),A (ram1)
        prog[k++] = 0xFA; prog[k++] = 0x00; prog[k++] = 0xA0; // LD A,(0xA000)
        prog[k++] = 0xEA; prog[k++] = 0x02; prog[k++] = 0xC0; // LD (0xC002),A (=0xBB)
        prog[k++] = 0x3E; prog[k++] = 0x00; // LD A,0
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x40; // LD (0x4000),A (ram bank 0)
        prog[k++] = 0xFA; prog[k++] = 0x00; prog[k++] = 0xA0; // LD A,(0xA000)
        prog[k++] = 0xEA; prog[k++] = 0x03; prog[k++] = 0xC0; // LD (0xC003),A (=0xAA)
        prog[k++] = 0x3E; prog[k++] = 0x02; // LD A,2
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x20; // LD (0x2000),A (rom low=2)
        prog[k++] = 0x3E; prog[k++] = 0x01; // LD A,1
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x30; // LD (0x3000),A (rom high=1 -> bank 0x102 OOB)
        prog[k++] = 0xFA; prog[k++] = 0x00; prog[k++] = 0x40; // LD A,(0x4000)
        prog[k++] = 0xEA; prog[k++] = 0x04; prog[k++] = 0xC0; // LD (0xC004),A (=0xFF OOB)
        prog[k++] = 0x18; prog[k++] = 0xFE; // JR loop
        require(k == 72, "prog len");
        for (uint256 i = 0; i < prog.length; i++) rom[0x150 + i] = bytes1(prog[i]);
        GameBoy gb = new GameBoy();
        gb.loadRom(rom);
        gb.step(700, 0);
        assertEq(uint8(helper.readMem(gb, 0xC000, 1)[0]), 0x11); // default bank 1
        assertEq(uint8(helper.readMem(gb, 0xC001, 1)[0]), 0x22); // switched bank 2
        assertEq(uint8(helper.readMem(gb, 0xC002, 1)[0]), 0xBB); // ram bank 1
        assertEq(uint8(helper.readMem(gb, 0xC003, 1)[0]), 0xAA); // ram bank 0 isolated
        assertEq(uint8(helper.readMem(gb, 0xC004, 1)[0]), 0xFF); // bank 0x102 past end
    }

    /// @dev MBC3 (0x11): bank 0 is legal in the switchable area (MBC1 forbids it).
    function test_Mbc3Bank0() public {
        bytes memory rom = new bytes(0x8000); // 2 banks
        rom[0x147] = bytes1(0x11);
        rom[0x149] = bytes1(0x00);
        rom[0x0000] = bytes1(0x77); // file-start marker
        rom[0x4000] = bytes1(0x11); // bank1 marker
        // LD A,0; LD (0x2000),A; LD A,(0x4000); LD (0xC000),A; JR loop
        uint8[] memory prog = new uint8[](13);
        prog[0] = 0x3E;
        prog[1] = 0x00;
        prog[2] = 0xEA;
        prog[3] = 0x00;
        prog[4] = 0x20;
        prog[5] = 0xFA;
        prog[6] = 0x00;
        prog[7] = 0x40;
        prog[8] = 0xEA;
        prog[9] = 0x00;
        prog[10] = 0xC0;
        prog[11] = 0x18;
        prog[12] = 0xFE;
        for (uint256 i = 0; i < prog.length; i++) rom[0x100 + i] = bytes1(prog[i]);
        GameBoy gb = new GameBoy();
        gb.loadRom(rom);
        gb.step(200, 0);
        // switched bank 0 mirrors file start (MBC1 would have forced bank 1 = 0x11)
        assertEq(uint8(helper.readMem(gb, 0xC000, 1)[0]), 0x77);
    }

    /// @dev Unsupported mappers fail loudly instead of mis-emulating.
    function test_Mbc2Reverts() public {
        bytes memory rom = new bytes(0x8000);
        rom[0x147] = bytes1(0x05); // MBC2
        GameBoy gb = new GameBoy();
        vm.expectRevert("unsupported MBC");
        gb.loadRom(rom);
    }

    // ---------- access control (Twitch-Plays-Pokemon model) ----------

    /// @dev Uploads are owner-only + once; play is owner-only until renounce,
    ///      then open to everyone. Uploads stay locked after renounce.
    function test_OwnerControls() public {
        address stranger = address(0xBEEF);
        GameBoy g = new GameBoy();
        bytes memory rom = _mkRom();
        // non-owner cannot step or upload
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        g.step(100, 0);
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        g.loadRom(rom);
        // owner loads once, plays fine
        g.loadRom(rom);
        g.step(100, 0);
        // owner cannot reload (no bait-and-switch)
        vm.expectRevert(Locked.selector);
        g.loadRom(rom);
        // non-owner cannot renounce
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        g.renounceOwnership();
        // renounce opens play to everyone...
        g.renounceOwnership();
        vm.prank(stranger);
        g.step(100, 0);
        vm.prank(stranger);
        g.runFrame(0);
        // ...but uploads stay locked forever (owner is zero: everyone fails auth)
        vm.expectRevert(NotOwner.selector);
        g.loadRom(rom);
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        g.loadRom(rom);
    }
}
