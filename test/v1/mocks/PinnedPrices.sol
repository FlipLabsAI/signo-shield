// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";

/// @dev What an app signs into an action config: the registry's price rule for
///      each priced token at signing time (FLIP-280 C1). Admission checks it.
library PinnedPrices {
    function pin(IShieldRegistryV1 registry, address[] memory tokens)
        internal
        view
        returns (ExprLib.PriceRound[] memory rounds)
    {
        rounds = new ExprLib.PriceRound[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            (bytes32 id, address feed) = registry.priceRound(tokens[i]);
            rounds[i] = ExprLib.PriceRound(tokens[i], id, feed);
        }
    }

    function pin(IShieldRegistryV1 registry, address a, address b)
        internal
        view
        returns (ExprLib.PriceRound[] memory)
    {
        return pin(registry, ExprLib.pair(a, b));
    }
}
