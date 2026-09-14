// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../GameBoy.sol";
import "../GameBoyFactory.sol";

/// @notice Large-build play tests: frames, stepping, serial — all games are
///         factory clones booted via chunked SSTORE2 upload.
contract PlayTest is Test {
    GameBoyFactory factory;

    function setUp() public {
        factory = new GameBoyFactory(new GameBoy());
    }

    function _mkRom() internal pure returns (bytes memory rom) {
        rom = new bytes(0x8000);
    }

    function _slice(bytes memory d, uint256 s, uint256 l) internal pure returns (bytes memory o) {
        o = new bytes(l);
        for (uint256 i = 0; i < l; i++) o[i] = d[s + i];
    }

    /// @dev Boot a game via the factory: bare clone + chunked upload + finalize.
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
    ///      every step tx stays under the 16.7M cap; exactly one FrameDone.
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

    /// @dev Storage one-shot upload boots an identical game to chunked SSTORE2.
    function test_DirectVsChunked() public {
        bytes memory rom = vm.readFileBinary("./test/roms/01-special.gb");
        GameBoy a = factory.create();
        a.loadRom(rom);
        GameBoy b = _gb(rom);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(keccak256(a.runFrame(0)), keccak256(b.runFrame(0)));
        }
    }
}
