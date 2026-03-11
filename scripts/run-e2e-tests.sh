#!/usr/bin/env zsh
set -e

# E2E Test Runner
#
# Starts a forked mainnet node in background and runs E2E tests
# against deployed contracts. Node is automatically stopped when tests complete.
#
# Usage: ./scripts/run-e2e-tests.sh [release-file] [network]
#
# Arguments:
#   release-file  - Release JSON file in releases/ folder (default: ethereum-1.0.0-beta.1.json)
#   network       - Network to fork: mainnet (default: mainnet)
#
# Examples:
#   ./scripts/run-e2e-tests.sh                                    # Uses defaults
#   ./scripts/run-e2e-tests.sh ethereum-1.0.0-beta.2.json         # Specific release
#   ./scripts/run-e2e-tests.sh ethereum-1.0.0-beta.1.json mainnet # Explicit network
#
# Environment Variables (set in .env):
#   ETHEREUM_NODE_URL     - RPC URL for ethereum fork (required)
#   MAINNET_BLOCK_NUMBER - Block number to fork from (optional)

RELEASE_FILE=${1:-"ethereum-1.0.0.json"}
NETWORK=${2:-"ethereum"}
NODE_PID=""
NODE_LOG="/tmp/hardhat-node-e2e.log"

# Cleanup function to kill node on exit
cleanup() {
    if [[ -n "$NODE_PID" ]]; then
        echo ""
        echo "Stopping forked node (PID: $NODE_PID)..."
        kill $NODE_PID 2>/dev/null || true
        wait $NODE_PID 2>/dev/null || true
        echo "Node stopped."
    fi
}
trap cleanup EXIT INT TERM

echo "========================================"
echo "E2E Test Runner"
echo "========================================"
echo "Release file: $RELEASE_FILE"
echo "Network: $NETWORK"
echo ""

# Check if release file exists
if [[ ! -f "releases/$RELEASE_FILE" ]]; then
    echo "Error: Release file not found: releases/$RELEASE_FILE"
    echo ""
    echo "Available release files:"
    ls -1 releases/*.json 2>/dev/null || echo "  (none)"
    exit 1
fi

# Check if node is already running on port 8545
if curl -s http://localhost:8545 > /dev/null 2>&1; then
    echo "Error: Port 8545 is already in use."
    echo "Please stop the existing node first, or run tests manually:"
    echo "  RELEASE_FILE=$RELEASE_FILE npx hardhat test test/e2e/deployed-contracts.test.ts --network localhost"
    exit 1
fi

# Load environment variables
set +e
source .env 2>/dev/null
set -e

# Get network-specific URL
network_upper=$(echo "$NETWORK" | tr '[:lower:]' '[:upper:]')
url_var="${network_upper}_NODE_URL"
block_var="${network_upper}_BLOCK_NUMBER"
url="${(P)url_var}"
block="${(P)block_var}"

if [[ -z "$url" ]]; then
    echo "Error: ${url_var} not set in .env"
    exit 1
fi

echo "Starting forked node in background..."
echo "  RPC URL: ${url:0:50}..."
echo "  Block: ${block:-latest}"
echo "  Log: $NODE_LOG"
echo ""

# Clean old artifacts
rm -rf artifacts/ cache/ multisig.batch.tmp.json

# Start forked node in background
if [[ -n "$block" ]]; then
    npx hardhat node --fork "$url" --fork-block-number "$block" --no-deploy > "$NODE_LOG" 2>&1 &
else
    npx hardhat node --fork "$url" --no-deploy > "$NODE_LOG" 2>&1 &
fi
NODE_PID=$!

echo "Waiting for node to start (PID: $NODE_PID)..."

# Wait for node to be ready (max 60 seconds)
for i in {1..60}; do
    if curl -s http://localhost:8545 > /dev/null 2>&1; then
        echo "Node started successfully!"
        echo ""
        break
    fi
    # Check if process died
    if ! kill -0 $NODE_PID 2>/dev/null; then
        echo "Error: Node process died. Check log: $NODE_LOG"
        echo ""
        echo "Last 20 lines of log:"
        tail -20 "$NODE_LOG"
        exit 1
    fi
    sleep 1
done

# Final check
if ! curl -s http://localhost:8545 > /dev/null 2>&1; then
    echo "Error: Node failed to start within 60 seconds"
    echo "Check log: $NODE_LOG"
    exit 1
fi

echo "========================================"
echo "Running E2E Tests"
echo "========================================"
echo ""

# Run tests
RELEASE_FILE=$RELEASE_FILE npx hardhat test test/e2e/deployed-contracts.test.ts --network localhost
TEST_EXIT_CODE=$?

echo ""
echo "========================================"
if [[ $TEST_EXIT_CODE -eq 0 ]]; then
    echo "E2E Tests PASSED"
else
    echo "E2E Tests FAILED (exit code: $TEST_EXIT_CODE)"
fi
echo "========================================"

exit $TEST_EXIT_CODE
