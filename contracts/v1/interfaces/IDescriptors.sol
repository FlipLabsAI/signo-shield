// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IDescriptors
/// @notice The read catalog Shield v1 keeps: what a read is allowed to be.
///
/// A descriptor fixes everything about a read that could authenticate or
/// misdescribe it: the contract (or the interface shape), the selector, which
/// argument names the account the read is about, which return word is the
/// value, its signedness, its decimals, the freshness rule, and the gas and
/// copy bounds. A read in a mandate names a descriptor and supplies only the
/// arguments. Descriptor ids are the hash of the contents, so nothing can be
/// replaced under an id; listing is a separate flag that gates new
/// registrations only.
interface IDescriptors {
    enum DescriptorKind {
        PerAddress, // one contract: price feeds, protocol views
        Shape // a standard interface any contract may answer: ERC-20 balanceOf, ERC-4626 conversions
    }

    enum SubjectRule {
        None, // the read is not about an account
        PrincipalRequired // the read is about an account; a read must name the principal, or another account on purpose
    }

    enum Freshness {
        None,
        ChainlinkRound // roundId, answer, startedAt, updatedAt, answeredInRound; answer > 0, updatedAt within maxAge, answeredInRound >= roundId
    }

    struct Descriptor {
        DescriptorKind kind;
        address target; // PerAddress only
        bytes4 selector;
        uint8 argCount; // static ABI words the read supplies
        int8 subjectArg; // index of the account argument, or -1
        SubjectRule subjectRule;
        uint8 word; // which return word is the value
        bool isSigned;
        bool mustBePositive;
        uint8 decimals; // PerAddress only; Shape reads pin the instance's decimals at registration
        Freshness freshness;
        uint32 maxAge;
        uint32 gasStipend;
        uint16 copyBytes;
        // Aave's health factor only (getUserAccountData, word 5, unsigned; the
        // registry refuses the flag anywhere else): Aave reports "no debt" as
        // exactly type(uint256).max, which reads as the top of the int256 range,
        // i.e. infinite. Any other value above the range is refused, here and on
        // every other descriptor, and the executors refuse a flagged read wherever
        // it would be an amount: two amounts must never read as equal (rounds 9-10).
        bool unboundedTop;
    }

    event DescriptorListed(bytes32 indexed id, bool listed);
    event DescriptorRevoked(bytes32 indexed id, address indexed by);

    /// @notice The descriptor behind `id`, whether it is listed for new registrations, and whether it is revoked.
    function descriptorOf(bytes32 id) external view returns (Descriptor memory d, bool listed, bool revoked);

    /// @notice Whether a concrete read target is suspended or revoked: a read through it must not happen.
    function isVenueBlocked(address target) external view returns (bool);

    /// @notice The id a descriptor would have: the hash of its contents.
    function descriptorId(Descriptor calldata d) external pure returns (bytes32);
}
