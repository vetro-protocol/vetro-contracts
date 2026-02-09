# Vetro Contracts Deployment Guide

## Overview

This guide covers the deployment process for Vetro contracts using Hardhat Deploy with OpenZeppelin v5 Transparent Proxy pattern.

### Contract Types

| Contract | Type | Proxy Pattern |
|----------|------|---------------|
| PeggedToken | Non-upgradeable | None |
| Treasury | Non-upgradeable | None |
| Gateway | Upgradeable | OZ v5 TransparentUpgradeableProxy |
| StakingVault | Upgradeable | OZ v5 TransparentUpgradeableProxy |
| YieldDistributor | Upgradeable | OZ v5 TransparentUpgradeableProxy |

### Proxy Architecture

For upgradeable contracts, we use OpenZeppelin v5's TransparentUpgradeableProxy:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     Proxy       │────▶│ Implementation  │     │   ProxyAdmin    │
│ (Transparent    │     │  (pure logic)   │     │  (auto-created) │
│  Upgradeable)   │     │                 │     │  owned by       │
└─────────────────┘     └─────────────────┘     │  GOVERNOR       │
        ▲                                       └─────────────────┘
        │                                               │
        └───────────────────────────────────────────────┘
                    (ProxyAdmin controls upgrades)
```

**Key Points:**
- OZ v5 proxy auto-creates a ProxyAdmin in its constructor
- Each upgradeable contract has its own ProxyAdmin (OZ v5 design)
- ProxyAdmin is owned by GOVERNOR (multisig on mainnet, deployer locally)
- Upgrades are performed via `ProxyAdmin.upgradeAndCall(proxy, newImpl, data)`

---

## Environment Setup

### 1. Install Dependencies

```bash
npm install
```

### 2. Configure Environment

Copy `.env.example` to `.env` and fill in the values:

```bash
cp .env.example .env
```

Required variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `MAINNET_NODE_URL` | Ethereum mainnet RPC URL | `https://eth-mainnet.g.alchemy.com/v2/xxx` |
| `MNEMONIC` | Deployer wallet mnemonic | `word1 word2 ... word12` |
| `DEPLOYER` | Deployer address (for fork testing) | `0x...` |
| `ETHERSCAN_API_KEY` | For contract verification | `xxx` |

Optional variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `MAINNET_BLOCK_NUMBER` | Fork at specific block | Latest |
| `FORK_CHAIN` | Chain to fork | `mainnet` |
| `REPORT_GAS` | Enable gas reporting | `false` |

---

## Local Development

### Compile Contracts

```bash
npx hardhat compile
```

### Run Tests

```bash
npx hardhat test
```

### Deploy to Local Hardhat Network

```bash
npx hardhat deploy --network hardhat
```

---

## Fork Testing (Simulating Mainnet Deployment)

Fork testing allows you to simulate deployments against a forked mainnet state. This is crucial for testing upgrades on existing contracts.

### Step 1: Start Forked Node

In **Terminal 1**, start the forked node:

```bash
./scripts/start-forked-node.sh mainnet
```

This will:
- Fork mainnet at the latest block (or `MAINNET_BLOCK_NUMBER` if set)
- Start a local node at `http://localhost:8545`
- Keep the terminal running (don't close it)

### Step 2: Run Deployment on Fork

In **Terminal 2**, run the deployment:

```bash
# Set the deployer address to impersonate
export DEPLOYER=0xYourDeployerAddress

# Run deployment
./scripts/test-next-deployment-on-fork.sh mainnet
```

This will:
1. Impersonate the deployer account (fund it with ETH)
2. Copy existing deployment files from `deployments/mainnet` to `deployments/localhost`
3. Run all deployment scripts against the forked node

### Step 3: Verify Deployment

After deployment, you can:

```bash
# Run tests against the fork
npx hardhat test --network localhost

# Interact with contracts via console
npx hardhat console --network localhost

# Check deployment files
ls -la deployments/localhost/
```

### Step 4: Review Changes

To see what changed during deployment:

```bash
# If you uncommented deployments/localhost in .gitignore
git diff deployments/localhost/
```

---

## Mainnet Deployment

### Prerequisites

1. Ensure `.env` has correct `MAINNET_NODE_URL` and `MNEMONIC`
2. Ensure deployer wallet has sufficient ETH for gas
3. Review deployment parameters in `deploy/config.ts`

### Deploy Commands

```bash
# Deploy all contracts
npx hardhat deploy --network mainnet

# Deploy specific contract(s)
npx hardhat deploy --network mainnet --tags Gateway
npx hardhat deploy --network mainnet --tags StakingVault,YieldDistributor
```

### Verify Contracts on Etherscan

```bash
npx hardhat etherscan-verify --network mainnet
```

---

## Deployment Configuration

All deployment parameters are centralized in `deploy/config.ts`:

```typescript
// Example configuration
export const GatewayConfig = {
  mintLimit: parseEther('100000000'), // 100M VUSD
  withdrawalDelay: 7 * 24 * 60 * 60,  // 7 days
}

export const StakingVaultConfig = {
  name: 'Staked Vetro USD',
  symbol: 'sVUSD',
}
```

### Network-Specific Addresses

External contract addresses (e.g., USDC, oracles) are defined in `deploy/config.ts`:

```typescript
export const NetworkAddresses = {
  1: {  // Ethereum Mainnet
    GOVERNOR: '0x...',  // Gnosis Safe multisig
    USDC_ADDRESS: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    // ...
  },
}
```

---

## Upgrading Contracts

### How Upgrades Work

1. Deploy new implementation contract
2. ProxyAdmin owner (GOVERNOR) calls `ProxyAdmin.upgradeAndCall(proxy, newImpl, data)`
3. Proxy now points to new implementation

### Upgrade Process

1. **Modify the implementation** (e.g., `src/Gateway.sol`)

2. **Run deployment** (detects new implementation automatically):
   ```bash
   npx hardhat deploy --network mainnet --tags Gateway
   ```

3. **If deployer is EOA** → upgrade executes immediately

4. **If deployer is multisig** → generates batch file for multisig execution

### Testing Upgrades on Fork

Always test upgrades on a fork before mainnet:

```bash
# Terminal 1
./scripts/start-forked-node.sh mainnet

# Terminal 2
export DEPLOYER=0xYourDeployerAddress
./scripts/test-next-deployment-on-fork.sh mainnet
```

---

## Deployment Scripts Structure

```
deploy/
├── config.ts                    # Centralized deployment parameters
├── helpers/
│   ├── index.ts                 # Deployment helper functions
│   ├── address.ts               # External contract addresses
│   ├── gnosis-safe.ts           # Gnosis Safe helpers
│   └── multisig-helpers.ts      # Multisig batch execution
└── scripts/
    └── mainnet/
        ├── 00_pegged_token.ts       # PeggedToken deployment
        ├── 01_treasury.ts           # Treasury deployment
        ├── 02_gateway.ts            # Gateway deployment (upgradeable)
        ├── 03_staking_vault.ts      # StakingVault deployment (upgradeable)
        ├── 04_yield_distributor.ts  # YieldDistributor deployment (upgradeable)
        ├── 05_setup_connections.ts  # Connect contracts together
        └── 99_multisig_txs.ts       # Execute multisig transactions
```

### Deployment Script Tags

Each script has tags for selective deployment:

| Tag | Script |
|-----|--------|
| `PeggedToken` | 00_pegged_token.ts |
| `Treasury` | 01_treasury.ts |
| `Gateway` | 02_gateway.ts |
| `StakingVault` | 03_staking_vault.ts |
| `YieldDistributor` | 04_yield_distributor.ts |

---

## Deployed Contract Artifacts

After deployment, artifacts are saved in `deployments/<network>/`:

```
deployments/mainnet/
├── PeggedToken.json
├── Treasury.json
├── Gateway.json                    # Points to proxy address
├── Gateway_Implementation.json     # Implementation contract
├── Gateway_Proxy.json              # Proxy contract
├── Gateway_ProxyAdmin.json         # Auto-created ProxyAdmin
├── StakingVault.json
├── StakingVault_Implementation.json
├── StakingVault_Proxy.json
├── StakingVault_ProxyAdmin.json
├── YieldDistributor.json
├── YieldDistributor_Implementation.json
├── YieldDistributor_Proxy.json
└── YieldDistributor_ProxyAdmin.json
```

---

## Troubleshooting

### Common Issues

**1. Fork node not connecting**

Ensure:
- `MAINNET_NODE_URL` is set correctly in `.env`
- The forked node is running (`./scripts/start-forked-node.sh mainnet`)
- You're using `--network localhost` (not `--network hardhat`)

**2. "Nonce too high" errors on fork**

Reset the fork:
```bash
# Stop the forked node (Ctrl+C)
# Restart it
./scripts/start-forked-node.sh mainnet
```

**3. Gas price too low on fork**

The fork inherits mainnet gas prices. Set base fee to 0:
```bash
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"hardhat_setNextBlockBaseFeePerGas","params":["0x0"],"id":1}' \
  http://127.0.0.1:8545
```

**4. "Cannot find artifact" error**

Clean and recompile:
```bash
npx hardhat clean && npx hardhat compile
```

---

## Security Considerations

1. **Never commit `.env`** - Contains sensitive keys
2. **Test on fork first** - Always simulate mainnet deployments
3. **Multisig for production** - Transfer ownership to multisig after initial setup
4. **Verify on Etherscan** - Always verify contracts for transparency
5. **Review upgrade diffs** - Carefully review implementation changes before upgrading
