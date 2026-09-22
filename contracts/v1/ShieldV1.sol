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
import {IDescriptors} from "./interfaces/IDescriptors.sol";
import {IEvaluatorV1} from "./interfaces/IEvaluatorV1.sol";
import {IExecutorV1, SemanticsV1} from "./interfaces/IExecutorV1.sol";

/// @title ShieldV1
/// @notice The Signo Shield core, version 1. Holds every mandate, the read
///         catalog, the executor and evaluator listings, and the emergency
///         controls; pulls only the mandate's asset, bounded by the caps the
///         owner signed; hands it to the pinned executor; measures what left
///         the owner; settles the fee and the bookkeeping; then judges the
///         owner's outcome tree on that final state. A revert anywhere undoes
///         all of it.
///
/// Roles. The admin (`Ownable2Step`) lists executors, evaluators and
/// descriptors for new registrations, sets the fee for new mandates and the
/// fee recipient, appoints enforcers, and executes a queued restoration
/// after the delay; it cannot touch a live mandate or any funds. An enforcer
/// freezes agents, halts listed contracts, suspends and revokes venues and
/// descriptors, and queues restorations. Nobody can change what an owner
/// signed. Every contract is immutable; a change is a new version.
contract ShieldV1 is IShieldV1, IDescriptors, Ownable2Step, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    string public constant VERSION = "1.0.0";
    uint16 public constant MAX_FEE_BPS = 1_000;
    uint64 public constant RESTORE_DELAY = 24 hours;
    uint256 private constant BPS = 10_000;
    bytes32 private constant REVOKE_TYPEHASH =
        keccak256("Revoke(bytes32 mandateId,address principal,uint256 nonce,uint256 deadline)");

    /// @dev A halt or a suspension: active with an epoch; a queued
    ///      restoration for one epoch, executable after the delay. A new halt
    ///      or suspension bumps the epoch and cancels the queue.
    struct Gate {
        bool active;
        uint64 epoch;
        uint64 queuedAt;
        uint64 queuedEpoch;
    }

    address public feeRecipient;
    uint16 public feeBps;
    mapping(address principal => uint256) public nonces;
    mapping(address principal => uint256) public sigNonces;

    mapping(bytes32 mandateId => Mandate) private _mandates;
    mapping(address agent => bool) private _frozen;
    mapping(address account => bool) private _enforcers;
    mapping(address executor => bool) private _executors;
    mapping(address evaluator => bool) private _evaluators;
    mapping(address listed => Gate) private _halts;
    mapping(address target => Gate) private _suspensions;
    mapping(address target => bool) private _revokedTargets;
    mapping(bytes32 id => Descriptor) private _descriptors;
    mapping(bytes32 id => bool) private _descriptorListed;
    mapping(bytes32 id => bool) private _descriptorRevoked;

    constructor(address initialOwner, uint16 feeBps_) Ownable(initialOwner) EIP712("SignoShield", "1") {
        _setFeeBps(feeBps_);
    }

    // ================================================================ principal

    /// @inheritdoc IShieldV1
    function registerMandate(MandateParams calldata p) external returns (bytes32 mandateId) {
        if (!_executors[p.executor]) revert ExecutorNotListed(p.executor);
        if (!_evaluators[p.evaluator]) revert EvaluatorNotListed(p.evaluator);
        if (feeBps > p.maxFeeBps) revert FeeAboveMax(feeBps, p.maxFeeBps);
        _validateParams(p, feeBps, msg.sender);

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
        _validateParams(p, m.feeBps, msg.sender);

        bool triggerChanged = keccak256(p.trigger) != keccak256(m.trigger);
        bool outcomeChanged = keccak256(p.outcome) != keccak256(m.outcome);
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
        // 4. The before values the outcome names.
        if (m.outcome.length != 0) {
            f.beforeValues = IEvaluatorV1(m.evaluator).snapshot(m.outcome, m.principal);
        }
        // 5. Reserve, take the fee's worst case, pull the amount (funding PULL).
        _fund(m, f, amount);
        // 6. The executor runs its action and its mandatory checks.
        f.used = _runExecutor(m, mandateId, amount, route);
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

    function _runExecutor(Mandate storage m, bytes32 mandateId, uint256 amount, bytes calldata route)
        internal
        returns (uint256 used)
    {
        IExecutorV1.Context memory ctx = IExecutorV1.Context({
            mandateId: mandateId,
            principal: m.principal,
            agent: m.agent,
            asset: m.asset,
            funding: m.funding,
            action: m.action,
            actionConfig: m.actionConfig,
            revision: m.revision
        });
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

    function isAgentFrozen(address agent) external view returns (bool) {
        return _frozen[agent];
    }

    function isEnforcer(address account) external view returns (bool) {
        return _enforcers[account];
    }

    function isExecutorListed(address executor) external view returns (bool) {
        return _executors[executor];
    }

    function isEvaluatorListed(address evaluator) external view returns (bool) {
        return _evaluators[evaluator];
    }

    /// @inheritdoc IShieldV1
    function isHalted(address listed) external view returns (bool) {
        return _halts[listed].active;
    }

    /// @inheritdoc IShieldV1
    function isSuspended(address target) external view returns (bool) {
        return _suspensions[target].active;
    }

    /// @inheritdoc IShieldV1
    function isRevoked(address target) external view returns (bool) {
        return _revokedTargets[target];
    }

    /// @inheritdoc IShieldV1
    function isVenueBlocked(address target) external view returns (bool) {
        return _suspensions[target].active || _revokedTargets[target];
    }

    /// @inheritdoc IDescriptors
    function descriptorOf(bytes32 id) external view returns (Descriptor memory d, bool listed, bool revoked) {
        return (_descriptors[id], _descriptorListed[id], _descriptorRevoked[id]);
    }

    /// @inheritdoc IDescriptors
    function descriptorId(Descriptor calldata d) external pure returns (bytes32) {
        return keccak256(abi.encode(d));
    }

    // ================================================================= enforcer

    modifier onlyEnforcer() {
        if (!_enforcers[msg.sender]) revert NotEnforcer();
        _;
    }

    function freezeAgent(address agent) external onlyEnforcer {
        _frozen[agent] = true;
        emit AgentFrozen(agent, msg.sender);
    }

    function unfreezeAgent(address agent) external onlyEnforcer {
        _frozen[agent] = false;
        emit AgentUnfrozen(agent, msg.sender);
    }

    /// @notice Stop every mandate that pins `listed` (an executor or an evaluator). Narrowing only.
    function halt(address listed) external onlyEnforcer {
        Gate storage g = _halts[listed];
        g.active = true;
        g.epoch += 1;
        g.queuedAt = 0;
        g.queuedEpoch = 0;
        emit Halted(listed, g.epoch, msg.sender);
    }

    /// @notice An enforcer approves restoring `listed` for the halt epoch it names.
    function queueUnhalt(address listed, uint64 epoch) external onlyEnforcer {
        Gate storage g = _halts[listed];
        if (!g.active || g.epoch != epoch) revert EpochMismatch(listed, epoch);
        // forge-lint: disable-next-line(unsafe-typecast)
        g.queuedAt = uint64(block.timestamp);
        g.queuedEpoch = epoch;
        emit UnhaltQueued(listed, epoch, msg.sender);
    }

    /// @notice The admin executes a queued restoration, 24 hours after it was queued.
    function executeUnhalt(address listed, uint64 epoch) external onlyOwner {
        Gate storage g = _halts[listed];
        _executeRestore(g, listed, epoch);
        emit UnhaltExecuted(listed, epoch, msg.sender);
    }

    /// @notice Stop every executor from calling or approving `target` until reviewed. Narrowing only.
    function suspend(address target) external onlyEnforcer {
        if (_revokedTargets[target]) revert TargetRevoked(target);
        Gate storage g = _suspensions[target];
        g.active = true;
        g.epoch += 1;
        g.queuedAt = 0;
        g.queuedEpoch = 0;
        emit Suspended(target, g.epoch, msg.sender);
    }

    function queueLift(address target, uint64 epoch) external onlyEnforcer {
        if (_revokedTargets[target]) revert TargetRevoked(target);
        Gate storage g = _suspensions[target];
        if (!g.active || g.epoch != epoch) revert EpochMismatch(target, epoch);
        // forge-lint: disable-next-line(unsafe-typecast)
        g.queuedAt = uint64(block.timestamp);
        g.queuedEpoch = epoch;
        emit LiftQueued(target, epoch, msg.sender);
    }

    function executeLift(address target, uint64 epoch) external onlyOwner {
        if (_revokedTargets[target]) revert TargetRevoked(target);
        Gate storage g = _suspensions[target];
        _executeRestore(g, target, epoch);
        emit LiftExecuted(target, epoch, msg.sender);
    }

    /// @notice Permanently refuse `target` as a venue or a read target. No restoration exists.
    function revoke(address target) external onlyEnforcer {
        _revokedTargets[target] = true;
        Gate storage g = _suspensions[target];
        g.active = false;
        g.queuedAt = 0;
        g.queuedEpoch = 0;
        emit Revoked(target, msg.sender);
    }

    /// @notice Permanently refuse a descriptor: no firing may read through it.
    function revokeDescriptor(bytes32 id) external onlyEnforcer {
        _descriptorRevoked[id] = true;
        _descriptorListed[id] = false;
        emit DescriptorRevoked(id, msg.sender);
    }

    function _executeRestore(Gate storage g, address target, uint64 epoch) internal {
        if (!g.active || g.epoch != epoch || g.queuedEpoch != epoch || g.queuedAt == 0) {
            revert EpochMismatch(target, epoch);
        }
        if (block.timestamp < uint256(g.queuedAt) + RESTORE_DELAY) revert RestoreNotReady(target, epoch);
        g.active = false;
        g.queuedAt = 0;
        g.queuedEpoch = 0;
    }

    // ==================================================================== admin

    function setEnforcer(address enforcer, bool enabled) external onlyOwner {
        if (enforcer == address(0)) revert InvalidParams("enforcer");
        if (enabled && (enforcer == owner() || enforcer == pendingOwner())) {
            revert AdminCannotBeEnforcer(enforcer);
        }
        _enforcers[enforcer] = enabled;
        emit EnforcerSet(enforcer, enabled);
    }

    /// @notice List or delist an executor for NEW registrations; reaches no live mandate.
    function setExecutor(address executor, bool listed) external onlyOwner {
        if (listed && executor.code.length == 0) revert InvalidParams("executor");
        _executors[executor] = listed;
        emit ExecutorListed(executor, listed);
    }

    /// @notice List or delist an evaluator for NEW registrations; reaches no live mandate.
    function setEvaluator(address evaluator, bool listed) external onlyOwner {
        if (listed && evaluator.code.length == 0) revert InvalidParams("evaluator");
        _evaluators[evaluator] = listed;
        emit EvaluatorListed(evaluator, listed);
    }

    /// @notice Store a descriptor under the hash of its contents and list it.
    ///         Nothing can ever be stored under an existing id with different
    ///         contents: the id is the contents.
    function listDescriptor(Descriptor calldata d) external onlyOwner returns (bytes32 id) {
        id = keccak256(abi.encode(d));
        if (_descriptorRevoked[id]) revert InvalidParams("revoked");
        if (d.kind == DescriptorKind.PerAddress && d.target.code.length == 0) revert InvalidParams("target");
        if (d.kind == DescriptorKind.Shape && d.target != address(0)) revert InvalidParams("target");
        // forge-lint: disable-next-item(unsafe-typecast)
        if (
            d.subjectRule == SubjectRule.PrincipalRequired
                && (d.subjectArg < 0 || uint8(d.subjectArg) >= d.argCount)
        ) {
            revert InvalidParams("subjectArg");
        }
        if (uint256(d.copyBytes) < (uint256(d.word) + 1) * 32) revert InvalidParams("copyBytes");
        if (d.freshness == Freshness.ChainlinkRound && (d.copyBytes < 160 || d.maxAge == 0)) {
            revert InvalidParams("freshness");
        }
        if (d.gasStipend == 0) revert InvalidParams("gasStipend");
        if (_descriptors[id].gasStipend == 0) _descriptors[id] = d;
        _descriptorListed[id] = true;
        emit DescriptorListed(id, true);
    }

    /// @notice Delist a descriptor for NEW registrations; live mandates keep reading through it.
    function delistDescriptor(bytes32 id) external onlyOwner {
        _descriptorListed[id] = false;
        emit DescriptorListed(id, false);
    }

    // forge-lint: disable-next-item(missing-zero-check)
    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(this) || _executors[recipient]) revert InvalidParams("feeRecipient");
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function setFeeBps(uint16 bps) external onlyOwner {
        _setFeeBps(bps);
    }

    function transferOwnership(address newOwner) public override(Ownable2Step) onlyOwner {
        if (_enforcers[newOwner]) revert AdminCannotBeEnforcer(newOwner);
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override(Ownable2Step) {
        if (_enforcers[msg.sender]) revert AdminCannotBeEnforcer(msg.sender);
        super.acceptOwnership();
    }

    function renounceOwnership() public view override(Ownable) onlyOwner {
        revert InvalidParams("renounceOwnership");
    }

    // ================================================================= internal

    /// @dev The single check sequence `canFireBy` reports and `fire` enforces.
    function _check(Mandate storage m, address caller, uint256 amount) internal view returns (MandateReason) {
        if (m.principal == address(0)) return MandateReason.NONEXISTENT;
        if (_frozen[m.agent]) return MandateReason.AGENT_FROZEN;
        if (caller != m.agent) return MandateReason.NOT_AGENT;
        if (_halts[m.executor].active) return MandateReason.EXECUTOR_HALTED;
        if (_halts[m.evaluator].active) return MandateReason.EVALUATOR_HALTED;
        if (block.timestamp < m.validFrom) return MandateReason.NOT_YET_VALID;
        if (block.timestamp > m.validUntil) return MandateReason.EXPIRED;
        if (m.lastFiredAt != 0 && block.timestamp < uint256(m.lastFiredAt) + m.minInterval) {
            return MandateReason.TOO_SOON;
        }
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

    function _validateParams(MandateParams calldata p, uint16 feeBpsFor, address principal) internal view {
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
        if (x.semanticsOf(p.action) == SemanticsV1.UNSUPPORTED) {
            revert ActionNotSupported(p.executor, p.action);
        }
        x.validateConfig(p.action, p.asset, p.actionConfig);
        IEvaluatorV1 e = IEvaluatorV1(p.evaluator);
        if (p.trigger.length != 0) e.validate(p.trigger, IEvaluatorV1.Phase.Trigger, principal);
        if (p.outcome.length != 0) e.validate(p.outcome, IEvaluatorV1.Phase.Outcome, principal);
    }

    function _writeMutable(Mandate storage m, MandateParams calldata p) internal {
        m.agent = p.agent;
        m.maxTransactionValue = p.maxTransactionValue;
        m.maxCumulativeValue = p.maxCumulativeValue;
        m.validFrom = p.validFrom;
        m.validUntil = p.validUntil;
        m.minInterval = p.minInterval;
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
