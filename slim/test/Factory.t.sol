// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../GameBoy.sol";
import "../GameBoyFactory.sol";

/// @notice Factory flows: chunked-only clone games, init guards, real ROM E2E.
contract FactoryTest is Test {
    GameBoyFactory factory;
    GameBoy impl;
    address stranger = address(0xBEEF);
    /// @dev Unowned sink: bricking the implementation here models the
    ///      production deploy (nobody holds this key, so its authed paths
    ///      are dead forever while clones stay fully usable).
    address internal constant DEAD = address(0xfeEFEEfeefEeFeefEEFEEfEeFeefEEFeeFEEFEeF);

    function setUp() public {
        impl = new GameBoy(); // born bricked: no one can init/upload/play it
        factory = new GameBoyFactory(impl);
    }

    function _smallRom() internal pure returns (bytes memory rom) {
        rom = new bytes(0x800);
        rom[0x100] = bytes1(uint8(0x00)); // NOP sled
    }

    function _slice(bytes memory d, uint256 s, uint256 l) internal pure returns (bytes memory o) {
        o = new bytes(l);
        for (uint256 i = 0; i < l; i++) o[i] = d[s + i];
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
        game.loadRomStoreChunk(_smallRom());
        game.finalizeSstore2Load();
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
        game.loadRomStoreChunk(_slice(rom, 0, 0x4000));
        game.loadRomStoreChunk(_slice(rom, 0x4000, 0x4000));
        game.finalizeSstore2Load();
        // ROM readable through the clone (bank 0 store deployed)
        assertTrue(game.romStore(0) != address(0));
        assertEq(game.romSize(), rom.length);
        // curator opens crowdplay: strangers play the real ROM
        game.renounceOwnership();
        vm.prank(stranger);
        bytes memory fb = game.runFrame(0);
        assertEq(fb.length, 23040);
    }

    /// @dev Curator flow: bare clone via factory, chunked upload + boot as
    ///      owner directly on the game, play, then renounce to crowdplay.
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
}
