// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployV1} from "script/DeployV1.s.sol";
import {ShieldRegistryV1} from "contracts/v1/ShieldRegistryV1.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";

interface IWBNB {
    function deposit() external payable;
}

interface IAtlasAllowlist {
    function isAuthorizedCaller(address caller) external view returns (bool);
}

/// A demo on BNB testnet (chain 97) for BNB Hack Bangkok (FLIP-668): the Shield
/// reads the Atlas BNB/USD feed on chain and acts only when the condition holds.
///
/// Atlas feeds answer only allowlisted contract callers (`OnlyAuthorizedCallerAllowed`),
/// on testnet too (read 25 Nov 2026), and Atlas allowlists on testnet only for now.
/// From the deployer's nonce 0 the evaluator lands at the mainnet address,
/// 0xc428a88A92Ecec99414152Ad2A5fd4244b222B15, so one allowlist request covers both.
/// Until Atlas adds it to the testnet feed, registration reverts (it reads the tree).
///
/// Not a production deployment: the core, the evaluator and the generic
/// executor only (Aave is not on BNB testnet), owned by the deployer, and NOT in
/// deployments/manifest.json, so the app never offers chain 97.
///
/// One permission fires: "when BNB (Atlas) is above $100, send 0.001 WBNB to
/// the recipient". A second permission, "above $1,000,000", is registered for
/// the refusal; firing it reverts with MandateBlocked(id, TRIGGER_NOT_MET).
///
///   DEMO_DEPLOYER_KEY=… DEMO_PRINCIPAL_KEY=… DEMO_RECIPIENT=0x… \
///   forge script script/DemoAtlasBnbTestnet.s.sol --rpc-url <BNB testnet RPC> --broadcast
contract DemoAtlasBnbTestnet is Script {
    uint256 public constant BNB_TESTNET = 97;
    /// atlasoracle.io/feeds/633, platform 293 (BNB testnet): BNB/USD, 18 decimals, 60 s heartbeat.
    address public constant ATLAS_BNB_USD_TESTNET = 0xb3d1614Bf894E68ADd1EA50CA250C152BAd5256F;
    address public constant WBNB_TESTNET = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    bytes32 public constant TRANSFER = keccak256("generic.transfer");
    uint16 public constant FEE_BPS = 10;
    /// WBNB per firing, and what the principal wraps: two firings and their fees.
    uint256 public constant AMOUNT = 0.001 ether;
    uint256 public constant WRAP = 2 * AMOUNT + (2 * AMOUNT * FEE_BPS) / 10_000;
    /// tBNB the deployer forwards to the principal for the wrap and gas, when it holds less.
    uint256 public constant PRINCIPAL_FUNDS = 0.005 ether;

    struct Demo {
        ShieldRegistryV1 registry;
        ShieldV1 shield;
        ExpressionEvaluator evaluator;
        GenericExecutorV1 generic;
        bytes32 atlasRead;
        bytes32 fires; // BNB above $100: holds
        bytes32 refuses; // BNB above $1,000,000: does not hold
        uint256 spent;
    }

    function run() external returns (Demo memory d) {
        require(block.chainid == BNB_TESTNET, "BNB testnet only");
        address deployer = vm.rememberKey(vm.envUint("DEMO_DEPLOYER_KEY"));
        address principal = vm.rememberKey(vm.envUint("DEMO_PRINCIPAL_KEY"));
        // The evaluator is the deployer's third creation from here. Spend no gas
        // before Atlas has allowlisted it: registration would revert.
        address evaluator = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        console.log("evaluator will be  ", evaluator);
        require(
            IAtlasAllowlist(ATLAS_BNB_USD_TESTNET).isAuthorizedCaller(evaluator),
            "Atlas has not allowlisted the evaluator on the testnet feed yet"
        );
        d = demo(deployer, principal, vm.envAddress("DEMO_RECIPIENT"));
    }

    function demo(address deployer, address principal, address recipient) public returns (Demo memory d) {
        // The read as DeployV1 lists it on mainnet (18 decimals, ten heartbeats).
        // Built off chain: this contract creation is not broadcast.
        IDescriptors.Descriptor memory read = new DeployV1().atlasRound(ATLAS_BNB_USD_TESTNET);

        // 1. The deployer deploys and lists, and funds the principal.
        vm.startBroadcast(deployer);
        d.registry = new ShieldRegistryV1(deployer);
        d.shield = new ShieldV1(d.registry, FEE_BPS);
        d.evaluator = new ExpressionEvaluator(d.registry);
        d.generic = new GenericExecutorV1(address(d.shield));
        d.registry.setEvaluator(address(d.evaluator), true);
        d.registry.setExecutor(address(d.generic), true);
        d.atlasRead = d.registry.listDescriptor(read);
        d.shield.setFeeRecipient(deployer);
        if (principal.balance < PRINCIPAL_FUNDS) {
            payable(principal).transfer(PRINCIPAL_FUNDS - principal.balance);
        }
        vm.stopBroadcast();

        // 2. The principal wraps, approves, and signs two permissions for the agent (the deployer).
        vm.startBroadcast(principal);
        IWBNB(WBNB_TESTNET).deposit{value: WRAP}();
        IERC20(WBNB_TESTNET).approve(address(d.shield), WRAP);
        d.fires = d.shield.registerMandate(_params(d, deployer, recipient, 100e18));
        d.refuses = d.shield.registerMandate(_params(d, deployer, recipient, 1_000_000e18));
        vm.stopBroadcast();

        // 3. The agent fires the permission whose condition holds.
        vm.startBroadcast(deployer);
        d.spent = d.shield.fire(d.fires, AMOUNT, "");
        vm.stopBroadcast();

        console.log("chainId            ", block.chainid);
        console.log("ShieldRegistryV1   ", address(d.registry));
        console.log("ShieldV1           ", address(d.shield));
        console.log("ExpressionEvaluator", address(d.evaluator));
        console.log("GenericExecutorV1  ", address(d.generic));
        console.log("Atlas BNB/USD      ", ATLAS_BNB_USD_TESTNET);
        console.log("atlas.bnb read id  ");
        console.logBytes32(d.atlasRead);
        console.log("fires (BNB > $100) ");
        console.logBytes32(d.fires);
        console.log("refuses (> $1M)    ");
        console.logBytes32(d.refuses);
        console.log("spent (with fee)   ", d.spent);
    }

    function _params(Demo memory d, address agent, address recipient, uint256 usd18)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](0); // a transfer calls no venue
        c.sweepSet = new address[](0);
        c.recipient = recipient;
        p.agent = agent;
        p.executor = address(d.generic);
        p.evaluator = address(d.evaluator);
        p.asset = WBNB_TESTNET;
        p.maxTransactionValue = AMOUNT;
        p.maxCumulativeValue = AMOUNT + (AMOUNT * FEE_BPS) / 10_000; // one firing and its fee
        p.validFrom = 0;
        p.validUntil = uint48(block.timestamp + 30 days);
        p.maxFeeBps = FEE_BPS;
        p.funding = uint8(IShieldV1.FundingMode.PULL);
        p.action = TRANSFER;
        p.actionConfig = abi.encode(uint8(1), c);
        p.trigger = atlasBnbAbove(d.atlasRead, usd18);
    }

    /// "BNB/USD on Atlas is above `usd18`" (18 decimals, as the feed answers).
    function atlasBnbAbove(bytes32 atlasRead, uint256 usd18) public pure returns (bytes memory) {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = ExprLib.Read({
            descriptor: atlasRead,
            target: ATLAS_BNB_USD_TESTNET,
            args: "",
            subject: ExprLib.Subject.None,
            decimals: 18
        });
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = ExprLib.Node({kind: uint8(ExprLib.Kind.READ), a: 0, b: 0});
        n[1] = ExprLib.Node({kind: uint8(ExprLib.Kind.CONST), a: usd18, b: 0});
        n[2] = ExprLib.Node({kind: uint8(ExprLib.Kind.GT), a: 0, b: 1});
        return abi.encode(r, n);
    }
}
