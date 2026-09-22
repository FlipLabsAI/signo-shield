// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDescriptors} from "./interfaces/IDescriptors.sol";
import {IEvaluatorV1} from "./interfaces/IEvaluatorV1.sol";
import {ExprLib} from "./libraries/ExprLib.sol";

/// @title ExpressionEvaluator
/// @notice Stateless. Bound to one core, whose descriptor catalog every read
///         is checked against. Every function is a view; the core supplies the
///         principal and the stored baselines.
contract ExpressionEvaluator is IEvaluatorV1 {
    using ExprLib for ExprLib.Tree;

    string public constant VERSION = "1.0.0";
    IDescriptors public immutable catalog;

    error CatalogInvalid();

    constructor(IDescriptors catalog_) {
        if (address(catalog_).code.length == 0) revert CatalogInvalid();
        catalog = catalog_;
    }

    /// @inheritdoc IEvaluatorV1
    function validate(bytes calldata tree, Phase phase, address principal, bool requireListed) external view {
        ExprLib.Tree memory t = ExprLib.decode(tree);
        ExprLib.checkShape(t, phase, catalog, principal, requireListed);
        // One liveness read per Read, whatever node names it: a read that
        // cannot be taken is refused at signing.
        for (uint256 i = 0; i < t.reads.length; i++) {
            // forge-lint: disable-next-line(calls-loop,unused-return)
            ExprLib.readValue(t.reads[i], i, catalog);
        }
    }

    /// @inheritdoc IEvaluatorV1
    function capture(bytes calldata tree, address principal) external view returns (int256[] memory) {
        ExprLib.Tree memory t = ExprLib.decode(tree);
        // The same structural and binding contract as judgement: a caller
        // cannot capture another account's values under this principal.
        ExprLib.checkShape(t, Phase.Outcome, catalog, principal, false);
        return ExprLib.readsFor(t, ExprLib.Kind.SIGNED, catalog);
    }

    /// @inheritdoc IEvaluatorV1
    function snapshot(bytes calldata outcome, address principal) external view returns (int256[] memory) {
        ExprLib.Tree memory t = ExprLib.decode(outcome);
        ExprLib.checkShape(t, Phase.Outcome, catalog, principal, false);
        return ExprLib.readsFor(t, ExprLib.Kind.BEFORE, catalog);
    }

    /// @inheritdoc IEvaluatorV1
    function judgeTrigger(
        bytes calldata trigger,
        address principal,
        int256[] calldata signedValues,
        uint256 amount
    ) external view returns (bool) {
        ExprLib.Tree memory t = ExprLib.decode(trigger);
        // The runtime contract, not only the registration one: shape and
        // limits again, the principal rebound, every named descriptor live.
        ExprLib.checkShape(t, Phase.Trigger, catalog, principal, false);
        ExprLib.checkLive(t, catalog);
        int256[] memory live = ExprLib.liveReads(t, catalog);
        ExprLib.Env memory env = ExprLib.Env({
            principal: principal,
            signedValues: signedValues,
            beforeValues: new int256[](0),
            amount: amount,
            haveBefore: false
        });
        return ExprLib.evaluate(t, live, env);
    }

    /// @inheritdoc IEvaluatorV1
    function judgeOutcome(
        bytes calldata outcome,
        address principal,
        int256[] calldata signedValues,
        int256[] calldata beforeValues,
        uint256 amount
    ) external view returns (bool) {
        ExprLib.Tree memory t = ExprLib.decode(outcome);
        ExprLib.checkShape(t, Phase.Outcome, catalog, principal, false);
        ExprLib.checkLive(t, catalog);
        int256[] memory live = ExprLib.liveReads(t, catalog);
        ExprLib.Env memory env = ExprLib.Env({
            principal: principal,
            signedValues: signedValues,
            beforeValues: beforeValues,
            amount: amount,
            haveBefore: true
        });
        return ExprLib.evaluate(t, live, env);
    }
}
