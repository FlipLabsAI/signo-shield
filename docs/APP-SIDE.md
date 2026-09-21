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

**Pins the deployed contracts.** The deployment manifest and ABIs exported by
this repository (`deployments/manifest.json`, `abi/`) are checked into the
application and covered by a test, so the application cannot drift from the
verified addresses. Re-pinned to the 17 September redeploy in build 3438.

**Signs and sends.** One service submits every transaction. The agent key is
held in a key-management service and never in the application. Each firing
is simulated before it is sent, one transaction is in flight per agent,
retries are bounded, receipts are reconciled into a ledger, and there is a
kill switch plus an environment hard stop. Builds 3388 to 3394, 16 September.

**Keeps a copy of every mandate from the chain, not from itself.** The
application's record of a mandate is written only from a chain read and
re-read on a schedule; every difference is surfaced, never absorbed. Build
3395, 16 September.

**Fires mandates when their conditions hold.** An agent armed by an on-chain
mandate checks its condition on an hourly tick, batched per chain, sizes a
firing from the live position, builds the calldata (for a swap, through the
OKX DEX aggregator, checked against the router pinned in the mandate), sends
it through the signer, decodes the receipt into the run record, and tells
the owner. One retry per failure; then the owner is told the run has
stopped. Builds 3400 to 3478, 16 to 18 September.

**Lets an owner create, review, sign, change and revoke a mandate.** The
agent builder has an Execute mode: the owner describes the action, the
application compiles it into exactly one enforceable mandate, a question, or
a refusal, shows the review (what the mandate enforces: when, then, and the
constraints), and hands the registration to the owner's wallet to sign.
Limits can be changed in place; deleting the agent revokes the mandate from
the wallet; the revoke screen reads and shows the remaining allowance. Tier 1
mandates (transfer, swap, vault deposit) and scheduled execution (the clock
as a condition) are built the same way. Builds 3423 to 3526, 17 to 21
September.

**Sizes and explains from the agent.** The execute tick's sizing moved into
the agent, with its reasons carried into the owner's notice. The agent
follows the owner's orders and does not form views of its own. Builds 3515
to 3522, 20 September.

**Writes to the owner in plain words.** Every message an owner receives
about a firing is composed from a fact sheet, rephrased by a small language
model with the deterministic text as the fallback, and validated so no fact
is dropped or invented. Builds 3464 to 3478, 17 and 18 September.

**Prepares mandates through MCP and a partner API.** An outside agent can
prepare a mandate proposal that the owner then reviews and signs in the
Signo application. Builds 3452 to 3508, 17 and 18 September.

**Runs the same conditions for alerts and for execution.** A price threshold,
a health factor, a yield, a schedule: one condition engine, read from the
same cached data, feeds both the notify path and the execute path. Builds
3494 to 3499, 18 September.

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

The application's `main` branch carried 170 commits from 16 September 12:05
to 21 September 11:17, 93 of them on the paths above.

## Size of the application-side work, non-test lines

| Area | Files | Lines |
| --- | --- | --- |
| Signer and chain port | 7 | 1,159 |
| Mandates and the compile step | 12 | 3,218 |
| Execution branch, sizing, notices | 13 | 2,903 |
| HTTP routes | 10 | 671 |
| Agent builder and mandate screens | 17 | 3,447 |
| Condition engine | 3 | 2,644 |
| Pinned artifacts generated from this repository | 2 | 2,569 |
| Tests on the above | 29 | 3,742 |

## What it has done on mainnet

Every firing below was sized and sent by the application through the
deployed Shield on X Layer (chain 196), with no person in the loop after the
owner signed the mandate. All were mined.

| When (UTC) | Path | Spent | Gas | Transaction |
| --- | --- | --- | --- | --- |
| 2026-09-17 08:35 | Tier 1 generic transfer: pinned recipient, no calldata | 0.002002 xETH | 173,933 | `0x4c2d52ea0f9d124cb6c440e738ea5c391c5dc95c89fc8848243dc05c30808f51` |
| 2026-09-17 08:35 | Tier 1 generic swap through the OKX router, oracle rule | 0.012012 xETH | 538,845 | `0x8ce580ab7a85d009e8d8d7d76e7474bec16890f211676336c7e24009b97a3bfb` |
| 2026-09-17 08:36 | Tier 1 generic swap through the OKX router, oracle rule | 1.001 USD₮0 | 571,190 | `0x6c2b72ca1b627c2633d32cf202bc64181deacf4857f046c86b2fc68e215bd9f0` |
| 2026-09-17 17:42 | Tier 2 Aave v3 supply through the adapter | 0.01001 xETH | 362,907 | `0xbef78b6900a4cfe557db99b9622b53c27d40d2a5d459b10aa32699147a55340e` |
| 2026-09-18 06:42 | Tier 2 Aave v3 supply through the adapter, the mandate's last slice | 0.00099 xETH | 287,118 | `0x9e79833d01d9cf0684950623d97576f1960e4122d183a35d56526d75e42e878e` |

For scale, ordinary swaps through the same OKX router on X Layer over sixty
blocks on 18 September ranged from 182,343 to 1,484,630 gas with a median of
637,031, so a fully bounded Tier 1 firing costs less than the median
hand-made swap on the same router. The same Aave supply on a fork costs
566,213 gas through the executor and 361,515 through the adapter; the
difference is the price of generality.

## Where the line is

The design in `docs/ARCHITECTURE.md` and the off-chain pieces this contract
is built to serve (the intent schema, the encoder catalogue, receipt-token
handling, position unlocking, the alerting cron) existed before this
repository was started. Everything in this repository, and everything in the
tables above, was added from 15 September 2026 onward.
