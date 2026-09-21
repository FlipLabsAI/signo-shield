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
run the adapter against the real Aave V3 markets on X Layer and Arbitrum One
at pinned blocks, where an agent repays real debt for a borrower that is not
the caller, every boundary case reverts with its reason code, real OKX
aggregator calldata is replayed through the swap leg, and the Shield firing is
shown to do exactly what the app's own action plan does. See
[Build and test](#build-and-test) and [`docs/TESTS.md`](docs/TESTS.md).

Not built: the Tier 1 bounded executor (research scope), the execution signer,
the app integration. Deployed on X Layer (chain 196); `deployments/manifest.json` carries the addresses and the source commit, and `docs/TRUST.md` states what each party can and cannot do.

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

`forge test` runs the unit suites and the fork suites: Aave V3 on X Layer at
a pinned block, the same through the real OKX DEX aggregator router with
replayed calldata, Aave V3 on Arbitrum One, and the deployment script itself. The fork suites read public
archive endpoints; `XLAYER_RPC_URL` and `ARBITRUM_RPC_URL` override them, and
`forge test --no-match-path "test/fork/*"` skips them offline.
[`docs/TESTS.md`](docs/TESTS.md) maps every boundary and accounting case to
its named test. `tools/okx-fixture.py` regenerates the OKX calldata with an
OKX API key; the suite itself needs none.

## Run the demo on a fork

```bash
tools/demo-fork.sh
```

Starts a local fork of X Layer, funds a demo wallet, deploys the contracts,
has the user open a small Aave position and sign one mandate, and has the
agent fire it. Prints the debt, the health factor, `canFire` and the budget
before and after; the second `canFire` is refused because the repay lifted the
health factor past the trigger. Needs Foundry (anvil, forge, cast) and
python3, nothing else. `forge lint` and Slither (`slither .`) both run clean of anything
that is not a documented design choice; the triage is in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#static-analysis).

## Layout

```
contracts/core/        the Shield, the condition module and the interfaces
contracts/adapters/    Tier 2 pinned adapters — one per protocol, see the README there
test/                  unit suites, test/mocks, and test/fork for pinned-chain suites
script/                deployment script, and the register-and-fire demo script
tools/                 artifact export, the fork demo, the OKX fixture generator
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

CI fails if `abi/` is stale, because a public repository that ships an ABI which
does not match its bytecode is worse than one that ships none.

## What pre-existed this repository, and what was added

What the application does around this contract, when it was built, and what it has done on mainnet, is in `docs/APP-SIDE.md`.

Stated plainly, so provenance can be read without asking.

**Pre-existed.** The design in `docs/ARCHITECTURE.md` — bounded execution with
post-conditions and a disposable clone, one generic condition module, pinned
adapters as the exception, and the four grant shapes it has to live with — was
worked out by Flip Labs before this repository was started and is recorded in
our internal tracker. The off-chain half that this contract is built to serve also
pre-existed: the intent schema, the encoder catalogue, receipt-token handling,
position unlocking and the alerting cron all live in Flip Labs' main
application and are not part of this repository.

**Added in this repository.** Everything in it: the Foundry project,
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
