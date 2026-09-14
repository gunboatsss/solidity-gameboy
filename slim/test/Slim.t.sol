// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../GameBoy.sol";
import "../GameBoyFactory.sol";

/// @notice Slim-build tests: runFrame/step API (chunked upload only,
///         regs()/readMem() views, SerialByte events). CPU depth comes from
///         Blargg-01/02 + the demo, plus sub-frame stepping via step().
///         All games are factory clones (direct deploys are bricked).
contract SlimTest is Test {
    GameBoyFactory factory;

    function setUp() public {
        factory = new GameBoyFactory(new GameBoy());
    }

    function _mkRom() internal pure returns (bytes memory rom) {
        rom = new bytes(0x8000);
    }

    /// @dev Boot a game via the factory: bare clone + chunked upload + finalize.
    ///      Owner stays the test contract (create() assigns msg.sender).
    function _gb(bytes memory rom) internal returns (GameBoy gb) {
        gb = factory.create();
        for (uint256 off = 0; off < rom.length; off += 0x4000) {
            uint256 len = rom.length - off > 0x4000 ? 0x4000 : rom.length - off;
            gb.loadRomStoreChunk(_slice(rom, off, len));
        }
        gb.finalizeSstore2Load();
    }

    function test_FrameBlank() public {
        bytes memory rom = _mkRom();
        rom[0x100] = bytes1(0x00);
        GameBoy gb = _gb(rom);
        bytes memory fb = gb.runFrame(0);
        assertEq(fb.length, 23040);
        assertEq(uint8(fb[0]), 0);
        assertEq(uint8(fb[23039]), 0);
    }

    function test_PpuTileAndSprite() public {
        bytes memory rom = _mkRom();
        // tile0 row0 = idx1; tile1 row0 = idx3; OAM[0]=(16,8,1,0); LCDC=0x93
        rom[0x100] = bytes1(0x21); rom[0x101] = bytes1(0x00); rom[0x102] = bytes1(0x80);
        rom[0x103] = bytes1(0x3E); rom[0x104] = bytes1(0xFF);
        rom[0x105] = bytes1(0x22);
        rom[0x106] = bytes1(0x3E); rom[0x107] = bytes1(0x00);
        rom[0x108] = bytes1(0x77);
        rom[0x109] = bytes1(0x21); rom[0x10A] = bytes1(0x10); rom[0x10B] = bytes1(0x80);
        rom[0x10C] = bytes1(0x3E); rom[0x10D] = bytes1(0xFF);
        rom[0x10E] = bytes1(0x22);
        rom[0x10F] = bytes1(0x77);
        rom[0x110] = bytes1(0x21); rom[0x111] = bytes1(0x00); rom[0x112] = bytes1(0xFE);
        rom[0x113] = bytes1(0x3E); rom[0x114] = bytes1(0x10);
        rom[0x115] = bytes1(0x22);
        rom[0x116] = bytes1(0x3E); rom[0x117] = bytes1(0x08);
        rom[0x118] = bytes1(0x22);
        rom[0x119] = bytes1(0x3E); rom[0x11A] = bytes1(0x01);
        rom[0x11B] = bytes1(0x22);
        rom[0x11C] = bytes1(0x3E); rom[0x11D] = bytes1(0x00);
        rom[0x11E] = bytes1(0x77);
        rom[0x11F] = bytes1(0x3E); rom[0x120] = bytes1(0x93);
        rom[0x121] = bytes1(0xE0); rom[0x122] = bytes1(0x40);
        rom[0x123] = bytes1(0x18); rom[0x124] = bytes1(0xFE);
        GameBoy gb = _gb(rom);
        bytes memory fb = gb.runFrame(0);
        // bg tile0 row0 = idx1 -> BGP(0xFC) shade 3; sprite covers 0..7 with idx3
        assertEq(uint8(fb[0]), 3); // sprite idx3
        assertEq(uint8(fb[7]), 3);
        assertEq(uint8(fb[8]), 3); // bg idx1
        assertEq(uint8(fb[160]), 0); // row1 blank
    }

    function test_VBlankInterrupt() public {
        bytes memory rom = _mkRom();
        rom[0x100] = bytes1(0xFB); // EI
        rom[0x101] = bytes1(0x3E);
        rom[0x102] = bytes1(0x01);
        rom[0x103] = bytes1(0xEA); // LD (IE),A
        rom[0x104] = bytes1(0xFF);
        rom[0x105] = bytes1(0xFF);
        rom[0x106] = bytes1(0x76); // HALT
        rom[0x107] = bytes1(0x18);
        rom[0x108] = bytes1(0xFE); // JR loop
        rom[0x040] = bytes1(0x04); // INC B
        rom[0x041] = bytes1(0xD9); // RETI
        GameBoy gb = _gb(rom);
        gb.runFrame(0);
        gb.runFrame(0);
        gb.runFrame(0);
        (, , uint8 b,,,,,,,) = gb.regs();
        assertGe(b, 2);
    }

    function test_SerialEvent() public {
        bytes memory rom = _mkRom();
        rom[0x100] = bytes1(0x3E);
        rom[0x101] = bytes1(0x48); // LD A,'H'
        rom[0x102] = bytes1(0xE0);
        rom[0x103] = bytes1(0x01); // LDH (SB),A
        rom[0x104] = bytes1(0x3E);
        rom[0x105] = bytes1(0x81);
        rom[0x106] = bytes1(0xE0);
        rom[0x107] = bytes1(0x02); // LDH (SC),A -> transfer
        rom[0x108] = bytes1(0x00);
        GameBoy gb = _gb(rom);
        vm.recordLogs();
        gb.runFrame(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SerialByte(uint8)");
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                (uint8 b) = abi.decode(logs[i].data, (uint8));
                assertEq(b, 0x48);
                found++;
            }
        }
        assertEq(found, 1);
    }

    function _slice(bytes memory d, uint256 s, uint256 l) internal pure returns (bytes memory o) {        o = new bytes(l);
        for (uint256 i = 0; i < l; i++) o[i] = d[s + i];
    }

    function test_ChunkedUploadBoots() public {
        bytes memory rom = vm.readFileBinary("./test/roms/01-special.gb");
        GameBoy g = _gb(rom);
        assertEq(g.romSize(), rom.length);
        (uint16 pc0,,,,,,,,,) = g.regs();
        g.runFrame(0);
        g.runFrame(0);
        g.runFrame(0);
        (uint16 pc1,,,,,,,,,) = g.regs();
        assertTrue(pc1 != pc0); // booted + executing, not halted at entry
    }

    function test_StoreGuards() public {
        GameBoy t = factory.create();
        vm.expectRevert(RomTooSmall.selector);
        t.finalizeSstore2Load();
        bytes memory part = new bytes(100);
        t.loadRomStoreChunk(part);
        vm.expectRevert(BadStore.selector);
        t.loadRomStoreChunk(part);
    }

    function test_Demo() public {
        bytes memory rom = new bytes(0x8000);
        uint8[] memory prog = new uint8[](62);
        uint256 k;
        prog[k++] = 0x21; prog[k++] = 0x10; prog[k++] = 0x80;
        prog[k++] = 0x3E; prog[k++] = 0xFF;
        prog[k++] = 0x22; prog[k++] = 0x77;
        prog[k++] = 0x21; prog[k++] = 0x00; prog[k++] = 0xFE;
        prog[k++] = 0x3E; prog[k++] = 0x50;
        prog[k++] = 0x22;
        prog[k++] = 0x3E; prog[k++] = 0x08;
        prog[k++] = 0x22;
        prog[k++] = 0x3E; prog[k++] = 0x01;
        prog[k++] = 0x22;
        prog[k++] = 0x3E; prog[k++] = 0x00;
        prog[k++] = 0x77;
        prog[k++] = 0x3E; prog[k++] = 0x93;
        prog[k++] = 0xE0; prog[k++] = 0x40;
        prog[k++] = 0xFB;
        prog[k++] = 0x3E; prog[k++] = 0x01;
        prog[k++] = 0xEA; prog[k++] = 0xFF; prog[k++] = 0xFF;
        prog[k++] = 0x76;
        prog[k++] = 0x3E; prog[k++] = 0x20;
        prog[k++] = 0xE0; prog[k++] = 0x00;
        prog[k++] = 0xF0; prog[k++] = 0x00;
        prog[k++] = 0x47; prog[k++] = 0x1F;
        prog[k++] = 0x30; prog[k++] = 0x07;
        prog[k++] = 0x78; prog[k++] = 0x1F; prog[k++] = 0x1F;
        prog[k++] = 0x30; prog[k++] = 0x08;
        prog[k++] = 0x18; prog[k++] = 0xEE;
        prog[k++] = 0x21; prog[k++] = 0x01; prog[k++] = 0xFE;
        prog[k++] = 0x34;
        prog[k++] = 0x18; prog[k++] = 0xE8;
        prog[k++] = 0x21; prog[k++] = 0x01; prog[k++] = 0xFE;
        prog[k++] = 0x35;
        prog[k++] = 0x18; prog[k++] = 0xE2;
        require(k == 62, "prog len");
        for (uint256 i = 0; i < prog.length; i++) rom[0x100 + i] = bytes1(prog[i]);
        rom[0x040] = bytes1(0xD9);
        GameBoy g = _gb(rom);
        bytes memory fb = g.runFrame(0);
        assertEq(uint8(g.readMem(0xFE01, 1)[0]), 0x08);
        assertEq(uint8(fb[64 * 160 + 0]), 3);
        fb = g.runFrame(0x10);
        assertEq(uint8(g.readMem(0xFE01, 1)[0]), 0x09);
        fb = g.runFrame(0x10);
        assertEq(uint8(g.readMem(0xFE01, 1)[0]), 0x0A);
        assertEq(uint8(fb[64 * 160 + 2]), 3);
        fb = g.runFrame(0x20);
        assertEq(uint8(g.readMem(0xFE01, 1)[0]), 0x09);
    }

    function _tileRom() internal pure returns (bytes memory rom) {
        rom = new bytes(0x8000);
        rom[0x100] = bytes1(0x21);
        rom[0x101] = bytes1(0x00);
        rom[0x102] = bytes1(0x80); // LD HL,0x8000
        rom[0x103] = bytes1(0x3E);
        rom[0x104] = bytes1(0xFF); // LD A,0xFF
        rom[0x105] = bytes1(0x22); // LD (HL+),A (tile0 lo)
        rom[0x106] = bytes1(0x3E);
        rom[0x107] = bytes1(0x00);
        rom[0x108] = bytes1(0x77); // LD (HL),A (tile0 hi)
        rom[0x109] = bytes1(0x18);
        rom[0x10A] = bytes1(0xFE); // JR loop
    }

    /// @dev One frame via step(): reassembled scanlines equal runFrame fb;
    ///      every step tx stays under the EIP-7825 cap; exactly one FrameDone.
    function test_StepFrame() public {
        GameBoy a = _gb(_tileRom());
        bytes memory ref = a.runFrame(0);
        GameBoy b = _gb(_tileRom());
        vm.recordLogs();
        uint32 total;
        bool fd;
        uint256 nSteps;
        uint256 nDone;
        while (!fd) {
            uint256 g0 = gasleft();
            (uint32 ex, bool f,) = b.step(16000, 0);
            uint256 used = g0 - gasleft();
            assertLt(used, 16777216, "step exceeded cap");
            total += ex;
            if (f) {
                assertFalse(fd, "double frameDone");
                fd = f;
                nDone++;
            }
            nSteps++;
            require(nSteps < 20, "frame never completed");
        }
        assertEq(nSteps, 5);
        assertEq(nDone, 1);
        assertGe(total, 70224);
        assertLt(total, 81000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory fb = new bytes(23040);
        uint256 nLines;
        uint256 nFrames;
        bytes32 scanSig = keccak256("Scanline(uint32,uint8,bytes)");
        bytes32 doneSig = keccak256("FrameDone(uint32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == doneSig) {
                nFrames++;
                continue;
            }
            if (logs[i].topics.length < 2 || logs[i].topics[0] != scanSig) continue;
            if (logs[i].topics[1] != bytes32(uint256(0))) continue;
            (uint8 ly, bytes memory px) = abi.decode(logs[i].data, (uint8, bytes));
            assertEq(px.length, 160);
            for (uint256 x = 0; x < 160; x++) fb[uint256(ly) * 160 + x] = px[x];
            nLines++;
        }
        assertEq(nLines, 144);
        assertEq(nFrames, 1);
        assertEq(keccak256(fb), keccak256(ref));
    }

    /// @dev Worst-case step gas on CPU-heavy workload stays under the cap.
    function test_StepGasCap() public {
        GameBoy gb2 = _gb(vm.readFileBinary("./test/roms/01-special.gb"));
        uint256 worst;
        for (uint256 i = 0; i < 6; i++) {
            uint256 g0 = gasleft();
            (, bool fdd,) = gb2.step(16000, 0);
            uint256 used = g0 - gasleft();
            assertLt(used, 16777216, "step exceeded cap");
            if (used > worst) worst = used;
            if (fdd) break;
        }
        emit log_named_uint("worst slim step(16000)", worst);
    }

    /// @dev Button input lands mid-frame via step().
    function test_StepInput() public {
        bytes memory rom = new bytes(0x8000);
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
        GameBoy g = _gb(rom);
        (, bool fd1,) = g.step(8000, 0);
        assertFalse(fd1);
        assertEq(uint8(g.readMem(0xC000, 1)[0]), 0xEF);
        (, bool fd2,) = g.step(8000, 0x40);
        assertFalse(fd2);
        assertEq(uint8(g.readMem(0xC000, 1)[0]), 0xEB);
    }

    // ---------- MBC3 / MBC5 (via initialize upload) ----------

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
        prog[k++] = 0xFA; prog[k++] = 0x00; prog[k++] = 0x40;
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0xC0;
        prog[k++] = 0x3E; prog[k++] = 0x0A;
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x00;
        prog[k++] = 0x3E; prog[k++] = 0xAA;
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0xA0;
        prog[k++] = 0x3E; prog[k++] = 0x02;
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x20;
        prog[k++] = 0xFA; prog[k++] = 0x00; prog[k++] = 0x40;
        prog[k++] = 0xEA; prog[k++] = 0x01; prog[k++] = 0xC0;
        prog[k++] = 0x3E; prog[k++] = 0x01;
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x40;
        prog[k++] = 0x3E; prog[k++] = 0xBB;
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0xA0;
        prog[k++] = 0xFA; prog[k++] = 0x00; prog[k++] = 0xA0;
        prog[k++] = 0xEA; prog[k++] = 0x02; prog[k++] = 0xC0;
        prog[k++] = 0x3E; prog[k++] = 0x00;
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x40;
        prog[k++] = 0xFA; prog[k++] = 0x00; prog[k++] = 0xA0;
        prog[k++] = 0xEA; prog[k++] = 0x03; prog[k++] = 0xC0;
        prog[k++] = 0x3E; prog[k++] = 0x02;
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x20;
        prog[k++] = 0x3E; prog[k++] = 0x01;
        prog[k++] = 0xEA; prog[k++] = 0x00; prog[k++] = 0x30;
        prog[k++] = 0xFA; prog[k++] = 0x00; prog[k++] = 0x40;
        prog[k++] = 0xEA; prog[k++] = 0x04; prog[k++] = 0xC0;
        prog[k++] = 0x18; prog[k++] = 0xFE;
        require(k == 72, "prog len");
        for (uint256 i = 0; i < prog.length; i++) rom[0x150 + i] = bytes1(prog[i]);
        GameBoy gb = _gb(rom);
        gb.step(700, 0);
        assertEq(uint8(gb.readMem(0xC000, 1)[0]), 0x11);
        assertEq(uint8(gb.readMem(0xC001, 1)[0]), 0x22);
        assertEq(uint8(gb.readMem(0xC002, 1)[0]), 0xBB);
        assertEq(uint8(gb.readMem(0xC003, 1)[0]), 0xAA);
        assertEq(uint8(gb.readMem(0xC004, 1)[0]), 0xFF);
    }

    /// @dev MBC3 (0x11): bank 0 is legal in the switchable area.
    function test_Mbc3Bank0() public {
        bytes memory rom = new bytes(0x8000);
        rom[0x100] = bytes1(0x00);
        rom[0x101] = bytes1(0xC3);
        rom[0x102] = bytes1(0x50);
        rom[0x103] = bytes1(0x01);
        rom[0x147] = bytes1(0x11);
        rom[0x149] = bytes1(0x00);
        rom[0x0000] = bytes1(0x77);
        rom[0x4000] = bytes1(0x11);
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
        for (uint256 i = 0; i < prog.length; i++) rom[0x150 + i] = bytes1(prog[i]);
        GameBoy gb = _gb(rom);
        gb.step(200, 0);
        assertEq(uint8(gb.readMem(0xC000, 1)[0]), 0x77);
    }

    /// @dev Unsupported mappers fail loudly at finalize.
    function test_Mbc2Reverts() public {
        bytes memory rom = new bytes(0x8000);
        rom[0x147] = bytes1(0x05);
        GameBoy g = factory.create();
        g.loadRomStoreChunk(_slice(rom, 0, 0x4000));
        g.loadRomStoreChunk(_slice(rom, 0x4000, 0x4000));
        vm.expectRevert(BadMbc.selector);
        g.finalizeSstore2Load();
    }

    /// @dev Uploads are owner-only + once; play is owner-only until renounce,
    ///      then open to everyone. Uploads stay locked after renounce.
    function test_OwnerControls() public {
        address stranger = address(0xBEEF);
        bytes memory rom = new bytes(0x800);
        GameBoy g = _gb(rom);
        // non-owner cannot play or upload
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        g.runFrame(0);
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        g.loadRomStoreChunk(new bytes(16));
        // owner plays fine
        g.runFrame(0);
        // finalize cannot reset a live game (locked even for owner)
        vm.expectRevert(Locked.selector);
        g.finalizeSstore2Load();
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
        g.finalizeSstore2Load();
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        g.loadRomStoreChunk(new bytes(16));
    }
}
