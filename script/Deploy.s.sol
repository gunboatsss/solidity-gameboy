// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../slim/GameBoy.sol";
import "../slim/GameBoyFactory.sol";

/// @notice Deploy impl + factory for the frontend (slim build, 24KiB profile).
///         Run against local Anvil (its dev accounts are unlocked, no key needed):
///           anvil &
///           FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol \
///             --rpc-url http://127.0.0.1:8545 --broadcast --unlocked \
///             --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
///         Writes frontend/.env with the deployed addresses.
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        GameBoy impl = new GameBoy(); // born bricked (owner = DEAD sink)
        GameBoyFactory factory = new GameBoyFactory(impl);
        vm.stopBroadcast();
        string memory env_ = string.concat(
            "VITE_RPC_URL=",
            vm.envOr("RPC_URL", string("http://127.0.0.1:8545")),
            "\n",
            "VITE_CHAIN_ID=31337\n",
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
