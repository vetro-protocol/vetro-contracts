#!/usr/bin/env zsh
set -e

# Upgrade dry run on a mainnet fork
#
# Runs the real deploy scripts against a forked node as the governance Safe, and checks that only the
# implementations changed and that the deployed contracts still work:
#   1. start a forked node and copy deployments/<network> to deployments/localhost
#   2. snapshot state through the live implementations
#   3. `hardhat deploy` (validates storage layouts, deploys implementations, upgrades proxies as the Safe)
#   4. snapshot again and fail if anything but implementations changed
#   5. run the Foundry flow tests against the upgraded node
#
# Usage: ./scripts/test-upgrade-on-fork.sh [network]
#
# Environment Variables (set in .env):
#   <NETWORK>_NODE_URL     - RPC URL to fork (required)
#   <NETWORK>_BLOCK_NUMBER - Block number to fork from (optional)

NETWORK=${1:-"ethereum"}
PORT=8545
NODE_URL="http://127.0.0.1:$PORT"
NODE_PID=""
OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vetro-upgrade.XXXXXX")
NODE_LOG="$OUT_DIR/node.log"

cleanup() {
    if [[ -n "$NODE_PID" ]]; then
        echo ""
        echo "Stopping forked node (PID: $NODE_PID)..."
        kill $NODE_PID 2>/dev/null || true
        wait $NODE_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

if [[ ! -d "deployments/$NETWORK" ]]; then
    echo "Error: deployments/$NETWORK not found"
    exit 1
fi

if curl -s $NODE_URL > /dev/null 2>&1; then
    echo "Error: Port $PORT is already in use. Stop the existing node first."
    exit 1
fi

set +e
source .env 2>/dev/null
set -e

network_upper=$(echo "$NETWORK" | tr '[:lower:]' '[:upper:]')
url_var="${network_upper}_NODE_URL"
block_var="${network_upper}_BLOCK_NUMBER"
url="${(P)url_var}"
block="${(P)block_var}"

if [[ -z "$url" ]]; then
    echo "Error: ${url_var} not set in .env"
    exit 1
fi

# Proxy admins are owned by the governance Safe; impersonating it executes the upgrades the Safe batch would. Read
# the owner at the forked block (it may have changed since), and assign before exporting: `export X=$(...)` would
# hide a failed lookup from `set -e` and the deploy would silently sign as the node's default account
proxy_admin=$(node -e "console.log(require('./deployments/$NETWORK/Gateway_ProxyAdmin.json').address)")
DEPLOYER=$(cast call "$proxy_admin" 'owner()(address)' --rpc-url "$url" --block "${block:-latest}")
if [[ -z "$DEPLOYER" ]]; then
    echo "Error: could not read the owner of ProxyAdmin $proxy_admin"
    exit 1
fi
export DEPLOYER

echo "========================================"
echo "Upgrade dry run on $NETWORK fork"
echo "========================================"
echo "Block:    ${block:-latest}"
echo "Deployer: $DEPLOYER (ProxyAdmin owner)"
echo "Output:   $OUT_DIR"
echo ""

# anvil rather than a hardhat node: forge forks by block hash, which the hardhat node rejects
rm -rf multisig.batch.tmp.json
if [[ -n "$block" ]]; then
    anvil --fork-url "$url" --fork-block-number "$block" --port $PORT > "$NODE_LOG" 2>&1 &
else
    anvil --fork-url "$url" --port $PORT > "$NODE_LOG" 2>&1 &
fi
NODE_PID=$!

for i in {1..60}; do
    curl -s $NODE_URL > /dev/null 2>&1 && break
    if ! kill -0 $NODE_PID 2>/dev/null; then
        echo "Error: node died, see $NODE_LOG"
        tail -20 "$NODE_LOG"
        exit 1
    fi
    sleep 1
done
curl -s $NODE_URL > /dev/null 2>&1 || { echo "Error: node did not start, see $NODE_LOG"; exit 1; }

rm -rf deployments/localhost
cp -r "deployments/$NETWORK" deployments/localhost
npx hardhat impersonate-deployer --network localhost

echo ">>> Snapshot before upgrade"
npx hardhat upgrade-snapshot --network localhost --out "$OUT_DIR/before.json"

echo ""
echo ">>> Deploying"
npx hardhat deploy --network localhost

echo ""
echo ">>> Snapshot after upgrade"
npx hardhat upgrade-snapshot --network localhost --out "$OUT_DIR/after.json" --compare "$OUT_DIR/before.json"

echo ""
echo ">>> Flow tests against the upgraded node"
ETHEREUM_FORK_NODE_URL=$NODE_URL ETHEREUM_FORK_BLOCK_NUMBER=0 forge test --match-contract LiveForkTest

echo ""
echo "========================================"
echo "Upgrade dry run PASSED"
echo "Snapshots: $OUT_DIR"
echo "Deployment changes: deployments/localhost"
echo "========================================"
