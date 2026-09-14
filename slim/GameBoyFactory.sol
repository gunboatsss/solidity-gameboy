// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GameBoy.sol";

/// @title GameBoyFactory — trustless crowdplay games via EIP-1167 clones.
/// @notice create() deploys a 45-byte minimal proxy to the implementation,
///         owned by the caller, who then uploads the ROM in 16KB chunks +
///         finalizes + plays/renounces directly on the game (no further
///         factory interaction). Chunked upload is the only ROM ingress:
///         it fits any ROM size under per-tx gas caps.
///         (The factory is tiny because game bytecode lives in the single
///         implementation contract, not inlined per deployment.)
contract GameBoyFactory {
    GameBoy public immutable implementation;

    event GameCreated(address indexed game, address indexed creator, bytes32 romHash);

    error NoCode();

    constructor(GameBoy _implementation) {
        if (address(_implementation).code.length == 0) revert NoCode();
        implementation = _implementation;
    }

    /// @dev Deploy a bare clone owned by the caller for chunked upload
    ///      (loadRomStoreChunk + finalizeSstore2Load, all directly on the game).
    function create() external returns (GameBoy game) {
        game = _clone();
        game.initialize(msg.sender);
        emit GameCreated(address(game), msg.sender, bytes32(0));
    }

    /// @dev EIP-1167 minimal proxy (verbatim OpenZeppelin Clones assembly).
    function _clone() internal returns (GameBoy game) {
        address impl = address(implementation);
        address clone;
        assembly {
            mstore(0x00, or(shr(232, shl(96, impl)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(120, impl), 0x5af43d82803e903d91602b57fd5bf3))
            clone := create(0, 0x09, 0x37)
            if iszero(clone) { revert(0, 0) }
        }
        game = GameBoy(clone);
    }
}
