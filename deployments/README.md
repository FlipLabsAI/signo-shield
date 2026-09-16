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
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast
python3 tools/export-artifacts.py --deployments
```

A `sourceCommit` ending in `-dirty` means the bytecode was built from a working
tree with uncommitted changes. That is a red flag on anything published.
