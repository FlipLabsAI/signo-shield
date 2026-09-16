# Tier 1: generic bounded execution

The generic executor (`contracts/executors/GenericExecutor.sol`) is the one
adapter that knows no protocol. It sits in the same `adapter` slot a mandate
pins; `SignoShield` does not change. The full evaluation of what it covers,
what stays a protocol adapter and what is refused lives on the team's
FLIP-217 record; this page is the contract.

## What the owner pins

For `generic.transform`, in the mandate's `actionConfig`:

| Field | Meaning |
| --- | --- |
| `tokenOut` | The token the owner must end up with more of. The input token is the mandate's asset. |
| `target`, `spender` | The one execution surface: the contract the sandbox calls, and the contract it approves for the input. Neither may be a token in play, the Shield, the executor or its template. |
| `rateKind`, `oracle`, `rateOrFloor`, `maxSlippageBps` | How the minimum output is computed (below). |

For `generic.transfer`: `recipient`. The amount goes there and nowhere else.

## What the agent supplies

The amount (within the caps) and calldata for the target. Nothing else. A
minimum the agent would like to pass is not a parameter: the contract
computes the bound from the rule the owner pinned.

## The three rate rules

- **Fixed**: `minOut = amount × rate / 1e18`, less one basis point plus one
  unit of rounding slack (real 1:1 receipts such as aTokens mint a wei
  short). Wraps, 1:1 receipts (aTokens, cTokens for a base asset, stETH).
- **Oracle**: `minOut = amount × price(in) / price(out)`, decimals adjusted,
  less the pinned slippage (at most 10 %). The oracle is pinned at
  registration and dry-run then: a pair it does not price is refused. Aave's
  oracle has the required shape; any other feed is wrapped into it by a
  contract, never replaced by an agent-supplied quote.
- **Floor**: `minOut = the pinned number`, whatever the amount. A fire-once
  order where the owner names the count.

The bound is computed on what was actually sold (measured, see below), and
integer division rounds it down by at most one unit of the output token.

## What happens in a firing

1. The Shield pulls the amount from the owner and hands it to the executor.
2. The executor deploys a fresh minimal-proxy clone of `DisposableClone`,
   at an address anyone can predict from the mandate id and the firing count
   (`nextClone`), so calldata that must name the wallet holding the tokens
   can be built before the firing.
3. The clone is funded with exactly the amount, approves the spender for it,
   makes one call to the target with the agent's calldata, clears the
   approval, and sends every input and output token it holds to the owner.
   A clone runs once and is never reused.
4. The executor measures the owner's balances: what left for good is the
   amount minus what came back; what arrived is the output token's rise. It
   reverts unless something was sold and the output reached the bound.
5. The Shield measures the owner's balance drop itself, charges the fee on
   the measured spend, and reconciles the budget.

## What this refuses to bound

Anything a balance check on the owner cannot see: borrowing, withdrawing
collateral, leverage loops, liquidity positions, credit delegation and
operator bits, bridges (a source-chain transaction cannot revert for a
destination failure), multi-call routes, any output token without a pinned
rate source, and other execution models (Solana). Those are protocol
adapters (`contracts/adapters/`) or nothing.

## What a review has to try

Make a clone keep authority after its call (an approval, a delegatecall, a
selfdestruct trick, a callback into the executor or the Shield); make the
bound miscount (output to a third party, a second token drained, a
re-entrant firing, a reused clone, a rate source that lies or is stale);
make the executor or the Shield hold anything between transactions. Every
one of those is a test in `test/GenericExecutor.t.sol` and the fork suite,
and a future finding gets a test before it gets a fix.
