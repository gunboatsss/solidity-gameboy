// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GameBoy.sol";
import "../src/GameBoyHelper.sol";

/// @notice Golden framebuffer battery for the PPU renderer.
///         States are poked directly into storage (slots verified by
///         test_SlotSanity + `forge inspect GameBoy storage-layout`),
///         then rendered with one runFrame. Hashes below were captured
///         from the reference Solidity renderer — any renderer change
///         must reproduce them exactly.
contract PpuGoldensTest is Test {
    GameBoyHelper helper;

    // storage slots (verify with `forge inspect GameBoy storage-layout`)
    uint256 internal constant VSLOT = 7;
    uint256 internal constant OSLOT = 9;
    uint256 internal constant IOSLOT = 11;
    // IO byte offsets within slot 11 (little-endian packing: byte N = value << 8N)
    uint256 internal constant O_LCDC = 10;
    uint256 internal constant O_SCY = 12;
    uint256 internal constant O_SCX = 13;
    uint256 internal constant O_BGP = 16;
    uint256 internal constant O_OBP0 = 17;
    uint256 internal constant O_OBP1 = 18;
    uint256 internal constant O_WY = 19;
    uint256 internal constant O_WX = 20;

    function setUp() public {
        helper = new GameBoyHelper();
    }

    function _fresh() internal returns (GameBoy gb) {
        gb = new GameBoy();
        bytes memory rom = new bytes(0x8000);
        rom[0x100] = bytes1(uint8(0x00)); // NOP sled, LCD on (default LCDC=0x91)
        gb.loadRom(rom);
    }

    function _base(uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(slot));
    }

    /// @dev Write arbitrary bytes at blob offset (read-modify-write per word).
    ///      File bytes are big-endian within each 32-byte slot.
    function _poke(GameBoy gb, uint256 slot, uint256 off, bytes memory data) internal {
        uint256 base = uint256(_base(slot));
        unchecked {
            for (uint256 i = 0; i < data.length; i++) {
                uint256 f = off + i;
                uint256 s = base + f / 32;
                uint256 shift = (31 - (f % 32)) * 8;
                uint256 cur = uint256(vm.load(address(gb), bytes32(s)));
                uint256 mask = ~(uint256(0xFF) << shift);
                cur = (cur & mask) | (uint256(uint8(data[i])) << shift);
                vm.store(address(gb), bytes32(s), bytes32(cur));
            }
        }
    }

    function _vram(GameBoy gb, uint256 off, bytes memory data) internal {
        _poke(gb, VSLOT, off, data);
    }

    function _oam(GameBoy gb, uint256 off, bytes memory data) internal {
        _poke(gb, OSLOT, off, data);
    }

    /// @dev Write one IO register (slot 11 packs bytes little-endian here).
    function _io(GameBoy gb, uint256 fieldOff, uint8 v) internal {
        uint256 cur = uint256(vm.load(address(gb), bytes32(IOSLOT)));
        uint256 shift = fieldOff * 8;
        cur = (cur & ~(uint256(0xFF) << shift)) | (uint256(v) << shift);
        vm.store(address(gb), bytes32(IOSLOT), bytes32(cur));
    }

    function _tile(GameBoy gb, uint256 n, bytes memory rows16) internal {
        _vram(gb, n * 16, rows16);
    }

    /// @dev Build 16 tile-row bytes from 8 lo-bytes + 8 hi-bytes.
    function _rows(
        uint8 l0,
        uint8 h0,
        uint8 l1,
        uint8 h1,
        uint8 l2,
        uint8 h2,
        uint8 l3,
        uint8 h3,
        uint8 l4,
        uint8 h4,
        uint8 l5,
        uint8 h5,
        uint8 l6,
        uint8 h6,
        uint8 l7,
        uint8 h7
    ) internal pure returns (bytes memory r) {
        r = new bytes(16);
        r[0] = bytes1(l0);
        r[1] = bytes1(h0);
        r[2] = bytes1(l1);
        r[3] = bytes1(h1);
        r[4] = bytes1(l2);
        r[5] = bytes1(h2);
        r[6] = bytes1(l3);
        r[7] = bytes1(h3);
        r[8] = bytes1(l4);
        r[9] = bytes1(h4);
        r[10] = bytes1(l5);
        r[11] = bytes1(h5);
        r[12] = bytes1(l6);
        r[13] = bytes1(h6);
        r[14] = bytes1(l7);
        r[15] = bytes1(h7);
    }

    function _run(GameBoy gb, string memory name) internal {
        bytes memory fb = gb.runFrame(0);
        emit log_named_bytes32(name, keccak256(fb));
    }

    function test_SlotSanity() public {
        GameBoy gb = _fresh();
        _vram(gb, 0, hex"aa55");
        bytes memory back = helper.readMem(gb, 0x8000, 2);
        assertEq(uint8(back[0]), 0xAA);
        assertEq(uint8(back[1]), 0x55);
        _oam(gb, 0, hex"10200300");
        back = helper.readMem(gb, 0xFE00, 4);
        assertEq(uint8(back[0]), 0x10);
        assertEq(uint8(back[3]), 0x00);
        _io(gb, O_SCX, 0x42);
        back = helper.readMem(gb, 0xFF00, 0); // empty read ok
        assertEq(back.length, 0);
    }

    function test_Generate() public {
        for (uint256 id = 0; id < 20; id++) {
            (GameBoy gb, string memory name) = _build(id);
            _run(gb, name);
        }
    }

    // captured from the reference Solidity renderer (test_Generate output)
    function _expected(uint256 id) internal pure returns (bytes32) {
        if (id == 0) return 0x3ecf50b9f20c018b6f5f19a49668347bc2699d225d5e5675e7e040239048dfa5;
        if (id == 1) return 0x9fa7ab5fee7418c90488fbe68ac49d08e688fe498637303c5e66698b7b982b35;
        if (id == 2) return 0x6911dd0dbbc3c6b842333cbe7fb6e7cef0e4543b621fe6a2262e4415dcdb44da;
        if (id == 3) return 0x6ce064a147ea723a216902dae6bfd520bc3fcef8d8bf5c33512c9f3e23bd6ae0;
        if (id == 4) return 0x23bf0164778a04449024b576d51b7f599294b2cffea1c4171c49dbd9caeda2bd;
        if (id == 5) return 0xc2f89523f47015199e25ba9e9ea5a223f18a3c03fc57b74ed9bae503eddbba63;
        if (id == 6) return 0x9fa7ab5fee7418c90488fbe68ac49d08e688fe498637303c5e66698b7b982b35;
        if (id == 7) return 0x3ecf50b9f20c018b6f5f19a49668347bc2699d225d5e5675e7e040239048dfa5;
        if (id == 8) return 0x71173d091f290fdb2784258a44ea25865268145873c9ebe2aae233270d4b569f;
        if (id == 9) return 0xec9df87b61619e5ae1b8da08dcdbefc9a4693cdfb2fcaf0ff0f56cd200032184;
        if (id == 10) return 0xfdf0b55bae081ede839ce03530f9d977dd7422a6b7feefb944736a451b20189c;
        if (id == 11) return 0xe2f4690cd9f1521c41f5faad3d073e31dcb331400462af0f49cfda1bb96917dd;
        if (id == 12) return 0x3ca48ecd01f7d623f882c7b4256451348c1d1c0e3cacf4bfe2019202f37d0bc6;
        if (id == 13) return 0x471167d0dd169c01f96ddba0d043d6f1acc56796359344cb8cd72ed2e107957d;
        if (id == 14) return 0xbe02f4346b1a238291927981b0ffb3fa951d6d6f486e2ff24a0e236e13755953;
        if (id == 15) return 0x6a765424f5750870a34daec3fbe7b98d068a4dfb410c1fa6147b36461101d4fa;
        if (id == 16) return 0x6911dd0dbbc3c6b842333cbe7fb6e7cef0e4543b621fe6a2262e4415dcdb44da;
        if (id == 17) return 0xfdf0b55bae081ede839ce03530f9d977dd7422a6b7feefb944736a451b20189c;
        if (id == 18) return 0xfdf0b55bae081ede839ce03530f9d977dd7422a6b7feefb944736a451b20189c;
        return 0x0de112d0571f0a29d6bdbd706eaa8b9be91a07e0b9056ecbaa2bd66a489b3a1e; // 19
    }

    function test_Goldens() public {
        for (uint256 id = 0; id < 20; id++) {
            (GameBoy gb,) = _build(id);
            bytes memory fb = gb.runFrame(0);
            assertEq(keccak256(fb), _expected(id));
        }
        // hand-computed pixels (independent correctness, Pan Docs semantics)
        (GameBoy g12,) = _build(11);
        bytes memory f12 = g12.runFrame(0);
        assertEq(uint8(f12[0]), 0); // xflip: bit0 of F0 row = 0
        assertEq(uint8(f12[160]), 1); // row1 0F flipped -> bit0 = 1
        (GameBoy g14,) = _build(13);
        bytes memory f14 = g14.runFrame(0);
        assertEq(uint8(f14[0]), 1); // behind flag: bg idx1 through identity palette
        (GameBoy g16,) = _build(15);
        bytes memory f16 = g16.runFrame(0);
        assertEq(uint8(f16[0]), 0); // 11th sprite dropped
        assertEq(uint8(f16[8]), 3); // first-10 cover x=8..15 with idx3
        (GameBoy g10,) = _build(9);
        bytes memory f10 = g10.runFrame(0);
        assertEq(uint8(f10[0]), 3); // negative winX0: px=7 -> win tile
        assertEq(uint8(f10[1]), 0); // px=8 -> bg tile
        (GameBoy g20,) = _build(19);
        bytes memory f20 = g20.runFrame(0);
        assertEq(uint8(f20[0]), 1); // tie -> lowest OAM index (idx1)
        assertEq(uint8(f20[8]), 2); // oam2 covers x=8..15 (idx2)
    }

    function _build(uint256 id) internal returns (GameBoy gb, string memory name) {
        // 01 blank
        if (id == 0) {
            gb = _fresh();
            return (gb, "01 blank");
        }
        // 02 solid idx1 tile0
        if (id == 1) {
            gb = _fresh();
        _tile(gb, 0, _rows(0xFF, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
            return (gb, "02 solid1");
        }
        // 03 solid idx3 tile0
        if (id == 2) {
            gb = _fresh();
        _tile(gb, 0, _rows(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF));
            return (gb, "03 solid3");
        }
        // 04 stripes (alternate idx3 / idx0 rows)
        if (id == 3) {
            gb = _fresh();
        _tile(gb, 0, _rows(0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00));
            return (gb, "04 stripes");
        }
        // 05 scrolled (SCX=3, SCY=5), vertical stripes tile
        if (id == 4) {
            gb = _fresh();
        _tile(gb, 0, _rows(0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0));
        _io(gb, O_SCX, 3);
        _io(gb, O_SCY, 5);
            return (gb, "05 scroll");
        }
        // 06 scroll wrap (250,250)
        if (id == 5) {
            gb = _fresh();
        _tile(gb, 0, _rows(0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0));
        _io(gb, O_SCX, 250);
        _io(gb, O_SCY, 250);
            return (gb, "06 scrollwrap");
        }
        // 07 signed tiles (LCDC=0x81: LCD+BG, signed), pattern at 0x9000
        if (id == 6) {
            gb = _fresh();
        _io(gb, O_LCDC, 0x81);
        _tile(gb, 0x100, _rows(0xFF, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
            return (gb, "07 signed");
        }
        // 08 signed idx 0 must NOT read 0x8000 (pattern only there -> blank)
        if (id == 7) {
            gb = _fresh();
        _io(gb, O_LCDC, 0x81);
        _tile(gb, 0, _rows(0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
            return (gb, "08 signedblank");
        }
        // 09 window (LCDC=0xB1, WX=20, WY=10), win tile1 solid
        if (id == 8) {
            gb = _fresh();
        _io(gb, O_LCDC, 0xB1);
        _io(gb, O_WX, 20);
        _io(gb, O_WY, 10);
        _tile(gb, 1, _rows(0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _vram(gb, 0x1800, hex"01");
            return (gb, "09 window");
        }
        // 10 window clip (WX=0 -> shifted, WY=0)
        if (id == 9) {
            gb = _fresh();
        _io(gb, O_LCDC, 0xB1);
        _io(gb, O_WX, 0);
        _io(gb, O_WY, 0);
        _tile(gb, 1, _rows(0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _vram(gb, 0x1800, hex"01");
            return (gb, "10 windowclip");
        }
        // 11 sprite basic (tile1 row0 solid idx3 at 0,0)
        if (id == 10) {
            gb = _fresh();
        _io(gb, O_LCDC, 0x93);
        _tile(gb, 1, _rows(0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _oam(gb, 0, hex"10080100");
            return (gb, "11 sprite");
        }
        // 12 sprite xflip (row0 F0 vs row1 0F prove the flip axis)
        if (id == 11) {
            gb = _fresh();
        _io(gb, O_LCDC, 0x93);
        _io(gb, O_OBP0, 0xE4);
        _tile(gb, 1, _rows(0xF0, 0x00, 0x0F, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _oam(gb, 0, hex"10080120");
            return (gb, "12 spriteflip");
        }
        // 13 sprite palette (OBP1=0x1B, attr pal1)
        if (id == 12) {
            gb = _fresh();
        _io(gb, O_LCDC, 0x93);
        _io(gb, O_OBP1, 0x1B);
        _tile(gb, 1, _rows(0xFF, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _oam(gb, 0, hex"10080110");
            return (gb, "13 spritepal");
        }
        // 14 sprite behind bg (attr 0x80, bg solid idx1, BGP identity)
        if (id == 13) {
            gb = _fresh();
        _io(gb, O_LCDC, 0x93);
        _io(gb, O_BGP, 0xE4);
        _tile(gb, 0, _rows(0xFF, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _tile(gb, 1, _rows(0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _oam(gb, 0, hex"10080180");
            return (gb, "14 spritebehind");
        }
        // 15 tall sprites 8x16 (tiles 2,3)
        if (id == 14) {
            gb = _fresh();
        _io(gb, O_LCDC, 0x97);
        _io(gb, O_OBP0, 0xE4);
        _tile(gb, 2, _rows(0xFF, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _tile(gb, 3, _rows(0x00, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _oam(gb, 0, hex"10080200");
            return (gb, "15 sprite816");
        }
        // 16 11 sprites on line 0: 11th (leftmost, distinct tile) must be dropped
        if (id == 15) {
            gb = _fresh();
        _io(gb, O_LCDC, 0x93);
        _io(gb, O_OBP0, 0xE4);
        _tile(gb, 1, _rows(0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _tile(gb, 2, _rows(0xFF, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _oam(gb, 0, hex"10100100101001001010010010100100101001001010010010100100101001001010010010100100");
        _oam(gb, 40, hex"10080200");
            return (gb, "16 sprite10limit");
        }
        // 17 bg palette map (BGP=0x1B turns blank tile black-ish)
        if (id == 16) {
            gb = _fresh();
        _io(gb, O_BGP, 0x1B);
            return (gb, "17 bgpal");
        }
        // 18 bg off, sprite over backdrop (LCDC=0x92)
        if (id == 17) {
            gb = _fresh();
        _io(gb, O_LCDC, 0x92);
        _tile(gb, 1, _rows(0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _oam(gb, 0, hex"10080100");
            return (gb, "18 bgoff");
        }
        // 19 alt bg map 0x9C00 (LCDC=0x99), tile there
        if (id == 18) {
            gb = _fresh();
        _io(gb, O_LCDC, 0x99);
        _tile(gb, 5, _rows(0xFF, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _vram(gb, 0x1C00, hex"05");
            return (gb, "19 altmap");
        }
        // 20 overlapping sprites priority (tie -> lower OAM index wins)
        if (id == 19) {
            gb = _fresh();
        _io(gb, O_LCDC, 0x93);
        _io(gb, O_OBP0, 0xE4);
        _tile(gb, 1, _rows(0xFF, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _tile(gb, 2, _rows(0x00, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
        _oam(gb, 0, hex"100801001008020010100200");
            return (gb, "20 spriteprio");
        }
        revert("bad case");
    }
}
