#!/usr/bin/env python3
"""Export what a reader needs without running the toolchain.

Two outputs, both checked in:

  abi/<Contract>.json         the generated ABI for every contract we author
  deployments/manifest.json   chainId -> [{contract, address, deployTx, sourceCommit, ...}]

The manifest is built from Foundry's own broadcast files rather than from
anything typed by hand, because a deployment record that someone copied by hand
is a deployment record that is wrong eventually. `sourceCommit` is the commit
the bytecode was built from, so an address can always be tied back to source.

Usage:
    forge build
    python3 tools/export-artifacts.py                 # ABIs only
    python3 tools/export-artifacts.py --deployments   # ABIs + manifest from broadcast/
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "out"
ABI_DIR = ROOT / "abi"
MANIFEST = ROOT / "deployments" / "manifest.json"
# Verified corrections to what a broadcast recorded, one record per run file,
# matched by the file's hash (see tools/verify-deployment.py).
PROVENANCE = ROOT / "deployments" / "provenance.json"
# Only contracts we author. Test helpers and forge-std are not part of the
# public surface and must not leak into abi/.
SOURCE_DIRS = ("contracts/",)


def source_commit() -> str:
    try:
        rev = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True)
        dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True, check=True)
        return rev.stdout.strip() + ("-dirty" if dirty.stdout.strip() else "")
    except Exception:
        return "unknown"


def full_sha(short: str | None) -> str | None:
    """Foundry stores the short commit; the manifest carries the full one."""
    if not short:
        return None
    try:
        return subprocess.run(["git", "rev-parse", "--verify", f"{short}^{{commit}}"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return short


def export_abis() -> list[str]:
    if not OUT.is_dir():
        sys.exit("out/ not found — run `forge build` first")
    ABI_DIR.mkdir(exist_ok=True)
    written: list[str] = []
    for artifact in sorted(OUT.rglob("*.json")):
        try:
            data = json.loads(artifact.read_text())
        except json.JSONDecodeError:
            continue
        target = (data.get("metadata") or {}).get("settings", {}).get("compilationTarget") or {}
        if not any(path.startswith(SOURCE_DIRS) for path in target):
            continue
        abi = data.get("abi")
        if abi is None:
            continue
        name = artifact.stem
        (ABI_DIR / f"{name}.json").write_text(json.dumps(abi, indent=2) + "\n")
        written.append(name)
    return written


def provenance_by_run_hash() -> dict[str, dict]:
    """The verified provenance records, keyed by the sha256 of their run file.

    A record applies only to the exact broadcast it was verified against: a
    new broadcast on the same chain has another hash and gets no record.
    """
    if not PROVENANCE.is_file():
        return {}
    records = {}
    for rec in json.loads(PROVENANCE.read_text()).get("runs", []):
        run = ROOT / rec["run"]
        digest = hashlib.sha256(run.read_bytes()).hexdigest() if run.is_file() else None
        if digest != rec.get("runSha256"):
            sys.exit(f"{PROVENANCE.relative_to(ROOT)}: {rec['run']} does not match its recorded hash")
        records[digest] = rec
    return records


def export_deployments() -> int:
    """Fold every broadcast run into the manifest, newest wins per (chain, contract)."""
    broadcast = ROOT / "broadcast"
    provenance = provenance_by_run_hash()
    manifest: dict[str, list[dict]] = {}
    if MANIFEST.is_file():
        try:
            manifest = json.loads(MANIFEST.read_text()).get("deployments", {})
        except json.JSONDecodeError:
            manifest = {}
    added = 0
    if broadcast.is_dir():
        for run in sorted(broadcast.rglob("run-latest.json")):
            data = json.loads(run.read_text())
            chain = str(data.get("chain", "unknown"))
            record = provenance.get(hashlib.sha256(run.read_bytes()).hexdigest())
            for tx in data.get("transactions", []):
                if tx.get("transactionType") != "CREATE":
                    continue
                # Foundry records the commit the broadcast was made from; that is
                # the commit the bytecode was built from. HEAD is only a fallback
                # (and carries -dirty when the tree is not clean).
                entry = {
                    "contract": tx.get("contractName"),
                    "address": tx.get("contractAddress"),
                    "deployTx": tx.get("hash"),
                    "sourceCommit": full_sha(data.get("commit")) or source_commit(),
                    "timestamp": data.get("timestamp"),
                }
                # sourceCommit stays what the broadcast recorded; the script
                # that actually ran is added beside it, with its evidence.
                if record:
                    entry["deployScriptCommit"] = record["deployScriptCommit"]
                    entry["provenance"] = record["note"]
                rows = [r for r in manifest.get(chain, []) if r.get("contract") != entry["contract"]]
                rows.append(entry)
                manifest[chain] = sorted(rows, key=lambda r: r.get("contract") or "")
                added += 1
    MANIFEST.parent.mkdir(exist_ok=True)
    MANIFEST.write_text(json.dumps({
        "$comment": "Generated by tools/export-artifacts.py from Foundry broadcast files. Do not hand-edit.",
        "deployments": manifest,
    }, indent=2) + "\n")
    return added


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--deployments", action="store_true", help="also fold broadcast/ into deployments/manifest.json")
    args = parser.parse_args()

    names = export_abis()
    print(f"abi: wrote {len(names)} contract(s): {', '.join(names) or '(none)'}")
    if args.deployments:
        print(f"deployments: folded {export_deployments()} CREATE transaction(s) into {MANIFEST.relative_to(ROOT)}")
