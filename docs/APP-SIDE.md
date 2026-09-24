# The app around the contract

This repository is the on-chain half of delegated execution in Signo. The
other half lives in the Signo application, which is private because it is
the whole product. This page says what that half does, when it was built,
and what it has done on mainnet, so a reader of this repository can judge the
integration without access to the application's source. Review access to the
application is offered on request.

Dates are UTC. Build numbers are the application's production build counter;
every commit on its `main` branch carries one. Commit hashes are the
application's.

## What the application does with the Shield

The application drives two cores. The first core (v0.1, `SignoShield`) went
live on 16 September. The v1 core (`ShieldV1` with its registry, evaluator
and executors) went live on 24 September. The application picks the core per
chain, and v1 is switched on for X Layer. The first group below applies to
both cores. The second group is v1 only.

### Both cores

**Pins the deployed contracts.** The deployment manifest and ABIs exported by
this repository (`deployments/manifest.json`, `abi/`) are checked into the
application and covered by a test, so the application cannot drift from the
verified addresses. Re-pinned to the 17 September redeploy in build 3438. The
v1 contracts are pinned the same way from the commit that deployed them
(build 3592, 24 September). The sync script refuses a manifest whose
contracts come from more than one deploy commit, or whose deploy commit
differs from the synced source, ABIs or deploy script. In that case the v1
switch stays off.

**Signs and sends.** One service submits every transaction. The agent key is
held in a key-management service and never in the application. Each firing
is simulated before it is sent, one transaction is in flight per agent,
retries are bounded, receipts are reconciled into a ledger, and there is a
kill switch plus an environment hard stop. Builds 3388 to 3394, 16 September.

**Keeps a copy of every mandate from the chain, not from itself.** The
application's record of a mandate is written only from a chain read and
re-read on a schedule; every difference is surfaced, never absorbed. A v1
mandate is read from the core its record names. Build 3395, 16 September;
v1 on 24 September.

**Fires mandates when their conditions hold.** An agent armed by an on-chain
mandate checks its condition on an hourly tick, batched per chain, sizes a
firing from the live position, builds the calldata (for a swap, through the
DEX aggregator, checked against the venue pinned in the mandate), sends it
through the signer, decodes the receipt into the run record, and tells the
owner. One retry per failure; then the owner is told the run has stopped.
Builds 3400 to 3478, 16 to 18 September. The same tick fires v1 mandates
beside v0.1 ones, each core with its own batch, signer and receipt profile
(built 23 September, live 24 September).

**Lets an owner create, review, sign, change and revoke a mandate.** The
agent builder has an Execute mode: the owner describes the action, the
application compiles it into exactly one enforceable mandate, a question, or
a refusal, shows the review (what the mandate enforces: when, then, and the
constraints), and hands the registration to the owner's wallet to sign.
Limits can be changed in place; deleting the agent revokes the mandate from
the wallet; the revoke screen reads and shows the remaining allowance. Tier 1
mandates (transfer, swap, vault deposit) and scheduled execution (the clock
as a condition) are built the same way. Builds 3423 to 3535, 17 to 21
September.

**Sizes and explains from the agent.** The execute tick's sizing moved into
the agent, with its reasons carried into the owner's notice. The agent
follows the owner's orders and does not form views of its own. When the
owner's instruction sizes a firing below the headroom, the route is rebuilt
for that amount. Builds 3515 to 3522 (20 September), 3579 and 3583 (23 and
24 September).

**Writes to the owner in plain words.** Every message an owner receives
about a firing is composed from a fact sheet, rephrased by a small language
model with the deterministic text as the fallback, and validated so no fact
is dropped or invented. Builds 3464 to 3478, 17 and 18 September.

**Tells the owner once when a firing fails.** One Telegram message per
failed episode: what the agent tried, in the owner's units, the plain
reason, and what happens next. The same reason again is silent; a new
reason is a new message; a mined firing closes the episode. The message
carries a Prepare link with the same action filled in, so the owner can
sign it by hand. Reverts and signer failures also alert the team. Builds
3560 and 3565, 22 September.

**Prepares mandates through MCP and a partner API.** An outside agent can
prepare a mandate proposal that the owner then reviews and signs in the
Signo application. Builds 3452 to 3508, 17 and 18 September. Since 22
September an assistant with no API key can also draft an agent or a
mandate; the owner opens the draft on the setup page and signs it there.
Builds 3538 to 3552.

**Runs the same conditions for alerts and for execution.** A price threshold,
a health factor, a yield, a schedule: one condition engine, read from the
same cached data, feeds both the notify path and the execute path. Builds
3494 to 3499, 18 September. Since 24 September an Execute agent can also
trigger on an asset's current price: the v0.1 condition module reads the
Aave oracle price (build 3596), and the v1 trigger reads the Chainlink feed
(build 3601).

### v1 only

**Compiles the owner's words into the whole v1 envelope.** The owner
describes the action or picks it from a list. The application compiles it
for the v1 core: the executor and action, the caps, the expiry, the venues
the owner kept, the price rules read from the registry at compile time, and
the trigger as a v1 expression tree. Before it shows the Sign button, it
asks the chain: the executor is listed, the fee is the core's, the executor
accepts the settings, and the evaluator accepts the tree. Actions: swap,
send, vault deposit, vault withdraw, reward claim, and Aave supply, repay
and repay from collateral. Each one was registered and read back on a local
X Layer fork before the switch. Built 23 and 24 September, live in build
3592.

**Pins the trigger on chain where it can.** The trigger compiler turns a
health factor, a token balance, an asset price, and arithmetic on them, into
the reads and nodes the evaluator runs. When a trigger mixes conditions the
chain can read with ones it cannot, such as a price change over a window
(the chain keeps no history), each unreadable condition counts as unknown:
the chain refuses a firing only when the readable part is definitely false,
and the agent checks the rest. Builds 3562 (22 September)
and 3601 (24 September).

**Shows only what is signed.** Before the wallet opens, the application
decodes the exact parameters the Sign button sends and compares every field
the review shows with them: executor, action, settings, trigger, fee,
expiry, caps, and per action the rate rule, price rules, venues, recipient,
vault, outputs and claim market. Any difference blocks signing. Amendments
get the same check. 23 and 24 September.

**Signs the venues and watches them.** The owner keeps or removes venues in
the builder, and the kept ones are signed into the mandate. A daily job
reads each reviewed venue's upgrade facts (implementation slot, owner,
facets, allowlist, code hash), keeps a baseline, and alerts the team on a
change. A mandate that can route through a changed venue is blocked until a
person acknowledges the change. Just before each v1 firing, the venues it
names are read again, because the daily job can be a day late. A swap tries
the venues the owner kept, in order, and skips one under review. Builds 3557
to 3564 (22 September) and the v1 tick (24 September).

**Takes any token for a send or a swap.** The owner types a listed symbol or
pastes a contract address. The application reads a pasted token on chain
(decimals, symbol, total supply) and refuses a contract that does not answer
as a token. A swap may name up to five tokens it may buy ("xETH or xBTC").
The mandate signs all of them, and the agent picks one at the firing. 24
September.

**Signs a swap with no price check only when there is no feed.** A swap whose
tokens all have a Chainlink feed is judged at the oracle price, and the
owner's maximum slippage must be at least 50 bps. A swap in which any token
has no feed is signed as Unpriced: the caps are the whole loss bound. The
review says so in one line. At the firing, the route builder refuses an
aggregator quote with more than 15 % price impact, or with no impact figure,
and tells the owner why. That check is off-chain, not in the contract. 23
and 24 September.

**Lets the agent choose inside the mandate.** At a firing, the agent's
decision sees the owner's instruction, the envelope, each condition of the
trigger with its reading and whether it holds, the wallet balance, and the
tokens the mandate may buy. It picks the output and the amount within the
caps. The route is quoted for that token, and the route builder refuses a
token the mandate does not sign. A swap whose outputs share a symbol is
refused at setup, so the agent never has to guess between them. The owner's
message leads with the condition that held and names the token and the
amount that arrived, read from the receipt. Builds 3583 and 3602, 24
September.

**Repays from collateral in steps.** Aave refuses a collateral transfer that
leaves the owner under a health factor of 1. The sizing caps each slice so
the pull leaves the owner at 1.01 or more, and the v1 adapter lets the next
firings step to the target. On an X Layer fork the health factor went 1.134,
1.188, 1.282, 1.478, 1.803 in four firings, then the agent stopped at the
target. When a firing stops short of the target, the message says so. 24
September.

**Was reviewed before it was switched on.** An independent reviewer checked
the v1 application changes in several passes, with tests written in the
application's own framework. Each finding was fixed with a test or deferred
in writing. v1 was switched on for X Layer after the last pass, and its
first mainnet firing was a small smoke test (below). 22 to 24 September.

## Timeline

| Dates | Builds | What landed |
| --- | --- | --- |
| 15 Sep | 3353 to 3384 | Terms for delegated execution under a mandate; the mandate authorization design request |
| 16 Sep | 3385 to 3401 | X Layer support in the product; the contracts pinned from this repository; the signer service; mandate persistence and reconciliation; the execution branch |
| 16 Sep | 3416 to 3422 | The application side of the generic executor: sizing with fee room, calldata builders, receipt decoding, the ERC-4626 rule |
| 17 Sep | 3423 to 3438 | The mandate core and compile step; Execute in the builder with review and signing; Execute agents in the list; attempts in history; limits changed in place; delete revokes; the redeployed contracts pinned; hourly batched ticks |
| 17 Sep | 3439 to 3462 | Check action; Describe-it fast path; scheduled execution; Tier 1 mandates in the builder; limits copy; MCP mandate proposals; prompt-injection hardening of the chat surfaces |
| 17 to 18 Sep | 3464 to 3478 | Owner notices rewritten; one retry then stop; the model-composed notice |
| 18 Sep | 3479 to 3508 | Agents page polish; execution notices on the home surface; revoke screen; price thresholds as conditions; the price cron retired; partner Prepare agents; keyless agent drafts |
| 19 to 21 Sep | 3511 to 3526 | Planner fixes found through real runs; the agent sizes its own firing and explains; per-member re-fire notices; builder polish |
| 21 Sep | 3527 to 3535 | Execute setup polish: expiry as a date in UTC, a back button that always works, the action first in the mandate box, the agent summary as When, Then, Notifies |
| 22 Sep | 3538 to 3552 | Keyless agent and mandate drafts over MCP, claimed on the setup page; the Shield reads in the public API spec |
| 22 Sep | 3544 to 3547 | Conditions: a gas-price trigger; a bare level takes its direction from the live reading; AND and OR grouping kept in the condition text |
| 22 Sep | 3557 to 3567 | Daily venue watch with a per-firing block; one failed-firing message per episode with a Prepare link; a team alert on reverts; the v1 trigger compiler (expression encoder, catalog ids, plan to tree); allowed venues in the builder and review behind the per-chain v1 switch |
| 23 Sep | 3579, and the v1 branch | A firing resized by the owner's instruction gets calldata for that amount. On the v1 branch: v1 artifacts pinned and the signed-settings encoders checked byte for byte against the contracts' own vectors; every action compiled for v1; the v1 setup screen and the review check; register, amend and record on the v1 core; the execute tick fires v1 mandates with a live venue check; the one-deploy guard |
| 24 Sep | 3580 to 3591, and the v1 branch | Any token by address; several outputs and the agent's pick; Unpriced swaps with the price-impact stop; repay from collateral in steps; fixes from the review passes; artifacts at each contract round |
| 24 Sep | 3592 to 3603 | v1 on X Layer mainnet (3592; 3593 fixed the database deploy typecheck); price triggers on the v0.1 core (3596); setup polish (3595, 3600); price triggers typed on the setup screen pinned on chain (3601); each condition and the wallet balance reach the agent's decision (3602); condition options read as conditions (3603) |

The application's `main` branch carried 170 commits from 16 September 12:05
to 21 September 11:17, 93 of them on the paths above. From 21 September
11:18 to 24 September 18:58 it carried 195 more commits (merges not
counted), 75 of them on the Shield paths listed under the next table.

## Size of the application-side work, non-test lines

At `main` on 24 September 18:58, build 3603.

| Area | Files | Lines |
| --- | --- | --- |
| Signer and chain port | 8 | 1,318 |
| Mandates and the compile step, shared by both cores | 19 | 3,816 |
| v1 compile, trigger compiler, review check and encoders | 13 | 1,919 |
| Execution branch, decision, sizing, notices, venue watch, and the mandate and run tables | 23 | 5,076 |
| HTTP routes | 12 | 799 |
| Mandate screens | 11 | 2,137 |
| Condition engine (shared with alerts) | 2 | 2,679 |
| Pinned artifacts generated from this repository (v0.1 and v1) | 2 | 7,549 |
| Tests and fixtures on the above | 50 | 6,709 |

Counted with `wc -l` on every file under `lib/shield/`, `app/api/shield/`,
`components/agents/mandate/` and `convex/shield*`, split by file name, plus
`lib/condition-plan.ts` and `lib/agents/compile-condition.ts` for the
condition engine. Test files (`*.test.*`), the compile fixture and the
encoder vectors count as tests. The table on the earlier version of this
page used a narrower set of files, so the two tables do not subtract.

## What it has done on mainnet

Every firing below was sized and sent by the application through a deployed
Shield core on X Layer (chain 196), with no person in the loop after the
owner signed the mandate. All were mined.

### v0.1 core

| When (UTC) | Path | Spent | Gas | Transaction |
| --- | --- | --- | --- | --- |
| 2026-09-17 08:35 | Tier 1 generic transfer: pinned recipient, no calldata | 0.002002 xETH | 173,933 | `0x4c2d52ea0f9d124cb6c440e738ea5c391c5dc95c89fc8848243dc05c30808f51` |
| 2026-09-17 08:35 | Tier 1 generic swap through the aggregator router, oracle rule | 0.012012 xETH | 538,845 | `0x8ce580ab7a85d009e8d8d7d76e7474bec16890f211676336c7e24009b97a3bfb` |
| 2026-09-17 08:36 | Tier 1 generic swap through the aggregator router, oracle rule | 1.001 USD₮0 | 571,190 | `0x6c2b72ca1b627c2633d32cf202bc64181deacf4857f046c86b2fc68e215bd9f0` |
| 2026-09-17 17:42 | Tier 2 Aave v3 supply through the adapter | 0.01001 xETH | 362,907 | `0xbef78b6900a4cfe557db99b9622b53c27d40d2a5d459b10aa32699147a55340e` |
| 2026-09-18 06:42 | Tier 2 Aave v3 supply through the adapter, the mandate's last slice | 0.00099 xETH | 287,118 | `0x9e79833d01d9cf0684950623d97576f1960e4122d183a35d56526d75e42e878e` |

For scale, ordinary swaps through the same aggregator router on X Layer over
sixty blocks on 18 September ranged from 182,343 to 1,484,630 gas with a
median of 637,031, so a fully bounded Tier 1 firing costs less than the
median hand-made swap on the same router. The same Aave supply on a fork
costs 566,213 gas through the executor and 361,515 through the adapter; the
difference is the price of generality.

### v1 core

The smoke test after the v1 deployment. The owner's wallet registered a
swap mandate from WOKB to USD₮0 at 15:24; the application's agent fired it
at 15:25.

| When (UTC) | Path | Spent | Received | Gas | Transaction |
| --- | --- | --- | --- | --- | --- |
| 2026-09-24 15:25 | Generic swap on the v1 core: a fresh sandbox, the aggregator router, output swept to the owner | 0.001001 WOKB (0.001 sold, 0.000001 fee) | 0.119465 USD₮0 | 706,590 | `0x68500884cebae48760de3e193081ec08a83d38940369a7ef44d3fed72426f4e1` |

The registration was `0x9784ed8820d1060c3cfc897881ca74a6c7e2a0b678b9a381071bfab55188d228`
(916,714 gas). Through block 71,507,517 these are the only mandate
transactions on the v1 core.

## Where the line is

The first design idea (bounded execution checked by post-conditions) and
the off-chain pieces this contract is built to serve (the intent schema, the encoder catalogue, receipt-token
handling, position unlocking, the alerting cron) existed before this
repository was started. Everything in this repository, and everything in the
tables above, was added from 15 September 2026 onward.
