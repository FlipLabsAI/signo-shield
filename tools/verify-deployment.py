#!/usr/bin/env python3
"""Verify that a broadcast deployment is exactly what a given commit's deploy
script produces, and record the result for deployments/provenance.json.

Written 30 Sep 2026 for the Arbitrum One deployment, which was broadcast from
commit f3aa7d3 with DeployV1.s.sol modified in the working tree; the script
that ran was committed afterwards as fb2d7e0. Foundry recorded f3aa7d3. This
tool does not trust either claim: it replays the deploy script at the claimed
commit and compares.

Two independent checks:

  1. Replay. Export `--script-commit` into a temporary directory (git
     archive, plus this checkout's submodules, which must sit at the commit's
     pins), build it, and run the deploy script as a dry run on a fork of the chain one block
     before the deployment's first transaction, from the same sender, with the
     same parameters. Every transaction the replay produces (from, to, value,
     nonce, calldata or init code) must equal the broadcast's, in order.
  2. Bytecode. For every contract the broadcast created (including those made
     inside a constructor), the runtime code on chain must equal the build at
     `--script-commit`, with the immutable slots masked (their values are the
     constructor arguments, which check 1 covers).

Any RPC failure or difference exits non-zero. On success it prints a JSON
record for deployments/provenance.json (block number and hash included, so the
result can be reproduced and reviewed).

    python3 tools/verify-deployment.py \\
      --run broadcast/DeployV1.s.sol/42161/run-1790793916113.json \\
      --script-commit fb2d7e0 \\
      --env SHIELD_OWNER=0x0330Bda68a6254e7a71222A381A40Db60c13D9aa --env SHIELD_FEE_BPS=10

The RPC comes from $VERIFY_RPC_URL (kept off the command line; it usually
carries a key) and must serve historical state at the fork block (an archive
endpoint). Output never prints it.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = "script/DeployV1.s.sol:DeployV1"
FORGE = os.environ.get("FORGE") or shutil.which("forge") or str(pathlib.Path.home() / ".foundry/bin/forge")


def rpc(method: str, params: list) -> object:
    req = urllib.request.Request(RPC_URL, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), headers={"Content-Type": "application/json"})
    try:
        body = json.load(urllib.request.urlopen(req, timeout=60))
    except Exception as error:  # any transport failure refuses; the URL stays out of the message
        sys.exit(redact(f"rpc {method}: {error}"))
    if "error" in body or body.get("result") is None:
        sys.exit(redact(f"rpc {method}: {body.get('error', 'no result')}"))
    return body["result"]


RPC_URL = os.environ.get("VERIFY_RPC_URL", "")


def redact(text: str) -> str:
    return text.replace(RPC_URL, "<rpc>") if RPC_URL else text


def run(cmd: list[str], cwd: pathlib.Path, env: dict | None = None, stdin: bytes | None = None) -> str:
    out = subprocess.run(cmd, cwd=cwd, env=env, input=stdin, capture_output=True)
    if out.returncode != 0:
        sys.exit(redact(f"{' '.join(cmd[:2])} failed:\n{out.stdout.decode(errors='replace')[-2000:]}\n{out.stderr.decode(errors='replace')[-2000:]}"))
    return out.stdout.decode()


def export(commit: str, dest: pathlib.Path) -> None:
    """The commit's tree in `dest`, with this checkout's submodules (pins checked)."""
    archive = subprocess.run(["git", "archive", "--format=tar", commit], cwd=ROOT, capture_output=True, check=True).stdout
    run(["tar", "-x", "-C", str(dest)], ROOT, stdin=archive)
    for line in run(["git", "ls-tree", "-r", commit], ROOT).splitlines():
        meta, path = line.split("\t", 1)
        _, kind, pin = meta.split()
        if kind != "commit":
            continue
        have = run(["git", "-C", str(ROOT / path), "rev-parse", "HEAD"], ROOT).strip()
        if have != pin:
            sys.exit(f"{path} is at {have[:12]} here, {commit[:12]} pins {pin[:12]}: check it out first")
        shutil.rmtree(dest / path, ignore_errors=True)
        shutil.copytree(ROOT / path, dest / path, symlinks=True, ignore=shutil.ignore_patterns(".git"))


def norm(v: object) -> str:
    return str(v or "").lower()


def masked(code: str, refs: dict) -> str:
    """Runtime code as hex with every immutable slot zeroed."""
    b = bytearray(bytes.fromhex(code[2:] if code.startswith("0x") else code))
    for slots in refs.values():
        for s in slots:
            b[s["start"]:s["start"] + s["length"]] = b"\0" * s["length"]
    return b.hex()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run", required=True, help="the broadcast run file (not run-latest.json)")
    ap.add_argument("--script-commit", required=True, help="the commit whose deploy script is claimed to have produced it")
    ap.add_argument("--env", action="append", default=[], help="a deploy parameter, NAME=value (repeatable)")
    args = ap.parse_args()
    if not RPC_URL:
        sys.exit("set VERIFY_RPC_URL to an archive RPC of the chain")

    run_file = (ROOT / args.run).resolve()
    data = json.loads(run_file.read_text())
    chain = int(data["chain"])
    txs = data["transactions"]
    receipts = data.get("receipts", [])
    if not txs or len(receipts) != len(txs) or any(r.get("status") != "0x1" for r in receipts):
        sys.exit("the run file must hold every transaction with a successful receipt")
    first_block = min(int(r["blockNumber"], 16) for r in receipts)
    fork_block = first_block - 1
    sender = txs[0]["transaction"]["from"]
    chain_id = int(rpc("eth_chainId", []), 16)
    if chain_id != chain:
        sys.exit(f"the RPC serves chain {chain_id}, the run is chain {chain}")
    fork = rpc("eth_getBlockByNumber", [hex(fork_block), False])
    script_commit = run(["git", "rev-parse", args.script_commit], ROOT).strip()

    tmp = pathlib.Path(tempfile.mkdtemp(prefix="shield-verify-"))
    try:
        export(script_commit, tmp)
        env = {**os.environ, **dict(e.split("=", 1) for e in args.env)}
        run([FORGE, "build"], tmp, env)
        run([FORGE, "script", SCRIPT, "--fork-url", RPC_URL, "--fork-block-number", str(fork_block), "--sender", sender], tmp, env)
        dry = json.loads((tmp / "broadcast" / "DeployV1.s.sol" / str(chain) / "dry-run" / "run-latest.json").read_text())
        replay = dry["transactions"]

        # 1. Replay: the same transactions, in order.
        if len(replay) != len(txs):
            sys.exit(f"replay produced {len(replay)} transactions, the broadcast has {len(txs)}")
        for i, (a, b) in enumerate(zip(txs, replay)):
            ta, tb = a["transaction"], b["transaction"]
            for field in ("from", "to", "value", "input", "nonce"):
                if norm(ta.get(field)) != norm(tb.get(field)):
                    sys.exit(f"transaction {i}: {field} differs between the broadcast and the replay at {script_commit[:12]}")

        # 2. Bytecode: every created contract, immutables masked.
        created: list[tuple[str | None, str, str]] = []
        for t in txs:
            if t.get("transactionType") == "CREATE":
                created.append((t.get("contractName"), t["contractAddress"], t["transaction"]["input"]))
            for extra in t.get("additionalContracts") or []:
                created.append((None, extra["address"], extra.get("initCode") or ""))
        artifacts = {}
        for path in (tmp / "out").rglob("*.json"):
            try:
                j = json.loads(path.read_text())
            except json.JSONDecodeError:
                continue
            if j.get("deployedBytecode", {}).get("object"):
                artifacts[path.stem] = j
        results = []
        for name, address, init in created:
            if name is None:
                # A contract made inside a constructor: the artifact whose creation code prefixes its init code.
                name = next((n for n, j in artifacts.items() if len(j["bytecode"]["object"]) > 4 and norm(init).startswith(norm(j["bytecode"]["object"]))), None)
                if name is None:
                    sys.exit(f"{address}: no artifact matches its init code")
            art = artifacts[name]
            refs = art["deployedBytecode"].get("immutableReferences") or {}
            onchain = rpc("eth_getCode", [address, "latest"])
            if masked(onchain, refs) != masked(art["deployedBytecode"]["object"], refs):
                sys.exit(f"{name} {address}: runtime code on chain differs from the build at {script_commit[:12]}")
            results.append({"contract": name, "address": address, "runtimeMatch": "exact, immutables masked"})
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print(json.dumps({
        "chain": chain,
        "run": args.run,
        "broadcastCommit": data.get("commit"),
        "deployScriptCommit": script_commit,
        "parameters": dict(e.split("=", 1) for e in args.env),
        "verification": {
            "tool": "tools/verify-deployment.py",
            "forkBlock": fork_block,
            "forkBlockHash": fork["hash"],
            "firstDeployBlock": first_block,
            "transactionsMatched": len(txs),
            "contracts": results,
            "verifiedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        },
    }, indent=2))


if __name__ == "__main__":
    main()
