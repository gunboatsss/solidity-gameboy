// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../monad/GameBoy.sol";
import "../monad/GameBoyFactory.sol";

/// @notice Deploy the Monad build (full features + factory init flow).
///         Monad's 128KB code limit fits the full GameBoy (no slimming).
///         Requires nightly Foundry with Monad support; the monad profile
///         sets `network = "monad"` so builds/scripts follow Monad rules.
///         Run against Monad testnet (funded key) or local Anvil:
///           anvil --network monad --gas-limit 100000000 &
///           FOUNDRY_PROFILE=monad forge script script/DeployMonad.s.sol \
///             --rpc-url $RPC_URL --broadcast --private-key $DEPLOY_KEY
///         (local: replace key flags with `--unlocked --sender <addr>`).
///         Writes frontend/.env with the deployed addresses. The UI speaks
///         the slim API subset, which monad/GameBoy implements with identical
///         signatures — no frontend changes needed; optionally refresh its
///         ABIs for the extra views (getState, loadRomChunk, ...):
///           jq .abi out-monad/GameBoy.sol/GameBoy.json > frontend/src/abi/GameBoy.json
///           jq .abi out-monad/GameBoyFactory.sol/GameBoyFactory.json > frontend/src/abi/GameBoyFactory.json
contract DeployMonad is Script {
    function run() external {
        vm.startBroadcast();
        GameBoy impl = new GameBoy(); // born bricked (owner = DEAD sink)
        GameBoyFactory factory = new GameBoyFactory(impl);
        vm.stopBroadcast();
        string memory env_ = string.concat(
            "VITE_RPC_URL=",
            vm.envOr("RPC_URL", string("http://127.0.0.1:8545")),
            "\n",
            "VITE_CHAIN_ID=",
            vm.toString(block.chainid),
            "\n",
            "VITE_IMPL_ADDRESS=",
            vm.toString(address(impl)),
            "\n",
            "VITE_FACTORY_ADDRESS=",
            vm.toString(address(factory)),
            "\n"
        );
        vm.writeFile("./frontend/.env", env_);
        console.log("impl:   ", address(impl));
        console.log("factory:", address(factory));
    }
}
