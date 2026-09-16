# Signo Shield

A bounded-execution contract for agent-driven DeFi. The owner signs a mandate;
an agent fires that mandate through the Shield; the contract enforces the
**bound** while the agent decides the **action**.

Funds stay in the owner's wallet. The agent never holds an allowance. Every
firing is measured against a post-condition on the owner's own balances, so
there is no calldata parser to fool.

Full design: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Status

**This repository is a scaffold.** `contracts/core/SignoShield.sol` compiles,
deploys and reverts `NotImplemented` on every entry point. The interfaces in
`contracts/core/interfaces/` carry the agreed design; the enforcement logic
lands in the tickets that follow.

A scaffold that half-enforced a bound would be worse than one that plainly
refuses, because a half-enforced bound reads as protection.

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

## Layout

```
contracts/core/        the Shield and its interfaces
contracts/adapters/    Tier 2 pinned adapters — the exception, see the README there
test/                  Foundry tests
script/                deployment scripts
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

**Reused from third parties.** Recorded in [`docs/REUSE.md`](docs/REUSE.md),
with the upstream source, the pinned revision and the licence for each entry.
[DeFi Saver](https://github.com/defisaver/defisaver-v3-contracts) is the
implementation reference for this project; no code has been copied from it at
the time of writing, and anything copied later is listed there with its notice
retained.

## Licence

MIT. See [`LICENSE`](LICENSE).
