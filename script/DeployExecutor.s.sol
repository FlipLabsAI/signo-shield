// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {GenericExecutor} from "contracts/executors/GenericExecutor.sol";

/// Deploy the Tier 1 generic executor for an already-deployed Shield
/// (FLIP-238). Listing it (`setAdapter`) is the admin's transaction, not this
/// script's: the deployer holds no seat after the hand-off.
///
///   SHIELD=0x... forge script script/DeployExecutor.s.sol --rpc-url $RPC \
///     --broadcast --account signo-shield-deployer --password-file ...
contract DeployExecutor is Script {
    function run() external returns (GenericExecutor executor) {
        address shield = vm.envAddress("SHIELD");
        vm.startBroadcast();
        executor = new GenericExecutor(shield);
        vm.stopBroadcast();
    }
}
