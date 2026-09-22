// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";

/// @dev A catalog for unit tests: descriptors are stored by their content id.
contract MockCatalog is IDescriptors {
    mapping(bytes32 => Descriptor) internal _d;
    mapping(bytes32 => bool) internal _listed;
    mapping(bytes32 => bool) internal _revoked;

    function list(Descriptor memory d) external returns (bytes32 id) {
        id = keccak256(abi.encode(d));
        _d[id] = d;
        _listed[id] = true;
    }

    function setListed(bytes32 id, bool v) external {
        _listed[id] = v;
    }

    function setRevoked(bytes32 id, bool v) external {
        _revoked[id] = v;
    }

    function descriptorOf(bytes32 id) external view returns (Descriptor memory d, bool listed, bool revoked) {
        return (_d[id], _listed[id], _revoked[id]);
    }

    mapping(address => bool) public blocked;

    function setBlocked(address t, bool v) external {
        blocked[t] = v;
    }

    function isVenueBlocked(address target) external view returns (bool) {
        return blocked[target];
    }

    function descriptorId(Descriptor calldata d) external pure returns (bytes32) {
        return keccak256(abi.encode(d));
    }
}

/// @dev A token-like read target with settable balances.
contract MockBalances {
    mapping(address => uint256) public balanceOf;
    uint8 public decimals = 6;

    function set(address a, uint256 v) external {
        balanceOf[a] = v;
    }
}

/// @dev A Chainlink-shaped feed with settable round data.
contract MockFeed {
    uint80 public roundId;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public answeredInRound;

    function set(uint80 r, int256 a, uint256 u, uint80 air) external {
        roundId = r;
        answer = a;
        updatedAt = u;
        answeredInRound = air;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

/// @dev Returns a huge unsigned word, or burns gas, on demand.
contract MockNasty {
    bool public burn;
    bool public short;

    function setBurn(bool v) external {
        burn = v;
    }

    function setShort(bool v) external {
        short = v;
    }

    function value() external view returns (uint256) {
        if (burn) {
            uint256 x;
            for (uint256 i = 0; i < 100000; i++) {
                x += uint256(keccak256(abi.encode(i, x)));
            }
            return x;
        }
        if (short) {
            assembly {
                return(0, 16)
            }
        }
        return type(uint256).max;
    }
}
