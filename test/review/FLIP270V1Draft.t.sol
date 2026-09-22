// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";

contract DraftPermitToken is ERC20Permit {
    constructor() ERC20("Draft test", "DRAFT") ERC20Permit("Draft test") {}

    function mint(address owner, uint256 amount) external {
        _mint(owner, amount);
    }
}

/// Deliberately permissive mock: an ERC-2612 permit is valid but does not
/// authorize this caller's chosen recipient. Not a deployed venue finding.
contract DraftPermitVenue {
    DraftPermitToken internal immutable token;

    constructor(DraftPermitToken t) {
        token = t;
    }

    function pay(
        address owner,
        address recipient,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        token.permit(owner, address(this), amount, deadline, v, r, s);
        token.transferFrom(owner, recipient, amount);
    }
}

/// Minimal models of draft ambiguities, NOT an implementation of Shield v1.
contract FLIP270V1DraftModelTest is Test {
    function test_permitSignatureDoesNotBindPaymentRecipient() public {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        address thief = makeAddr("thief");
        DraftPermitToken token = new DraftPermitToken();
        DraftPermitVenue venue = new DraftPermitVenue(token);
        token.mint(owner, 100e18);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 typeHash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 data =
            keccak256(abi.encode(typeHash, owner, address(venue), 100e18, token.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), data));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        // A real token/spender/value/nonce/deadline-bound permit passes, but
        // the caller can still choose where the owner's tokens go.
        venue.pay(owner, thief, 100e18, deadline, v, r, s);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(thief), 100e18);
        assertEq(token.nonces(owner), 1);
    }

    function test_postconditionBeforeFeeRefundIsNotFinalPostcondition() public pure {
        uint256 initialBalance = 1000;
        uint256 amount = 100;
        uint256 feeBps = 100; // within the draft's normal 1% limit
        uint256 feeMax = amount * feeBps / 10_000; // 1
        uint256 actuallySpent = 50;
        uint256 beforeSettlement = initialBalance - actuallySpent - feeMax; // 949
        bool outcomePassed = beforeSettlement == 949;
        uint256 actualFee = actuallySpent * feeBps / 10_000; // 0 (integer units)
        uint256 finalBalance = beforeSettlement + feeMax - actualFee; // 950
        assertTrue(outcomePassed);
        assertNotEq(finalBalance, 949);
    }

    function test_optionalFallbackIsNotAMandatorySlippageFloor() public pure {
        uint256 sold = 100;
        uint256 received = 0;
        uint256 floor = sold * 9900 / 10_000;
        bool builtInPassed = received >= floor;
        bool nonemptyCustomOutcome = true; // legal CONST(1) == CONST(1)
        bool acceptedIfReplacement = nonemptyCustomOutcome;
        assertFalse(builtInPassed);
        assertTrue(acceptedIfReplacement);
    }

    function test_amendmentGlobalFeeCheckCanMissStoredFee() public pure {
        uint16 oldMaxFeeBps = 100;
        uint16 stampedFeeBps = 100;
        uint16 currentGlobalFeeBps = 10;
        uint16 newlySignedMaxFeeBps = 20;
        assertLe(stampedFeeBps, oldMaxFeeBps);
        assertLe(currentGlobalFeeBps, newlySignedMaxFeeBps, "draft's amendment check passes");
        assertGt(stampedFeeBps, newlySignedMaxFeeBps, "unchanged lifetime fee exceeds new consent");
    }

    function test_acyclicSharedNodesStillNeedMemoizedEvaluation() public pure {
        // Node 0 is CONST(1); node i is ADD(i-1, i-1). All references point
        // backwards. A naive recursive walk recomputes shared children.
        (uint256 value, uint256 visits) = _recursive(11);
        assertEq(value, 2048);
        assertEq(visits, 4095);
        assertGt(visits, 12 * 100);
    }

    function _recursive(uint256 i) internal pure returns (uint256 value, uint256 visits) {
        if (i == 0) return (1, 1);
        (uint256 a, uint256 av) = _recursive(i - 1);
        (uint256 b, uint256 bv) = _recursive(i - 1);
        return (a + b, av + bv + 1);
    }

    function test_checkedArithmeticDoesNotCheckExplicitUintToIntCast() public pure {
        uint256 unsignedWord = type(uint256).max;
        int256 converted = int256(unsignedWord);
        assertEq(converted, -1);
        assertTrue(converted < 100, "signed comparison can flip without an arithmetic overflow");
    }
}

/// Representative fork probes, not certification of the entire read catalog.
contract FLIP270V1ReadBudgetTest is Test {
    address internal constant POOL = 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
    address internal constant XETH = 0xE7B000003A45145decf8a28FC755aD5eC5EA025A;
    address internal constant A_XETH = 0xe6639ba6c1d79Be6d4c776E4c17504538d1719cD;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    function test_xlayerAccountAndBalanceFitReadBudget() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), 70_752_723);
        address owner = makeAddr("draft-borrower");
        vm.prank(A_XETH);
        IERC20(XETH).transfer(owner, 0.05e18);
        vm.startPrank(owner);
        IERC20(XETH).approve(POOL, 0.05e18);
        IPool(POOL).supply(XETH, 0.05e18, owner, 0);
        IPool(POOL).borrow(USDT0, 60e6, 2, 0, owner);
        vm.stopPrank();
        bytes memory account =
            _probe(POOL, abi.encodeCall(IPool.getUserAccountData, (owner)), "xlayer_account_gas");
        assertEq(account.length, 192);
        bytes memory balance = _probe(USDT0, abi.encodeCall(IERC20.balanceOf, (owner)), "usdt0_balance_gas");
        assertEq(balance.length, 32);
        emit log_named_uint("xlayer_block", block.number);
    }

    function test_sdaiConversionFitsReadBudget() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        bytes memory shares =
            _probe(SDAI, abi.encodeCall(IERC4626.convertToShares, (1e18)), "sdai_convert_gas");
        assertEq(shares.length, 32);
        assertGt(abi.decode(shares, (uint256)), 0);
        emit log_named_uint("ethereum_block", block.number);
    }

    function _probe(address target, bytes memory data, string memory name)
        internal
        returns (bytes memory ret)
    {
        uint256 start = gasleft();
        bool ok;
        (ok, ret) = target.staticcall{gas: 200_000}(data);
        uint256 gasUsed = start - gasleft();
        assertTrue(ok, "representative view fits stipend");
        assertLe(ret.length, 256);
        emit log_named_uint(name, gasUsed);
        emit log_named_uint("returned_bytes", ret.length);
    }
}
