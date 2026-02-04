#!/bin/bash
#
# Test deployment scripts on a forked mainnet node
#
# Usage: ./scripts/test-next-deployment-on-fork.sh <network>
# Example: ./scripts/test-next-deployment-on-fork.sh mainnet
#
# Prerequisites:
# - Start forked node first: ./scripts/start-forked-node.sh <network>
# - Set DEPLOYER env var to impersonate the deployer account
#
# This script will:
# 1. Impersonate the deployer account
# 2. Copy existing deployment files from <network> to localhost
# 3. Run deployment scripts against the forked node
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

echo "=== Testing Deployment on Fork ==="
echo "Network: $network"
echo "Deployer: ${DEPLOYER:-not set}"
echo ""
echo "Make sure the forked node is running (./scripts/start-forked-node.sh $network)"
echo -n "Press <ENTER> to continue (Ctrl+C to cancel): "
read

# Impersonate deployer account
echo ""
echo ">>> Impersonating deployer..."
npx hardhat impersonate-deployer --network localhost

# Copy existing deployment files
echo ""
echo ">>> Copying deployment files from $network to localhost..."
rm -rf deployments/localhost
cp -r deployments/$network deployments/localhost

# Update chainId in localhost deployment
# This is needed because hardhat node uses chainId from config
echo ""
echo ">>> Updating chainId in localhost deployment..."
if [ -f "deployments/localhost/.chainId" ]; then
    # Keep the original chainId for compatibility
    echo "ChainId file exists, keeping original"
fi

# Run deployment
echo ""
echo ">>> Running deployment scripts..."
npx hardhat deploy --network localhost

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "You can now:"
echo "1. Check the deployment changes in deployments/localhost/"
echo "2. Run tests against the fork: npx hardhat test --network localhost"
echo "3. Interact with contracts: npx hardhat console --network localhost"
