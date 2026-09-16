# Adapters

One directory per protocol, one contract per protocol, one entry point per
action inside it. The mandate pins the pair (adapter, action), so a mandate for
one action can never reach another, and a bug in one action does not expose
every mandate on the protocol.

| Adapter | Actions | Notes |
| --- | --- | --- |
| `aave-v3/AaveV3Adapter.sol` | `supply`, `repay`, `repayWithCollateral` | Aave V3. Fork-tested against the X Layer market; the swap leg replays real OKX DEX aggregator calldata (router `0x7c5BEE2A…aeAf`, approval contract `0x8b773D83…F000` on X Layer). |

Tier 2, a pinned adapter, is the **exception** in this design, not the rule.
Tier 1 bounded execution covers ordinary actions with zero new Solidity per
protocol: the Shield pulls at most the mandate's amount, the call runs from a
disposable clone that holds no allowance, and a post-condition on the owner's
balances decides whether the firing stands.

An adapter is written only where a balance check cannot see the harm, which is
obligation-shaped grants:

- credit delegation (Aave `approveDelegation`)
- operator bits (Compound `allow`, Morpho `setAuthorization`)

and for the demo mandate, where a pinned path makes a stronger on-stage claim
than a general bound.

Anything added here must be recorded in `docs/REUSE.md` with its provenance and
licence before it lands.
