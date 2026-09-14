// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GameBoy.sol";
import "../src/GameBoyHelper.sol";

/// @notice Blargg cpu_instrs validation (serial output harness).
///         ROMs live in test/roms/ (see test/roms/README.md for URLs).
contract BlarggTest is Test {
    GameBoyHelper helper;

    function setUp() public {
        helper = new GameBoyHelper();
    }
    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        unchecked {
            for (uint256 i = 0; i + needle.length <= hay.length; i++) {
                bool ok = true;
                for (uint256 j = 0; j < needle.length; j++) {
                    if (hay[i + j] != needle[j]) {
                        ok = false;
                        break;
                    }
                }
                if (ok) return true;
            }
        }
        return false;
    }

    function _runRom(string memory path, uint256 maxFrames) internal returns (bytes memory serial) {
        GameBoy gb = new GameBoy();
        bytes memory rom = vm.readFileBinary(path);
        gb.loadRom(rom);
        for (uint256 i = 0; i < maxFrames; i++) {
            gb.runFrame(0);
            // serial output is append-only: poll every 4th frame (snapshots are heavy)
            if (i % 4 == 3 || i + 1 == maxFrames) {
                serial = helper.serialText(gb);
                if (_contains(serial, bytes("Failed")) || _contains(serial, bytes("Passed"))) return serial;
            }
        }
        serial = helper.serialText(gb);
        return serial;
    }

    function _check(string memory path, string memory name, uint256 maxFrames) internal {
        bytes memory s = _runRom(path, maxFrames);
        emit log_named_bytes(name, s);
        assertTrue(_contains(s, bytes("Passed")), string.concat(name, ": no Passed"));
        assertFalse(_contains(s, bytes("Failed")), string.concat(name, ": FAILED"));
    }

    function test_01_special() public {
        _check("./test/roms/01-special.gb", "01-special", 600);
    }

    function test_02_interrupts() public {
        _check("./test/roms/02-interrupts.gb", "02-interrupts", 600);
    }

    function test_03_op_sp_hl() public {
        _check("./test/roms/03.gb", "03-op_sp_hl", 900);
    }

    function test_04_op_r_imm() public {
        _check("./test/roms/04.gb", "04-op_r_imm", 900);
    }

    function test_05_op_rp() public {
        _check("./test/roms/05.gb", "05-op_rp", 800);
    }

    function test_06_ld_r_r() public {
        _check("./test/roms/06.gb", "06-ld_r_r", 900);
    }

    function test_07_jr_jp_call_ret_rst() public {
        _check("./test/roms/07.gb", "07-ctrl", 900);
    }

    function test_08_misc_instrs() public {
        _check("./test/roms/08.gb", "08-misc", 900);
    }

    function test_09_op_r_r() public {
        _check("./test/roms/09.gb", "09-op_r_r", 8000);
    }

    function test_10_bit_ops() public {
        _check("./test/roms/10.gb", "10-bit_ops", 2000);
    }

    function test_11_op_a_hl() public {
        _check("./test/roms/11.gb", "11-op_a_hl", 8000);
    }
}
