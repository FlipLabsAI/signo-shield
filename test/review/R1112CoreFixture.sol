// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {ShieldRegistryV1} from "contracts/v1/ShieldRegistryV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IEvaluatorV1} from "contracts/v1/interfaces/IEvaluatorV1.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {MockExecutor, MockToken, MockWallet1271} from "test/v1/mocks/MockExecutor.sol";
import {MockBalances} from "test/v1/mocks/MockCatalog.sol";
import {MockScaledToken} from "test/v1/mocks/MockScaledToken.sol";

abstract contract R1112CoreFixture is Test {
    ShieldV1 internal shield;
    ShieldRegistryV1 internal registry;
    ExpressionEvaluator internal ev;
    MockExecutor internal exec;
    MockToken internal usdc;
    MockBalances internal gauge; // an external read target for triggers

    address internal admin = address(0xAD);
    address internal enforcer = address(0xE0);
    address internal feeSink = address(0xFEE);
    uint256 internal principalKey = 0xA11CE;
    address internal principal;
    address internal agent = address(0xA6E);

    bytes32 internal dBalance;
    bytes32 internal constant ACTION = keccak256("mock.transform");
    bytes32 internal constant CLAIM = keccak256("mock.claim");

    function setUp() public {
        principal = vm.addr(principalKey);
        registry = new ShieldRegistryV1(admin);
        shield = new ShieldV1(registry, 10); // 10 bps
        ev = new ExpressionEvaluator(registry);
        exec = new MockExecutor(address(shield));
        usdc = new MockToken();
        gauge = new MockBalances();
        vm.startPrank(admin);
        registry.setEnforcer(enforcer, true);
        registry.setExecutor(address(exec), true);
        registry.setEvaluator(address(ev), true);
        shield.setFeeRecipient(feeSink);
        dBalance = registry.listDescriptor(
            IDescriptors.Descriptor({
                kind: IDescriptors.DescriptorKind.Shape,
                target: address(0),
                selector: bytes4(keccak256("balanceOf(address)")),
                argCount: 1,
                subjectArg: 0,
                subjectRule: IDescriptors.SubjectRule.PrincipalRequired,
                word: 0,
                isSigned: false,
                mustBePositive: false,
                decimals: 0,
                freshness: IDescriptors.Freshness.None,
                maxAge: 0,
                gasStipend: 100_000,
                copyBytes: 32,
                unboundedTop: false
            })
        );
        vm.stopPrank();
        usdc.mint(principal, 1_000_000e6);
        vm.prank(principal);
        usdc.approve(address(shield), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers

    function _tree(address target, address who, ExprLib.Kind cmp, uint256 threshold)
        internal
        view
        returns (bytes memory)
    {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = ExprLib.Read({
            descriptor: dBalance,
            target: target,
            args: abi.encode(who),
            subject: ExprLib.Subject.Principal,
            decimals: target == address(usdc) ? 18 : 6 // pinned to the instance (MockToken 18, MockBalances 6)
        });
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = ExprLib.Node({kind: uint8(ExprLib.Kind.READ), a: 0, b: 0});
        n[1] = ExprLib.Node({kind: uint8(ExprLib.Kind.CONST), a: threshold, b: 0});
        n[2] = ExprLib.Node({kind: uint8(cmp), a: 0, b: 1});
        return abi.encode(r, n);
    }

    function _params() internal view returns (IShieldV1.MandateParams memory p) {
        p = IShieldV1.MandateParams({
            agent: agent,
            executor: address(exec),
            evaluator: address(ev),
            asset: address(usdc),
            maxTransactionValue: 1_000e6,
            maxCumulativeValue: 10_000e6,
            // forge-lint: disable-next-line(environment-read-across-mutation)
            validFrom: uint48(block.timestamp),
            // forge-lint: disable-next-line(environment-read-across-mutation)
            validUntil: uint48(block.timestamp + 30 days),
            maxFeeBps: 50,
            funding: uint8(IShieldV1.FundingMode.PULL),
            action: ACTION,
            actionConfig: "",
            trigger: "",
            outcome: ""
        });
    }

    function _register(IShieldV1.MandateParams memory p) internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    /// Round 11 (found on the X Layer fork): with an Aave aToken as the asset
    /// (repay from collateral), each transfer rounds to scaled units, so after
    /// the fee reached the recipient the core could hold one unit less than the
    /// unused reserve and the refund reverted with Panic(0x11). The refund now
    /// goes first and the fee recipient takes at most what is left.
    function _scaledMandate(uint256 index) internal returns (MockScaledToken a, bytes32 id) {
        a = new MockScaledToken();
        a.setIndex(index);
        a.mint(principal, 1_000e18);
        vm.prank(principal);
        a.approve(address(shield), type(uint256).max);
        IShieldV1.MandateParams memory p = _params();
        p.asset = address(a);
        p.maxTransactionValue = 100e18;
        p.maxCumulativeValue = 1_000e18;
        id = _register(p);
    }

    /// The firing never reverts on the fee refund, whatever the rounding.

    /// What the owner lost matches what the core charged, within the token's own rounding
    /// (a few units: each transfer rounds to the scaled unit, at most 2 wei at index <= 2).

    // ----------------------------------------------------------- registration

    // ------------------------------------------------------------------ firing

    // --------------------------------------------------------------- amendment

    // -------------------------------------------------------------- revocation

    function _revokeDigest(bytes32 id, address who, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Revoke(bytes32 mandateId,address principal,uint256 nonce,uint256 deadline)"),
                id,
                who,
                nonce,
                deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("SignoShield"),
                keccak256("1"),
                block.chainid,
                address(shield)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    // -------------------------------------------------- halts and suspensions

    /// Round 9 (Austin: "handle infinite for health factor only"): the flag is
    /// accepted only on Aave's health factor, getUserAccountData's sixth word,
    /// unsigned. Any other read, and so any amount, is refused it.
}
