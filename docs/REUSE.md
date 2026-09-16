# Reuse and attribution

This file exists so that the line between reused work and Signo's own work is
readable without diffing anything. It is maintained by hand and reviewed before
each submission.

## Rule

Anything copied, adapted or depended upon is recorded here **before it lands**,
with its source, the pinned upstream revision, and its licence. A dependency
that is not in this file is not in the repository.

## Reference implementation

[defisaver/defisaver-v3-contracts](https://github.com/defisaver/defisaver-v3-contracts)
is the implementation reference for this project.

- Root licence: MIT. It permits use, modification and distribution provided the
  copyright and permission notices are retained.
- Individual file headers and transitive dependency licences are checked
  separately from the root licence, because a permissive root does not make
  every file in a tree permissive.
- **No DeFi Saver code has been copied into this repository yet.** When any is,
  it is listed in the table below with the file path, the upstream path and the
  pinned commit, and the upstream notice is retained in the file header.
- Public source is not permission to route transactions through DeFi Saver's
  production automation. Their Strategy Executor entry point is BotAuth gated.
  We reference the design; we do not call their deployments.

| This repo | Upstream file | Upstream commit | Licence | Notes |
|---|---|---|---|---|
| _(none yet)_ | | | | |

## Dependencies

| Dependency | Version / commit | Licence | Why |
|---|---|---|---|
| [forge-std](https://github.com/foundry-rs/forge-std) | v1.9.6 (pinned submodule) | MIT / Apache-2.0 | Foundry's standard test and script library. Test-time only; no production bytecode depends on it. |

## What is Signo's own work

Everything under `contracts/`, `test/`, `script/` and `tools/` in this
repository is original unless the table above says otherwise. The design it
implements — bounded execution with post-conditions and a disposable clone, one
generic condition module, pinned adapters as the exception — is Signo's, and is
described in `docs/ARCHITECTURE.md`.
