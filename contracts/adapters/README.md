# Adapters

Empty on purpose.

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
