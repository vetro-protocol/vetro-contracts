#!/usr/bin/env zsh
#
# Start a local hardhat node forked from mainnet
#
# Usage: ./scripts/start-forked-node.sh <network>
# Example: ./scripts/start-forked-node.sh mainnet
#
# Notes:
# - Set DEPLOYER env var to impersonate that account
# - Uncomment `deployments/localhost` in `.gitignore` to track deployment changes
#

set -e

network=$1

if [[ -z "$network" ]]; then
    echo "Usage: $0 <network>"
    echo "Example: $0 mainnet"
    exit 1
fi

if [[ ! -d "deploy/scripts/$network" ]]; then
    echo "Error: '$network' is invalid (deploy/scripts/$network not found)"
    exit 1
fi

# Load environment variables (ignore errors from malformed lines)
set +e
source .env 2>/dev/null
set -e

# Convert network name to uppercase for env var lookup
network_upper=$(echo "$network" | tr '[:lower:]' '[:upper:]')

# Get network-specific URL and block number using zsh indirect expansion
url_var="${network_upper}_NODE_URL"
block_var="${network_upper}_BLOCK_NUMBER"

url="${(P)url_var}"
block="${(P)block_var}"

if [[ -z "$url" ]]; then
    echo "Error: ${url_var} not set in .env"
    exit 1
fi

echo "=== Forked Node Configuration ==="
echo "Network: $network"
echo "Node URL: $url"
echo "Block Number: ${block:-latest}"
echo ""
echo "Make sure .env has the correct values."
echo -n "Press <ENTER> to continue (Ctrl+C to cancel): "
read

# Clean old artifacts
rm -rf artifacts/ cache/ multisig.batch.tmp.json

# Run forked node
if [[ -n "$block" ]]; then
    npx hardhat node --fork "$url" --fork-block-number "$block" --no-deploy
else
    npx hardhat node --fork "$url" --no-deploy
fi
