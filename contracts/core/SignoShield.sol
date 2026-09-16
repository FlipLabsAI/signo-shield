// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICondition} from "./interfaces/ICondition.sol";
import {IShieldAdapter} from "./interfaces/IShieldAdapter.sol";
import {ISignoShield} from "./interfaces/ISignoShield.sol";

/// @title SignoShield
/// @notice Holds mandates and enforces their limits. A tool the agent fires,
///         not another agent. The owner signs a mandate; the agent fires a
///         mandate through the Shield; the Shield enforces the bound while the
///         agent decides the action.
///
/// What the Shield does on a firing, in order: every check in `canFire`'s
/// order, reserve the amount against the budget, pull the amount from the
/// principal with the allowance the principal granted this contract, hand it
/// to the pinned adapter, require the adapter's outcome check to pass, then
/// reconcile the budget to what was actually spent. It holds no user funds
/// between transactions and has no withdrawal function.
///
/// Three roles, kept apart:
///   - The PRINCIPAL registers, amends and revokes its own mandates. Nobody
///     else can touch them.
///   - The ADMIN (`Ownable2Step`) lists adapters for NEW registrations,
///     appoints enforcers and sets the fee recipient. It cannot move funds,
///     cannot change a live mandate, and cannot freeze: an admin key that
///     could freeze would be one key with two powers.
///   - An ENFORCER can freeze and unfreeze an agent and nothing else. It halts
///     every mandate the agent holds, for every principal, in one transaction
///     and reversibly. It cannot revoke, cannot move funds, cannot widen.
///
/// A mandate pins its adapter at registration. Listing or delisting an adapter
/// afterwards reaches no live mandate, so no admin action can silently widen
/// or narrow what a principal signed.
contract SignoShield is ISignoShield, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Human-readable build marker, surfaced in the deployments manifest.
    string public constant VERSION = "0.1.0";
    /// @notice Hard ceiling on what any mandate may carry as a fee. A number a
    ///         review screen can be wrong about is a number the contract caps.
    uint16 public constant MAX_FEE_BPS = 1_000;
    uint256 private constant BPS = 10_000;

    /// @inheritdoc ISignoShield
    ICondition public immutable conditionModule;
    /// @inheritdoc ISignoShield
    address public feeRecipient;
    /// @inheritdoc ISignoShield
    uint16 public feeBps;
    /// @notice Per-principal registration counter; part of the mandate id.
    mapping(address principal => uint256) public nonces;

    mapping(bytes32 mandateId => Mandate) private _mandates;
    mapping(address agent => bool) private _frozen;
    mapping(address account => bool) private _enforcers;
    mapping(address adapter => bool) private _adapters;

    constructor(address initialOwner, ICondition conditionModule_, uint16 feeBps_) Ownable(initialOwner) {
        if (address(conditionModule_).code.length == 0) revert InvalidParams("conditionModule");
        conditionModule = conditionModule_;
        _setFeeBps(feeBps_);
    }

    // ---------------------------------------------------------------- principal

    /// @inheritdoc ISignoShield
    function registerMandate(MandateParams calldata params) external returns (bytes32 mandateId) {
        if (!_adapters[params.adapter]) revert AdapterNotListed(params.adapter);
        _validateParams(params, feeBps);

        mandateId = keccak256(abi.encode(block.chainid, address(this), msg.sender, nonces[msg.sender]++));
        Mandate storage m = _mandates[mandateId];
        m.principal = msg.sender;
        m.agent = params.agent;
        m.adapter = params.adapter;
        m.action = params.action;
        m.asset = params.asset;
        // The fee is stamped, not chosen: what the Shield charges today is what
        // this mandate pays for life, shown on the review screen as a number.
        m.feeBps = feeBps;
        _writeMutable(m, params);

        // The only external call before this is the trigger dry-run, a
        // staticcall into our own immutable module: it cannot reenter.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MandateRendered(msg.sender, params.agent, mandateId, m);
    }

    /// @inheritdoc ISignoShield
    function amendMandate(bytes32 mandateId, MandateParams calldata params) external {
        Mandate storage m = _mandates[mandateId];
        if (m.principal == address(0)) revert MandateBlocked(mandateId, MandateReason.NONEXISTENT);
        if (msg.sender != m.principal) revert NotPrincipal();
        if (m.revoked) revert MandateBlocked(mandateId, MandateReason.REVOKED);
        // Widening scope must never widen who holds it, what it runs, or what it pulls.
        if (params.agent != m.agent) revert FieldImmutable("agent");
        if (params.adapter != m.adapter) revert FieldImmutable("adapter");
        if (params.action != m.action) revert FieldImmutable("action");
        if (params.asset != m.asset) revert FieldImmutable("asset");
        // cumulativeUsed never resets, so the cap cannot be moved underneath it.
        if (params.maxCumulativeValue < m.cumulativeUsed) revert InvalidParams("maxCumulativeValue");
        // The adapter is pinned, so it is consulted even if it has since been
        // delisted: delisting gates new registrations, not the principal's
        // right to narrow or extend what it already signed.
        _validateParams(params, m.feeBps);

        _writeMutable(m, params);
        // Same as registration: the dry-run is a staticcall, nothing reenters.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MandateRendered(msg.sender, m.agent, mandateId, m);
    }

    /// @inheritdoc ISignoShield
    function revokeMandate(bytes32 mandateId) external {
        Mandate storage m = _mandates[mandateId];
        if (m.principal == address(0)) revert MandateBlocked(mandateId, MandateReason.NONEXISTENT);
        if (msg.sender != m.principal) revert NotPrincipal();
        if (m.revoked) revert MandateBlocked(mandateId, MandateReason.REVOKED);
        m.revoked = true;
        emit MandateRevoked(mandateId, msg.sender);
    }

    // -------------------------------------------------------------------- agent

    /// @inheritdoc ISignoShield
    function fire(bytes32 mandateId, uint256 amount, bytes calldata data)
        external
        nonReentrant
        returns (uint256 spent)
    {
        Mandate storage m = _mandates[mandateId];
        MandateReason reason = _check(m, msg.sender, amount);
        if (reason != MandateReason.OK) revert MandateBlocked(mandateId, reason);

        // Reserve the worst case before any external call: the amount plus
        // the fee it would carry if all of it were spent. A reentrant or
        // nested firing sees the budget already taken; the reservation is
        // reconciled to the real figure below.
        uint256 feeOn = feeRecipient == address(0) ? 0 : m.feeBps;
        uint256 feeMax = Math.mulDiv(amount, feeOn, BPS);
        m.cumulativeUsed += amount + feeMax;

        // The fee's worst case is taken first and settled after the outcome
        // stands, so every check the adapter makes sees the principal's final
        // state (a repay-with-collateral's health factor included); what was
        // not owed goes straight back.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        if (feeMax != 0) IERC20(m.asset).safeTransferFrom(m.principal, address(this), feeMax);
        uint256 used = _pullAndRun(m, mandateId, amount, data);

        uint256 fee = Math.mulDiv(used, feeOn, BPS);
        if (fee != 0) IERC20(m.asset).safeTransfer(feeRecipient, fee);
        if (feeMax > fee) IERC20(m.asset).safeTransfer(m.principal, feeMax - fee);

        // Only what left the principal for good counts against the budget.
        spent = used + fee;
        m.cumulativeUsed -= (amount + feeMax) - spent;

        // After the external call on purpose: the receipt carries the reconciled
        // spend, and `nonReentrant` rules out a nested firing reordering it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MandateFired(mandateId, msg.sender, m.adapter, m.action, amount, spent, fee);
    }

    /// @dev Pull the amount to the adapter, run it, and MEASURE what left the
    ///      principal: the adapter reports what it spent, the principal's
    ///      balance says what actually left, and the larger of the two is
    ///      what counts. A listed adapter can therefore under-report but
    ///      never under-charge the budget, and more than `amount` leaving is
    ///      a failure of the firing, not a charge.
    function _pullAndRun(Mandate storage m, bytes32 mandateId, uint256 amount, bytes calldata data)
        internal
        returns (uint256 used)
    {
        IERC20 asset = IERC20(m.asset);
        uint256 before = asset.balanceOf(m.principal);
        // Pulling from the principal is the whole point: the principal granted
        // this contract the allowance so that exactly this, bounded by the
        // checks above, can happen without their signature.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        asset.safeTransferFrom(m.principal, m.adapter, amount);
        used = _runAdapter(m, mandateId, amount, data);
        uint256 after_ = asset.balanceOf(m.principal);
        uint256 left = before > after_ ? before - after_ : 0;
        if (left > amount) revert SpendExceedsAmount(left, amount);
        if (left > used) used = left;
    }

    /// @dev The one external call a firing makes. An adapter revert is
    ///      re-thrown, never swallowed: one typed code for the relayer, the
    ///      adapter's own revert data for whoever has to read it.
    function _runAdapter(Mandate storage m, bytes32 mandateId, uint256 amount, bytes calldata data)
        internal
        returns (uint256 used)
    {
        IShieldAdapter.Context memory ctx = IShieldAdapter.Context({
            mandateId: mandateId,
            principal: m.principal,
            agent: m.agent,
            action: m.action,
            asset: m.asset,
            actionConfig: m.actionConfig
        });
        try IShieldAdapter(m.adapter).execute(ctx, amount, data) returns (uint256 consumed) {
            used = consumed;
        } catch (bytes memory adapterError) {
            revert OutcomeRejected(mandateId, MandateReason.POSTCONDITION_FAILED, adapterError);
        }
        if (used > amount) revert SpendExceedsAmount(used, amount);
    }

    // -------------------------------------------------------------------- views

    /// @inheritdoc ISignoShield
    function canFire(bytes32 mandateId, uint256 amount)
        external
        view
        returns (bool ok, MandateReason reason)
    {
        Mandate storage m = _mandates[mandateId];
        reason = _check(m, m.agent, amount);
        ok = reason == MandateReason.OK;
    }

    /// @inheritdoc ISignoShield
    function canFireBy(bytes32 mandateId, address caller, uint256 amount)
        external
        view
        returns (bool ok, MandateReason reason)
    {
        reason = _check(_mandates[mandateId], caller, amount);
        ok = reason == MandateReason.OK;
    }

    /// @inheritdoc ISignoShield
    function getMandate(bytes32 mandateId) external view returns (Mandate memory) {
        return _mandates[mandateId];
    }

    /// @inheritdoc ISignoShield
    function isAgentFrozen(address agent) external view returns (bool) {
        return _frozen[agent];
    }

    /// @inheritdoc ISignoShield
    function isEnforcer(address account) external view returns (bool) {
        return _enforcers[account];
    }

    /// @inheritdoc ISignoShield
    function isAdapterListed(address adapter) external view returns (bool) {
        return _adapters[adapter];
    }

    // ----------------------------------------------------------------- enforcer

    /// @inheritdoc ISignoShield
    function freezeAgent(address agent) external {
        if (!_enforcers[msg.sender]) revert NotEnforcer();
        _frozen[agent] = true;
        emit AgentFrozen(agent, msg.sender);
    }

    /// @inheritdoc ISignoShield
    function unfreezeAgent(address agent) external {
        if (!_enforcers[msg.sender]) revert NotEnforcer();
        _frozen[agent] = false;
        emit AgentUnfrozen(agent, msg.sender);
    }

    // -------------------------------------------------------------------- admin

    /// @notice Appoint or dismiss an enforcer. The admin can never appoint
    ///         itself, and ownership can never pass to an enforcer (see
    ///         `transferOwnership` / `acceptOwnership`), so no single key ever
    ///         holds both roles.
    function setEnforcer(address enforcer, bool enabled) external onlyOwner {
        if (enforcer == address(0)) revert InvalidParams("enforcer");
        if (enabled && (enforcer == owner() || enforcer == pendingOwner())) {
            revert AdminCannotBeEnforcer(enforcer);
        }
        _enforcers[enforcer] = enabled;
        emit EnforcerSet(enforcer, enabled);
    }

    /// @notice List or delist an adapter for NEW registrations. Reaches no live
    ///         mandate: each one pinned its adapter when it was signed.
    function setAdapter(address adapter, bool listed) external onlyOwner {
        if (listed && adapter.code.length == 0) revert InvalidParams("adapter");
        _adapters[adapter] = listed;
        emit AdapterListed(adapter, listed);
    }

    /// @notice Where fees go. `address(0)` disables fee collection entirely,
    ///         whatever a mandate's `feeBps` says. This is the one admin lever
    ///         that reaches live mandates: it turns collection on or off and
    ///         moves where the fee goes. It can only lower what a principal
    ///         pays (the rate is stamped), and it can never point at this
    ///         contract or a listed adapter, where a fee could not be spent.
    // forge-lint: disable-next-item(missing-zero-check)
    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(this) || _adapters[recipient]) revert InvalidParams("feeRecipient");
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice The fee every NEW mandate is stamped with. Reaches no live
    ///         mandate: a fee is part of what the principal signed.
    function setFeeBps(uint16 bps) external onlyOwner {
        _setFeeBps(bps);
    }

    /// @dev Ownership may never be offered to an enforcer.
    function transferOwnership(address newOwner) public override(Ownable2Step) onlyOwner {
        if (_enforcers[newOwner]) revert AdminCannotBeEnforcer(newOwner);
        super.transferOwnership(newOwner);
    }

    /// @dev Belt and braces: an account made enforcer while it was pending owner
    ///      cannot then accept. (`setEnforcer` already refuses the pending owner.)
    function acceptOwnership() public override(Ownable2Step) {
        if (_enforcers[msg.sender]) revert AdminCannotBeEnforcer(msg.sender);
        super.acceptOwnership();
    }

    /// @dev The admin seat is never abandoned: without it no adapter could be
    ///      listed and no enforcer appointed, and nothing is gained by it since
    ///      the admin already cannot reach funds or live mandates.
    function renounceOwnership() public view override(Ownable) onlyOwner {
        revert InvalidParams("renounceOwnership");
    }

    // ----------------------------------------------------------------- internal

    /// @dev The single check sequence `canFire` reports and `fire` enforces.
    ///      The order is fixed; the first failure is the answer. It matches
    ///      ERC-8226's `canExecute` order where the checks coincide, with our
    ///      three inserted where they belong: the caller identity next to the
    ///      freeze (both are about who is firing), zero amount before the caps,
    ///      and the trigger last because it is the one external read.
    function _check(Mandate storage m, address caller, uint256 amount) internal view returns (MandateReason) {
        if (m.principal == address(0)) return MandateReason.NONEXISTENT;
        if (_frozen[m.agent]) return MandateReason.AGENT_FROZEN;
        if (caller != m.agent) return MandateReason.NOT_AGENT;
        if (block.timestamp < m.validFrom) return MandateReason.NOT_YET_VALID;
        if (block.timestamp > m.validUntil) return MandateReason.EXPIRED;
        if (m.revoked) return MandateReason.REVOKED;
        if (amount == 0) return MandateReason.ZERO_AMOUNT;
        if (amount > m.maxTransactionValue) return MandateReason.OVER_TX_CAP;
        // The lifetime cap covers the fee too, so the worst case (all of the
        // amount spent, fee on all of it) is what has to fit. Two steps so an
        // absurd amount cannot overflow into a panic instead of a reason.
        uint256 remaining = m.maxCumulativeValue - m.cumulativeUsed;
        if (amount > remaining) return MandateReason.OVER_CUMULATIVE_CAP;
        uint256 feeOn = feeRecipient == address(0) ? 0 : m.feeBps;
        uint256 feeMax = Math.mulDiv(amount, feeOn, BPS);
        if (feeMax > remaining - amount) return MandateReason.OVER_CUMULATIVE_CAP;
        // The pull needs the principal's allowance and balance for that same
        // worst case; a relayer learns it here rather than from a bare revert.
        uint256 need = amount + feeMax;
        if (IERC20(m.asset).allowance(m.principal, address(this)) < need) {
            return MandateReason.INSUFFICIENT_ALLOWANCE;
        }
        if (IERC20(m.asset).balanceOf(m.principal) < need) return MandateReason.INSUFFICIENT_BALANCE;
        if (m.condition.target != address(0) && !conditionModule.isMet(m.condition)) {
            return MandateReason.TRIGGER_NOT_MET;
        }
        return MandateReason.OK;
    }

    /// @dev Everything about the params that does not depend on the stored
    ///      record. The adapter gets the last word on (action, asset, config).
    function _validateParams(MandateParams calldata p, uint16 feeBpsFor) internal view {
        if (p.agent == address(0) || p.agent == msg.sender || p.agent == address(this)) {
            revert InvalidParams("agent");
        }
        if (p.asset == address(0)) revert InvalidParams("asset");
        if (p.maxTransactionValue == 0) revert InvalidParams("maxTransactionValue");
        if (p.maxCumulativeValue < p.maxTransactionValue) revert InvalidParams("maxCumulativeValue");
        // One firing at the per-firing cap, fee included, must fit the lifetime
        // cap, or the mandate could never fire at its own cap.
        if (p.maxCumulativeValue - p.maxTransactionValue < Math.mulDiv(p.maxTransactionValue, feeBpsFor, BPS))
        {
            revert InvalidParams("maxCumulativeValue");
        }
        if (p.validUntil <= p.validFrom || p.validUntil <= block.timestamp) {
            revert InvalidParams("validUntil");
        }
        if (p.condition.target == address(0)) {
            if (p.condition.callData.length != 0) revert InvalidParams("condition");
        } else {
            if (p.condition.callData.length < 4) revert InvalidParams("condition");
            // Dry-run the trigger: a target without code, a wrong selector or a
            // word past the return data would make a mandate that can never
            // fire, signed and paid for. The module reverts on every such case;
            // the answer itself is not the point.
            // forge-lint: disable-next-line(unused-return)
            conditionModule.isMet(p.condition);
        }
        if (!IShieldAdapter(p.adapter).supportsAction(p.action)) {
            revert ActionNotSupported(p.adapter, p.action);
        }
        IShieldAdapter(p.adapter).validateConfig(p.action, p.asset, p.actionConfig);
    }

    function _setFeeBps(uint16 bps) internal {
        if (bps > MAX_FEE_BPS) revert InvalidParams("feeBps");
        feeBps = bps;
        emit FeeBpsSet(bps);
    }

    /// @dev The fields registration and amendment both write.
    function _writeMutable(Mandate storage m, MandateParams calldata p) internal {
        m.maxTransactionValue = p.maxTransactionValue;
        m.maxCumulativeValue = p.maxCumulativeValue;
        m.validFrom = p.validFrom;
        m.validUntil = p.validUntil;
        m.condition = p.condition;
        m.actionConfig = p.actionConfig;
    }
}
