#!/usr/bin/env python3
"""Regenerate the OKX swap fixture for test/fork/AaveV3Adapter.okx.fork.t.sol.

Asks the OKX Onchain OS aggregator for a real xETH -> USD-T0 swap on X Layer,
quoted for the adapter address the fork test deploys, and prints the three
values the test pins: the block the quote was taken at, the adapter address,
and the calldata. Paste them into the test; the test replays the calldata
against a fork at that block, so nobody running the suite needs a key.

Needs OKX_DEX_API_KEY, OKX_DEX_API_SECRET and OKX_DEX_API_PASSPHRASE in the
environment (never printed). Usage:

    python3 tools/okx-fixture.py --adapter 0x... --amount-in 7900000000000000
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import hmac
import json
import os
import sys
import urllib.parse
import urllib.request

HOST = "https://web3.okx.com"
RPC = os.environ.get("XLAYER_RPC_URL", "")
if not RPC.startswith("http"):
    RPC = "https://rpc.xlayer.tech"
XETH = "0xe7b000003a45145decf8a28fc755ad5ec5ea025a"
USDT0 = "0x779Ded0c9e1022225f8E0630b35a9b54bE713736"


def okx(path: str, params: dict) -> dict:
    key, secret, passphrase = (os.environ[k] for k in ("OKX_DEX_API_KEY", "OKX_DEX_API_SECRET", "OKX_DEX_API_PASSPHRASE"))
    qs = "?" + urllib.parse.urlencode(params)
    now = dt.datetime.now(dt.timezone.utc)
    ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
    sig = base64.b64encode(hmac.new(secret.encode(), (ts + "GET" + path + qs).encode(), hashlib.sha256).digest()).decode()
    req = urllib.request.Request(
        HOST + path + qs,
        headers={
            "OK-ACCESS-KEY": key,
            "OK-ACCESS-SIGN": sig,
            "OK-ACCESS-TIMESTAMP": ts,
            "OK-ACCESS-PASSPHRASE": passphrase,
            # OKX's edge refuses Python's default user agent with a 403.
            "User-Agent": "signo-shield-fixture/1.0",
        },
    )
    body = json.load(urllib.request.urlopen(req, timeout=30))
    if body.get("code") != "0" or not body.get("data"):
        sys.exit(f"OKX error: {body.get('code')} {body.get('msg')}")
    return body["data"][0]


def block_number() -> int:
    req = urllib.request.Request(RPC, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []}).encode(), headers={"Content-Type": "application/json"})
    return int(json.load(urllib.request.urlopen(req, timeout=20))["result"], 16)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--adapter", required=True, help="the adapter address the fork test deploys (see test_fixtureMatchesTheDeployedAdapter)")
    ap.add_argument("--amount-in", required=True, type=int, help="xETH to sell, in wei; must be below the aToken slice the test fires")
    ap.add_argument("--slippage-percent", default="1")
    args = ap.parse_args()

    block = block_number()
    swap = okx("/api/v6/dex/aggregator/swap", {
        "chainIndex": "196",
        "fromTokenAddress": XETH,
        "toTokenAddress": USDT0,
        "amount": str(args.amount_in),
        "slippagePercent": args.slippage_percent,
        "userWalletAddress": args.adapter,
    })
    tx = swap["tx"]
    print(f"FORK_BLOCK        = {block}")
    print(f"FIXTURE_ADAPTER   = {args.adapter}")
    print(f"router (tx.to)    = {tx['to']}")
    print(f"from              = {tx.get('from')}")
    print(f"minReceiveAmount  = {tx.get('minReceiveAmount')}")
    print(f"quoted toAmount   = {swap.get('routerResult', {}).get('toTokenAmount')}")
    print(f"OKX_CALLDATA      = {tx['data']}")
