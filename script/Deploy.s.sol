// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";

/// Deploy the Shield and print what `tools/export-artifacts.sh` needs for the
/// deployments manifest: chain id, address, deploy transaction and the source
/// commit the bytecode came from.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast
///
/// The broadcast file under `broadcast/` carries the transaction hash; the
/// export tool reads it rather than asking anyone to copy it by hand.
contract Deploy is Script {
    function run() external returns (SignoShield shield) {
        vm.startBroadcast();
        shield = new SignoShield();
        vm.stopBroadcast();

        console.log("chainId ", block.chainid);
        console.log("address ", address(shield));
        console.log("version ", shield.VERSION());
    }
}
