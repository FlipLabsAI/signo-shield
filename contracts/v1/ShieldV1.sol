// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IShieldV1} from "./interfaces/IShieldV1.sol";
import {IShieldRegistryV1} from "./interfaces/IShieldRegistryV1.sol";
import {IEvaluatorV1} from "./interfaces/IEvaluatorV1.sol";
import {IExecutorV1, SemanticsV1} from "./interfaces/IExecutorV1.sol";

/// @title ShieldV1
/// @notice The Signo Shield core, version 1. Holds every mandate; pulls only
///         the mandate's asset, bounded by the caps the owner signed; hands
///         it to the pinned executor; measures what left the owner; settles
///         the fee and the bookkeeping; then judges the owner's outcome tree
///         on that final state. A revert anywhere undoes all of it. The
///         listings, the read catalog and the emergency controls live in the
///         registry it is bound to (ShieldRegistryV1).
///
/// Roles. The admin (`Ownable2Step`) sets the fee for new mandates and the
/// fee recipient; it cannot touch a live mandate or any funds. Nobody can
/// change what an owner signed. Every contract is immutable; a change is a
/// new version.
contract ShieldV1 is IShieldV1, Ownable2Step, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    string public constant VERSION = "1.0.0";
    uint16 public constant MAX_FEE_BPS = 1_000;
    uint256 private constant BPS = 10_000;
    bytes32 private constant REVOKE_TYPEHASH =
        keccak256("Revoke(bytes32 mandateId,address principal,uint256 nonce,uint256 deadline)");

    /// @inheritdoc IShieldV1
    IShieldRegistryV1 public immutable registry;
    address public feeRecipient;
    uint16 public feeBps;
    mapping(address principal => uint256) public nonces;
    mapping(address principal => uint256) public sigNonces;

    mapping(bytes32 mandateId => Mandate) private _mandates;

    constructor(address initialOwner, IShieldRegistryV1 registry_, uint16 feeBps_)
        Ownable(initialOwner)
        EIP712("SignoShield", "1")
    {
        if (address(registry_).code.length == 0) revert InvalidParams("registry");
        registry = registry_;
        _setFeeBps(feeBps_);
    }

    // ================================================================ principal

    /// @inheritdoc IShieldV1
    function registerMandate(MandateParams calldata p) external returns (bytes32 mandateId) {
        if (!registry.isExecutorListed(p.executor)) revert ExecutorNotListed(p.executor);
        if (!registry.isEvaluatorListed(p.evaluator)) revert EvaluatorNotListed(p.evaluator);
        if (feeBps > p.maxFeeBps) revert FeeAboveMax(feeBps, p.maxFeeBps);
        _validateParams(p, feeBps, msg.sender, true, true);

        mandateId = keccak256(abi.encode(block.chainid, address(this), msg.sender, nonces[msg.sender]++));
        Mandate storage m = _mandates[mandateId];
        m.principal = msg.sender;
        m.executor = p.executor;
        m.evaluator = p.evaluator;
        m.asset = p.asset;
        m.funding = p.funding;
        m.action = p.action;
        m.feeBps = feeBps;
        m.revision = 1;
        _writeMutable(m, p);
        _captureBoth(m, p, msg.sender);
        // The external calls before this are views (validate, capture, validateConfig): nothing reenters.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MandateRegistered(mandateId, msg.sender, p.agent, p.executor, p.evaluator);
    }

    /// @inheritdoc IShieldV1
    function amendMandate(bytes32 mandateId, MandateParams calldata p) external {
        Mandate storage m = _mandates[mandateId];
        if (m.principal == address(0)) revert MandateBlocked(mandateId, MandateReason.NONEXISTENT);
        if (msg.sender != m.principal) revert NotPrincipal();
        if (m.revoked) revert MandateBlocked(mandateId, MandateReason.REVOKED);
        if (p.executor != m.executor) revert FieldImmutable("executor");
        if (p.evaluator != m.evaluator) revert FieldImmutable("evaluator");
        if (p.asset != m.asset) revert FieldImmutable("asset");
        if (p.funding != m.funding) revert FieldImmutable("funding");
        if (p.action != m.action) revert FieldImmutable("action");
        if (p.maxCumulativeValue < m.cumulativeUsed) revert InvalidParams("maxCumulativeValue");
        // The stamped fee is kept for life and must fit the newly signed ceiling.
        if (m.feeBps > p.maxFeeBps) revert FeeAboveMax(m.feeBps, p.maxFeeBps);
        bool triggerChanged = keccak256(p.trigger) != keccak256(m.trigger);
        bool outcomeChanged = keccak256(p.outcome) != keccak256(m.outcome);
        // An unchanged tree may keep a delisted descriptor; a changed one is a new tree.
        _validateParams(p, m.feeBps, msg.sender, triggerChanged, outcomeChanged);
        _writeMutable(m, p);
        m.revision += 1;
        // An unchanged tree keeps its baseline; a changed one is re-taken.
        if (triggerChanged) {
            m.triggerSigned = p.trigger.length == 0
                ? new int256[](0)
                : IEvaluatorV1(m.evaluator).capture(p.trigger, msg.sender);
        }
        if (outcomeChanged) {
            m.outcomeSigned = p.outcome.length == 0
                ? new int256[](0)
                : IEvaluatorV1(m.evaluator).capture(p.outcome, msg.sender);
        }
        // The external calls before this are views (validate, capture, validateConfig): nothing reenters.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MandateAmended(mandateId, m.revision);
    }

    /// @inheritdoc IShieldV1
    function revokeMandate(bytes32 mandateId) external {
        Mandate storage m = _mandates[mandateId];
        if (m.principal == address(0)) revert MandateBlocked(mandateId, MandateReason.NONEXISTENT);
        if (msg.sender != m.principal) revert NotPrincipal();
        _revoke(m, mandateId);
    }

    /// @inheritdoc IShieldV1
    /// @dev EIP-712 over (mandateId, principal, nonce, deadline); an EOA by
    ///      recovery, a contract wallet by ERC-1271. Revokes and nothing else.
    function revokeWithSig(bytes32 mandateId, uint256 deadline, bytes calldata signature) external {
        Mandate storage m = _mandates[mandateId];
        if (m.principal == address(0)) revert MandateBlocked(mandateId, MandateReason.NONEXISTENT);
        if (block.timestamp > deadline) revert SignatureExpired();
        address principal = m.principal;
        uint256 nonce = sigNonces[principal]++;
        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(REVOKE_TYPEHASH, mandateId, principal, nonce, deadline)));
        if (!SignatureChecker.isValidSignatureNow(principal, digest, signature)) revert BadSignature();
        _revoke(m, mandateId);
    }

    function _revoke(Mandate storage m, bytes32 mandateId) internal {
        if (m.revoked) revert MandateBlocked(mandateId, MandateReason.REVOKED);
        m.revoked = true;
        // The external calls before this are views (validate, capture, validateConfig): nothing reenters.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MandateRevoked(mandateId, m.principal);
    }

    // ==================================================================== agent

    /// @dev What one firing carries between its steps.
    struct Firing {
        uint256 feeMax;
        uint256 before;
        uint256 used;
        uint256 fee;
        int256[] beforeValues;
    }

    /// @inheritdoc IShieldV1
    function fire(bytes32 mandateId, uint256 amount, bytes calldata route)
        external
        nonReentrant
        returns (uint256 spent)
    {
        Mandate storage m = _mandates[mandateId];
        MandateReason reason = _check(m, msg.sender, amount);
        if (reason != MandateReason.OK) revert MandateBlocked(mandateId, reason);
        // 3. The trigger, before anything moves.
        if (m.trigger.length != 0) {
            if (!IEvaluatorV1(m.evaluator).judgeTrigger(m.trigger, m.principal, m.triggerSigned, amount)) {
                revert MandateBlocked(mandateId, MandateReason.TRIGGER_NOT_MET);
            }
        }
        Firing memory f;
        // 4. The before values the outcome names, and the executor's own
        //    mandatory before values (a debt, a collateral, a vault rate):
        //    both taken before anything is pulled.
        if (m.outcome.length != 0) {
            f.beforeValues = IEvaluatorV1(m.evaluator).snapshot(m.outcome, m.principal);
        }
        IExecutorV1.Context memory ctx = _context(m, mandateId);
        ctx.before = IExecutorV1(m.executor).snapshot(ctx, amount);
        // 5. Reserve, take the fee's worst case, pull the amount (funding PULL).
        _fund(m, f, amount);
        // 6. The executor runs its action and its mandatory checks.
        f.used = _runExecutor(m, mandateId, ctx, amount, route);
        // 7. Measure, apply the spend rule, settle the fee, reconcile, record.
        spent = _settle(m, f, amount);
        // 8. The owner's outcome tree, on the final state.
        if (m.outcome.length != 0) {
            bool ok = IEvaluatorV1(m.evaluator)
                .judgeOutcome(m.outcome, m.principal, m.outcomeSigned, f.beforeValues, amount);
            if (!ok) revert OutcomeRejected(mandateId, MandateReason.OUTCOME_FAILED, "");
        }
        // 9. Recorded. After the external calls on purpose: the receipt carries
        //    the reconciled spend and `nonReentrant` rules out reordering.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MandateFired(mandateId, msg.sender, m.executor, m.action, amount, spent, f.fee);
    }

    function _fund(Mandate storage m, Firing memory f, uint256 amount) internal {
        IERC20 asset = IERC20(m.asset);
        if (m.funding != uint8(FundingMode.PULL)) {
            f.before = asset.balanceOf(m.principal);
            return;
        }
        uint256 feeOn = feeRecipient == address(0) ? 0 : m.feeBps;
        f.feeMax = Math.mulDiv(amount, feeOn, BPS);
        m.cumulativeUsed += amount + f.feeMax;
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        if (f.feeMax != 0) asset.safeTransferFrom(m.principal, address(this), f.feeMax);
        f.before = asset.balanceOf(m.principal);
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        asset.safeTransferFrom(m.principal, m.executor, amount);
    }

    /// @dev The exact spend rule: revert if the measured outflow or the
    ///      executor's report is above the amount; otherwise charge the larger.
    ///      Funding NONE: nothing may leave and nothing may be reported.
    function _settle(Mandate storage m, Firing memory f, uint256 amount) internal returns (uint256 spent) {
        IERC20 asset = IERC20(m.asset);
        uint256 after_ = asset.balanceOf(m.principal);
        uint256 left = f.before > after_ ? f.before - after_ : 0;
        if (m.funding == uint8(FundingMode.PULL)) {
            if (left > amount) revert SpendExceedsAmount(left, amount);
            if (f.used > amount) revert SpendExceedsAmount(f.used, amount);
            if (left > f.used) f.used = left;
            uint256 feeOn = feeRecipient == address(0) ? 0 : m.feeBps;
            f.fee = Math.mulDiv(f.used, feeOn, BPS);
            if (f.fee != 0) asset.safeTransfer(feeRecipient, f.fee);
            if (f.feeMax > f.fee) asset.safeTransfer(m.principal, f.feeMax - f.fee);
            spent = f.used + f.fee;
            m.cumulativeUsed -= (amount + f.feeMax) - spent;
        } else {
            if (f.used != 0) revert SpendExceedsAmount(f.used, 0);
            if (left != 0) revert NothingMayLeave(left);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        m.lastFiredAt = uint48(block.timestamp);
        m.firings += 1;
    }

    function _context(Mandate storage m, bytes32 mandateId)
        internal
        view
        returns (IExecutorV1.Context memory)
    {
        return IExecutorV1.Context({
            mandateId: mandateId,
            principal: m.principal,
            agent: m.agent,
            asset: m.asset,
            funding: m.funding,
            action: m.action,
            actionConfig: m.actionConfig,
            revision: m.revision,
            before: ""
        });
    }

    function _runExecutor(
        Mandate storage m,
        bytes32 mandateId,
        IExecutorV1.Context memory ctx,
        uint256 amount,
        bytes calldata route
    ) internal returns (uint256 used) {
        try IExecutorV1(m.executor).execute(ctx, amount, route) returns (uint256 consumed) {
            used = consumed;
        } catch (bytes memory executorError) {
            revert OutcomeRejected(mandateId, MandateReason.OUTCOME_FAILED, executorError);
        }
    }

    // ==================================================================== views

    /// @inheritdoc IShieldV1
    function canFireBy(bytes32 mandateId, address caller, uint256 amount)
        external
        view
        returns (bool ok, MandateReason reason)
    {
        reason = _check(_mandates[mandateId], caller, amount);
        ok = reason == MandateReason.OK;
    }

    /// @inheritdoc IShieldV1
    function getMandate(bytes32 mandateId) external view returns (Mandate memory) {
        return _mandates[mandateId];
    }

    // forge-lint: disable-next-item(missing-zero-check)
    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(this) || registry.isExecutorListed(recipient)) {
            revert InvalidParams("feeRecipient");
        }
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function setFeeBps(uint16 bps) external onlyOwner {
        _setFeeBps(bps);
    }

    function transferOwnership(address newOwner) public override(Ownable2Step) onlyOwner {
        if (registry.isEnforcer(newOwner)) revert AdminCannotBeEnforcer(newOwner);
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override(Ownable2Step) {
        if (registry.isEnforcer(msg.sender)) revert AdminCannotBeEnforcer(msg.sender);
        super.acceptOwnership();
    }

    function renounceOwnership() public view override(Ownable) onlyOwner {
        revert InvalidParams("renounceOwnership");
    }

    // ================================================================= internal

    /// @dev The single check sequence `canFireBy` reports and `fire` enforces.
    function _check(Mandate storage m, address caller, uint256 amount) internal view returns (MandateReason) {
        if (m.principal == address(0)) return MandateReason.NONEXISTENT;
        if (registry.isAgentFrozen(m.agent)) return MandateReason.AGENT_FROZEN;
        if (caller != m.agent) return MandateReason.NOT_AGENT;
        if (registry.stopped(m.executor)) return MandateReason.EXECUTOR_HALTED;
        if (registry.stopped(m.evaluator)) return MandateReason.EVALUATOR_HALTED;
        if (block.timestamp < m.validFrom) return MandateReason.NOT_YET_VALID;
        if (block.timestamp > m.validUntil) return MandateReason.EXPIRED;
        if (m.revoked) return MandateReason.REVOKED;
        if (m.funding == uint8(FundingMode.NONE)) {
            if (amount != 0) return MandateReason.AMOUNT_NOT_ZERO;
            return MandateReason.OK;
        }
        if (amount == 0) return MandateReason.ZERO_AMOUNT;
        if (amount > m.maxTransactionValue) return MandateReason.OVER_TX_CAP;
        uint256 remaining = m.maxCumulativeValue - m.cumulativeUsed;
        if (amount > remaining) return MandateReason.OVER_CUMULATIVE_CAP;
        uint256 feeOn = feeRecipient == address(0) ? 0 : m.feeBps;
        uint256 feeMax = Math.mulDiv(amount, feeOn, BPS);
        if (feeMax > remaining - amount) return MandateReason.OVER_CUMULATIVE_CAP;
        uint256 need = amount + feeMax;
        if (IERC20(m.asset).allowance(m.principal, address(this)) < need) {
            return MandateReason.INSUFFICIENT_ALLOWANCE;
        }
        if (IERC20(m.asset).balanceOf(m.principal) < need) return MandateReason.INSUFFICIENT_BALANCE;
        return MandateReason.OK;
    }

    function _validateParams(
        MandateParams calldata p,
        uint16 feeBpsFor,
        address principal,
        bool triggerNew,
        bool outcomeNew
    ) internal view {
        if (p.agent == address(0) || p.agent == principal || p.agent == address(this)) {
            revert InvalidParams("agent");
        }
        if (p.asset == address(0)) revert InvalidParams("asset");
        if (p.funding > uint8(FundingMode.NONE)) revert InvalidParams("funding");
        if (p.maxFeeBps > MAX_FEE_BPS) revert InvalidParams("maxFeeBps");
        if (p.funding == uint8(FundingMode.PULL)) {
            if (p.maxTransactionValue == 0) revert InvalidParams("maxTransactionValue");
            if (p.maxCumulativeValue < p.maxTransactionValue) revert InvalidParams("maxCumulativeValue");
            if (
                p.maxCumulativeValue - p.maxTransactionValue
                    < Math.mulDiv(p.maxTransactionValue, feeBpsFor, BPS)
            ) {
                revert InvalidParams("maxCumulativeValue");
            }
        } else {
            // Nothing is pulled: a no-input action must carry an outcome tree or rely on the executor's checks; both caps are zero.
            if (p.maxTransactionValue != 0 || p.maxCumulativeValue != 0) revert InvalidParams("caps");
        }
        if (p.validUntil <= p.validFrom || p.validUntil <= block.timestamp) {
            revert InvalidParams("validUntil");
        }
        IExecutorV1 x = IExecutorV1(p.executor);
        // Fail closed: only the semantics this core knows, nothing reserved upward.
        uint8 sem = x.semanticsOf(p.action);
        if (sem == SemanticsV1.UNSUPPORTED || sem > SemanticsV1.MAX) {
            revert ActionNotSupported(p.executor, p.action);
        }
        // Funding NONE is only for the claim semantics; everything else pulls.
        bool noInput = sem == SemanticsV1.CLAIM_COLLECT || sem == SemanticsV1.CLAIM_COMPOSE;
        if (noInput != (p.funding == uint8(FundingMode.NONE))) revert InvalidParams("funding");
        x.validateConfig(p.action, p.asset, p.actionConfig);
        IEvaluatorV1 e = IEvaluatorV1(p.evaluator);
        if (p.trigger.length != 0) e.validate(p.trigger, IEvaluatorV1.Phase.Trigger, principal, triggerNew);
        if (p.outcome.length != 0) e.validate(p.outcome, IEvaluatorV1.Phase.Outcome, principal, outcomeNew);
    }

    function _writeMutable(Mandate storage m, MandateParams calldata p) internal {
        m.agent = p.agent;
        m.maxTransactionValue = p.maxTransactionValue;
        m.maxCumulativeValue = p.maxCumulativeValue;
        m.validFrom = p.validFrom;
        m.validUntil = p.validUntil;
        m.maxFeeBps = p.maxFeeBps;
        m.actionConfig = p.actionConfig;
        m.trigger = p.trigger;
        m.outcome = p.outcome;
    }

    function _captureBoth(Mandate storage m, MandateParams calldata p, address principal) internal {
        IEvaluatorV1 e = IEvaluatorV1(m.evaluator);
        if (p.trigger.length != 0) m.triggerSigned = e.capture(p.trigger, principal);
        if (p.outcome.length != 0) m.outcomeSigned = e.capture(p.outcome, principal);
    }

    function _setFeeBps(uint16 bps) internal {
        if (bps > MAX_FEE_BPS) revert InvalidParams("feeBps");
        feeBps = bps;
        emit FeeBpsSet(bps);
    }
}
