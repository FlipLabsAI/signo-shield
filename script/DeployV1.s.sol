// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {ShieldRegistryV1} from "contracts/v1/ShieldRegistryV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";
import {AaveV3AdapterV1} from "contracts/v1/AaveV3AdapterV1.sol";

/// @title DeployV1
/// @notice Shield v1 on one chain: the core, the expression evaluator, the two
///         Tier 1 executors and the Aave adapter, listed; the launch read
///         catalog listed by content id; fee recipient and enforcer set; the
///         admin seat handed to SHIELD_OWNER (two-step, to be accepted).
///
/// Env: SHIELD_OWNER (required), FEE_RECIPIENT (default owner), ENFORCER
/// (optional, neither deployer nor owner), SHIELD_FEE_BPS (default 10),
/// AAVE_V3_POOL for chains not pinned below.
contract DeployV1 is Script {
    uint256 internal constant XLAYER = 196;
    uint256 internal constant ARBITRUM_ONE = 42_161;

    struct Deployed {
        ShieldRegistryV1 registry;
        ShieldV1 shield;
        ExpressionEvaluator evaluator;
        GenericExecutorV1 generic;
        AaveV3AdapterV1 aave;
    }

    function run() external returns (Deployed memory d) {
        address owner = vm.envAddress("SHIELD_OWNER");
        return deployWith(
            owner,
            vm.envOr("FEE_RECIPIENT", owner),
            vm.envOr("ENFORCER", address(0)),
            vm.envOr("SHIELD_FEE_BPS", uint256(10))
        );
    }

    function deployWith(address owner, address feeRecipient, address enforcer, uint256 feeBpsRaw)
        public
        returns (Deployed memory d)
    {
        if (feeBpsRaw > type(uint16).max) revert("SHIELD_FEE_BPS out of range");
        uint16 feeBps = uint16(feeBpsRaw);
        address pool = _poolFor(block.chainid);
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        if (enforcer != address(0) && (enforcer == deployer || enforcer == owner)) {
            revert("ENFORCER must be neither deployer nor owner");
        }
        d.registry = new ShieldRegistryV1(deployer);
        d.shield = new ShieldV1(d.registry, feeBps);
        d.evaluator = new ExpressionEvaluator(d.registry);
        d.generic = new GenericExecutorV1(address(d.shield));
        d.aave = new AaveV3AdapterV1(address(d.shield), IPool(pool));
        d.registry.setEvaluator(address(d.evaluator), true);
        d.registry.setExecutor(address(d.generic), true);
        // The claim executor is not deployed or listed at launch: claims wait
        // for per-venue claimable reads and receiver rules (FLIP-280 F2, v1.1).
        d.registry.setExecutor(address(d.aave), true);
        _listCatalog(d.registry, pool);
        d.shield.setFeeRecipient(feeRecipient);
        if (enforcer != address(0)) d.registry.setEnforcer(enforcer, true);
        // One admin: the registry's owner is the core's admin too.
        d.registry.transferOwnership(owner);
        vm.stopBroadcast();
        console.log("chainId            ", block.chainid);
        console.log("ShieldRegistryV1   ", address(d.registry));
        console.log("ShieldV1           ", address(d.shield));
        console.log("ExpressionEvaluator", address(d.evaluator));
        console.log("GenericExecutorV1  ", address(d.generic));
        console.log("AaveV3AdapterV1    ", address(d.aave));
        console.log("Aave pool          ", pool);
        console.log("fee bps            ", feeBps);
        console.log("fee recipient      ", feeRecipient);
        console.log("enforcer           ", enforcer);
        console.log("pending owner      ", owner);
        console.log("version            ", d.shield.VERSION());
    }

    // ---------------------------------------------------------------- catalog

    /// @dev The launch read catalog (the read-catalog note in docs/).
    ///      Shape descriptors are chain-independent; per-address ones are
    ///      listed for the chains they exist on.
    function _listCatalog(ShieldRegistryV1 shield, address pool) internal {
        _log(
            "erc20.balanceOf",
            shield.listDescriptor(_shape(bytes4(keccak256("balanceOf(address)")), 1, 0, true, 100_000, 32))
        );
        _log(
            "erc4626.convertToAssets",
            shield.listDescriptor(
                _shape(bytes4(keccak256("convertToAssets(uint256)")), 1, -1, false, 100_000, 32)
            )
        );
        _log(
            "erc4626.convertToShares",
            shield.listDescriptor(
                _shape(bytes4(keccak256("convertToShares(uint256)")), 1, -1, false, 100_000, 32)
            )
        );
        _log("chainlink.round.1h", shield.listDescriptor(_round(address(0), 3600)));
        _log("chainlink.round.24h", shield.listDescriptor(_round(address(0), 86_400)));
        if (pool != address(0)) {
            _log("aave.accountData.collateralBase", shield.listDescriptor(_accountData(pool, 0)));
            _log("aave.accountData.debtBase", shield.listDescriptor(_accountData(pool, 1)));
            _log("aave.accountData.hf", shield.listDescriptor(_accountData(pool, 5)));
        }
        if (block.chainid == XLAYER) {
            address oracle = 0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6;
            _log("aave.price", shield.listDescriptor(_price(oracle)));
            // The fresh round every mandatory price of a reserve must pass
            // (read catalog rule); GHO and USDG have no round-capable source.
            _feed(
                shield,
                "feed.eth",
                0xE7B000003A45145decf8a28FC755aD5eC5EA025A,
                0x8b85b50535551F8E8cDAF78dA235b5Cf1005907b,
                3600
            );
            _feed(
                shield,
                "feed.usdt",
                0x779Ded0c9e1022225f8E0630b35a9b54bE713736,
                0xb928a0678352005a2e51F614efD0b54C9830dB80,
                86_400
            );
            _feed(
                shield,
                "feed.usdc",
                0xB6CEceAB302E2E4948951eE7843FC24E92933061,
                0xB8a08c178D96C315FbFB5661ABD208477391BC40,
                86_400
            );
            _feed(
                shield,
                "feed.btc",
                0xb7C00000bcDEeF966b20B3D884B98E64d2b06b4f,
                0x4D6f6488a2B3a5f7b088f276887f608a1e9805c4,
                3600
            );
            _feed(
                shield,
                "feed.okb",
                0xe538905cf8410324e03A5A23C1c177a474D59b2b,
                0x4Ff345b18a2bF894F8627F41501FBf30d5C5e7BE,
                3600
            );
            _feed(
                shield,
                "feed.sol",
                0x505000008DE8748DBd4422ff4687a4FC9bEba15b,
                0xF959E1B5cA535C28aD24F7f672Bf1A93900810cF,
                3600
            );
        }
    }

    /// @dev List a feed's round descriptor and bind it as the fresh round of `token`.
    function _feed(ShieldRegistryV1 shield, string memory name, address token, address feed, uint32 maxAge)
        internal
    {
        bytes32 id = shield.listDescriptor(_round(feed, maxAge));
        shield.setPriceRound(token, id, feed);
        _log(name, id);
    }

    function _shape(
        bytes4 selector,
        uint8 argCount,
        int8 subjectArg,
        bool principalRequired,
        uint32 gas_,
        uint16 copy
    ) internal pure returns (IDescriptors.Descriptor memory) {
        return IDescriptors.Descriptor({
            kind: IDescriptors.DescriptorKind.Shape,
            target: address(0),
            selector: selector,
            argCount: argCount,
            subjectArg: subjectArg,
            subjectRule: principalRequired
                ? IDescriptors.SubjectRule.PrincipalRequired
                : IDescriptors.SubjectRule.None,
            word: 0,
            isSigned: false,
            mustBePositive: false,
            decimals: 0,
            freshness: IDescriptors.Freshness.None,
            maxAge: 0,
            gasStipend: gas_,
            copyBytes: copy
        });
    }

    /// @dev A Chainlink-shaped round read: per address when `feed` is set, else the shape.
    function _round(address feed, uint32 maxAge) internal pure returns (IDescriptors.Descriptor memory) {
        return IDescriptors.Descriptor({
            kind: feed == address(0)
                ? IDescriptors.DescriptorKind.Shape
                : IDescriptors.DescriptorKind.PerAddress,
            target: feed,
            selector: bytes4(keccak256("latestRoundData()")),
            argCount: 0,
            subjectArg: -1,
            subjectRule: IDescriptors.SubjectRule.None,
            word: 1,
            isSigned: true,
            mustBePositive: true,
            decimals: 8,
            freshness: IDescriptors.Freshness.ChainlinkRound,
            maxAge: maxAge,
            gasStipend: 160_000,
            copyBytes: 160
        });
    }

    function _accountData(address pool, uint8 word) internal pure returns (IDescriptors.Descriptor memory) {
        return IDescriptors.Descriptor({
            kind: IDescriptors.DescriptorKind.PerAddress,
            target: pool,
            selector: IPool.getUserAccountData.selector,
            argCount: 1,
            subjectArg: 0,
            subjectRule: IDescriptors.SubjectRule.PrincipalRequired,
            word: word,
            isSigned: false,
            mustBePositive: false,
            decimals: word == 5 ? 18 : 8,
            freshness: IDescriptors.Freshness.None,
            maxAge: 0,
            gasStipend: 500_000,
            copyBytes: 192
        });
    }

    function _price(address oracle) internal pure returns (IDescriptors.Descriptor memory) {
        return IDescriptors.Descriptor({
            kind: IDescriptors.DescriptorKind.PerAddress,
            target: oracle,
            selector: bytes4(keccak256("getAssetPrice(address)")),
            argCount: 1,
            subjectArg: -1,
            subjectRule: IDescriptors.SubjectRule.None,
            word: 0,
            isSigned: false,
            mustBePositive: true,
            decimals: 8,
            freshness: IDescriptors.Freshness.None,
            maxAge: 0,
            gasStipend: 100_000,
            copyBytes: 32
        });
    }

    function _log(string memory name, bytes32 id) internal pure {
        console.log(name, vm.toString(id));
    }

    function _poolFor(uint256 chainId) internal view returns (address) {
        if (chainId == XLAYER) return 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
        if (chainId == ARBITRUM_ONE) return 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
        return vm.envOr("AAVE_V3_POOL", address(0));
    }
}
