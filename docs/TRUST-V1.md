# Signo Shield v1: security design and trust boundaries

This page says what each party can and cannot do in Shield v1, so it can be
checked against the code. The short version: an AI agent can act for you,
but only through a mandate you signed. The contract checks every firing, and
the worst an agent can do is spend what you allowed, on the one action you
allowed, through the venues you allowed.

Status: public code is evidence, not an audit claim. The v1 contracts went
through fifteen review rounds (an internal author and an independent
reviewer, FLIP-280). Every finding was fixed and pinned by a test. The final
review found no open high or critical item. Nobody outside the team has
audited them. `forge lint` and `forge fmt` are clean.

## Deployed on X Layer (chain 196)

Source commit `9acaa6f` (round 15), deployed 24 Sep 2026, verified on
Sourcify and OKLink. The manifest is in `deployments/manifest.json`.

| Contract | Address |
| --- | --- |
| ShieldV1 (core) | `0xd64807a7207D62d8F3E14aC1e05dB9fD1f1500CB` |
| ShieldRegistryV1 | `0xE87b50B7E3e996a0C60B4a24221FE44B4277272A` |
| ExpressionEvaluator | `0xaB964864f6436A15445279e41C7C99985B9eCcb5` |
| GenericExecutorV1 | `0x41817086D841E146F52E95BA85C68DE541654f18` |
| AaveV3AdapterV1 | `0x78749F9bfB020358050a2EeB53aD5234C4B840b5` |
| ClaimExecutorV1 | `0x2434AC952990C0C78940D92362354A26E673DB0E` |

The v0.1 contracts in `TRUST.md` stay live beside v1 for existing mandates.

## The design in five rules

1. **The owner signs the whole envelope.** A mandate pins the agent, the
   action, the asset, the per-firing and lifetime caps, the validity window,
   the exact venues (contract and approval pairs), the rule that judges the
   result, and optionally a trigger and an outcome check. The agent chooses
   only the amount (within the caps), the route (through the signed venues)
   and, when the owner signed several outputs, which one to buy.
2. **Every firing runs in a fresh sandbox.** The executor deploys a
   single-use clone per firing. The clone may call only the signed venues,
   approves only for the call, and sweeps every token it holds back to the
   owner. The agent never holds the owner's tokens.
3. **The result is measured on the owner, not reported.** After the calls,
   the executor measures what left the owner and what arrived at the owner,
   and applies the mandatory check of the action. If the check fails, the
   whole transaction reverts. Nothing moves, and no fee is charged.
4. **Prices come from reviewed feeds.** A swap judged at the oracle is
   valued with prices read before the route runs (so a route cannot move the
   prices it is judged by), from Chainlink rounds the registry binds and
   that must be fresh. Tokens valued this way must have 18 decimals or fewer.
5. **Stopping is fast; restarting is slow.** An enforcer can freeze an agent,
   halt an executor or evaluator, or suspend a venue in one transaction.
   Restoring needs an enforcer's approval and then the admin, 24 hours later.
   Revoking a venue, a read or a claim rule is permanent.

## The parties

| Party | Can | Cannot |
| --- | --- | --- |
| **Owner** (the wallet that signs) | register, amend and revoke their own mandates; set every number in them; revoke the token allowance at any time | change a mandate's agent, executor, action or asset after registration; touch anyone else's mandate |
| **Agent** (a key held in Turnkey) | call `fire` on a mandate that names it, for an amount within the caps, while the trigger holds, with a route through the signed venues | send the output anywhere but the owner; call or approve an unsigned contract; exceed a cap; fire after expiry, revocation, a freeze or a halt; hold the owner's tokens |
| **Admin** (registry owner, `Ownable2Step`) | list executors, evaluators, reads, price rounds and claim rules for new mandates; set the fee and fee recipient; appoint enforcers; execute a restoration an enforcer approved, 24 h after it was queued | move funds; change or revoke a live mandate; raise a live mandate's fee; lift a freeze or halt on its own |
| **Enforcer** | freeze an agent; halt an executor or evaluator; suspend a venue; revoke a venue, a read or a claim rule for good | anything that moves funds or loosens a limit |
| **Executors** | run one firing for the core, in a sandbox, and revert unless the action's check passes | be called by anyone but the core; keep tokens or approvals between firings |
| **Evaluator** | judge a trigger or outcome tree over listed reads | write state or hold tokens; treat an unreadable value as "true" (an unreadable read reverts) |
| **Anyone** | read every mandate; call `canFireBy` | everything else |

## What each action checks

- **Swap** (`generic.transform`): the output's value at the oracle is at least the input's value less the owner's slippage. The oracle prices both sides from reviewed Chainlink rounds, read before the route. With several signed outputs, the value of everything that arrived is summed. Alternatives the owner can sign instead: a fixed minimum ("at least 250 received"), the vault's own quote for an ERC-4626 deposit, or no price check (below).
- **Transfer**: the amount reaches the one recipient the owner signed.
- **Vault withdraw** (`generic.redeem`): the owner receives at least the vault's quote less the slippage, with an optional floor.
- **Repay on Aave**: the debt fell. **Repay from collateral**: judged on the health factor before anything moves. A position already at the target is refused, and each firing must raise the health factor.
- **Claim**: listed claim rules only, and every declared reward goes to the owner.

## Swaps with no price check

A token with no Chainlink feed cannot be valued on chain. The owner can
still sign a swap of it, with no price check. Then the signed caps are the
whole loss bound, and the contract checks only that something signed
arrived. That means a reported balance increase. A token that rebases can
show one without a purchase. The app offers this only for tokens with no
feed, says so on the review screen, and its agent refuses a route that OKX
rates over 15 % price impact. That is an off-chain guard, not a contract
check.

## What a leaked key can do

- **Agent key**: fire live mandates that name it, within their caps, venues,
  rules, windows and triggers, into the owners' own wallets. An enforcer's
  freeze stops it in one transaction, and each owner can revoke. The key is
  held in Turnkey. The app's API key is a non-root Turnkey user whose policy
  allows only `fire` on the two Shield cores on chain 196.
- **Admin key**: control over future listings and fees, and nothing over live
  mandates or funds. The seat moves only in two steps (propose, then accept).
  It belongs behind a multisig before scale.
- **Enforcer key**: the power to stop things, never to move or loosen.
- **Owner key**: the owner's own funds, as always. The Shield adds no exposure
  beyond the allowance the owner granted, and that allowance is spendable
  only through the owner's own mandates.

## Off-chain, for completeness

The agent decides when to fire and how much, within the mandate. The
contract does not trust those decisions; it checks them. Before each firing,
the app reads every signed venue's code and configuration and refuses a
venue that changed since review. The signer simulates each firing before it
sends it and keeps one transaction in flight per agent. It can be stopped by
a kill switch read fail-closed, by revoking the key at Turnkey, or by a
freeze on chain.

## Known limits

- X Layer only. OKX DEX is the only swap venue.
- One asset (the token sold) per mandate. A trigger fires once per crossing:
  it must turn false before it can fire again.
- Oracle-priced tokens need 18 decimals or fewer.
- Swaps with no price check are bounded by the caps only (see above).
- Not externally audited.
