// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GenericExecutor} from "contracts/executors/GenericExecutor.sol";
import {IShieldAdapter} from "contracts/core/interfaces/IShieldAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// The fourth rate rule (Austin 2026-09-16, "let's do whatever the better
/// long-term design is"): an ERC-4626 deposit bounded by the vault's own
/// `convertToShares`, read before the agent's call. The test contract plays
/// the Shield: it funds the executor and calls `execute`.
contract GenericExecutor4626Test is Test {
    GenericExecutor internal executor;
    MockERC20 internal dai;
    MockERC20 internal other;
    MockVault internal vault;
    MockRouter internal router;
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal seeder = makeAddr("seeder");
    bytes32 internal constant MANDATE = keccak256("mandate-4626");
    bytes32 internal constant TRANSFORM = keccak256("generic.transform");

    function setUp() public {
        dai = new MockERC20("DAI", "DAI", 18);
        other = new MockERC20("Other", "OTH", 18);
        vault = new MockVault(IERC20(address(dai)));
        router = new MockRouter();
        executor = new GenericExecutor(address(this));
        // A live vault with a share price of exactly 1.0 to start.
        dai.mint(seeder, 1_000e18);
        vm.startPrank(seeder);
        dai.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18, seeder);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- helpers

    function _cfg(uint16 slippageBps) internal view returns (bytes memory) {
        return abi.encode(
            GenericExecutor.TransformConfig({
                tokenOut: address(vault),
                target: address(vault),
                spender: address(vault),
                rateKind: GenericExecutor.RateKind.Erc4626,
                oracle: address(0),
                rateOrFloor: 0,
                maxSlippageBps: slippageBps
            })
        );
    }

    function _ctx(bytes memory cfg) internal view returns (IShieldAdapter.Context memory) {
        return IShieldAdapter.Context({
            mandateId: MANDATE, principal: principal, agent: agent, action: TRANSFORM,
            asset: address(dai), actionConfig: cfg
        });
    }

    function _depositData(uint256 assets) internal view returns (bytes memory) {
        return abi.encodeCall(IERC4626.deposit, (assets, principal));
    }

    function _fire(bytes memory cfg, uint256 amount) internal returns (uint256) {
        dai.mint(address(executor), amount);
        return executor.execute(_ctx(cfg), amount, _depositData(amount));
    }

    function _fireExpecting(bytes memory cfg, uint256 amount, bytes memory revertData) internal {
        dai.mint(address(executor), amount);
        IShieldAdapter.Context memory ctx = _ctx(cfg);
        bytes memory data = _depositData(amount);
        vm.expectRevert(revertData);
        executor.execute(ctx, amount, data);
    }

    function _expectInvalid(bytes memory cfg, string memory field) internal {
        vm.expectRevert(abi.encodeWithSelector(GenericExecutor.ConfigInvalid.selector, field));
        executor.validateConfig(TRANSFORM, address(dai), cfg);
    }

    // --------------------------------------------------------------- firing

    function test_deposit_sharesLandWithTheOwner_andNothingSurvives() public {
        address clone = executor.nextClone(MANDATE);
        uint256 spent = _fire(_cfg(0), 100e18);
        assertEq(spent, 100e18);
        assertEq(vault.balanceOf(principal), 100e18, "1:1 at a share price of 1.0");
        assertEq(dai.balanceOf(address(executor)), 0, "executor holds nothing");
        assertEq(dai.balanceOf(clone), 0, "sandbox holds nothing");
        assertEq(vault.balanceOf(clone), 0);
        assertEq(dai.allowance(clone, address(vault)), 0, "no approval survives");
    }

    /// The whole reason this is a rule and not a Fixed pin: the vault earned,
    /// so a deposit now buys fewer shares. The rule follows the vault; a pin
    /// made at registration would refuse a perfectly good deposit.
    function test_deposit_afterTheVaultEarned_stillPasses_whereAFixedPinWouldNot() public {
        dai.mint(address(vault), 100e18); // 10 % yield: share price 1.1
        uint256 preview = vault.previewDeposit(100e18);
        assertLt(preview, 100e18, "fewer shares per DAI now");
        uint256 spent = _fire(_cfg(0), 100e18);
        assertEq(spent, 100e18);
        assertEq(vault.balanceOf(principal), preview, "exactly what the vault said it would mint");

        // The same vault under Fixed 1:1 — refused, because the pin is stale.
        bytes memory fixedCfg = abi.encode(
            GenericExecutor.TransformConfig({
                tokenOut: address(vault), target: address(router), spender: address(router),
                rateKind: GenericExecutor.RateKind.Fixed, oracle: address(0), rateOrFloor: 1e18, maxSlippageBps: 0
            })
        );
        // Route the same deposit through the mock router so the surface is not the token.
        dai.mint(address(executor), 100e18);
        vault.mint(address(router), 0); // the router pays out of what it holds; fund it with real shares
        vm.startPrank(address(router));
        dai.mint(address(router), 100e18);
        dai.approve(address(vault), 100e18);
        vault.deposit(100e18, address(router));
        vm.stopPrank();
        uint256 routerShares = vault.balanceOf(address(router)); // ~90.9e18: what a fair route can pay
        bytes memory swap = abi.encodeCall(MockRouter.swap, (address(dai), 100e18, address(vault), routerShares, principal));
        IShieldAdapter.Context memory ctx = _ctx(fixedCfg);
        vm.expectRevert(); // OutputBelowMinimum: 1:1 demands ~100e18, the market gives ~90.9e18
        executor.execute(ctx, 100e18, swap);
    }

    function test_deposit_feeVault_refusedWithoutAllowance_acceptedWithIt() public {
        vault.setFeeBps(50);
        uint256 preview = vault.previewDeposit(100e18); // 99.5e18
        // convertToShares excludes the fee, so the bound is ~100e18 less slack; 99.5e18 is below it.
        _fireExpecting(_cfg(0), 100e18, abi.encodeWithSelector(GenericExecutor.OutputBelowMinimum.selector, preview, 100e18 - (100e18 / 10_000 + 1)));
        uint256 spent = _fire(_cfg(50), 100e18);
        assertEq(spent, 100e18);
        assertEq(vault.balanceOf(principal), preview);
    }

    function test_deposit_dustForNothingIsRefused() public {
        // 1 wei of DAI at price 1.0 mints 1 share; make the vault price it at 0 shares.
        dai.mint(address(vault), 9_000e18); // share price 10.0: 1 wei -> 0 shares
        _fireExpecting(_cfg(0), 1, abi.encodeWithSelector(GenericExecutor.OutputBelowMinimum.selector, 0, 1));
    }

    function test_deposit_boundIsSnapshottedBeforeTheCall() public {
        // With the surface pinned to the vault there is no third party between
        // the snapshot and the mint, so the only way the price can move inside
        // the firing is the deposit itself — which cannot change the ratio.
        // Assert the receipt's minOut equals the pre-call figure.
        uint256 perUnit = vault.convertToShares(1e18);
        uint256 exact = 100e18 * perUnit / 1e18;
        uint256 expectedMin = exact - (exact / 10_000 + 1);
        // Fund first: expectEmit binds to the NEXT call, which must be execute.
        dai.mint(address(executor), 100e18);
        address clone = executor.nextClone(MANDATE);
        IShieldAdapter.Context memory ctx = _ctx(_cfg(0));
        bytes memory data = _depositData(100e18);
        vm.expectEmit(true, true, true, true, address(executor));
        emit GenericExecutor.Transformed(MANDATE, principal, address(dai), address(vault), clone, 100e18, 100e18, expectedMin);
        executor.execute(ctx, 100e18, data);
    }

    // --------------------------------------------------------- validateConfig

    function test_validateConfig_acceptsAVerifiedVault() public view {
        executor.validateConfig(TRANSFORM, address(dai), _cfg(0));
        executor.validateConfig(TRANSFORM, address(dai), _cfg(1_000));
    }

    function test_validateConfig_refusesWhatIsNotAVaultOverTheAsset() public {
        GenericExecutor.TransformConfig memory c = abi.decode(_cfg(0), (GenericExecutor.TransformConfig));

        // A plain token answers balanceOf but not asset(): not a vault.
        c.tokenOut = address(other); c.target = address(other); c.spender = address(other);
        _expectInvalid(abi.encode(c), "vault:asset");

        // A real vault, over a different underlying — the wrong-receipt hazard, caught here.
        MockVault otherVault = new MockVault(IERC20(address(other)));
        c.tokenOut = address(otherVault); c.target = address(otherVault); c.spender = address(otherVault);
        _expectInvalid(abi.encode(c), "vault:asset");

        // The surface must be the vault itself.
        c = abi.decode(_cfg(0), (GenericExecutor.TransformConfig));
        c.target = address(router);
        _expectInvalid(abi.encode(c), "vault:surface");
        c.target = address(vault); c.spender = address(router);
        _expectInvalid(abi.encode(c), "vault:surface");

        // No second rate source beside the vault.
        c = abi.decode(_cfg(0), (GenericExecutor.TransformConfig));
        c.oracle = address(router);
        _expectInvalid(abi.encode(c), "oracle");
        c.oracle = address(0); c.rateOrFloor = 1;
        _expectInvalid(abi.encode(c), "rate");
        c.rateOrFloor = 0; c.maxSlippageBps = 1_001;
        _expectInvalid(abi.encode(c), "maxSlippageBps");
    }

    /// The relaxation is scoped to a VERIFIED vault. Every other rule still
    /// refuses a surface that is the output token — the original guard.
    function test_validateConfig_targetEqualsTokenOut_stillRefusedForOtherRules() public {
        GenericExecutor.TransformConfig memory c = GenericExecutor.TransformConfig({
            tokenOut: address(vault), target: address(vault), spender: address(vault),
            rateKind: GenericExecutor.RateKind.Fixed, oracle: address(0), rateOrFloor: 1e18, maxSlippageBps: 0
        });
        _expectInvalid(abi.encode(c), "target");
        c.rateKind = GenericExecutor.RateKind.Floor; c.rateOrFloor = 1;
        _expectInvalid(abi.encode(c), "target");
    }
}
