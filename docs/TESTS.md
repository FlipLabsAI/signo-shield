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

The map from the boundary and accounting cases the v0.1 design commits to,
to the named test that exercises each one.

| Suite | File | What it runs against |
| --- | --- | --- |
| Core | `test/SignoShield.t.sol` | Local EVM, configurable mock adapter |
| Condition module | `test/ConditionModule.t.sol` | Local EVM |
| Compound evaluator | `test/CompoundCondition.t.sol` | Local EVM, mock target |
| Pluggable evaluators on the core | `test/SignoShieldEvaluators.t.sol` | Local EVM, listing, pinning, the dry-run through a compound |
| Generic executor | `test/GenericExecutor.t.sol` | Local EVM, mock router and oracle; the whole path through the real Shield |
| Generic executor, ERC-4626 rule | `test/GenericExecutor4626.t.sol` | Local EVM, mock vault with movable share price and a fee |
| Generic executor, X Layer | `test/fork/GenericExecutor.fork.t.sol` | Aave supply and a real aggregator swap through the sandbox on X Layer |
| Generic executor, sDAI | `test/fork/GenericExecutor4626.fork.t.sol` | Sky's sDAI on Ethereum mainnet, forked at latest (`MAINNET_RPC_URL`) |
| Aave adapter, X Layer | `test/fork/AaveV3Adapter.fork.t.sol` | Aave V3 on X Layer, block 70752723 |
| Aave adapter, aggregator router | `test/fork/AaveV3Adapter.okx.fork.t.sol` | Real aggregator calldata replayed on X Layer, block 70756518 |
| Aave adapter, Arbitrum | `test/fork/AaveV3Adapter.arbitrum.fork.t.sol` | Aave V3 on Arbitrum One, block 505617500 |
| Slippage arithmetic | `test/AaveV3AdapterMinOut.t.sol` | Local EVM, mocked oracle and tokens of any decimals |
| Deployment script | `test/fork/Deploy.fork.t.sol` | `Deploy.s.sol` end to end on the X Layer fork, then the hand-off |

### Rejection cases

| Case | Test | Expected |
| --- | --- | --- |
| Wrong borrower | `test_rejection_wrongBorrowerIsNotExpressible` (X Layer) | Not expressible: `fire` has no borrower parameter; a second borrower's debt does not move |
| Wrong action | `test_rejection_wrongActionIsPinned` (X Layer), `test_register_rejectsUnsupportedAction` (core) | A supply mandate never touches debt; an unimplemented action reverts `ActionNotSupported` at registration |
| Wrong asset | `test_rejection_wrongAssetIsPinned` (X Layer), `test_amend_cannotChangeWhoWhatOrWhich` (core) | Only the pinned asset moves; amendment onto another asset reverts `FieldImmutable("asset")` |
| Over the per-execution cap | `test_reason_overTxCap` (core), `test_repay_boundariesRevertWithTheirReasonCodes` (X Layer, Arbitrum) | `OVER_TX_CAP` |
| Cumulative spend over the lifetime cap | `test_reason_overCumulativeCap` (core), `test_repay_boundariesRevertWithTheirReasonCodes` (X Layer, Arbitrum) | `OVER_CUMULATIVE_CAP` after firings that were each under the per-execution cap |
| Trigger false | `test_reason_triggerNotMet_andMet` (core), `test_repay_repaysRealDebtForABorrowerThatIsNotTheCaller` (X Layer, Arbitrum) | `TRIGGER_NOT_MET`, including after the repay itself lifts the health factor past the trigger |
| Trigger unreadable | `test_trigger_unreadableRevertsInsteadOfDenying` (core), `ConditionModuleTest` | Reverts; never reported as a denial |
| After expiry | `test_reason_expired` (core), boundaries (X Layer, Arbitrum) | `EXPIRED` |
| After revocation | `test_reason_revoked` (core), boundaries (X Layer, Arbitrum) | `REVOKED` |
| After `freezeAgent` | `test_reason_agentFrozen_andUnfreezeRestores`, `test_roles_freezeReachesEveryMandateTheAgentHolds` (core), boundaries (X Layer, Arbitrum) | `AGENT_FROZEN`, for every mandate the agent holds; `unfreezeAgent` restores |
| Caller is not the agent | `test_reason_notAgent` (core), boundaries (X Layer, Arbitrum) | `NOT_AGENT`, for the principal and for a stranger |
| Fixed check order | `test_reason_orderIsFixed` (core) | The first failing check is the answer |
| Adapter called by anyone but the Shield | `test_adapter_onlyShield` (X Layer) | `NotShield` |
| Bad swap on repay-with-collateral | `test_repayWithCollateral_refusesABadSwap` (X Layer) | `SwapOutputBelowMinimum` (under the bound, or diverted), `SwapFailed`, `OutcomeFailed("health factor below target")`; nothing moved |
| Slice that would break the position | `test_repayWithCollateral_aaveRejectsASliceThatBreaksThePosition` (X Layer) | Aave's own `HealthFactorLowerThanLiquidationThreshold()` |
| Sale past the debt | `test_repayWithCollateral_refusesOversellingPastTheDebt` (X Layer) | `OutcomeFailed("sold more collateral than the debt needs")` beyond the slippage bound |
| Tokens parked on the adapter | `test_repayWithCollateral_parkedDustNeitherBlocksNorLoosens` (X Layer) | The firing goes through, the bound is unchanged, the parked tokens are untouched |
| Router or spender pointed at a token or protocol contract | `test_repayWithCollateral_configIsValidatedAtRegistration` (X Layer) | `ConfigInvalid("router")` / `ConfigInvalid("spender")` |
| Adapter revert of any kind | every wrapped case above | `OutcomeRejected(id, POSTCONDITION_FAILED, adapterError)` from the Shield, with the adapter's revert data attached |

### Accounting cases

| Case | Test | Expected |
| --- | --- | --- |
| Several executions under the per-execution cap that together exceed the lifetime cap | `test_reason_overCumulativeCap`, `testFuzz_fire_budgetNeverExceedsLifetime` (core), boundaries (X Layer, Arbitrum) | Refused at the cap; the counter never exceeds it and always equals what left the principal |
| Rollback on a failed outcome check | `test_fire_failedOutcomeRollsEverythingBack` (core), `test_repayWithCollateral_refusesABadSwap` (X Layer) | No funds moved, no budget used |
| Budget reconciled to actual spend | `test_fire_reconcilesBudgetToActualSpend`, `test_fire_adapterCannotReportMoreThanItGot` (core), `test_repay_clampsToTheDebtAndRefundsTheRest` (X Layer) | Unspent amount returns; counter equals what was spent |
| Changed token allowance mid mandate | `test_fire_allowanceChangeDoesNotResetBudget` (core), `test_accounting_allowanceChangedMidMandate` (X Layer) | A cut allowance fails the pull with nothing moved and no budget used; raising it hands back no budget |
| Attempt to alter the execution implementation of an active mandate | `test_amend_cannotChangeWhoWhatOrWhich`, `test_amend_andFire_survivesAdapterDelisting` (core), `test_accounting_executionImplementationCannotBeAltered` (X Layer) | `FieldImmutable("adapter")`; delisting reaches no live mandate |
| Reentrant firing | `test_fire_reentrantFiringIsRefused` (core) | The whole outer firing reverts |
| Fee | `test_fee_*` (core), `test_repay_takesTheLaunchFeeWhenARecipientIsSet`, `test_repayWithCollateral_takesTheFeeInATokens` (X Layer) | Stamped at registration, charged on what was spent, taken only with a recipient, worst case reserved against the lifetime cap |
| Partial sale on repay-with-collateral | `test_repayWithCollateral_partialSaleGoesBackIntoThePosition` (X Layer) | Only what was sold is spent; the rest of the slice is re-supplied, nothing lands in the wallet |
| Slippage bound across decimals | `AaveV3AdapterMinOutTest` (18→6, 8→6, 6→18, fuzz) | Linear in the amount, never above oracle parity, zero price refused |
| Deployment and hand-off | `DeployForkTest` | Adapter listed, fee and recipient set, enforcer armed, deployer is admin only until the owner accepts; owner cannot freeze or make itself an enforcer |
| Caller check as a view | `test_canFireBy_reportsTheCallerCheck` (core) | `canFireBy` answers `NOT_AGENT` for a stranger |
| Parity with the app's action plan | `test_parity_shieldRepayMatchesTheAppsActionPlan` (X Layer) | The user signing the app-built `Pool.repay` and the agent firing the mandate produce the same debt, wallet and health-factor deltas |

### The public script

`tools/demo-fork.sh` registers and fires a mandate against a local fork of X
Layer with nothing but Foundry and python3: anvil's development accounts play
deployer, user and agent; the demo wallet is funded from the Aave aToken
contracts; `script/Deploy.s.sol` deploys; `script/RegisterAndFire.s.sol` has
the user open a position and sign one mandate, then has the agent fire it, and
prints the debt, the health factor, `canFire` and the budget before and after.
The second `canFire` answers `TRIGGER_NOT_MET` (reason 10): the repay lifted
the health factor past the trigger, so the same mandate is refused.
