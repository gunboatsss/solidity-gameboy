// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../GameBoy.sol";
import "../GameBoyFactory.sol";
import "../GameBoyHelper.sol";

/// @notice Large-build factory flows: chunked-only clone games (SSTORE2 and
///         storage upload paths), init guards, views, real ROM E2E.
///         Direct deploys are born bricked (owner = DEAD sink).
contract FactoryTest is Test {
    GameBoyFactory factory;
    GameBoy impl;
    GameBoyHelper helper;
    address stranger = address(0xBEEF);
    /// @dev Unowned sink matching the implementation's constructor owner.
    address internal constant DEAD = address(0xfeEFEEfeefEeFeefEEFEEfEeFeefEEFeeFEEFEeF);

    function setUp() public {
        impl = new GameBoy(); // born bricked: no one can init/upload/play it
        factory = new GameBoyFactory(impl);
        helper = new GameBoyHelper();
    }

    function _smallRom() internal pure returns (bytes memory rom) {
        rom = new bytes(0x800);
        rom[0x100] = bytes1(uint8(0x00)); // NOP sled
    }

    function _slice(bytes memory d, uint256 s, uint256 l) internal pure returns (bytes memory o) {
        o = new bytes(l);
        for (uint256 i = 0; i < l; i++) o[i] = d[s + i];
    }

    function _uploadSstore2(GameBoy game, bytes memory rom) internal {
        for (uint256 off = 0; off < rom.length; off += 0x4000) {
            uint256 len = rom.length - off > 0x4000 ? 0x4000 : rom.length - off;
            game.loadRomStoreChunk(_slice(rom, off, len));
        }
        game.finalizeSstore2Load();
    }

    function test_CreateStartsBare() public {
        GameBoy game = factory.create();
        // curator-owned, empty, strangers cannot touch it
        assertEq(game.owner(), address(this));
        assertEq(game.romSize(), 0);
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        game.runFrame(0);
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        game.loadRomStoreChunk(new bytes(16));
    }

    /// @dev The bricked implementation rejects everyone (even its deployer):
    ///      init, uploads, play, renounce all revert. Clones keep their own
    ///      storage via delegatecall, so they boot + play fine regardless.
    function test_ImplementationBricked() public {
        assertEq(impl.owner(), DEAD);
        // nobody can init it — not strangers, not the deployer
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        impl.initialize(address(0));
        vm.expectRevert(NotOwner.selector);
        impl.initialize(address(this));
        // uploads + play + renounce are dead too
        vm.expectRevert(NotOwner.selector);
        impl.loadRomStoreChunk(new bytes(16));
        vm.expectRevert(NotOwner.selector);
        impl.finalizeSstore2Load();
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        impl.runFrame(0);
        vm.expectRevert(NotOwner.selector);
        impl.renounceOwnership();
        // ...and clones are unaffected
        GameBoy game = factory.create();
        _uploadSstore2(game, _smallRom());
        game.renounceOwnership();
        vm.prank(stranger);
        assertEq(game.runFrame(0).length, 23040);
    }

    function test_CloneCannotReinit() public {
        // owner can rotate ownership while pristine...
        GameBoy game = factory.create();
        game.initialize(stranger);
        assertEq(game.owner(), stranger);
        // ...but in-progress uploads lock init
        GameBoy b2 = factory.create();
        b2.loadRomStoreChunk(_smallRom());
        vm.expectRevert(Locked.selector);
        b2.initialize(address(this));
        // ...and booted games lock init too
        b2.finalizeSstore2Load();
        vm.expectRevert(Locked.selector);
        b2.initialize(address(this));
        // ...and strangers can never hijack a pristine game
        GameBoy bare2 = factory.create();
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        bare2.initialize(stranger);
    }

    function test_CreateRealRom() public {
        bytes memory rom = vm.readFileBinary("./test/roms/01-special.gb");
        GameBoy game = factory.create();
        _uploadSstore2(game, rom);
        assertEq(game.romSize(), rom.length);
        // ROM readable through the clone (bank 0 store deployed)
        assertTrue(game.romStore(0) != address(0));
        // curator opens crowdplay: strangers play the real ROM
        game.renounceOwnership();
        vm.prank(stranger);
        bytes memory fb = game.runFrame(0);
        assertEq(fb.length, 23040);
        vm.prank(stranger);
        (uint32 ex,,) = game.step(16000, 0);
        assertGt(ex, 0);
    }

    /// @dev Storage upload path also works on clones (big-limit chains have
    ///      no reason to restrict ingress to SSTORE2).
    function test_StorageUploadPath() public {
        GameBoy game = factory.create();
        bytes memory rom = _smallRom();
        game.loadRomChunk(0, rom);
        game.finalizeLoad();
        (,,,,,,,,, uint16 pc) = game.regs();
        game.runFrame(0);
        (,,,,,,,,, uint16 pc2) = game.regs();
        assertTrue(pc2 != pc); // advanced: weren't halted at entry
    }

    /// @dev Curator flow: chunked SSTORE2 upload + boot as owner directly on
    ///      the game, play, then renounce to crowdplay.
    function test_BareCuratorFlow() public {
        GameBoy game = factory.create();
        assertEq(game.owner(), address(this));
        // stranger cannot touch it
        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        game.runFrame(0);
        // curator uploads two chunks + boots, all directly (no factory relay)
        bytes memory c1 = new bytes(0x4000);
        bytes memory c2 = new bytes(0x200);
        c1[0x100] = bytes1(uint8(0x00)); // NOP sled so it executes
        game.loadRomStoreChunk(c1);
        game.loadRomStoreChunk(c2);
        game.finalizeSstore2Load();
        (,,,,,,,,, uint16 pc) = game.regs();
        game.runFrame(0);
        (,,,,,,,,, uint16 pc2) = game.regs();
        assertTrue(pc2 != pc); // advanced: weren't halted at entry
        // curator plays, then opens crowdplay
        game.renounceOwnership();
        assertEq(game.owner(), address(0));
        vm.prank(stranger);
        game.runFrame(0);
    }

    function test_OwnerControls() public {
        address stranger2 = address(0xBEEF);
        GameBoy g = factory.create();
        _uploadSstore2(g, _smallRom());
        // non-owner cannot play or upload
        vm.prank(stranger2);
        vm.expectRevert(NotOwner.selector);
        g.runFrame(0);
        vm.prank(stranger2);
        vm.expectRevert(NotOwner.selector);
        g.loadRomStoreChunk(new bytes(16));
        // owner plays fine
        g.runFrame(0);
        // finalize cannot reset a live game (locked even for owner)
        vm.expectRevert(Locked.selector);
        g.finalizeSstore2Load();
        // non-owner cannot renounce
        vm.prank(stranger2);
        vm.expectRevert(NotOwner.selector);
        g.renounceOwnership();
        // renounce opens play to everyone...
        g.renounceOwnership();
        vm.prank(stranger2);
        g.step(100, 0);
        vm.prank(stranger2);
        g.runFrame(0);
        // ...but uploads stay locked forever (owner is zero: everyone fails auth)
        vm.expectRevert(NotOwner.selector);
        g.finalizeSstore2Load();
        vm.prank(stranger2);
        vm.expectRevert(NotOwner.selector);
        g.loadRomStoreChunk(new bytes(16));
    }

    function test_Guards() public {
        GameBoy bare = factory.create();
        // unbooted games refuse play/step
        vm.expectRevert("no ROM");
        bare.runFrame(0);
        vm.expectRevert("no ROM");
        bare.step(100, 0);
        // oversize budgets revert
        _uploadSstore2(bare, _smallRom());
        vm.expectRevert("bad budget");
        bare.step(20001, 0);
        // unsupported mappers fail loudly at finalize
        GameBoy bad = factory.create();
        bytes memory rom = new bytes(0x8000);
        rom[0x147] = bytes1(0x05);
        bad.loadRomStoreChunk(_slice(rom, 0, 0x4000));
        bad.loadRomStoreChunk(_slice(rom, 0x4000, 0x4000));
        vm.expectRevert("unsupported MBC");
        bad.finalizeSstore2Load();
    }

    function test_Views() public {
        GameBoy game = factory.create();
        _uploadSstore2(game, _smallRom());
        // slim-compatible views read live state
        (uint8 a,,,,,,,,,) = game.regs();
        assertEq(a, 0x01); // post-boot reset value
        (uint8 lcdc,,,,,,,) = game.ppuRegs();
        assertEq(lcdc, 0x91); // LCD on by default
        assertEq(game.readMem(0x8000, 2).length, 2);
        assertEq(game.readMem(0xFE00, 0xA0).length, 0xA0);
        assertTrue(game.romStore(0) != address(0));
        assertEq(game.romSize(), 0x800);
        // full snapshot via the helper agrees
        GbState memory s = helper.fullState(game);
        assertTrue(s.booted);
        assertEq(s.romLen, 0x800);
        (,,,,,,,,, uint16 pc) = helper.regs(game);
        assertEq(pc, 0x100); // entry point before first frame
    }
}
