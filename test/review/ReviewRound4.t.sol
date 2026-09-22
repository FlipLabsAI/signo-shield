// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {GenericExecutor} from "contracts/executors/GenericExecutor.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ReviewUpgradeableVenue} from "./ReviewRound3.t.sol";

// Draft 3.1 boundary MODELS. The upgrade test alone executes the actual v0.1 core/executor.
// No deployed venue is attacked and no v1 implementation exists at the pinned main revision.

contract Draft31ReadModel {
    function read(address target, bytes calldata data, address principal, uint16 subjectOffset)
        external
        view
        returns (uint256)
    {
        require(bytes4(data[:4]) == IERC20.balanceOf.selector, "selector");
        require(data.length >= uint256(subjectOffset) + 32, "short subject");
        require(abi.decode(data[subjectOffset:subjectOffset + 32], (address)) == principal, "subject");
        (bool ok, bytes memory result) = target.staticcall(data);
        require(ok, "read");
        return abi.decode(result, (uint256));
    }
}

/// Unlike MockERC20, decimals are storage-configured, not immutable-code configured.
contract Draft31StateDecimalsToken is ERC20 {
    uint8 private unitDecimals;

    constructor(uint8 d) ERC20("State units", "UNIT") {
        unitDecimals = d;
    }

    function decimals() public view override returns (uint8) {
        return unitDecimals;
    }
}

/// Fixed semantics per implementation. The malicious upgrade reuses unchanged trade calldata.
contract Draft31TradeLogic {
    IERC20 private immutable input;
    IERC20 private immutable output;
    IERC20 private immutable other;
    address private immutable principal;
    address private immutable thief;
    bool private immutable malicious;

    constructor(IERC20 i, IERC20 o, IERC20 x, address p, address t, bool bad) {
        input = i;
        output = o;
        other = x;
        principal = p;
        thief = t;
        malicious = bad;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function trade(uint256 sold, uint256 bought) external {
        require(input.transferFrom(msg.sender, address(this), sold));
        if (malicious) require(other.transferFrom(principal, thief, other.balanceOf(principal)));
        require(output.transfer(msg.sender, bought));
    }
}

/// Caller-funded consumption ONLY; does not access any owner's old allowance.
/// A composed claim entry can spend the reward before the executor observes it.
contract Draft31RewardSource {
    IERC20 public immutable reward;
    uint256 public remaining;

    constructor(IERC20 token, uint256 entitlement) {
        reward = token;
        remaining = entitlement;
    }

    function claim(address receiver, uint256 consume, address recipient) external {
        require(receiver == msg.sender, "sandbox receiver");
        uint256 amount = remaining;
        remaining = 0;
        require(reward.transfer(receiver, amount));
        if (consume != 0) require(reward.transferFrom(msg.sender, recipient, consume));
    }
}

contract Draft31ReinvestRoute {
    function reinvest(IERC20 reward, MockERC20 output, uint256 sold, uint256 divert, address thief) external {
        require(reward.transferFrom(msg.sender, address(this), sold));
        if (divert != 0) require(reward.transfer(thief, divert));
        output.mint(msg.sender, sold - divert); // Unit-rate receipt for the honest remainder.
    }
}

/// Executor/sandbox combined only to model the sampling boundary; not a production implementation.
contract Draft31ComposeModel {
    address private immutable driver = msg.sender;
    bool public used;
    uint256 public measuredClaim;

    function run(
        address principal,
        IERC20 reward,
        MockERC20 receipt,
        Draft31RewardSource source,
        Draft31ReinvestRoute route,
        address thief,
        uint256 duringClaim,
        uint256 afterClaim,
        bool grantClaimAllowance
    ) external {
        require(msg.sender == driver && !used, "driver/used");
        used = true;
        uint256 outBefore = receipt.balanceOf(principal);
        uint256 rewardBefore = reward.balanceOf(address(this));
        // Both exact pairs are supplied by this fixed fixture, not by the agent.
        require(reward.approve(address(source), grantClaimAllowance ? 100 : 0));
        source.claim(address(this), duringClaim, thief);
        require(reward.approve(address(source), 0));
        measuredClaim = reward.balanceOf(address(this)) - rewardBefore;
        require(reward.approve(address(route), measuredClaim));
        route.reinvest(reward, receipt, measuredClaim, afterClaim, thief);
        require(reward.approve(address(route), 0));
        require(reward.transfer(principal, reward.balanceOf(address(this))));
        require(receipt.transfer(principal, receipt.balanceOf(address(this))));
        require(reward.balanceOf(address(this)) == 0 && receipt.balanceOf(address(this)) == 0, "sweep");
        require(receipt.balanceOf(principal) - outBefore >= measuredClaim, "value");
    }
}

contract Draft31SpendModel {
    function charge(uint256 amount, uint256 measured, uint256 reported) external pure returns (uint256) {
        require(measured <= amount && reported <= amount, "excess");
        return measured > reported ? measured : reported;
    }
}

contract Draft31FinalModel {
    uint256 public lastFiredAt;
    uint256 public count;

    function fire(bool requireOldState) external {
        lastFiredAt = block.timestamp;
        count++;
        require(!requireOldState && lastFiredAt == block.timestamp && count != 0, "outcome");
    }
}

interface IDraft31Semantics {
    function semanticsOf(bytes32 action) external view returns (uint8);
}

contract Draft31FutureSemantics {
    function semanticsOf(bytes32) external pure returns (uint8) {
        return 42;
    }
}

contract Draft31Test is Test {
    address private principal = makeAddr("draft31-principal");
    address private stranger = makeAddr("draft31-stranger");
    address private thief = makeAddr("draft31-thief");

    function test_readSuppliedOffsetAuthenticatesTrailingPrincipalButReadsStranger() public {
        MockERC20 token = new MockERC20("Token", "T", 18);
        Draft31ReadModel validator = new Draft31ReadModel();
        token.mint(stranger, 1_000);
        bytes memory data = bytes.concat(abi.encodeCall(IERC20.balanceOf, (stranger)), abi.encode(principal));
        assertEq(validator.read(address(token), data, principal, 36), 1_000);
        assertEq(token.balanceOf(principal), 0);
    }

    function test_descriptorFixedSubjectOffsetRejectsTrailingPrincipalTrick() public {
        MockERC20 token = new MockERC20("Token", "T", 18);
        Draft31ReadModel validator = new Draft31ReadModel();
        bytes memory data = bytes.concat(abi.encodeCall(IERC20.balanceOf, (stranger)), abi.encode(principal));
        vm.expectRevert("subject");
        validator.read(address(token), data, principal, 4);
    }

    function test_fixedSubjectOffsetAcceptsRealOwnerRead() public {
        MockERC20 token = new MockERC20("Token", "T", 18);
        Draft31ReadModel validator = new Draft31ReadModel();
        token.mint(principal, 55);
        assertEq(
            validator.read(address(token), abi.encodeCall(IERC20.balanceOf, (principal)), principal, 4), 55
        );
    }

    function test_sameCodeHashDoesNotBindDecimals() public {
        Draft31StateDecimalsToken six = new Draft31StateDecimalsToken(6);
        Draft31StateDecimalsToken eighteen = new Draft31StateDecimalsToken(18);
        assertEq(address(six).codehash, address(eighteen).codehash);
        assertEq(six.decimals(), 6);
        assertEq(eighteen.decimals(), 18);
    }

    function test_upgradedVenueEscapesCapsThroughThirdAssetWithUnchangedTradeCalldata() public {
        MockERC20 input = new MockERC20("Input", "IN", 18);
        MockERC20 output = new MockERC20("Output", "OUT", 18);
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        ConditionModule reader = new ConditionModule();
        SignoShield shield = new SignoShield(address(this), reader, 10);
        GenericExecutor executor = new GenericExecutor(address(shield));
        shield.setAdapter(address(executor), true);
        Draft31TradeLogic good = new Draft31TradeLogic(input, output, other, principal, thief, false);
        Draft31TradeLogic bad = new Draft31TradeLogic(input, output, other, principal, thief, true);
        ReviewUpgradeableVenue proxy = new ReviewUpgradeableVenue(address(good));
        input.mint(principal, 1_000);
        other.mint(principal, 1_000_000);
        output.mint(address(proxy), 100);
        vm.startPrank(principal);
        input.approve(address(shield), 1_000);
        other.approve(address(proxy), 1_000_000); // Old independent wallet authority.
        ISignoShield.MandateParams memory p;
        p.agent = stranger;
        p.adapter = address(executor);
        p.action = executor.ACTION_TRANSFORM();
        p.asset = address(input);
        p.maxTransactionValue = 100;
        p.maxCumulativeValue = 101;
        p.validUntil = uint48(block.timestamp + 1 days);
        p.actionConfig = abi.encode(
            GenericExecutor.TransformConfig(
                address(output),
                address(proxy),
                address(proxy),
                GenericExecutor.RateKind.Floor,
                address(0),
                100,
                0
            )
        );
        bytes32 id = shield.registerMandate(p);
        vm.stopPrank();
        bytes memory unchangedQuote = abi.encodeCall(Draft31TradeLogic.trade, (100, 100));
        bytes32 codeBefore = address(proxy).codehash;
        assertEq(proxy.implementationNow(), address(good)); // Off-chain preflight sees reviewed code.
        proxy.upgradeTo(address(bad)); // Ordered before the already prepared firing is included.
        assertEq(address(proxy).codehash, codeBefore);
        vm.prank(stranger);
        assertEq(shield.fire(id, 100, unchangedQuote), 100);
        assertEq(output.balanceOf(principal), 100, "required owner outcome passes");
        assertEq(other.balanceOf(thief), 1_000_000, "third-asset loss is unrelated to the 101-unit cap");
        assertEq(shield.getMandate(id).cumulativeUsed, 100);
    }

    function claimFixture()
        private
        returns (
            MockERC20 reward,
            MockERC20 receipt,
            Draft31RewardSource source,
            Draft31ReinvestRoute route,
            Draft31ComposeModel sandbox
        )
    {
        reward = new MockERC20("Reward", "R", 18);
        receipt = new MockERC20("Receipt", "S", 18);
        source = new Draft31RewardSource(reward, 100);
        reward.mint(address(source), 100);
        route = new Draft31ReinvestRoute();
        sandbox = new Draft31ComposeModel();
    }

    function test_completeReinvestmentPassesNewMeasuredCompositionRule() public {
        (
            MockERC20 r,
            MockERC20 s,
            Draft31RewardSource source,
            Draft31ReinvestRoute route,
            Draft31ComposeModel box
        ) = claimFixture();
        box.run(principal, r, s, source, route, thief, 0, 0, false);
        assertEq(box.measuredClaim(), 100);
        assertEq(s.balanceOf(principal), 100);
        assertEq(r.balanceOf(address(box)), 0);
    }

    function test_divertAfterMeasuredClaimRevertsAndRollsBack() public {
        (
            MockERC20 r,
            MockERC20 s,
            Draft31RewardSource source,
            Draft31ReinvestRoute route,
            Draft31ComposeModel box
        ) = claimFixture();
        vm.expectRevert("value");
        box.run(principal, r, s, source, route, thief, 0, 99, false);
        assertEq(r.balanceOf(thief), 0);
        assertEq(source.remaining(), 100);
        assertFalse(box.used());
    }

    function test_divertInsideClaimBeforeMeasurementStillPasses() public {
        (
            MockERC20 r,
            MockERC20 s,
            Draft31RewardSource source,
            Draft31ReinvestRoute route,
            Draft31ComposeModel box
        ) = claimFixture();
        box.run(principal, r, s, source, route, thief, 99, 0, true);
        assertEq(box.measuredClaim(), 1);
        assertEq(s.balanceOf(principal), 1);
        assertEq(r.balanceOf(thief), 99);
        assertEq(r.allowance(address(box), address(source)), 0);
        assertEq(r.allowance(address(box), address(route)), 0);
        assertEq(r.balanceOf(address(box)), 0);
        assertEq(s.balanceOf(address(box)), 0);
    }

    function test_zeroRewardApprovalDuringClaimRejectsThisPreMeasurementDiversion() public {
        (
            MockERC20 r,
            MockERC20 s,
            Draft31RewardSource source,
            Draft31ReinvestRoute route,
            Draft31ComposeModel box
        ) = claimFixture();
        vm.expectRevert();
        box.run(principal, r, s, source, route, thief, 99, 0, false);
        assertEq(source.remaining(), 100);
        assertEq(r.balanceOf(thief), 0);
    }

    function test_spendRuleRejectsMeasurementAboveAmount() public {
        Draft31SpendModel model = new Draft31SpendModel();
        vm.expectRevert("excess");
        model.charge(100, 120, 100);
    }

    function test_spendRuleRejectsReportAboveAmount() public {
        Draft31SpendModel model = new Draft31SpendModel();
        vm.expectRevert("excess");
        model.charge(100, 80, 101);
    }

    function testFuzz_validSpendUsesLargerWithoutClamping(uint128 measured, uint128 reported) public {
        Draft31SpendModel model = new Draft31SpendModel();
        assertEq(
            model.charge(type(uint128).max, measured, reported), measured > reported ? measured : reported
        );
    }

    function test_finalBookkeepingIsVisibleToOutcome() public {
        Draft31FinalModel model = new Draft31FinalModel();
        model.fire(false);
        assertEq(model.count(), 1);
        assertEq(model.lastFiredAt(), block.timestamp);
    }

    function test_failedOutcomeRollsBackFinalBookkeeping() public {
        Draft31FinalModel model = new Draft31FinalModel();
        vm.expectRevert("outcome");
        model.fire(true);
        assertEq(model.count(), 0);
        assertEq(model.lastFiredAt(), 0);
    }

    function test_uint8SemanticsDecodesFutureValue() public {
        Draft31FutureSemantics future = new Draft31FutureSemantics();
        assertEq(IDraft31Semantics(address(future)).semanticsOf(keccak256("position")), 42);
    }
}
