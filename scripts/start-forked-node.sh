#!/bin/bash
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

network=$1;

if [[ "$network" == "" ]];
then
    echo "Usage: $0 <network>"
    echo "Example: $0 mainnet"
    exit 1
fi

if [ ! -d "deploy/scripts/$network" ];
then
    echo "Error: '$network' is invalid (deploy/scripts/$network not found)"
    exit 1
fi

# Load environment variables
source .env

# Get network-specific URL and block number
# Converts network name to uppercase for env var lookup (e.g., mainnet -> MAINNET_NODE_URL)
url=$(eval echo "\$${network^^}_NODE_URL")
block=$(eval echo "\$${network^^}_BLOCK_NUMBER")

if [[ "$url" == "" ]];
then
    echo "Error: ${network^^}_NODE_URL not set in .env"
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
if [[ "$block" != "" ]];
then
    npx hardhat node --fork $url --fork-block-number $block --no-deploy
else
    npx hardhat node --fork $url --no-deploy
fi
