# Signo Shield v0.1: architecture

> This page describes v0.1 (16 and 17 September 2026), which stays deployed for
> existing mandates. Shield v1 is described in
> [ARCHITECTURE-V1.md](ARCHITECTURE-V1.md), and how one led to the other in
> [DESIGN-HISTORY.md](DESIGN-HISTORY.md).

The contract enforces the **bound**. Signo decides the **action**.

Anything that is a number goes on chain, because a number is enforceable
without understanding anything. Anything that is a judgement stays off chain.
That single rule is what keeps this action-agnostic: there is no contract per
intent type, and adding a protocol needs no new Solidity.

It is called a Shield rather than a Guardian because it is something the agent
uses, not another agent. The owner signs a mandate. The agent fires a mandate
through the Shield.

## Tier 1 — bounded execution (built as `GenericExecutor`; see `docs/TIER1.md`)

Three pieces, none of which parse calldata.

1. **The agent holds no allowance.** The Shield does, and it pulls at most the
   mandate's per-firing amount.
2. **The call runs from a fresh disposable clone.** A minimal proxy, deployed
   and discarded within the transaction, holding no allowance of its own, so no
   standing approval survives the firing.
3. **A post-condition on the owner's balances.** The owner pins the input
   token, the output token, the direction and a minimum rate at registration.
   The agent supplies only a number, a target and calldata. The contract
   computes the bound itself.

   One rule: the pinned output token must rise on the owner by at least the
   bound. Supply: the aToken must rise. ERC-4626 deposit: shares must rise.
   Swap: the output token must rise at the owner's limit rate. A repay (the
   debt token must fall) is not this shape; it is the Aave adapter's.

**Why this is not a calldata filter.** A filter parses the call, and is fooled
by batched calls and by delegatecall. A post-condition measures the owner's
balances at the end, so there is no parser to fool.

**Loss bound: tolerance times budget.** Fifty basis points on five thousand
USDC is about twenty-five USDC worst case. That is tighter than an
adapter-per-action design, where a malicious listed adapter can take a full
per-action cap.

## Tier 2 — pinned adapter (the exception)

Reserved for two cases:

- the demo mandate, where a pinned path makes a stronger on-stage claim;
- **obligation-shaped grants**, where a balance check cannot see the harm.
  Credit delegation and operator bits: Aave `approveDelegation`, Compound
  `allow`, Morpho `setAuthorization`. Nothing in the owner's balances moves when
  one of those is granted, so a post-condition has nothing to measure.

## Conditions

One generic module covers every trigger. Pin a view target, its calldata, the
word offset to read out of the return data, a comparator and a threshold.
`staticcall` cannot change state, so a fully generic reader is safe in a way a
generic writer would not be. Health factor, oracle price, token balance and
vault share price are one contract.

This is the part that is not standard practice: all nine ERC-7579 SmartSessions
policies inspect the call being made. None of them read protocol state.

The evaluator is pluggable per mandate. A condition names which listed
`ICondition` judges it (`condition.evaluator`); the zero address is the
default module above. The owner lists evaluators the way adapters are
listed (`setEvaluator`), and a mandate pins its evaluator at registration,
so delisting reaches no live mandate. The first listed evaluator is
`CompoundCondition`: "A and B" or "A or B" over up to eight plain leaves,
every leaf read every time with no short-circuit, so a leaf that cannot be
read reverts the whole trigger instead of hiding behind a true sibling — and
the registration dry-run exercises every leaf, so a dead one is refused at
signing. Leaves only, one level deep: eight flat leaves cover "health factor
below X and price above Y and balance over Z", and nesting would make a
trigger's cost unbounded and its meaning hard to put on a review screen.

## Amendment

Raising a cap, extending an expiry or changing a trigger is one owner
transaction through `amendMandate`. The asset is immutable: a new input token
is a new mandate, and it needs its own ERC-20 approve, so that is one
signature in an ERC-5792 batching wallet and two elsewhere.

Three rules hold for every amendment:

- `amendMandate` can never change the agent address;
- every amendment re-renders the **whole** resulting permission, never the
  delta, so a user and an indexer read the same thing;
- widening emits the registration event shape.

## Grant shapes this design has to live with

The ceiling on action-agnosticism is the protocols, not this contract:

1. no grant at all, where the protocol takes `onBehalfOf` (Aave and Spark
   supply and repay; Compound reward claim is permissionless);
2. a plain ERC-20 allowance;
3. an ERC-4626 share allowance, which the standard mandates, so one path covers
   Yearn V3, MetaMorpho, Sky, Pendle SY and Aave collateral exits via the
   aToken;
4. a protocol-native operator bit, which costs one extra setup transaction.

## Known limits

- Native ETH cannot be approved. That needs WETH, not an escrow: funds staying
  in the owner's wallet is the property this design exists to keep.
- Aave's `claimAllRewardsOnBehalf` is gated by their RewardsAdmin, so Aave
  reward claiming is not delegable.
- Solana and cross-chain execution are a separate model, not this contract.

## What is built

**`SignoShield`** holds the mandate record and enforces it. Field names follow
ERC-8226 where they mean the same thing (`principal`, `agent`, `asset`,
`validFrom`, `validUntil`, `revoked`, `maxTransactionValue`,
`maxCumulativeValue`, `cumulativeUsed`); the rest is ours: the pinned pair
(`adapter`, `action`), the trigger `condition`, an opaque `actionConfig` the
adapter validates, and `feeBps`. The fee is the Shield's current rate stamped
into the record at registration (10 bps at launch), never changed for the life
of a mandate; a rate change reaches new registrations only, and a fee
recipient of `address(0)` disables collection entirely. It is charged on what
a firing actually spends, on top of the amount, and the lifetime cap covers
both: the worst case (all of the amount spent, fee on all of it) is what has
to fit, and what is reserved before the adapter runs. The contract is
interface-aligned with ERC-8226, never conformant.

The agent's entire authority is `fire(mandateId, amount, data)`. Every firing
runs the same fixed sequence, and `canFire(mandateId, amount)` reports the
first failing step as a reason code so a relayer and a UI can say why before
sending anything:

```
NONEXISTENT → AGENT_FROZEN → NOT_AGENT → NOT_YET_VALID → EXPIRED → REVOKED
→ ZERO_AMOUNT → OVER_TX_CAP → OVER_CUMULATIVE_CAP
→ INSUFFICIENT_ALLOWANCE → INSUFFICIENT_BALANCE → TRIGGER_NOT_MET
```

The allowance and balance checks cover the worst case of the firing (amount
plus the fee on all of it). What `canFire` cannot see is the adapter's own
outcome check and the protocol's answer; those surface as `OutcomeRejected`.

Then: reserve the worst case against the budget, take the fee's worst case
from the principal, pull `amount` with the allowance the principal granted
the Shield, hand it to the pinned adapter, **measure** what left the
principal (the larger of the adapter's report and the balance drop counts,
and more than `amount` leaving reverts), settle the fee on that and refund
the rest, reconcile the budget to spend plus fee, emit the receipt. The fee
leaves before the adapter runs so every outcome check the adapter makes sees
the principal's final state. Any adapter-side revert surfaces as
`OutcomeRejected(mandateId, POSTCONDITION_FAILED, adapterError)`: one typed
code for a relayer, the adapter's own revert data for whoever has to read it,
and the whole transaction reverts. `canFireBy(mandateId, caller, amount)` is
`canFire` for a specific caller, `NOT_AGENT` included. The Shield holds no
funds between transactions and has no withdrawal function. A trigger that
cannot be read reverts rather than reporting "not met".

Three roles, kept apart. The **principal** registers, amends and revokes its
own mandates; amendment cannot change `agent`, `adapter`, `action` or `asset`,
cannot raise the fee, cannot move the lifetime cap under what is used, and
re-emits the whole record. The **admin** (`Ownable2Step`) lists adapters for
new registrations, appoints enforcers and sets the fee rate for new
registrations; it cannot move funds, freeze, or renounce the seat. One admin
lever reaches live mandates: the fee recipient, which turns collection on or
off and moves where the fee goes. It can only lower what a principal pays,
and it can never point at the Shield or a listed adapter. Listing an adapter
is a trust decision on what the adapter does with the funds inside one
firing, and only that: the Shield measures what left the principal itself,
so a listed adapter can under-report but never under-charge the budget. An
**enforcer** can freeze and unfreeze an agent and nothing else, and the admin
address can never be one (a person holding two keys can, which is why the
admin seat belongs behind a multisig before real users); the deployment script appoints one before handing the seat
over, so the freeze switch is armed from the first block. A mandate pins its
adapter at registration, so listing or delisting later reaches no live
mandate. Registration dry-runs the trigger, so a target without code, a
wrong selector or a word past the return data is refused rather than signed
into a mandate that could never fire; and the lifetime cap must hold one
firing at the per-firing cap plus its fee.

**`ConditionModule`** is the generic trigger described above, as one
`staticcall` reader, and the Shield's default evaluator.

**`CompoundCondition`** is the first listed evaluator: `and` / `or` over
plain leaves, each judged by the default module, every leaf every time.

**`AaveV3Adapter`** is the first Tier 2 adapter: one contract for the protocol,
one entry point per action, callable only by the Shield, holding no state.
`supply` requires the principal's aToken balance to rise by the amount (a
first supply of a reserve also turns it on as collateral, as Aave does).
`repay` clamps to the debt actually owed, returns the rest, and requires the
variable debt to fall by what was repaid; the rate mode is pinned to variable.
`repayWithCollateral` takes a slice of the collateral aToken, withdraws it,
swaps it through the router pinned in the mandate with the agent's calldata
(the collateral is approved to a separately pinned spender, since aggregators
pull through their own approval contract), bounded by a minimum
output from the Aave oracle and the mandate's slippage limit, repays, and
requires the health factor to end at or above the pinned target (the fee has
already left the position when that check runs, so it holds for the final
state). What the
router took is measured as the drop in the adapter's own balance across the
call, so tokens anyone parks on the adapter neither block a firing nor loosen
its bound (parked debt asset ends up with whichever principal fires next,
never with the agent); the loss bound of the swap leg is the slippage limit
times the budget, measured against the Aave oracle, so it carries the
oracle's own deviation from the market; the unsold part of the slice goes back into the position, never to
the wallet; a sale that overshoots the debt by more than the slippage bound
is refused. Aave itself refuses a collateral transfer that would leave the
position under-collateralised, so a slice that breaks the loan never reaches
the swap. The router and the spender may not be any token or protocol
contract the adapter holds authority over. Every approval an action grants is
cleared before it returns.

## Static analysis

`forge lint` runs as part of `forge build` and is clean. Slither reports
twenty-three findings on the contracts, all of them the design stated above,
each left in place on purpose. Two independent reviews found one medium and four low
issues each, all fixed and pinned with tests. `docs/TRUST.md` states what each party can and cannot do.

| Finding | Where | Why it stays |
| --- | --- | --- |
| arbitrary `from` in `transferFrom` | `SignoShield.fire` | The principal granted the Shield the allowance so that exactly this, bounded by the checks above, can happen without their signature. |
| reentrancy (balance, events, no-eth) | `fire`, adapter actions | `fire` is `nonReentrant`; the adapter keeps no state; receipts are emitted after the checked outcome on purpose. |
| strict equality on a balance | adapter `debt == 0` | A zero debt is refused, not compared for a payout. |
| unused return | `getUserAccountData` | Only the health-factor word is needed. |
| missing zero check | `setFeeRecipient`, adapter constructor | `address(0)` disables fees by design; the constructor's code-length check refuses it. |
| timestamp comparison | validity window | Mandate validity is a timestamp window, as in ERC-8226. |
| assembly, low-level call | condition module, swap leg | The generic reader and the pinned-router call are the design; both are bounded by balance checks. |
| naming | `ADDRESSES_PROVIDER` | Aave's own function name. |

## Status

Core, condition module and Aave V3 adapter are built and tested: unit suites,
fork suites on X Layer and Arbitrum One at pinned blocks, a replay of real DEX
aggregator calldata through the swap leg, a parity check against the app's own
action-plan calldata, the deployment script on a fork, and the slippage
arithmetic across token decimals (`docs/TESTS.md`). `tools/demo-fork.sh` runs
the whole story on a local fork. The Tier 1 generic executor
(`contracts/executors/`) is built and fork-proven (a real aggregator swap and a real
Aave supply through a disposable sandbox on X Layer, `test/fork/GenericExecutor.fork.t.sol`);
it is not deployed or listed until its own review (docs/TIER1.md, last section).
