// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Minimal SSTORE2-style blob storage (data lives in contract bytecode)
/// @notice Each store holds 0x00 (STOP, so calls halt) ++ data.
///         Deploy cost is ~200 gas/byte of code (EIP-170: max 24576 bytes per
///         store). Reads use EXTCODECOPY (2600 cold / 100 warm per store per
///         tx, plus 3 gas/word) and zero-pad past the end.
library Sstore2 {
    /// @dev Deploy `data` (max 16KB) as a code blob. Returns store address.
    function write(bytes memory data) internal returns (address ptr) {
        uint256 dlen = data.length;
        require(dlen > 0 && dlen <= 0x4000, "bad blob");
        uint256 rlen = dlen + 1; // + STOP prefix
        // init (15B): PUSH2 L DUP1 PUSH1 0x0F PUSH1 0 CODECOPY PUSH2 L PUSH1 0 RETURN
        // then 0x00 ++ data; CODECOPY copies code[15:15+L] to mem and returns it.
        bytes memory init = abi.encodePacked(
            hex"61",
            uint16(rlen),
            hex"80",
            hex"600F",
            hex"6000",
            hex"39",
            hex"61",
            uint16(rlen),
            hex"6000",
            hex"F3",
            hex"00",
            data
        );
        assembly {
            ptr := create(0, add(init, 32), mload(init))
        }
        require(ptr != address(0), "deploy failed");
    }

    /// @dev Read `n` bytes at data offset `start` (zero-padded past the end).
    function read(address ptr, uint256 start, uint256 n) internal view returns (bytes memory out) {
        out = new bytes(n);
        if (n == 0) return out;
        assembly {
            // +1 skips the STOP prefix byte
            extcodecopy(ptr, add(out, 32), add(start, 1), n)
        }
    }
}
