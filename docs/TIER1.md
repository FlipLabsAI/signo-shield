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

## The four rate rules

- **Fixed**: `minOut = amount × rate / 1e18`, less one basis point plus one
  unit of rounding slack (real 1:1 receipts such as aTokens mint a wei
  short). Wraps, 1:1 receipts (aTokens, cTokens for a base asset, stETH).
- **Oracle**: `minOut = amount × price(in) / price(out)`, decimals adjusted,
  less the pinned slippage (at most 10 %). The oracle is pinned at
  registration and dry-run then: a pair it does not price is refused. Aave's
  oracle has the required shape; any other feed is wrapped into it by a
  contract, never replaced by an agent-supplied quote.
- **Floor**: `minOut = the pinned number`, whatever the amount. An order
  where the owner names the count: every firing must clear the whole number,
  so a partial sale is refused by construction, and the mandate fires as
  often as its caps allow, each time at the full count. "Once" is the app's
  firing policy and the lifetime cap, not this rule.
- **Erc4626**: `minOut = amount × convertToShares(one unit of the input) /
  one unit`, read from the vault BEFORE the agent's call, less the pinned
  fee allowance and the same rounding slack as a fixed rate. `tokenOut` is
  the ERC-4626 vault, and it must also be the target and the spender: by the
  standard the vault is the receipt token and the deposit surface in one, and
  pinning the surface to it means no third party's call can sit between the
  price snapshot and the mint. At registration the executor asks the vault
  for its `asset()` and refuses the mandate unless it is the token being
  spent — the wrong-receipt check, inside the contract, for every vault.
  Why a rule and not a fixed pin: a share is not 1:1 with the underlying and
  its price rises as the vault earns, so a rate fixed at registration would
  refuse a good deposit a month later. `convertToShares` must round down and
  must exclude fees (EIP-4626), so it is a lower bound on the mint for a
  fee-less vault; `maxSlippageBps` is the owner's allowance for one that
  charges a fee.

The bound is computed on what was actually sold (measured, see below). It
never rounds up. A fixed rate is short by the stated tolerance (one basis
point plus one unit; the agent can take that on every firing, and it is
part of the loss bound alongside the fee); an oracle rate is computed in a
single division and is short by at most one unit of the output token. A
bound that rounds to zero is raised to one unit: a sale for nothing is never
a success. Oracle prices are read before the agent's call runs, so a feed
the route could move inside the transaction is not read after it moved.

## What happens in a firing

1. The Shield pulls the amount from the owner and hands it to the executor.
2. The executor deploys a fresh minimal-proxy clone of `DisposableClone`,
   at an address anyone can predict from the mandate id and the firing count
   (`nextClone`), so calldata that must name the wallet holding the tokens
   can be built before the firing.
3. The clone is funded with exactly the amount, approves the spender for it,
   makes one call to the target with the agent's calldata, clears the
   approval, and sends every input and output token it holds to the owner.
   A clone runs once and is never reused. Any other token a route leaves on
   a clone stays there; only the agent's own calldata can put it there.
4. The executor measures the owner's balances: what left for good is the
   amount minus what came back; what arrived is the output token's rise. It
   reverts unless something was sold and the output reached the bound.
   Input tokens that already sat at the predicted sandbox before the firing
   (anyone can send them there) are swept to the owner with the rest but do
   not count as "came back", so a stranger cannot make every firing read as
   a sale of nothing.
5. The Shield measures the owner's balance drop itself, charges the fee on
   the measured spend, and reconciles the budget.

## What this refuses to bound

Anything a balance check on the owner cannot see: borrowing, withdrawing
collateral, leverage loops, liquidity positions, credit delegation and
operator bits, bridges (a source-chain transaction cannot revert for a
destination failure), multi-call routes, any output token without a pinned
rate source (an ERC-4626 vault carries its own, see the fourth rule), debt reduction (a repay is the adapter's shape: the executor
only knows "the output token must rise"), native-coin output, and other
execution models (Solana). Those are protocol adapters
(`contracts/adapters/`) or nothing.

Two things the measurement cannot see, so the app must refuse at target
vetting: a target that pulls from a caller-chosen payer rather than
`msg.sender` (the owner's standing allowance to it for any token other than
the two measured would be drained while the firing passes; the two measured
are safe, a pull of more than the amount reverts the firing), and a
recipient for `generic.transfer` that is the owner or a contract that
cannot hold tokens (a round trip that still pays the fee, or a stranding).
OKX's router and Aave's pool pull from `msg.sender` only.

## What a review has to try

Make a clone keep authority after its call (an approval, a delegatecall, a
selfdestruct trick, a callback into the executor or the Shield); make the
bound miscount (output to a third party, a second token drained, a
re-entrant firing, a reused clone, a rate source that lies or is stale);
make the executor or the Shield hold anything between transactions. Every
one of those is a test in `test/GenericExecutor.t.sol` and the fork suite,
and a future finding gets a test before it gets a fix.
