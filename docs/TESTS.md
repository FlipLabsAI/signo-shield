# Tests, and what each one proves

The public repository has to prove the rules, not describe them. `forge test`
runs 499 tests in 49 suites: 296 for Shield v1 and 203 for v0.1. Most
refusals assert the specific reason code or error, not only that a call
reverted. The fork suites read public archive endpoints at pinned blocks
(`XLAYER_RPC_URL`, `ARBITRUM_RPC_URL` and `MAINNET_RPC_URL` override them);
`forge test --no-match-path "test/fork/*"` skips them offline.

## Shield v1

| Suite | Files | Tests | What it runs against |
| --- | --- | --- | --- |
| Core | `test/v1/ShieldV1.t.sol` | 21 | Local EVM, mock executor and read catalog |
| Expression evaluator | `test/v1/ExpressionEvaluator.t.sol` | 18 | Local EVM, pinned Chainlink-style prices |
| Generic executor | `test/v1/GenericExecutorV1.t.sol` | 31 | Local EVM, mock venues, oracle and tokens of any decimals |
| Claim executor | `test/v1/ClaimExecutorV1.t.sol` | 14 | Local EVM, mock reward venues |
| Aave adapter, X Layer | `test/fork/AaveV3AdapterV1.fork.t.sol` | 9 | Aave V3 on X Layer, real debt and collateral |
| Generic executor, X Layer | `test/fork/GenericExecutorV1*.fork.t.sol` | 10 | The real Aave pool, a real aggregator route replayed from the sandbox, several outputs with real tokens and real price rounds |
| Claims, X Layer | `test/fork/ClaimExecutorV1.pendle.fork.t.sol` | 3 | A real Pendle reward claim |
| Deployment script | `test/fork/DeployV1.fork.t.sol` | 1 | `DeployV1.s.sol` end to end on the X Layer fork, then the hand-off |
| Review rounds | `test/review/V1*.t.sol` | 189 | The independent reviewer's own tests, imported as written |

### How review findings become tests

The reviewer writes a Foundry test for every gap it finds. We import the
test under `test/review/` unchanged, fix the code, and rename the gap test to
`test_fix...`, which now expects the refusal. The reviewer's control tests
(the honest case still works) stay as they are. So each fix is pinned by a
test that fails on the old code. The story of each round is in
[`DESIGN-HISTORY.md`](DESIGN-HISTORY.md).

### Selected v1 cases

| Case | Test | Expected |
| --- | --- | --- |
| Spend over the amount, measured or reported | `test_spendRuleRevertsOnExcessMeasurementAndExcessReport` | The firing reverts |
| Unspent amount | `test_fireUnspentIsRefundedAndOnlySpentIsCharged` | Returned to the owner; only the spend counts against the caps |
| Fee above the owner's signed maximum | `test_registerStampsFeeAndRefusesAboveMax` | Registration refused |
| A failed attempt | `test_failedAttemptLeavesNoBookkeeping` | No budget used, nothing recorded |
| Revocation by signature | `test_revokeWithSigEOA`, `test_revokeWithSigContractWallet` | Revoked for a plain wallet and for a contract wallet |
| Halt and restoration | `test_haltEpochsQueuedRestorationAndDelay` | A halt stops every firing at once; restoring needs the queue and the delay |
| A call to a venue the owner did not sign | `test_venueNotInMandateAndBlockedVenueAreRefused` | Refused, as is a suspended venue |
| An approval on a token the mandate never named, or a venue that pulls from the owner | `test_approveTokenMustBeAssetOrSweepSetAndOwnerTokensAreOutOfReach` | Reverts; the owner never approves a venue, so there is nothing to pull |
| Swap below the signed value | `test_transformRejectsBelowMinimumAndRollsBack` | Reverts; nothing left the owner |
| Several outputs, loss on any route | `test_r12_aLossIsRefusedWhicheverOutputTheRouteChose`, `test_r12f_theBoundIsOnTheTotalNotEachLeg` | Refused on the total value, whichever output arrived |
| A stale price round | `test_r12f_aStaleRoundOnAnyOutputStopsTheFiring` | Refused |
| Nothing signed arrives (only dust, or only a token the mandate did not sign) | `test_r12f_dustOrAnUnsignedTokenIsNothing`, `test_r14_unpricedRefusesAFiringWhereNothingArrives` | `OutputBelowMinimum`; the owner's balance is unchanged |
| No price check: caps are the bound | `test_r14_theSignedCapsAreTheLossBound` | The caps hold; a firing over them is refused |
| Oracle bound at odd decimals | `test_r15_theOracleBoundIsExactAt6And18Decimals` | One raw unit under the bound is refused; the next passes |
| Repay from collateral near a health factor of 1 | `test_fixNearOneFiringsStepToTheTarget` | Firings step the position to the target |
| Repay from collateral at the target | `test_fixAtTheTargetTheAdapterRefuses` | Refused, no fee |
| Health factor trigger with no debt | `test_healthFactorTriggerRegistersForAWalletWithNoDebt` | Registers; "no debt" reads above every limit |
| A claim that pays less than owed | `test_aVenuePayingLessThanClaimableIsRefused` | Refused |
| Fee refund with aToken rounding | `testFuzz_fixFeeRefundSurvivesScaledTokenRounding` | Never reverts; a one-unit shortfall comes from the fee, not the owner |
| Unreadable read | `test_shortReturnAndGasExhaustionRevert`, `test_divByZeroAndOverflowRevertNeverFalse` | Reverts; never read as "false" |

## Shield v0.1

The first-generation contracts (`contracts/core/`, `contracts/executors/`,
`contracts/adapters/`) stay in the repository with their 203 tests: unit
suites under `test/`, fork suites on X Layer, Arbitrum One and Ethereum
mainnet under `test/fork/`, and four review suites
(`test/review/ReviewRound1.t.sol` to `ReviewRound4.t.sol`).
