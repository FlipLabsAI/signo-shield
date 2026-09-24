# How the design got here: 16 to 24 September 2026

This repository started on 16 September 2026 as an empty Foundry project.
Nine days later it holds two deployed generations of the Shield and 499
tests. This page tells how the design moved from the first version to the
second: what we built, what each review and each real firing taught us, and
what we changed because of it. Commit hashes let a reader check every step.

Times are UTC. "We" is the Flip Labs team. "The reviewer" is an independent
review pass that read the code against its specification and wrote Foundry
tests for every gap it found.

## The idea that did not change

An AI agent can act on a wallet only through a mandate the owner signed. The
contract does not try to understand the agent's calldata. It measures the
result on the owner's own balances and positions, and it reverts the whole
transaction when the result breaks the mandate. The contract enforces the
bound; the agent decides the action inside it.

Every version below keeps this. What changed is how much an owner can
express, and how exactly the contract can check it.

## 16 September: v0.1, one protocol and one trigger

**00:49 to 01:45, the core.** The first commits are the interfaces and a
scaffold whose tests assert that it refuses everything (`f815d85`,
`6b0c744`). Then the real thing (`c5e9c0c`, `d6bb3d6`, `d6c777c`):

- `SignoShield`: the mandate record, the per-firing and lifetime caps, a
  fixed check order with one reason code per failure, revocation, and an
  enforcer who can freeze an agent.
- `ConditionModule`: one generic trigger, a view read compared to a
  threshold.
- `AaveV3Adapter`: supply, repay and repay-with-collateral, each with an
  outcome check on the owner's position.

A fork suite on X Layer repaid real Aave debt for a borrower who was not
the caller (`4251ea8`).

**02:16 to 02:27, fees and the swap leg.** The fee became the Shield's rate,
stamped into each mandate at registration and kept for life (`e9972f8`).
Aggregators pull the input token through their own approval contract, not
through the router the transaction goes to. So a mandate pins both, and the
adapter approves only the spender, only for the amount, only for the call
(`21aec4b`).

**03:11, the first review.** The sale is measured across the call, so
tokens someone parks on the adapter cannot block a firing or loosen the
bound. The fee is charged on what was spent. Every adapter failure has a
typed reason. The admin cannot renounce (`ced2033`, `0963aa6`).

**03:16, deployed to X Layer** (`673a74a`).

**07:23, the independent review.** The Shield now charges the larger of the
adapter's report and the owner's measured balance drop, so a listed adapter
can under-report but never under-charge. The fee's worst case leaves the
owner before the adapter runs, so every outcome check sees the final state.
Registration dry-runs the trigger, so a trigger that can never be read
cannot be signed (`fe47fdb`). Redeployed at 11:35.

## 16 and 17 September: Tier 1, execution that knows no protocol

A pinned adapter per protocol does not scale. So we built an executor that
knows no protocol at all (`6481a9e`):

- Each firing gets a fresh, single-use clone at an address anyone can
  predict. The clone gets exactly the amount, makes the call to the target
  the mandate pinned, and sweeps everything back to the owner.
- The minimum output comes from a rule the owner signed: a fixed rate, an
  oracle price less a slippage, or an absolute floor. The agent never sets
  its own bar.

The review of it (`d9464c9`) fixed tokens parked at the predicted clone
address, moved the oracle read before the agent's call, and made a bound
that rounds to zero one unit, because a sale for nothing is never a success.

Two more choices were made while nothing was listed, because they would be
expensive later:

- **ERC-4626 deposits are bounded by the vault itself** (`44fa977`): the
  vault's own `convertToShares`, read before the call, and the call surface
  must be the vault.
- **The trigger evaluator is pluggable per mandate** (`fe489e8`), with
  "A and B" / "A or B" as the first evaluator. Its review (`de89e35`) made
  sure a pinned evaluator survives a delisting, gave each compound one
  encoding, and closed nesting through a plain read.

Redeployed on 17 September at 09:42 (`c07c9aa`). From 17 to 18 September the
Signo app fired these contracts on mainnet by itself: transfers, swaps and
Aave supplies. [`APP-SIDE.md`](APP-SIDE.md) lists every firing.

## 18 to 22 September: what running it taught us

Real use showed four limits that no patch to v0.1 could remove:

1. Registration only dry-ran the trigger through a view call, so nothing
   could be stored at signing. An outcome that compares "after" with
   "before" needs a baseline taken before any token moves.
2. The core did not take that snapshot before it pulled the owner's tokens.
3. There was no way to halt a listed version that turned out to be bad,
   without touching each mandate.
4. The fee came from the core's current rate. The owner did not sign a
   maximum.

And one limit of expression: one call per firing, one venue, one output
token, and triggers of one level. "Buy whichever coin crossed its line" was
not one mandate.

So we wrote v1 as a specification first. It went through four independent
passes before any v1 code existed.

## 22 September: v1 in six slices

The v1 code landed in one afternoon, in six reviewed slices:

1. **Expression trees** (`7b80d53`). A trigger or an outcome is an array of
   nodes that may refer only to earlier nodes, evaluated once per node in
   order, with no recursion. Reads come from a catalog of listed
   descriptors. The contract builds the calldata from the descriptor; a read
   cannot supply the bytes that identify it.
2. **The core** (`ebeb48c`). The owner signs a maximum fee. The core takes
   the executor's "before" values before it pulls anything. Halts,
   suspensions and revocations stop live mandates; restoring needs a queue.
3. **The executors** (`aa5cb19`). A multi-call sandbox, a generic executor
   for swaps, transfers, vault withdrawals and repays, each with its
   mandatory check, and exact venue pairs (the contract and its approval
   target).
4. **Aave on the v1 interface** (`4419575`, `aa394d6`).
5. **A real aggregator route from the v1 sandbox** on an X Layer fork
   (`8083532`).
6. **The deploy script** with its own fork test (`11db98d`).

Two design corrections the same evening:

- **No cooldown on chain** (`1b759e6`). Timing is a product choice, so it
  stays off chain. The chain keeps the bookkeeping.
- **The registry split** (`67a80bb`). The core was 163 bytes under the
  contract size limit. Listings, the read catalog and the emergency
  controls moved to `ShieldRegistryV1`, which gave the firing sequence
  6,828 bytes of room.

## 22 to 24 September: fifteen review rounds

The loop, every round: the reviewer reads the code against the specification
and writes a Foundry test for each gap. We import those tests under
`test/review/`, fix the code, and turn each gap test into a named refusal
(`test_fix...`). A finding is closed only by a test that fails on the old
code. The app's own end-to-end firings on an X Layer fork found several of
the issues below; those are marked "found by a real firing".

| Round | When | What changed, and why |
| --- | --- | --- |
| 1 to 3 | 22 Sep | Suspensions stop firings. Unknown actions fail closed. The core takes the mandatory "before" values ahead of any pull. Every read is checked on every firing. A vault withdrawal is priced at the exact quote before the call. A repay's debt read must be the asset's own debt token. Each priced token needs a fresh Chainlink round. One admin for the core and the registry. |
| 4 | 23 Sep | Each mandate carries its own signed price rules, so an admin change reaches only new mandates. A vault's redemption band is judged on a sample the owner signed. |
| 5 | 23 Sep | A vault deposit's precision is judged at the firing, where the amount is known. |
| 6 | 23 Sep | Claims: collect only, through listed claim rules, with the owner written into every owner argument. "Claim and reinvest" was removed rather than patched. A real fork claim of Pendle rewards. |
| 7 | 23 Sep | A reward nobody declared can still reach the owner after the firing. The vault floor became optional. A wallet with no Aave debt can sign a health factor trigger. |
| 8 | 23 Sep | A transfer signs no venue (found by a real firing). Only a value that really means "unbounded" may read as the top of the range. |
| 9 | 23 to 24 Sep | Price rounds may be up to 25 hours old: the feeds have a 24 hour heartbeat, and a calm market writes no round for hours (found by a real firing). "Infinite" is Aave's health factor only, and only its exact no-debt value. |
| 10 | 24 Sep | A read flagged "infinite" can never be used as an amount. |
| 11 | 24 Sep | The fee refund goes before the fee, so aToken rounding cannot revert a firing (found by a real firing). Repay from collateral steps to its target: near a health factor of 1, a one-shot rule could never fire, which is exactly when the owner needs it (found by a real firing). |
| 12 | 24 Sep | A swap may deliver any of up to five signed outputs, and the loss bound is on the total value. So "buy xETH or xBTC, whichever crossed" is one mandate. Tests on an X Layer fork with thin routes, split routes, stale rounds and dust, and a unit test with a fee-on-transfer token. |
| 13 | 24 Sep | A repay is judged against the health factor before the pull. Every output is valued before the route runs, so a route cannot move the prices it is judged by. Several outputs must be reviewed tokens, so one balance cannot be counted twice. |
| 14 | 24 Sep | "Unpriced": an explicit opt-in for a token with no price feed. The signed caps are then the whole loss bound, and something signed must still arrive. |
| 15 | 24 Sep | The oracle value of one raw unit is exact. A token with more than 18 decimals is refused under the oracle rule. |

**24 September 14:45, v1 deployed to X Layer** from round 15 (`9acaa6f`,
manifest in `6543827`): 36 transactions, all eight contracts verified on
Sourcify, ownership handed over in two steps. The first mainnet firing
through the app, a small smoke-test swap, was mined at 15:25.

## What the nine days taught us

- **Measure, do not parse.** This held from the first commit to the last.
  Every new action got a check on the owner's balances, not a calldata
  rule.
- **Take "before" before anything moves.** The v0.1 dry-run became the v1
  snapshot, and round 13 moved the repay check ahead of the pull.
- **Price before the route.** A route must not be able to move the prices
  that judge it.
- **Sign what you check.** The maximum fee, the price rules and the venues
  are in the owner's signature, not in an admin setting.
- **Real chains find what unit tests miss.** A feed heartbeat, aToken
  rounding and a health factor near 1 were each found by a real firing on a
  fork, not by a unit test.
- **Remove rather than patch.** The cooldown and "claim and reinvest" went,
  instead of being fenced in.
- **Stop fast, restore slow.** An enforcer can freeze an agent, halt an
  executor or suspend a venue in one transaction. Lifting a halt or a
  suspension takes an enforcer's approval, 24 hours and the admin.

## Where to read more

- [`ARCHITECTURE.md`](ARCHITECTURE.md): how v1 works.
- [`TRUST.md`](TRUST.md): who can do what, and what each action checks.
- [`APP-SIDE.md`](APP-SIDE.md): what the Signo app does around the contracts.
- [`TESTS.md`](TESTS.md): the test map.
