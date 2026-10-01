# Signo Shield v1: security design and trust boundaries

This page says what each party can and cannot do in Shield v1, so it can be
checked against the code. How v1 works is in
[`ARCHITECTURE.md`](ARCHITECTURE.md). The short version: an AI agent
can act for you, but only through a permission you signed. The contract checks
every firing, and the worst an agent can do is spend what you allowed, on the
one action you allowed, through the venues you allowed.

Status: the public code is evidence, not an audit claim. The v1 contracts
went through 15 review passes, by the internal author and an external
reviewer. The story is in [`DESIGN-HISTORY.md`](DESIGN-HISTORY.md). Every
finding was fixed and pinned by a test, or kept by a written decision. The
accepted limit of swaps with no price check is described below. The final
review found no open high or critical item. The contracts have not been
formally audited. A mainnet canary runs daily ([`CANARY.md`](CANARY.md)).
`forge lint` and `forge fmt` are clean.

## Deployed on X Layer (chain 196)

Source commit `9acaa6f` (round 15), deployed 24 Sep 2026, verified on
Sourcify and on the X Layer block explorer. The manifest is in `deployments/manifest.json`.

| Contract | Address |
| --- | --- |
| ShieldV1 (core) | `0xd64807a7207D62d8F3E14aC1e05dB9fD1f1500CB` |
| ShieldRegistryV1 | `0xE87b50B7E3e996a0C60B4a24221FE44B4277272A` |
| ExpressionEvaluator | `0xaB964864f6436A15445279e41C7C99985B9eCcb5` |
| GenericExecutorV1 | `0x41817086D841E146F52E95BA85C68DE541654f18` |
| AaveV3AdapterV1 | `0x78749F9bfB020358050a2EeB53aD5234C4B840b5` |
| ClaimExecutorV1 | `0x2434AC952990C0C78940D92362354A26E673DB0E` |

The first-generation (v0.1) contracts stay deployed beside v1; their
addresses are in the manifest.

## Deployed on Arbitrum One (chain 42161)

The same source (contracts unchanged since `9acaa6f`; broadcast from `f3aa7d3`),
deployed 30 Sep 2026. The owner is the same admin as on X Layer; the admin
accepted the handover on chain. Listed: the Aave V3 pool and oracle, nine
Chainlink price rounds (WETH, WBTC, USDC, USDC.e, USD₮0, DAI, ARB, LINK, AAVE;
25 h freshness), and a read of Chainlink's sequencer uptime feed ("the
sequencer is up").

**Every Signo agent on Arbitrum checks that the sequencer is up.** Since
1 October 2026 the Signo app adds "the sequencer is up" (the uptime feed reads
0) to the trigger of every Arbitrum permission it prepares. It is part of what the
owner signs. The Shield re-checks it on chain at every firing, so no agent
acts while the sequencer is down, including through a transaction forced in
from L1. A permission whose own condition the chain cannot read still carries
this check.

The grace period after a sequencer restart (waiting before acting on prices
that may be stale) needs a clock node the expression language does not have
yet; until then it is a known limitation. No enforcer is set yet.

| Contract | Address |
| --- | --- |
| ShieldV1 (core) | `0xc9f83d96ee711C06dE80A532785d3BaEA966de97` |
| ShieldRegistryV1 | `0xE0377C8C1742FCbe885E99d8d746F56eE7982f6F` |
| ExpressionEvaluator | `0xc428a88A92Ecec99414152Ad2A5fd4244b222B15` |
| GenericExecutorV1 | `0xDdA03e096Eaa3AC649965B62F02007970cf22836` |
| AaveV3AdapterV1 | `0xE6f6d73c782fb6263F04bB5966af7661b9ebE9d9` |
| ClaimExecutorV1 | `0x9331264a9e1C0573D920cD8403031cC9761AC60A` |


## The design in five rules

1. **The owner signs the whole envelope.** A permission pins the agent, the
   action, the asset, the per-firing and lifetime caps, the validity window,
   the exact venues (contract and approval pairs), the rule that judges the
   result, and optionally a trigger and an outcome check. The agent chooses
   only the amount (within the caps), the route (through the signed venues)
   and, when the owner signed several outputs, which one to buy.
2. **A generic firing runs in a fresh sandbox.** The generic and claim
   executors deploy a single-use clone per firing. The clone may call only
   the signed venues, approves only for the call, and sweeps every token it
   holds back to the owner. The Aave adapter knows one protocol: it calls
   only the Aave pool and, for a repay from collateral, the signed swap
   router and spender. The agent never holds the owner's tokens.
3. **The result is measured on the owner, not reported.** After the calls,
   the executor measures what left the owner and what arrived at the owner,
   and applies the mandatory check of the action. If the check fails, the
   whole transaction reverts. Nothing moves, and no fee is charged.
4. **Prices come from reviewed feeds.** A swap judged at the oracle is
   valued with Aave's price oracle, read before the route runs, so a route
   cannot move the prices it is judged by. Each priced token's Chainlink
   round, bound in the registry, must also be fresh. Tokens valued this way
   must have 18 decimals or fewer.
5. **Stopping is fast; restarting is slow.** An enforcer can freeze an agent,
   halt an executor or evaluator, or suspend a venue in one transaction.
   Lifting a halt or a suspension needs an enforcer's approval and then the
   admin, 24 hours later. Revoking a venue, a read or a claim rule is
   permanent.

## The parties

| Party | Can | Cannot |
| --- | --- | --- |
| **Owner** (the wallet that signs) | register, amend and revoke their own permissions; set every number in them; change the agent by amendment; revoke the token allowance at any time | change a permission's executor, evaluator, action, asset or funding mode after registration (that is a new permission); touch anyone else's permission |
| **Agent** (a key held in Google Cloud KMS) | call `fire` on a permission that names it, for an amount within the caps, while the trigger holds, with a route through the signed venues | send the output anywhere but the owner; call or approve an unsigned contract; exceed a cap; fire after expiry, revocation, a freeze or a halt; hold the owner's tokens |
| **Admin** (registry owner, `Ownable2Step`) | list executors, evaluators, reads, price rounds and claim rules for new permissions; set the fee and fee recipient; appoint enforcers; execute a restoration an enforcer approved, 24 h after it was queued | move funds; change or revoke a live permission; raise a live permission's fee; lift a freeze or halt on its own |
| **Enforcer** | freeze and unfreeze an agent; halt an executor or evaluator; suspend a venue; approve a restoration; revoke a venue, a read or a claim rule for good | anything that moves funds; lift a halt or a suspension without the admin and the 24 h delay; undo a revocation |
| **Executors** | run one firing for the core, in a sandbox, and revert unless the action's check passes | be called by anyone but the core; keep tokens or approvals between firings |
| **Evaluator** | judge a trigger or outcome tree over listed reads | write state or hold tokens; treat an unreadable value as "true" (an unreadable read reverts) |
| **Anyone** | read every permission; call `canFireBy` | everything else |

## What each action checks

- **Swap** (`generic.transform`): the output's value at the oracle is at least the input's value less the owner's slippage, with both sides priced before the route. With several signed outputs, the value of everything that arrived is summed. Alternatives the owner can sign instead: a fixed minimum ("at least 250 received"), the vault's own quote for an ERC-4626 deposit, or no price check (below).
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
feed, says so on the review screen, and its agent refuses a route that the
swap venue rates over 15 % price impact. That is an off-chain guard, not a contract
check.

## What a leaked key can do

- **Agent key**: fire live permissions that name it, within their caps, venues,
  rules, windows and triggers, into the owners' own wallets. An enforcer's
  freeze stops it in one transaction, and each owner can revoke. Since
  1 October 2026 the key (`0x6735ADe192A1Dce20E058A41D6365F8568C75706`) is
  held in Google Cloud KMS, in a hardware security module it never leaves.
  Only Signo's production deployment can ask it to sign. Google does not
  check what it signs, so the contract's checks above are what bound it.
  The earlier agent key, `0x4eA690C26A7C499f8ABd39cf0546901c0635db75` (held
  in Turnkey), is retired: Signo no longer fires permissions that name it.
- **Admin key**: control over future listings and fees, and nothing over live
  permissions or funds. The seat moves only in two steps (propose, then accept).
  A 2 of 3 multisig for this seat is planned. It is not deployed yet.
- **Enforcer key**: the power to stop things, never to move or loosen.
- **Owner key**: the owner's own funds, as always. The Shield adds no exposure
  beyond the allowance the owner granted, and that allowance is spendable
  only through the owner's own permissions.

## Off-chain, for completeness

The agent decides when to fire and how much, within the permission. The
contract does not trust those decisions; it checks them. Before each firing,
the app reads every signed venue's code and configuration and refuses a
venue that changed since review. The signer simulates each firing before it
sends it and keeps one transaction in flight per agent. It can be stopped by
a kill switch read fail-closed, by disabling the key in Google Cloud KMS, or by a
freeze on chain.

## Known limits

- X Layer and Arbitrum One only. On each chain the app signs one DEX aggregator
  as its only swap venue.
- One asset (the token sold) per permission. A trigger fires once per crossing:
  it must turn false before it can fire again.
- Oracle-priced tokens need 18 decimals or fewer.
- Swaps with no price check are bounded by the caps only (see above).
- Not formally audited.
