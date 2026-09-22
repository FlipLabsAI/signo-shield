// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDescriptors} from "../interfaces/IDescriptors.sol";
import {IEvaluatorV1} from "../interfaces/IEvaluatorV1.sol";

/// @title ExprLib
/// @notice The expression tree: encoding, shape checks, bounded reads and
///         once-per-node evaluation.
///
/// A tree is `abi.encode(Read[] reads, Node[] nodes)`. A node refers only to
/// nodes with a smaller index, so the graph is acyclic; nodes may be shared,
/// so it is evaluated once per node in index order into a value table, never
/// by recursion. Reads are made once per read index per phase.
///
/// A read supplies a descriptor id, a target, its ABI arguments and a subject
/// kind; everything that could authenticate or misdescribe the read (the
/// selector, the position of the account argument, the value word, the
/// signedness, the freshness rule, the gas and copy bounds) comes from the
/// descriptor, and the calldata is assembled here as `selector || args`.
library ExprLib {
    uint256 internal constant MAX_READS = 16;
    uint256 internal constant MAX_NODES = 64;
    uint256 internal constant MAX_TREE_BYTES = 12288; // 16 reads and 64 nodes ABI-encode to about 10 KB

    enum Kind {
        CONST,
        READ,
        SIGNED,
        BEFORE,
        AMOUNT,
        ADD,
        SUB,
        MUL,
        DIV,
        MIN,
        MAX,
        LT,
        LE,
        GT,
        GE,
        EQ,
        AND,
        OR,
        NOT
    }

    enum Subject {
        None,
        Principal,
        Explicit
    }

    struct Read {
        bytes32 descriptor;
        address target;
        bytes args; // ABI-encoded static arguments only
        Subject subject;
        uint8 decimals; // pinned at registration for Shape descriptors
    }

    struct Node {
        uint8 kind;
        uint256 a;
        uint256 b;
    }

    struct Tree {
        Read[] reads;
        Node[] nodes;
    }

    /// @dev Per-evaluation inputs the core supplies.
    struct Env {
        address principal;
        int256[] signedValues;
        int256[] beforeValues;
        uint256 amount;
        bool haveBefore;
    }

    // ------------------------------------------------------------- decoding

    function decode(bytes calldata tree) internal pure returns (Tree memory t) {
        if (tree.length > MAX_TREE_BYTES) revert IEvaluatorV1.TreeInvalid("size");
        (t.reads, t.nodes) = abi.decode(tree, (Read[], Node[]));
    }

    // ---------------------------------------------------------------- shape

    /// @dev Everything about the tree that does not need a chain read:
    ///      counts, references, phases, operand kinds, descriptor binding.
    ///      Returns nothing; reverts with the first fault.
    function checkShape(
        Tree memory t,
        IEvaluatorV1.Phase phase,
        IDescriptors catalog,
        address principal,
        bool requireListed
    ) internal view {
        uint256 nr = t.reads.length;
        uint256 nn = t.nodes.length;
        if (nr > MAX_READS) revert IEvaluatorV1.TreeInvalid("reads");
        if (nn == 0 || nn > MAX_NODES) revert IEvaluatorV1.TreeInvalid("nodes");

        for (uint256 i = 0; i < nr; i++) {
            // forge-lint: disable-next-line(calls-loop)
            _checkRead(t.reads[i], i, catalog, principal, requireListed);
        }

        // isBool[i]: node i yields 0/1 and may feed AND/OR/NOT; a comparison
        // or a Boolean node. Numeric nodes may not feed Boolean operators and
        // Boolean nodes may not feed arithmetic or comparisons.
        bool[] memory isBool = new bool[](nn);
        for (uint256 i = 0; i < nn; i++) {
            Node memory n = t.nodes[i];
            if (n.kind > uint8(Kind.NOT)) revert IEvaluatorV1.TreeInvalid("kind");
            Kind k = Kind(n.kind);
            if (k == Kind.CONST) {
                continue;
            } else if (k == Kind.READ || k == Kind.SIGNED) {
                if (n.a >= nr) revert IEvaluatorV1.TreeInvalid("readIndex");
            } else if (k == Kind.BEFORE) {
                if (phase != IEvaluatorV1.Phase.Outcome) revert IEvaluatorV1.TreeInvalid("beforeInTrigger");
                if (n.a >= nr) revert IEvaluatorV1.TreeInvalid("readIndex");
            } else if (k == Kind.AMOUNT) {
                continue;
            } else if (k == Kind.NOT) {
                if (n.a >= i || !isBool[n.a]) revert IEvaluatorV1.TreeInvalid("notOperand");
                isBool[i] = true;
            } else if (k == Kind.AND || k == Kind.OR) {
                if (n.a >= i || n.b >= i || !isBool[n.a] || !isBool[n.b]) {
                    revert IEvaluatorV1.TreeInvalid("boolOperand");
                }
                isBool[i] = true;
            } else {
                // arithmetic and comparisons take numeric operands
                if (n.a >= i || n.b >= i || isBool[n.a] || isBool[n.b]) {
                    revert IEvaluatorV1.TreeInvalid("numOperand");
                }
                if (k >= Kind.LT) isBool[i] = true;
            }
        }
        if (!isBool[nn - 1]) revert IEvaluatorV1.TreeInvalid("root");
    }

    function _checkRead(Read memory r, uint256 i, IDescriptors catalog, address principal, bool requireListed)
        private
        view
    {
        // forge-lint: disable-next-line(calls-loop)
        (IDescriptors.Descriptor memory d, bool listed, bool revoked) = catalog.descriptorOf(r.descriptor);
        // Revoked blocks everything; delisted blocks only a NEW tree (an unchanged
        // tree on amendment keeps reading through a delisted descriptor).
        if (revoked) revert IEvaluatorV1.TreeInvalid("descriptorRevoked");
        if (requireListed && !listed) revert IEvaluatorV1.TreeInvalid("descriptor");
        if (r.args.length != uint256(d.argCount) * 32) revert IEvaluatorV1.TreeInvalid("args");
        // A suspended or revoked read target must not be read through.
        // forge-lint: disable-next-line(calls-loop)
        if (catalog.isVenueBlocked(r.target)) revert IEvaluatorV1.TreeInvalid("targetBlocked");
        if (d.kind == IDescriptors.DescriptorKind.PerAddress) {
            if (r.target != d.target) revert IEvaluatorV1.TreeInvalid("target");
        } else {
            if (r.target.code.length == 0) revert IEvaluatorV1.TreeInvalid("target");
            // The pinned decimals are the instance's own (or, for a vault's
            // convertToAssets, its underlying's): a mis-scaled tree is refused at signing.
            if (r.decimals != _instanceDecimals(r.target, d.selector)) {
                revert IEvaluatorV1.TreeInvalid("decimals");
            }
        }
        if (d.subjectRule == IDescriptors.SubjectRule.PrincipalRequired) {
            if (r.subject == Subject.None) revert IEvaluatorV1.TreeInvalid("subject");
            // forge-lint: disable-next-line(unsafe-typecast)
            if (d.subjectArg < 0 || uint8(d.subjectArg) >= d.argCount) {
                revert IEvaluatorV1.TreeInvalid("subjectArg");
            }
            if (r.subject == Subject.Principal) {
                bytes memory args = r.args;
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 off = uint256(uint8(d.subjectArg)) * 32;
                uint256 wordv;
                assembly ("memory-safe") {
                    wordv := mload(add(add(args, 32), off))
                }
                if (wordv != uint256(uint160(principal))) revert IEvaluatorV1.SubjectMismatch(i);
            }
        } else if (r.subject != Subject.None) {
            revert IEvaluatorV1.TreeInvalid("subject");
        }
    }

    /// @dev `decimals()` of the value a shape read returns: the target's own, except
    ///      convertToAssets, whose value is in the vault's underlying.
    bytes4 private constant SEL_ASSET = 0x38d52e0f; // asset()
    bytes4 private constant SEL_DECIMALS = 0x313ce567; // decimals()
    bytes4 private constant SEL_CONVERT_TO_ASSETS = 0x07a2d13a; // convertToAssets(uint256)

    function _instanceDecimals(address target, bytes4 selector) private view returns (uint8) {
        address unit = target;
        if (selector == SEL_CONVERT_TO_ASSETS) {
            // forge-lint: disable-next-line(calls-loop)
            (bool okA, bytes memory retA) = target.staticcall(abi.encodeWithSelector(SEL_ASSET));
            if (!okA || retA.length < 32) revert IEvaluatorV1.TreeInvalid("decimals");
            unit = abi.decode(retA, (address));
        }
        // forge-lint: disable-next-line(calls-loop)
        (bool ok, bytes memory ret) = unit.staticcall(abi.encodeWithSelector(SEL_DECIMALS));
        // An instance with no decimals() (a gauge, a staking balance) is read
        // in raw units: the tree must pin 0.
        if (!ok || ret.length < 32) return 0;
        uint256 dec = abi.decode(ret, (uint256));
        if (dec > type(uint8).max) revert IEvaluatorV1.TreeInvalid("decimals");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(dec);
    }

    /// @dev Every descriptor the tree names, live or cached (SIGNED, BEFORE),
    ///      is still unrevoked and its target unblocked. Run at every judgement:
    ///      a value captured at signing must not outlive its descriptor.
    function checkLive(Tree memory t, IDescriptors catalog) internal view {
        for (uint256 i = 0; i < t.reads.length; i++) {
            // forge-lint: disable-next-line(calls-loop,unused-return)
            (,, bool revoked) = catalog.descriptorOf(t.reads[i].descriptor);
            if (revoked) revert IEvaluatorV1.TreeInvalid("descriptorRevoked");
            // forge-lint: disable-next-line(calls-loop)
            if (catalog.isVenueBlocked(t.reads[i].target)) revert IEvaluatorV1.TreeInvalid("targetBlocked");
        }
    }

    // ----------------------------------------------------------------- reads

    /// @dev One bounded read through its descriptor. Reverts on any failure.
    function readValue(Read memory r, uint256 i, IDescriptors catalog) internal view returns (int256 value) {
        // A revoked descriptor blocks every firing that reads through it;
        // a delisted one only stops new registrations (checked in shape).
        // forge-lint: disable-next-line(calls-loop,unused-return)
        (IDescriptors.Descriptor memory d,, bool revoked) = catalog.descriptorOf(r.descriptor);
        if (revoked) revert IEvaluatorV1.TreeInvalid("descriptorRevoked");
        // forge-lint: disable-next-line(calls-loop)
        if (catalog.isVenueBlocked(r.target)) revert IEvaluatorV1.TreeInvalid("targetBlocked");
        uint256 need = _needBytes(d);
        bytes memory out = _staticRead(r.target, d.gasStipend, abi.encodePacked(d.selector, r.args), need, i);
        if (d.freshness == IDescriptors.Freshness.ChainlinkRound) _checkRound(out, d.maxAge, i);
        uint256 raw = _word(out, d.word);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (!d.isSigned && raw > uint256(type(int256).max)) revert IEvaluatorV1.ValueOutOfRange(i);
        // Signed reads are int256 bit patterns; unsigned ones were range-checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        value = int256(raw);
        if (d.mustBePositive && value <= 0) revert IEvaluatorV1.ReadNotPositive(i);
    }

    function _needBytes(IDescriptors.Descriptor memory d) private pure returns (uint256 need) {
        need = uint256(d.copyBytes);
        uint256 wordEnd = (uint256(d.word) + 1) * 32;
        if (need < wordEnd) need = wordEnd;
        if (d.freshness == IDescriptors.Freshness.ChainlinkRound && need < 160) need = 160;
    }

    /// @dev The staticcall with the descriptor's stipend; copies exactly `need` bytes, never more.
    function _staticRead(address target, uint256 stipend, bytes memory data, uint256 need, uint256 i)
        private
        view
        returns (bytes memory out)
    {
        out = new bytes(need);
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(stipend, target, add(data, 32), mload(data), 0, 0)
            size := returndatasize()
            if and(ok, iszero(lt(size, need))) { returndatacopy(add(out, 32), 0, need) }
        }
        if (!ok) revert IEvaluatorV1.ReadFailed(i, "");
        if (size < need) revert IEvaluatorV1.ReadTooShort(i, size, need);
    }

    function _word(bytes memory out, uint8 word) private pure returns (uint256 raw) {
        uint256 off = uint256(word) * 32;
        assembly ("memory-safe") {
            raw := mload(add(add(out, 32), off))
        }
    }

    /// @dev Chainlink's round rule over the five copied words.
    function _checkRound(bytes memory out, uint32 maxAge, uint256 i) private view {
        uint256 roundId = _word(out, 0);
        uint256 updatedAt = _word(out, 3);
        uint256 answeredInRound = _word(out, 4);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert IEvaluatorV1.ReadStale(i);
        }
        if (answeredInRound < roundId) revert IEvaluatorV1.ReadStale(i);
    }

    // ------------------------------------------------------------ evaluation

    /// @dev Which reads a phase must make live: every READ node's read. The
    ///      caller decides what SIGNED and BEFORE resolve to.
    function liveReads(Tree memory t, IDescriptors catalog) internal view returns (int256[] memory vals) {
        uint256 nr = t.reads.length;
        vals = new int256[](nr);
        bool[] memory needed = new bool[](nr);
        for (uint256 i = 0; i < t.nodes.length; i++) {
            if (t.nodes[i].kind == uint8(Kind.READ)) needed[t.nodes[i].a] = true;
        }
        // One external read per needed index is the design; each is bounded by its descriptor.
        for (uint256 i = 0; i < nr; i++) {
            // forge-lint: disable-next-line(calls-loop)
            if (needed[i]) vals[i] = readValue(t.reads[i], i, catalog);
        }
    }

    /// @dev The reads the SIGNED (or BEFORE) nodes name, taken live now.
    function readsFor(Tree memory t, Kind which, IDescriptors catalog)
        internal
        view
        returns (int256[] memory vals)
    {
        uint256 nr = t.reads.length;
        vals = new int256[](nr);
        bool[] memory needed = new bool[](nr);
        for (uint256 i = 0; i < t.nodes.length; i++) {
            if (t.nodes[i].kind == uint8(which)) needed[t.nodes[i].a] = true;
        }
        for (uint256 i = 0; i < nr; i++) {
            // forge-lint: disable-next-line(calls-loop)
            if (needed[i]) vals[i] = readValue(t.reads[i], i, catalog);
        }
    }

    /// @dev Evaluate the root. `live` are the READ values; SIGNED and BEFORE
    ///      come from `env`. Arithmetic is checked int256; DIV by zero and any
    ///      overflow revert. Boolean nodes yield 0 or 1.
    function evaluate(Tree memory t, int256[] memory live, Env memory env) internal pure returns (bool) {
        uint256 nn = t.nodes.length;
        int256[] memory v = new int256[](nn);
        for (uint256 i = 0; i < nn; i++) {
            Node memory n = t.nodes[i];
            Kind k = Kind(n.kind);
            if (k == Kind.CONST) {
                // A constant is the int256 bit pattern by definition; negatives are encoded this way.
                // forge-lint: disable-next-line(unsafe-typecast)
                v[i] = int256(n.a);
            } else if (k == Kind.READ) {
                v[i] = live[n.a];
            } else if (k == Kind.SIGNED) {
                if (n.a >= env.signedValues.length) revert IEvaluatorV1.TreeInvalid("signedIndex");
                v[i] = env.signedValues[n.a];
            } else if (k == Kind.BEFORE) {
                if (!env.haveBefore || n.a >= env.beforeValues.length) {
                    revert IEvaluatorV1.TreeInvalid("beforeIndex");
                }
                v[i] = env.beforeValues[n.a];
            } else if (k == Kind.AMOUNT) {
                // forge-lint: disable-next-line(unsafe-typecast)
                if (env.amount > uint256(type(int256).max)) revert IEvaluatorV1.ValueOutOfRange(i);
                // forge-lint: disable-next-line(unsafe-typecast)
                v[i] = int256(env.amount);
            } else if (k == Kind.ADD) {
                v[i] = v[n.a] + v[n.b];
            } else if (k == Kind.SUB) {
                v[i] = v[n.a] - v[n.b];
            } else if (k == Kind.MUL) {
                v[i] = v[n.a] * v[n.b];
            } else if (k == Kind.DIV) {
                v[i] = v[n.a] / v[n.b]; // reverts on zero
            } else if (k == Kind.MIN) {
                v[i] = v[n.a] < v[n.b] ? v[n.a] : v[n.b];
            } else if (k == Kind.MAX) {
                v[i] = v[n.a] > v[n.b] ? v[n.a] : v[n.b];
            } else if (k == Kind.LT) {
                v[i] = v[n.a] < v[n.b] ? int256(1) : int256(0);
            } else if (k == Kind.LE) {
                v[i] = v[n.a] <= v[n.b] ? int256(1) : int256(0);
            } else if (k == Kind.GT) {
                v[i] = v[n.a] > v[n.b] ? int256(1) : int256(0);
            } else if (k == Kind.GE) {
                v[i] = v[n.a] >= v[n.b] ? int256(1) : int256(0);
            } else if (k == Kind.EQ) {
                v[i] = v[n.a] == v[n.b] ? int256(1) : int256(0);
            } else if (k == Kind.AND) {
                v[i] = (v[n.a] != 0 && v[n.b] != 0) ? int256(1) : int256(0);
            } else if (k == Kind.OR) {
                v[i] = (v[n.a] != 0 || v[n.b] != 0) ? int256(1) : int256(0);
            } else {
                v[i] = v[n.a] == 0 ? int256(1) : int256(0);
            }
        }
        return v[nn - 1] != 0;
    }
}
