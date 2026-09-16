// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISignoShield} from "./interfaces/ISignoShield.sol";

/// @title SignoShield
/// @notice Scaffold. Every entry point reverts `NotImplemented`.
///
/// It is named Shield and not Guardian on purpose: it is something the agent
/// USES, not another agent. The owner signs a mandate; the agent fires a
/// mandate through the Shield.
///
/// This file exists so a clean clone compiles, deploys and tests before any
/// enforcement logic is written (FLIP-190). It deliberately stores nothing and
/// enforces nothing — a scaffold that half-enforced a bound would be worse
/// than one that plainly refuses, because it would read as protection.
///
/// The implementation lands in the tickets FLIP-190 blocks. `ISignoShield`
/// carries the agreed design those tickets build against.
contract SignoShield is ISignoShield {
    /// @notice Human-readable build marker, surfaced in the deployments manifest.
    string public constant VERSION = "0.0.0-scaffold";

    /// @inheritdoc ISignoShield
    function registerMandate(bytes calldata) external pure returns (bytes32) {
        revert NotImplemented();
    }

    /// @inheritdoc ISignoShield
    function amendMandate(bytes32, bytes calldata) external pure {
        revert NotImplemented();
    }

    /// @inheritdoc ISignoShield
    function revokeMandate(bytes32) external pure {
        revert NotImplemented();
    }

    /// @inheritdoc ISignoShield
    function fire(bytes32, address, uint256, bytes calldata) external pure {
        revert NotImplemented();
    }
}
