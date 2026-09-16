// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AaveV3Adapter} from "contracts/adapters/aave-v3/AaveV3Adapter.sol";
import {IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {CompoundCondition} from "contracts/core/CompoundCondition.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";

/// Deploy the condition module, the Shield and the Aave V3 adapter, list the
/// adapter, then hand the admin role to `SHIELD_OWNER`.
///
/// The deployer is the admin only for the length of this script: it lists the
/// adapter and offers ownership to `SHIELD_OWNER`, which accepts with one call
/// (`acceptOwnership`, Ownable2Step). Until then the deployer remains admin,
/// and a deployer key kept for gas only should never stay in that seat.
///
/// Usage:
///   SHIELD_OWNER=0x... forge script script/Deploy.s.sol:Deploy \
///       --rpc-url $RPC_URL --account <keystore> --broadcast
///
/// SHIELD_FEE_BPS (default 10) is stamped into every mandate registered on this
/// deployment; FEE_RECIPIENT (default: SHIELD_OWNER) receives it. ENFORCER, if
/// set, is appointed before the hand-off so the freeze switch is armed from
/// the first block; it must be neither the deployer nor the owner. The Aave
/// pool is chosen by chain id. Any other chain must pass AAVE_V3_POOL.
/// The broadcast file under `broadcast/` carries the transaction hashes;
/// `tools/export-artifacts.py --deployments` folds them into the manifest.
contract Deploy is Script {
    uint256 internal constant XLAYER = 196;
    uint256 internal constant ARBITRUM_ONE = 42_161;

    function run()
        external
        returns (SignoShield shield, ConditionModule conditions, AaveV3Adapter aave, CompoundCondition compound)
    {
        address owner = vm.envAddress("SHIELD_OWNER");
        return deployWith(
            owner,
            vm.envOr("FEE_RECIPIENT", owner),
            vm.envOr("ENFORCER", address(0)),
            vm.envOr("SHIELD_FEE_BPS", uint256(10))
        );
    }

    /// The deployment itself, parameterised so a test can drive it without
    /// touching the process environment.
    function deployWith(address owner, address feeRecipient, address enforcer, uint256 feeBpsRaw)
        public
        returns (SignoShield shield, ConditionModule conditions, AaveV3Adapter aave, CompoundCondition compound)
    {
        if (feeBpsRaw > type(uint16).max) revert("SHIELD_FEE_BPS out of range");
        uint16 feeBps = uint16(feeBpsRaw);
        address pool = _poolFor(block.chainid);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        if (enforcer != address(0) && (enforcer == deployer || enforcer == owner)) {
            revert("ENFORCER must be neither deployer nor owner");
        }
        conditions = new ConditionModule();
        shield = new SignoShield(deployer, conditions, feeBps);
        aave = new AaveV3Adapter(address(shield), IPool(pool));
        shield.setAdapter(address(aave), true);
        compound = new CompoundCondition(conditions);
        shield.setEvaluator(address(compound), true);
        shield.setFeeRecipient(feeRecipient);
        if (enforcer != address(0)) shield.setEnforcer(enforcer, true);
        shield.transferOwnership(owner);
        vm.stopBroadcast();

        console.log("chainId        ", block.chainid);
        console.log("ConditionModule", address(conditions));
        console.log("CompoundCondition", address(compound));
        console.log("SignoShield    ", address(shield));
        console.log("AaveV3Adapter  ", address(aave));
        console.log("Aave pool      ", pool);
        console.log("fee bps        ", feeBps);
        console.log("fee recipient  ", feeRecipient);
        console.log("enforcer       ", enforcer);
        console.log("pending owner  ", owner);
        console.log("version        ", shield.VERSION());
    }

    function _poolFor(uint256 chainId) internal view returns (address) {
        if (chainId == XLAYER) return 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
        if (chainId == ARBITRUM_ONE) return 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
        return vm.envAddress("AAVE_V3_POOL");
    }
}
