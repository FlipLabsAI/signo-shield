# Signo Shield

A bounded-execution contract for agent-driven DeFi. The owner signs a mandate;
an agent fires that mandate through the Shield; the contract enforces the
**bound** while the agent decides the **action**.

Funds stay in the owner's wallet. The agent never holds an allowance. Every
firing is measured against a post-condition on the owner's own balances, so
there is no calldata parser to fool.

Full design: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Status

**Core and Aave adapter built; not yet deployed.** The contracts enforce the
design in `docs/ARCHITECTURE.md`:

- `contracts/core/SignoShield.sol`: the mandate record, budget accounting,
  reason codes, amendment rules, revocation, the enforcer freeze and the
  adapter allowlist. FLIP-191.
- `contracts/core/ConditionModule.sol`: the one generic on-chain trigger.
- `contracts/adapters/aave-v3/AaveV3Adapter.sol`: `supply`, `repay` and
  `repayWithCollateral` against Aave V3, each with its outcome check. FLIP-192.

Unit tests cover every reason code and rejection path with mocks. Fork tests
run the adapter against the real Aave V3 market on X Layer at a pinned block,
where an agent repays real debt for a borrower that is not the caller and every
boundary case reverts with its reason code. See [Build and test](#build-and-test).

Not built: the Tier 1 bounded executor (research scope), the execution signer,
the app integration. Nothing is deployed; `deployments/manifest.json` is empty.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).
Nothing else: no private registry, no API keys, no database.

```bash
git clone --recursive https://github.com/FlipLabsAI/signo-shield
cd signo-shield
forge build
forge test
```

If you cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

`forge test` runs the unit suites and the X Layer fork suites. The fork suites
read the public X Layer RPC at pinned blocks; set `XLAYER_RPC_URL` to use
another endpoint, and `forge test --no-match-path "test/fork/*"` to skip them
offline. One fork test replays real OKX DEX aggregator calldata through the
adapter (`test/fork/AaveV3Adapter.okx.fork.t.sol`); the calldata is pinned in
the test, and `tools/okx-fixture.py` regenerates it with an OKX API key. `forge lint` and Slither (`slither .`) both run clean of anything
that is not a documented design choice; the triage is in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#static-analysis).

## Layout

```
contracts/core/        the Shield, the condition module and the interfaces
contracts/adapters/    Tier 2 pinned adapters — one per protocol, see the README there
test/                  unit suites, test/mocks, and test/fork for pinned-chain suites
script/                deployment script
abi/                   generated ABIs, checked in so they can be read without the toolchain
deployments/           manifest keyed by chain id, generated from broadcast files
docs/                  architecture, and the reuse and attribution record
tools/                 artifact export
```

## Artifacts

ABIs and the deployments manifest are generated, never written by hand:

```bash
forge build
python3 tools/export-artifacts.py               # ABIs into abi/
python3 tools/export-artifacts.py --deployments # plus deployments/manifest.json
```

CI fails if `abi/` is stale, because a submission that ships an ABI which does
not match its bytecode is worse than one that ships none.

## What pre-existed this event, and what was added

Stated plainly, because the submission rules ask for it.

**Pre-existed.** The design in `docs/ARCHITECTURE.md` — bounded execution with
post-conditions and a disposable clone, one generic condition module, pinned
adapters as the exception, and the four grant shapes it has to live with — was
worked out by Flip Labs before the event and is recorded in our internal
tracker. The off-chain half that this contract is built to serve also
pre-existed: the intent schema, the encoder catalogue, receipt-token handling,
position unlocking and the alerting cron all live in Flip Labs' main
application and are not part of this repository.

**Added during the event.** Everything in this repository: the Foundry project,
the interfaces as written here, the contracts, the tests, the deployment
script, the artifact export and CI.

**Reused from third parties.** OpenZeppelin Contracts v5.7.0 (MIT) for
`Ownable2Step`, `ReentrancyGuard` and `SafeERC20`, and forge-std as a test-time
dependency. No third-party contract code has been copied or adapted.
[`docs/REUSE.md`](docs/REUSE.md) records both, and is where any future
third-party code is listed with its upstream source, pinned revision, licence
and retained notice before it lands.

## Licence

MIT. See [`LICENSE`](LICENSE).
