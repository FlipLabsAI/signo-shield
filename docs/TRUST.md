# Signo Shield: trust boundaries

What each party can and cannot do, stated so it can be checked against the
code. Public code is inspectable evidence, not an audit claim: the contracts
have had two internal reviews with every finding fixed and pinned by a test
(FLIP-201 records them), Slither and `forge lint` are clean, and nobody
outside the team has audited them.

Addresses on X Layer (chain 196), source commit `3907f08` (deployed
2026-09-17, Sourcify-verified):
SignoShield `0x8a07B505Da63f2Fd0a17BEb78e906F2f9b42b4B4`,
ConditionModule `0x506577BC1770231b353C22729Bd4a7472ae8e210`,
CompoundCondition `0xb58E1A61F7ccF358c2a7f78705c56644fC10D059` (listed),
AaveV3Adapter `0x8eDE71F6613E3cAd455EDb7ced313aeD23164C76` (listed),
GenericExecutor `0x364efa85B3D2aA8A539DB6856D1D2bF34b423654` with its clone
template `0x2bC45CFd3E3B3cB7580a004Ba5A0287131D9633C`, listed on the Shield
only by the admin's `setAdapter`; see `docs/TIER1.md` for what it bounds.
The previous set (Shield `0x9331…c60a`, source `fe47fdb`, and the executor
from `d9464c9`) holds no mandate and is not used by the app.

## The parties

| Party | Holds | Can | Cannot |
| --- | --- | --- | --- |
| **Principal** (the wallet owner) | their own key; an ERC-20 allowance they granted the Shield | register, amend and revoke their own mandates; set every number in them; revoke the allowance at the token | change a mandate's agent, adapter, action or asset after registration; raise its fee; drop its lifetime cap under what is used; touch anyone else's mandate |
| **Agent** (the signer key, held in Turnkey) | the right to call `fire` | fire a live mandate it is named on, for an amount within the caps, while the trigger holds, through the pinned adapter, into the principal's own position | receive tokens; hold an allowance; pick the recipient, the protocol or the action; fire after expiry, revocation or freeze; fire past the per-firing or lifetime cap; fire a mandate naming another agent |
| **Admin** (`Ownable2Step` owner) | the admin seat | list and delist adapters and condition evaluators for **new** registrations; appoint and remove enforcers; set the fee rate for **new** registrations; set the fee recipient, which reaches live mandates only by turning collection off, on, or elsewhere | move funds; change, freeze or revoke a live mandate; raise a live mandate's fee; point the fee at the Shield or a listed adapter; be an enforcer (as an address; a person with two keys can, so the seat belongs behind a multisig before real users); renounce the seat |
| **Enforcer** | a role granted by the admin | freeze and unfreeze an agent address, which halts every mandate it holds | anything else: no funds, no mandate changes, no revocation |
| **Adapter** (AaveV3Adapter) | tokens only inside one `fire` call | execute one pinned action for the Shield, and revert unless the outcome check passes | be called by anyone but the Shield; keep tokens between calls; keep an approval after returning; under-charge the budget (the Shield measures what left the principal itself, so a listed adapter that mis-reports is still charged for what it took, and taking more than the amount reverts the firing) |
| **Generic executor** (Tier 1) | tokens only inside one `fire` call, in a single-use clone | run the agent's calldata against the one target and spender the owner pinned, then require the pinned output token to rise on the owner by the bound the owner's rule computes (fixed rate, oracle less slippage, or a floor) | pick the target, the spender, the output token or the rate; keep an approval; run a clone twice; count output paid to anyone but the owner; count tokens a stranger parked at the sandbox as a refund; read the oracle after the agent's call |
| **Evaluator** (the default ConditionModule, or a listed one such as CompoundCondition) | nothing; called with `staticcall` | judge a mandate's trigger: the default module reads one word of one view call, a compound judges two to eight such leaves with "and" or "or", every leaf every time | write state; hold tokens; be switched on a live mandate by anyone but its principal (the evaluator is pinned at registration, and an amendment that keeps it needs no listing); nest compounds |
| **Fee recipient** | the fee on each firing | receive `feeBps` of what a firing spent | pull anything; affect a firing |
| **Anyone** | nothing | read every mandate; call `canFire` | everything else |

## What holds funds, and when

Between transactions: only the principal's wallet and the principal's own
Aave position. The Shield holds nothing and has no withdrawal function. The
adapter holds nothing. Inside one `fire`, the Shield pulls `amount` from the
principal with the allowance the principal granted, hands it to the adapter,
and the adapter must leave it in the principal's own position (supply),
return it to the principal (repay refunds the unspent part), or have swapped
and repaid it (repay with collateral, unsold collateral re-supplied). What
the fee recipient receives is the only value that leaves the principal for a
third party, and its rate was stamped into the mandate at registration.

## What bounds a firing

The contract checks, in this order, before anything moves:
`NONEXISTENT`, `AGENT_FROZEN`, `NOT_AGENT`, `NOT_YET_VALID`, `EXPIRED`,
`REVOKED`, `ZERO_AMOUNT`, `OVER_TX_CAP`, `OVER_CUMULATIVE_CAP`,
`INSUFFICIENT_ALLOWANCE`, `INSUFFICIENT_BALANCE`, `TRIGGER_NOT_MET`. The
lifetime cap is charged the worst case (all of the amount spent, fee on all
of it) before the adapter runs and reconciled to what actually left the
principal after, measured by the Shield, not reported by the adapter. The
fee's worst case leaves the principal before the adapter runs and the unowed
part comes back after, so every outcome check the adapter makes sees the
final state. Every adapter-side revert surfaces as `OutcomeRejected` and the
whole transaction reverts. What `canFire` cannot foresee is the adapter's
own outcome check and the protocol's answer.

The trigger is a `staticcall` into the evaluator the mandate pinned: by
default the plain ConditionModule (a pinned target, pinned calldata, a word
offset, a comparator and a threshold), or a listed evaluator such as
CompoundCondition, whose calldata carries two to eight plain leaves joined by
"and" or "or". Every leaf is read on every check, and a compound's outer
word, comparator and threshold must be zero. It cannot change state and it
cannot read another chain. A leaf is still an arbitrary view read the
principal chose, so a review screen must show each one as the read it is. A
trigger that cannot be read reverts rather than reporting "not met". A mandate may be registered without
a trigger; then the caps and the window are its only bound, and a user
interface must say so.

## The swap leg

Repay with collateral is the one action that touches a third-party router.
The router **and** the approval contract are pinned in the mandate by the
principal; the agent supplies only the calldata. The adapter approves the
pinned spender for the slice, calls the pinned router, measures what left
its own balance, requires the output to reach a minimum derived from the
Aave oracle and the mandate's slippage limit, refuses a sale that overshoots
the debt by more than that limit, re-supplies the unsold part, repays, and
requires the health factor to end at or above the pinned target. Neither
the router nor the spender may be a token or protocol contract the adapter
has authority over during the firing. The loss bound of the swap leg is the
slippage limit times the lifetime cap.

## What a leaked key buys

- **Agent key**: firings of live mandates within their caps, windows and
  triggers, landing in the principals' own positions. Stopped by an
  enforcer's freeze in one transaction, or by each principal's revoke. The
  key lives in Turnkey; the app holds an API key that may ask Turnkey to
  sign, scoped to the Shield, revocable there.
- **Admin key**: control over future registrations (which adapters, what
  fee, who enforces) and nothing over live mandates or funds. The seat moves
  only by `Ownable2Step` (propose, then accept from the new key).
- **Enforcer key**: the power to halt agents, never to move or take.
- **Principal key**: the principal's own funds, as always; the Shield adds no
  exposure beyond the allowance the principal chose to grant, and that
  allowance is spendable only through the principal's own mandates.

## Off-chain, for completeness

Signo's watcher decides *when* to fire and *how much*, within the mandate;
the contract does not trust those decisions, it checks them. The app's copy
of a mandate is written only from a chain read and re-read on a schedule;
the chain wins every difference. The signer simulates before it sends,
keeps one transaction in flight per agent, bounds retries, and stops in this
order, fastest first: revoking the signer's key at the key service or freezing
the agent on chain (seconds), a kill switch read fail-closed (no answer means
no firing), and an environment hard stop that needs a redeploy but survives
an outage of the app's database. A user interface may show a mandate's
numbers; only the wallet's signature creates one.

## Known limits

- Native gas tokens cannot be approved; a mandate needs an ERC-20 (WOKB, not OKB).
- One Shield per chain, one mandate per chain; nothing bridges.
- Aave reward claiming is not delegable through the Shield.
- An unlimited cap is accepted by the contract; the bound that remains is the pinned action itself.
- The swap leg's loss bound is the slippage limit times the budget, measured against the Aave oracle, so it carries the oracle's own deviation from the market. A principal may pin up to 10 %; a user interface should default far under it.
- The admin and enforcer keys are single addresses today; the admin seat belongs behind a multisig or timelock before real users.
- Nobody outside the team has audited these contracts. Say "reviewed", never "audited".
