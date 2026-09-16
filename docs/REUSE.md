# Reuse and attribution

This file exists so that the line between reused work and Signo's own work is
readable without diffing anything. It is maintained by hand and reviewed before
each submission.

## Rule

Anything copied, adapted or depended upon is recorded here **before it lands**,
with its source, the pinned upstream revision, and its licence. A dependency
that is not in this file is not in the repository.

## Third-party code

**None.** No third-party contract code has been copied or adapted into this
repository. Everything under `contracts/` is original work.

If that changes, the entry goes in the table below before the code lands, with
the upstream path, the pinned upstream revision and the licence, and the
upstream notice is retained in the file header. A permissive licence at the
root of an upstream project does not make every file in it permissive, so file
headers and transitive dependencies are checked separately.

Public source is also not permission to call someone's production deployments.
Referencing a design and routing transactions through another protocol's
automation are different things, and only the first is free.

| This repo | Upstream file | Upstream commit | Licence | Notes |
|---|---|---|---|---|
| _(none)_ | | | | |

## Dependencies

| Dependency | Version / commit | Licence | Why |
|---|---|---|---|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | v5.7.0, commit `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` (pinned submodule) | MIT | `Ownable2Step` (the admin role), `ReentrancyGuard` (`fire`), `SafeERC20` (every token movement), `ERC20` in test mocks only. Inherited and imported, never copied. |
| [forge-std](https://github.com/foundry-rs/forge-std) | v1.9.6 (pinned submodule) | MIT / Apache-2.0 | Foundry's standard test and script library. Test-time only; no production bytecode depends on it. |

## What is Signo's own work

Everything under `contracts/`, `test/`, `script/` and `tools/` in this
repository is original. The core inherits OpenZeppelin's `Ownable2Step` and
`ReentrancyGuard` and uses `SafeERC20`, as listed above; no OpenZeppelin source
is copied into this tree. The design it implements — bounded execution with
post-conditions and a disposable clone, one generic condition module, pinned
adapters as the exception — is Signo's, and is described in
`docs/ARCHITECTURE.md`.
