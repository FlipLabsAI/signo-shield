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

## Status

This repository is the scaffold (FLIP-190). `contracts/core/SignoShield.sol` is
a stub whose entry points revert, and the interfaces carry the design above.
The enforcement lands in the tickets this one blocks.
