# Signo Shield — architecture

The contract enforces the **bound**. Signo decides the **action**.

Anything that is a number goes on chain, because a number is enforceable
without understanding anything. Anything that is a judgement stays off chain.
That single rule is what keeps this action-agnostic: there is no contract per
intent type, and adding a protocol needs no new Solidity.

It is called a Shield rather than a Guardian because it is something the agent
uses, not another agent. The owner signs a mandate. The agent fires a mandate
through the Shield.

## Tier 1 — bounded execution (the default)

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

   Repay: the debt token must fall. Supply: the aToken must rise. ERC-4626
   deposit: shares must rise. Swap: the output token must rise at the owner's
   limit rate.

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

## Amendment

Raising a cap, extending an expiry, changing a trigger or adding a Tier 1
action is one owner transaction through `amendMandate`. Adding a new input
token also needs an ERC-20 approve, so it is one signature in an ERC-5792
batching wallet and two elsewhere.

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
into the record at registration (5 bps at launch), never changed for the life
of a mandate; a rate change reaches new registrations only, and a fee
recipient of `address(0)` disables collection entirely. The contract is
interface-aligned with ERC-8226, never conformant.

The agent's entire authority is `fire(mandateId, amount, data)`. Every firing
runs the same fixed sequence, and `canFire(mandateId, amount)` reports the
first failing step as a reason code so a relayer and a UI can say why before
sending anything:

```
NONEXISTENT → AGENT_FROZEN → NOT_AGENT → NOT_YET_VALID → EXPIRED → REVOKED
→ ZERO_AMOUNT → OVER_TX_CAP → OVER_CUMULATIVE_CAP → TRIGGER_NOT_MET
```

Then: reserve `amount` against the budget, pull it from the principal with the
allowance the principal granted the Shield, hand it to the pinned adapter,
require the adapter's outcome check to pass, reconcile the budget to what was
actually spent, emit the receipt. A failed outcome reverts the whole
transaction. The Shield holds no funds between transactions and has no
withdrawal function. A trigger that cannot be read reverts rather than
reporting "not met".

Three roles, kept apart. The **principal** registers, amends and revokes its
own mandates; amendment cannot change `agent`, `adapter`, `action` or `asset`,
cannot raise the fee, cannot move the lifetime cap under what is used, and
re-emits the whole record. The **admin** (`Ownable2Step`) lists adapters for
new registrations, appoints enforcers and sets the fee recipient; it cannot
move funds, touch a live mandate, or freeze. An **enforcer** can freeze and
unfreeze an agent and nothing else, and the admin can never be one. A mandate
pins its adapter at registration, so listing or delisting later reaches no
live mandate.

**`ConditionModule`** is the generic trigger described above, as one
`staticcall` reader.

**`AaveV3Adapter`** is the first Tier 2 adapter: one contract for the protocol,
one entry point per action, callable only by the Shield, holding no state.
`supply` requires the principal's aToken balance to rise by the amount.
`repay` clamps to the debt actually owed, returns the rest, and requires the
variable debt to fall by what was repaid; the rate mode is pinned to variable.
`repayWithCollateral` takes a slice of the collateral aToken, withdraws it,
swaps it through the router pinned in the mandate with the agent's calldata,
bounded by a minimum output from the Aave oracle and the mandate's slippage
limit, repays, returns any dust, and requires the health factor to end at or
above the pinned target. Aave itself refuses a collateral transfer that would
leave the position under-collateralised, so a slice that breaks the loan never
reaches the swap. Every approval an action grants is cleared before it returns.

## Static analysis

`forge lint` runs as part of `forge build` and is clean. Slither reports
twenty-two findings on the contracts, all of them the design stated above,
each left in place on purpose:

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

Core, condition module and Aave V3 adapter are built and tested (unit suites
plus an X Layer fork suite at a pinned block). Nothing is deployed. The Tier 1
bounded executor stays research scope.
