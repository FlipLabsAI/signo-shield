// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3Adapter} from "contracts/adapters/aave-v3/AaveV3Adapter.sol";
import {IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ICondition} from "contracts/core/interfaces/ICondition.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";

/// The whole story in one script, against a fork of X Layer: the user opens
/// a small Aave position and signs one mandate; the agent fires it; the debt
/// falls; the same mandate is then refused because the trigger is no longer
/// true. No Signo service is involved: two keys and the contracts.
///
/// Run through `tools/demo-fork.sh`, which starts the fork, funds the demo
/// wallet and deploys the contracts first. Env: SHIELD, ADAPTER,
/// PRINCIPAL_KEY, AGENT_KEY.
contract RegisterAndFire is Script {
    address internal constant POOL = 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
    address internal constant XETH = 0xE7B000003A45145decf8a28FC755aD5eC5EA025A;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant V_USDT0 = 0x04837866D0cb0cd2D8F60fBCa83B4a24b3a7c8ac;

    function run() external {
        SignoShield shield = SignoShield(vm.envAddress("SHIELD"));
        AaveV3Adapter adapter = AaveV3Adapter(vm.envAddress("ADAPTER"));
        uint256 principalKey = vm.envUint("PRINCIPAL_KEY");
        uint256 agentKey = vm.envUint("AGENT_KEY");
        address principal = vm.addr(principalKey);
        address agent = vm.addr(agentKey);
        IPool pool = IPool(POOL);

        // 1. The user, from their own wallet: a position, one allowance to the
        //    Shield, one mandate. The agent is named; it signs nothing here.
        vm.startBroadcast(principalKey);
        IERC20(XETH).approve(POOL, 0.05e18);
        pool.supply(XETH, 0.05e18, principal, 0);
        pool.borrow(USDT0, 60e6, 2, 0, principal);
        IERC20(USDT0).approve(address(shield), 40e6);
        ISignoShield.MandateParams memory p;
        p.agent = agent;
        p.adapter = address(adapter);
        p.action = adapter.ACTION_REPAY();
        p.asset = USDT0;
        p.maxTransactionValue = 20e6;
        p.maxCumulativeValue = 40e6;
        p.validUntil = uint48(block.timestamp + 30 days);
        p.condition = ICondition.Condition({
            target: POOL,
            callData: abi.encodeCall(IPool.getUserAccountData, (principal)),
            wordOffset: 5,
            comparator: ICondition.Comparator.LessThan,
            threshold: 1.6e18
        });
        bytes32 id = shield.registerMandate(p);
        vm.stopBroadcast();

        console.log("principal          ", principal);
        console.log("agent              ", agent);
        console.log("mandate            ", vm.toString(id));
        _report(shield, pool, principal, id, "before");

        // 2. The agent fires. Its whole authority is this one call.
        vm.startBroadcast(agentKey);
        uint256 spent = shield.fire(id, 10e6, "");
        vm.stopBroadcast();
        console.log("spent (USDT0, 6dp) ", spent);
        _report(shield, pool, principal, id, "after");
    }

    function _report(SignoShield shield, IPool pool, address principal, bytes32 id, string memory label)
        internal
        view
    {
        (,,,,, uint256 hf) = pool.getUserAccountData(principal);
        (bool ok, ISignoShield.MandateReason reason) = shield.canFire(id, 10e6);
        console.log(string.concat("--- ", label));
        console.log("debt (USDT0, 6dp)  ", IERC20(V_USDT0).balanceOf(principal));
        console.log("health factor (1e18)", hf);
        console.log("canFire(10 USDT0)  ", ok);
        console.log("reason code        ", uint256(reason));
        console.log("budget used        ", shield.getMandate(id).cumulativeUsed);
    }
}
