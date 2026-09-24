// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IShieldRegistryV1} from "./interfaces/IShieldRegistryV1.sol";
import {IDescriptors} from "./interfaces/IDescriptors.sol";

/// @title ShieldRegistryV1
/// @notice What the Shield core, the evaluator and every executor consult
///         before they act: the executor and evaluator listings, the read
///         catalog (descriptors), and the emergency controls (frozen agents,
///         halts, suspensions, revocations). Split from the core so the core
///         keeps its byte budget for the firing sequence; immutable like it.
///
/// Roles. The admin (`Ownable2Step`) lists executors, evaluators and
/// descriptors for new registrations, appoints enforcers, and executes a
/// queued restoration after the delay. An enforcer freezes agents, halts
/// listed contracts, suspends and revokes venues and descriptors, and queues
/// restorations. The admin cannot be an enforcer.
/// Claim rules (FLIP-280 F1/F2, 23 Sep): the admin lists the exact claim calls
/// a claim mandate may sign; an enforcer can revoke one for every mandate.
contract ShieldRegistryV1 is IShieldRegistryV1, IDescriptors, Ownable2Step {
    /// @dev Aave v3's getUserAccountData(address): its sixth word is the health
    ///      factor, type(uint256).max when the account has no debt.
    bytes4 internal constant HEALTH_FACTOR_SELECTOR = 0xbf92857c; // getUserAccountData(address)

    string public constant VERSION = "1.0.0";
    uint64 public constant RESTORE_DELAY = 24 hours;

    /// @dev A halt or a suspension: active with an epoch; a queued
    ///      restoration for one epoch, executable after the delay. A new halt
    ///      or suspension bumps the epoch and cancels the queue.
    struct Gate {
        bool active;
        uint64 epoch;
        uint64 queuedAt;
        uint64 queuedEpoch;
    }

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

    /// @dev The round read (descriptor and feed) a mandatory price of `token` must pass.
    struct PriceRound {
        bytes32 descriptor;
        address feed;
    }

    mapping(address token => PriceRound) private _priceRounds;
    mapping(bytes32 id => ClaimRule) private _claimRules;
    mapping(bytes32 id => bool) private _claimRuleListed;
    mapping(bytes32 id => bool) private _claimRuleRevoked;

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc IShieldRegistryV1
    function owner() public view override(Ownable, IShieldRegistryV1) returns (address) {
        return super.owner();
    }

    // ==================================================================== views

    /// @inheritdoc IShieldRegistryV1
    function priceRound(address token) external view returns (bytes32 descriptor, address feed) {
        PriceRound storage r = _priceRounds[token];
        return (r.descriptor, r.feed);
    }

    /// @inheritdoc IShieldRegistryV1
    function stopped(address listed) external view returns (bool) {
        return _halts[listed].active || _suspensions[listed].active || _revokedTargets[listed];
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

    function isHalted(address listed) external view returns (bool) {
        return _halts[listed].active;
    }

    function isSuspended(address target) external view returns (bool) {
        return _suspensions[target].active;
    }

    function isRevoked(address target) external view returns (bool) {
        return _revokedTargets[target];
    }

    function isVenueBlocked(address target)
        external
        view
        override(IDescriptors, IShieldRegistryV1)
        returns (bool)
    {
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

    /// @inheritdoc IShieldRegistryV1
    function claimRuleOf(bytes32 id)
        external
        view
        returns (ClaimRule memory rule, bool listed, bool revoked)
    {
        return (_claimRules[id], _claimRuleListed[id], _claimRuleRevoked[id]);
    }

    /// @notice Permanently refuse a claim rule: no live mandate may make that claim again.
    function revokeClaimRule(bytes32 id) external onlyEnforcer {
        _claimRuleRevoked[id] = true;
        _claimRuleListed[id] = false;
        emit ClaimRuleRevoked(id, msg.sender);
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
        if (
            d.freshness == Freshness.ChainlinkRound
                && (d.copyBytes < 160 || d.maxAge == 0 || !d.mustBePositive)
        ) {
            revert InvalidParams("freshness");
        }
        if (d.gasStipend == 0) revert InvalidParams("gasStipend");
        // "Infinite" is Aave's health factor only (Austin, round 9): the sixth
        // word of getUserAccountData, unsigned. No other read, and so no amount,
        // can be listed with it.
        if (d.unboundedTop && (d.isSigned || d.selector != HEALTH_FACTOR_SELECTOR || d.word != 5)) {
            revert InvalidParams("unboundedTop");
        }
        if (_descriptors[id].gasStipend == 0) _descriptors[id] = d;
        _descriptorListed[id] = true;
        emit DescriptorListed(id, true);
    }

    /// @notice Bind the fresh round read a mandatory price of `token` must pass; a zero descriptor
    ///         clears it (positivity only, for a reserve with no round-capable source).
    function setPriceRound(address token, bytes32 descriptor, address feed) external onlyOwner {
        if (descriptor != bytes32(0)) {
            Descriptor storage d = _descriptors[descriptor];
            if (!_descriptorListed[descriptor] || _descriptorRevoked[descriptor]) {
                revert InvalidParams("round");
            }
            if (d.freshness != Freshness.ChainlinkRound) revert InvalidParams("round");
            if (d.kind == DescriptorKind.PerAddress ? d.target != feed : feed.code.length == 0) {
                revert InvalidParams("feed");
            }
        }
        _priceRounds[token] = PriceRound({descriptor: descriptor, feed: feed});
        emit PriceRoundSet(token, descriptor, feed);
    }

    /// @notice Store a claim rule under the hash of its contents and list it for NEW claim
    ///         mandates. The owner words must be zero in `args`: the executor writes the
    ///         owner's address there at firing, so no listed claim can pay anyone else
    ///         through those arguments.
    function listClaimRule(ClaimRule calldata r) external onlyOwner returns (bytes32 id) {
        id = keccak256(abi.encode(r));
        if (_claimRuleRevoked[id]) revert InvalidParams("revoked");
        if (r.target.code.length == 0) revert InvalidParams("target");
        if (r.selector == bytes4(0)) revert InvalidParams("selector");
        if (r.argCount == 0 || r.argCount > 16 || r.args.length != uint256(r.argCount) * 32) {
            revert InvalidParams("args");
        }
        uint256 owners = r.ownerArgs;
        if (owners == 0 || owners >> r.argCount != 0) revert InvalidParams("ownerArgs");
        for (uint256 i = 0; i < r.argCount; i++) {
            if ((owners >> i) & 1 != 0 && bytes32(r.args[i * 32:i * 32 + 32]) != bytes32(0)) {
                revert InvalidParams("ownerWord");
            }
        }
        if (_claimRules[id].target == address(0)) _claimRules[id] = r;
        _claimRuleListed[id] = true;
        emit ClaimRuleListed(id, true);
    }

    /// @notice Delist a claim rule for NEW claim mandates; live mandates keep using it.
    function delistClaimRule(bytes32 id) external onlyOwner {
        _claimRuleListed[id] = false;
        emit ClaimRuleListed(id, false);
    }

    /// @notice Delist a descriptor for NEW registrations; live mandates keep reading through it.
    function delistDescriptor(bytes32 id) external onlyOwner {
        _descriptorListed[id] = false;
        emit DescriptorListed(id, false);
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
}
