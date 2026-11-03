# Deployments

`manifest.json` is generated, never hand-edited. It is written by
`tools/export-artifacts.py --deployments`, which reads Foundry's own broadcast
files, so an address is always tied to the transaction that created it and to
the source commit the bytecode was built from.

Shape:

```json
{
  "deployments": {
    "<chainId>": [
      {
        "contract": "SignoShield",
        "address": "0x…",
        "deployTx": "0x…",
        "sourceCommit": "<git sha>",
        "timestamp": 1758000000
      }
    ]
  }
}
```

Keyed by chain id rather than by a network name, because a name is ambiguous
across testnets and a chain id is not.

To record a deployment:

```bash
forge script script/DeployV1.s.sol:DeployV1 --rpc-url "$RPC_URL" --broadcast   # Shield v1
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast       # v0.1
python3 tools/export-artifacts.py --deployments
```

A `sourceCommit` ending in `-dirty` means the bytecode was built from a working
tree with uncommitted changes. That is a red flag on anything published.

## Admin

The admin of every Shield contract is a 2 of 3 Safe,
`0xFC6EFFC12D8CF67eD135090C6c530FD72b204172` (Safe 1.5.0, the same address on X Layer
and Arbitrum). That covers both v1 registries (each v1 core reads its
registry's `owner()`) and the three v0.1 cores on X Layer. The Safe took over
from the deploy owner `0x0330Bda68a6254e7a71222A381A40Db60c13D9aa` on
3 November 2026 through `Ownable2Step`: `transferOwnership` from the deploy
owner, then `acceptOwnership` from the Safe with two signatures.

| Chain | Contracts | Accepted by the Safe |
| --- | --- | --- |
| X Layer (196) | registry `0xE87b50B7E3e996a0C60B4a24221FE44B4277272A`; v0.1 cores `0x8a07b505da63f2fd0a17beb78e906f2f9b42b4b4`, `0x9331264a9e1c0573d920cd8403031cc9761ac60a`, `0xc9f83d96ee711c06de80a532785d3baea966de97` | `0x1cba96643759bd8def3da66511c717ee4e88975b2f045eb6257bcce1b7b92f89` (one batch) |
| Arbitrum One (42161) | registry `0xE0377C8C1742FCbe885E99d8d746F56eE7982f6F` | `0x8774064818db206d728223cf09c72893d95805cada3e4550b273bbf3aea4e2c6` |

On Arbitrum, `0x9331…c60a` and `0xc9f8…de97` are v1 contracts (the
ClaimExecutorV1 and the ShieldV1 core). Only the X Layer contracts at those
addresses are v0.1.

`provenance.json` keeps `SHIELD_OWNER` as the deploy-time input. The live owner
is the Safe.

## v0.1 retirement

On 3 November 2026, before the handover, the deploy owner delisted the v0.1
adapters on X Layer (`setAdapter(adapter, false)` on the three cores), so no
new v0.1 permission can be registered. The last open v0.1 permission cannot
fire: `canFire` returns `INSUFFICIENT_ALLOWANCE`, because its owner's token
allowance to the core is zero. v0.1 has no pause, and renouncing ownership is
blocked, so the Safe stays the owner.
