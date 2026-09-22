// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {GenericExecutor} from "contracts/executors/GenericExecutor.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAdapter} from "../mocks/MockAdapter.sol";

// These are executable interpretations of Draft 2.1, NOT a v1 implementation.
// The migration and debt-repayment tests below use the actual v0.1 contracts.

/// Permissionless claim to a beneficiary-fixed receiver. The caller cannot redirect it.
contract Draft21RewardSource {
    IERC20 public immutable reward;
    address public immutable beneficiary;
    address public immutable receiver;
    uint256 public remaining;

    constructor(IERC20 token, address owner, address to, uint256 entitlement) {
        reward = token;
        beneficiary = owner;
        receiver = to;
        remaining = entitlement;
    }

    function claim(address owner) external {
        require(owner == beneficiary, "wrong beneficiary");
        uint256 amount = remaining;
        remaining = 0;
        require(reward.transfer(receiver, amount));
    }
}

/// A caller-funded route; no arbitrary payer, permit, or prior owner allowance.
contract Draft21CallerRoute {
    function forward(IERC20 token, uint256 amount, address recipient) external {
        require(token.transferFrom(msg.sender, recipient, amount));
    }

    function reinvest(IERC20 reward, MockERC20 receipt, uint256 amount) external {
        require(reward.transferFrom(msg.sender, address(this), amount));
        receipt.mint(msg.sender, amount);
    }
}

contract Draft21ClaimSandbox {
    struct Call {
        address target;
        address spender;
        IERC20 approveToken;
        uint256 approveAmount;
        bytes data;
    }

    address public immutable driver = msg.sender;
    bool public used;

    function run(
        address principal,
        IERC20 reward,
        IERC20 receipt,
        address claimSource,
        address route,
        Call[] calldata calls
    ) external {
        require(msg.sender == driver && !used, "driver or used");
        used = true;
        uint256 beforeReward = reward.balanceOf(principal);
        for (uint256 i; i < calls.length; i++) {
            Call calldata c = calls[i];
            // Exact approved pair, not independent membership checks.
            require(
                (c.target == claimSource && c.spender == claimSource)
                    || (c.target == route && c.spender == route),
                "pair"
            );
            require(c.approveToken == reward || c.approveToken == receipt, "token");
            require(c.approveToken.approve(c.spender, c.approveAmount));
            (bool ok,) = c.target.call(c.data);
            require(ok, "call");
            require(c.approveToken.approve(c.spender, 0));
        }
        require(reward.transfer(principal, reward.balanceOf(address(this))));
        require(receipt.transfer(principal, receipt.balanceOf(address(this))));
        require(reward.balanceOf(address(this)) == 0 && receipt.balanceOf(address(this)) == 0, "sweep");
        require(reward.balanceOf(principal) > beforeReward, "mandatory claim delta");
        // An explicit, nonempty custom expression 1 == 1 adds no protection.
        require(uint256(1) == uint256(1), "custom outcome");
    }
}

contract Draft21ExtraPull {
    function takeExtra(IERC20 token, address owner, address recipient, uint256 extra) external {
        require(token.transferFrom(owner, recipient, extra));
    }
}

/// Literal interpretation of "take the larger ... capped at the amount".
contract Draft21Accounting {
    uint256 public budgetUsed;

    function fire(IERC20 token, Draft21ExtraPull venue, uint256 amount, bool rejectExcess) external {
        uint256 beforeBalance = token.balanceOf(msg.sender);
        require(token.transferFrom(msg.sender, address(venue), amount));
        venue.takeExtra(token, msg.sender, address(venue), 20);
        uint256 measured = beforeBalance - token.balanceOf(msg.sender);
        uint256 reported = amount;
        if (rejectExcess) require(measured <= amount && reported <= amount, "excess");
        uint256 charged = measured > reported ? measured : reported;
        budgetUsed += charged > amount ? amount : charged;
    }
}

contract Draft21FinalState {
    uint64 public lastFiredAt;

    function outcome() public view returns (bool) {
        return lastFiredAt == 0;
    }

    function fire() external {
        require(outcome(), "outcome");
        lastFiredAt = uint64(block.timestamp);
    }
}

interface IDraft21Kind {
    enum Kind {
        INPUT,
        NO_INPUT
    }
    function supportsAction(bytes32 action) external view returns (Kind);
}

contract Draft21FutureKind {
    function supportsAction(bytes32) external pure returns (uint8) {
        return 2; // A new POSITION value cannot be decoded by the two-value enum.
    }
}

contract Draft21LogicOne {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract Draft21LogicTwo {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract Draft21UpgradeableVenue is ERC1967Proxy {
    address internal immutable admin;

    receive() external payable {}

    constructor(address implementation)
        ERC1967Proxy(implementation, abi.encodeCall(Draft21LogicOne.version, ()))
    {
        admin = msg.sender;
    }

    function upgradeTo(address implementation) external {
        require(msg.sender == admin);
        ERC1967Utils.upgradeToAndCall(implementation, "");
    }

    function implementationNow() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}

contract Draft21DailyMonitor {
    address public immutable approvedImplementation;
    bool public suspended;

    constructor(address approved) {
        approvedImplementation = approved;
    }

    function poll(Draft21UpgradeableVenue venue) external {
        if (venue.implementationNow() != approvedImplementation) suspended = true;
    }

    function fire(address venue) external view returns (uint256) {
        require(!suspended, "suspended");
        return Draft21LogicOne(venue).version();
    }
}

contract Draft21Batch {
    function revoke(SignoShield oldCore, bytes32 oldId) external {
        oldCore.revokeMandate(oldId);
    }

    function register(SignoShield core, ISignoShield.MandateParams calldata p) external returns (bytes32) {
        return core.registerMandate(p);
    }

    function migrate(
        SignoShield oldCore,
        bytes32 oldId,
        SignoShield newCore,
        ISignoShield.MandateParams calldata p
    ) external returns (bytes32) {
        oldCore.revokeMandate(oldId);
        return newCore.registerMandate(p);
    }
}

contract Draft21DebtToken is MockERC20 {
    constructor() MockERC20("Debt", "D", 18) {}

    function reduce(address owner, uint256 amount) external {
        _burn(owner, amount);
    }
}

contract Draft21RepayVenue {
    function repay(IERC20 input, Draft21DebtToken debt, address owner, uint256 amount) external {
        require(input.transferFrom(msg.sender, address(this), amount));
        debt.reduce(owner, amount);
    }
}

contract FLIP270Draft21Test is Test {
    address internal principal = makeAddr("draft21-principal");
    address internal thief = makeAddr("draft21-thief");

    function claimFixture(uint256 total)
        internal
        returns (
            MockERC20 reward,
            MockERC20 receipt,
            Draft21ClaimSandbox sandbox,
            Draft21RewardSource source,
            Draft21CallerRoute route
        )
    {
        reward = new MockERC20("Reward", "R", 18);
        receipt = new MockERC20("Receipt", "P", 18);
        sandbox = new Draft21ClaimSandbox();
        source = new Draft21RewardSource(reward, principal, address(sandbox), total);
        route = new Draft21CallerRoute();
        reward.mint(address(source), total);
    }

    function test_claimCanDivert99Of100WhileAllDeclaredChecksPass() public {
        (
            MockERC20 reward,
            MockERC20 receipt,
            Draft21ClaimSandbox sandbox,
            Draft21RewardSource source,
            Draft21CallerRoute route
        ) = claimFixture(100);
        Draft21ClaimSandbox.Call[] memory calls = new Draft21ClaimSandbox.Call[](2);
        calls[0] = Draft21ClaimSandbox.Call(
            address(source), address(source), reward, 0, abi.encodeCall(source.claim, (principal))
        );
        calls[1] = Draft21ClaimSandbox.Call(
            address(route), address(route), reward, 99, abi.encodeCall(route.forward, (reward, 99, thief))
        );
        sandbox.run(principal, reward, receipt, address(source), address(route), calls);
        assertEq(source.remaining(), 0);
        assertEq(reward.balanceOf(principal), 1);
        assertEq(reward.balanceOf(thief), 99);
        assertEq(reward.balanceOf(address(sandbox)), 0);
        assertEq(reward.allowance(address(sandbox), address(route)), 0);
        assertEq(reward.allowance(principal, address(route)), 0, "no old owner approval used");
    }

    function test_completeClaimSweepsAllRewardsToOwner() public {
        (
            MockERC20 reward,
            MockERC20 receipt,
            Draft21ClaimSandbox sandbox,
            Draft21RewardSource source,
            Draft21CallerRoute route
        ) = claimFixture(100);
        Draft21ClaimSandbox.Call[] memory calls = new Draft21ClaimSandbox.Call[](1);
        calls[0] = Draft21ClaimSandbox.Call(
            address(source), address(source), reward, 0, abi.encodeCall(source.claim, (principal))
        );
        sandbox.run(principal, reward, receipt, address(source), address(route), calls);
        assertEq(reward.balanceOf(principal), 100);
    }

    function test_fullReinvestmentFailsTheMandatoryRewardBalanceCheck() public {
        (
            MockERC20 reward,
            MockERC20 receipt,
            Draft21ClaimSandbox sandbox,
            Draft21RewardSource source,
            Draft21CallerRoute route
        ) = claimFixture(100);
        Draft21ClaimSandbox.Call[] memory calls = new Draft21ClaimSandbox.Call[](2);
        calls[0] = Draft21ClaimSandbox.Call(
            address(source), address(source), reward, 0, abi.encodeCall(source.claim, (principal))
        );
        calls[1] = Draft21ClaimSandbox.Call(
            address(route),
            address(route),
            reward,
            100,
            abi.encodeCall(route.reinvest, (reward, receipt, 100))
        );
        vm.expectRevert("mandatory claim delta");
        sandbox.run(principal, reward, receipt, address(source), address(route), calls);
        assertEq(source.remaining(), 100, "entitlement rolled back");
        assertEq(receipt.balanceOf(principal), 0, "receipt rolled back");
        assertFalse(sandbox.used(), "clone flag rolled back");
    }

    function test_literalSpendClampHidesExcessOwnerLoss() public {
        MockERC20 token = new MockERC20("Input", "I", 18);
        Draft21ExtraPull venue = new Draft21ExtraPull();
        Draft21Accounting core = new Draft21Accounting();
        token.mint(principal, 1000);
        vm.startPrank(principal);
        token.approve(address(core), 100);
        token.approve(address(venue), 20);
        core.fire(token, venue, 100, false);
        vm.stopPrank();
        assertEq(token.balanceOf(principal), 880);
        assertEq(core.budgetUsed(), 100, "120 lost but only 100 recorded");
    }

    function test_rejectingExcessSpendRollsBackAllMovement() public {
        MockERC20 token = new MockERC20("Input", "I", 18);
        Draft21ExtraPull venue = new Draft21ExtraPull();
        Draft21Accounting core = new Draft21Accounting();
        token.mint(principal, 1000);
        vm.startPrank(principal);
        token.approve(address(core), 100);
        token.approve(address(venue), 20);
        vm.expectRevert("excess");
        core.fire(token, venue, 100, true);
        vm.stopPrank();
        assertEq(token.balanceOf(principal), 1000);
        assertEq(core.budgetUsed(), 0);
    }

    function test_bookkeepingAfterFinalJudgementCanInvalidateIt() public {
        vm.warp(1000);
        Draft21FinalState core = new Draft21FinalState();
        core.fire();
        assertFalse(core.outcome(), "the accepted read is false in the final state");
    }

    function decodeFutureKind(address future) external view returns (IDraft21Kind.Kind) {
        return IDraft21Kind(future).supportsAction(bytes32(0));
    }

    function test_twoKindABIRejectsFuturePositionEnumValue() public {
        Draft21FutureKind future = new Draft21FutureKind();
        vm.expectRevert();
        this.decodeFutureKind(address(future));
    }

    function test_upgradeCanFireBeforeDailyMonitorSuspendsIt() public {
        Draft21LogicOne oldLogic = new Draft21LogicOne();
        Draft21UpgradeableVenue venue = new Draft21UpgradeableVenue(address(oldLogic));
        Draft21DailyMonitor monitor = new Draft21DailyMonitor(address(oldLogic));
        assertEq(monitor.fire(address(venue)), 1);
        bytes32 oldCodeHash = address(venue).codehash;
        Draft21LogicTwo newLogic = new Draft21LogicTwo();
        venue.upgradeTo(address(newLogic));
        assertEq(address(venue).codehash, oldCodeHash, "proxy code hash did not change");
        assertEq(monitor.fire(address(venue)), 2, "unreviewed implementation is reachable before detection");
        monitor.poll(venue);
        vm.expectRevert("suspended");
        monitor.fire(address(venue));
    }

    function deltaRatio(uint256 beforeValue, uint256 currentValue) external pure returns (uint256) {
        return 100 / (currentValue - beforeValue);
    }

    function test_equalBeforeDryRunRejectsAnOtherwiseValidDeltaRatio() public {
        vm.expectRevert(stdError.divisionError);
        this.deltaRatio(100, 100);
        assertEq(this.deltaRatio(100, 110), 10);
    }

    function migrationFixture()
        internal
        returns (
            SignoShield oldCore,
            SignoShield newCore,
            ISignoShield.MandateParams memory oldP,
            ISignoShield.MandateParams memory newP
        )
    {
        ConditionModule evaluator = new ConditionModule();
        oldCore = new SignoShield(address(this), evaluator, 10);
        newCore = new SignoShield(address(this), evaluator, 10);
        MockAdapter oldExecutor = new MockAdapter(address(oldCore));
        MockAdapter newExecutor = new MockAdapter(address(newCore));
        oldCore.setAdapter(address(oldExecutor), true);
        newCore.setAdapter(address(newExecutor), true);
        MockERC20 token = new MockERC20("Input", "I", 18);
        oldP.agent = makeAddr("draft21-agent");
        oldP.adapter = address(oldExecutor);
        oldP.action = oldExecutor.ACTION();
        oldP.asset = address(token);
        oldP.maxTransactionValue = 100;
        oldP.maxCumulativeValue = 1000;
        oldP.validUntil = uint48(block.timestamp + 1 days);
        newP = oldP;
        newP.adapter = address(newExecutor);
        // Solidity memory struct assignment aliases: restore an independent old struct below.
        oldP = ISignoShield.MandateParams({
            agent: oldP.agent,
            adapter: address(oldExecutor),
            action: oldExecutor.ACTION(),
            asset: address(token),
            maxTransactionValue: 100,
            maxCumulativeValue: 1000,
            validFrom: 0,
            validUntil: uint48(block.timestamp + 1 days),
            condition: oldP.condition,
            actionConfig: bytes("")
        });
    }

    function test_ordinaryMulticallCannotRevokeAnEOAsMandate() public {
        (SignoShield oldCore,, ISignoShield.MandateParams memory p,) = migrationFixture();
        vm.prank(principal);
        bytes32 oldId = oldCore.registerMandate(p);
        Draft21Batch batch = new Draft21Batch();
        vm.expectRevert(ISignoShield.NotPrincipal.selector);
        vm.prank(principal);
        batch.revoke(oldCore, oldId);
        assertFalse(oldCore.getMandate(oldId).revoked);
    }

    function test_ownerAccountBatchRevokesOldAndRegistersNewAtomically() public {
        (
            SignoShield oldCore,
            SignoShield newCore,
            ISignoShield.MandateParams memory oldP,
            ISignoShield.MandateParams memory newP
        ) = migrationFixture();
        Draft21Batch ownerAccount = new Draft21Batch();
        bytes32 oldId = ownerAccount.register(oldCore, oldP);
        bytes32 newId = ownerAccount.migrate(oldCore, oldId, newCore, newP);
        assertTrue(oldCore.getMandate(oldId).revoked);
        assertEq(newCore.getMandate(newId).principal, address(ownerAccount));
    }

    function test_failedNewRegistrationRollsBackOwnerAccountRevocation() public {
        (
            SignoShield oldCore,
            SignoShield newCore,
            ISignoShield.MandateParams memory oldP,
            ISignoShield.MandateParams memory newP
        ) = migrationFixture();
        Draft21Batch ownerAccount = new Draft21Batch();
        bytes32 oldId = ownerAccount.register(oldCore, oldP);
        newP.agent = address(0);
        vm.expectRevert();
        ownerAccount.migrate(oldCore, oldId, newCore, newP);
        assertFalse(oldCore.getMandate(oldId).revoked, "revoke rolled back with the failed batch");
    }

    function test_actualTokenIncreaseRuleRejectsSuccessfulDebtRepayment() public {
        (SignoShield core,, ISignoShield.MandateParams memory p,) = migrationFixture();
        GenericExecutor executor = new GenericExecutor(address(core));
        core.setAdapter(address(executor), true);
        Draft21RepayVenue venue = new Draft21RepayVenue();
        Draft21DebtToken debt = new Draft21DebtToken();
        MockERC20 input = MockERC20(p.asset);
        input.mint(principal, 1000);
        debt.mint(principal, 1000);
        p.adapter = address(executor);
        p.action = executor.ACTION_TRANSFORM();
        p.actionConfig = abi.encode(
            GenericExecutor.TransformConfig({
                tokenOut: address(debt),
                target: address(venue),
                spender: address(venue),
                rateKind: GenericExecutor.RateKind.Floor,
                oracle: address(0),
                rateOrFloor: 100,
                maxSlippageBps: 0
            })
        );
        vm.startPrank(principal);
        input.approve(address(core), 100);
        bytes32 id = core.registerMandate(p);
        vm.stopPrank();
        bytes memory route = abi.encodeCall(venue.repay, (input, debt, principal, 100));
        vm.expectRevert(
            abi.encodeWithSelector(
                ISignoShield.OutcomeRejected.selector,
                id,
                ISignoShield.MandateReason.POSTCONDITION_FAILED,
                abi.encodeWithSignature("Panic(uint256)", 0x11)
            )
        );
        vm.prank(p.agent);
        core.fire(id, 100, route);
        assertEq(debt.balanceOf(principal), 1000, "valid debt reduction rolled back by token-up check");
        assertEq(input.balanceOf(principal), 1000);
    }
}
