#!/usr/bin/env bash
# Register and fire a Shield mandate on a local fork of X Layer, end to end,
# with nothing but Foundry (anvil, forge, cast) and python3. No Signo service,
# no key of ours: anvil's well-known development accounts play deployer, user
# and agent, and the demo wallet is funded from the Aave aToken contracts,
# which hold the underlying they were supplied.
#
#   tools/demo-fork.sh                      # public X Layer RPC, pinned block
#   XLAYER_RPC_URL=... tools/demo-fork.sh   # your own endpoint
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${XLAYER_RPC_URL:-https://rpc.xlayer.tech}"
BLOCK="${FORK_BLOCK:-70752723}"
PORT="${PORT:-8545}"
LOCAL="http://127.0.0.1:$PORT"
XETH=0xE7B000003A45145decf8a28FC755aD5eC5EA025A
A_XETH=0xe6639ba6c1d79Be6d4c776E4c17504538d1719cD
USDT0=0x779Ded0c9e1022225f8E0630b35a9b54bE713736
A_USDT0=0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297

# anvil's published development keys. Never real funds.
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PRINCIPAL_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
AGENT_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
PRINCIPAL=$(cast wallet address --private-key "$PRINCIPAL_KEY")

TMP=$(mktemp -d)
export FOUNDRY_BROADCAST="$TMP/broadcast"   # keep the demo out of deployments/
anvil --fork-url "$RPC" --fork-block-number "$BLOCK" --port "$PORT" --silent >"$TMP/anvil.log" 2>&1 &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in $(seq 1 90); do cast block-number --rpc-url "$LOCAL" >/dev/null 2>&1 && break; sleep 1; done
echo "fork of X Layer at block $(cast block-number --rpc-url "$LOCAL")"

fund() { # from the aToken contract that holds the underlying
  local holder=$1 token=$2 amount=$3
  cast rpc --rpc-url "$LOCAL" anvil_impersonateAccount "$holder" >/dev/null
  cast rpc --rpc-url "$LOCAL" anvil_setBalance "$holder" 0xDE0B6B3A7640000 >/dev/null
  cast send --rpc-url "$LOCAL" --unlocked --from "$holder" "$token" "transfer(address,uint256)" "$PRINCIPAL" "$amount" >/dev/null
}
fund "$A_XETH" "$XETH" 1000000000000000000
fund "$A_USDT0" "$USDT0" 100000000
echo "demo wallet $PRINCIPAL funded with 1 xETH and 100 USDT0"

SHIELD_OWNER="$DEPLOYER" forge script script/Deploy.s.sol:Deploy --rpc-url "$LOCAL" --broadcast --private-key "$DEPLOYER_KEY" -q >/dev/null
read -r SHIELD ADAPTER < <(python3 - "$TMP/broadcast/Deploy.s.sol/196/run-latest.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); a={t["contractName"]:t["contractAddress"] for t in d["transactions"] if t["transactionType"]=="CREATE"}
print(a["SignoShield"], a["AaveV3Adapter"])
PY
)
echo "deployed SignoShield $SHIELD, AaveV3Adapter $ADAPTER"

SHIELD="$SHIELD" ADAPTER="$ADAPTER" PRINCIPAL_KEY="$PRINCIPAL_KEY" AGENT_KEY="$AGENT_KEY" \
  forge script script/RegisterAndFire.s.sol:RegisterAndFire --rpc-url "$LOCAL" --broadcast 2>&1 \
  | awk '/== Logs ==/{p=1; next} /## Setting up/{p=0} p'
echo "done: the agent repaid the user's debt through the Shield; the same mandate is now refused (reason 10 = TRIGGER_NOT_MET)"
