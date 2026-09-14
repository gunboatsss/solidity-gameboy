// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../large/GameBoy.sol";
import "../large/GameBoyFactory.sol";

/// @notice Deploy the large build (full features + factory init flow).
///         Targets big-limit chains (Monad 128KB, Robinhood 96KB) — no
///         slimming needed. Select the network per command
///         (e.g. `--network monad`); the large profile stays neutral.
///         Run against Monad testnet (funded key) or local Anvil
///         (`anvil --network monad` for Monad rules):
///           FOUNDRY_PROFILE=large forge script script/DeployLarge.s.sol \
///             --rpc-url $RPC_URL --broadcast --private-key $DEPLOY_KEY
///         (local: replace key flags with `--unlocked --sender <addr>`).
///         Writes frontend/.env with the deployed addresses. The UI speaks
///         the slim API subset, which large/GameBoy implements with identical
///         signatures — no frontend changes needed; optionally refresh its
///         ABIs for the extra views (getState, loadRomChunk, ...):
///           jq .abi out-large/GameBoy.sol/GameBoy.json > frontend/src/abi/GameBoy.json
///           jq .abi out-large/GameBoyFactory.sol/GameBoyFactory.json > frontend/src/abi/GameBoyFactory.json
contract DeployLarge is Script {
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
