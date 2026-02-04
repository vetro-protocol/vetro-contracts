import {parseEther} from 'ethers/lib/utils'

/**
 * Centralized deployment configuration
 * All deployment parameters should be defined here
 */

// =============================================================================
// NETWORK ADDRESSES
// =============================================================================

interface NetworkAddresses {
  // Governance
  GOVERNOR: string
  GNOSIS_SAFE_ADDRESS: string

  // Core tokens
  USDC_ADDRESS: string
  USDT_ADDRESS: string
  DAI_ADDRESS: string

  // Chainlink Oracle feeds (USD pairs)
  USDC_USD_CHAINLINK_AGGREGATOR: string
  USDT_USD_CHAINLINK_AGGREGATOR: string
  DAI_USD_CHAINLINK_AGGREGATOR: string

  // ERC4626 Vaults for collateral
  VAUSDC_ADDRESS: string
}

export const NetworkAddresses: {[chainId: number]: NetworkAddresses} = {
  // Ethereum Mainnet
  1: {
    // Governance - UPDATE BEFORE MAINNET DEPLOYMENT
    GOVERNOR: '0x0000000000000000000000000000000000000000',
    GNOSIS_SAFE_ADDRESS: '0x0000000000000000000000000000000000000000',

    // Core tokens
    USDC_ADDRESS: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    USDT_ADDRESS: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
    DAI_ADDRESS: '0x6B175474E89094C44Da98b954EedeAC495271d0F',

    // Chainlink Oracle feeds (USD pairs)
    USDC_USD_CHAINLINK_AGGREGATOR: '0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6',
    USDT_USD_CHAINLINK_AGGREGATOR: '0x3E7d1eAB13ad0104d2750B8863b489D65364e32D',
    DAI_USD_CHAINLINK_AGGREGATOR: '0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9',

    // ERC4626 Vaults: UPDATE BEFORE MAINNET DEPLOYMENT
    VAUSDC_ADDRESS: '0x0000000000000000000000000000000000000000',
  },

  // Hardhat local network - mirrors mainnet for fork testing
  31337: {
    GOVERNOR: '0x0000000000000000000000000000000000000000',
    GNOSIS_SAFE_ADDRESS: '0x0000000000000000000000000000000000000000',

    USDC_ADDRESS: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    USDT_ADDRESS: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
    DAI_ADDRESS: '0x6B175474E89094C44Da98b954EedeAC495271d0F',

    USDC_USD_CHAINLINK_AGGREGATOR: '0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6',
    USDT_USD_CHAINLINK_AGGREGATOR: '0x3E7d1eAB13ad0104d2750B8863b489D65364e32D',
    DAI_USD_CHAINLINK_AGGREGATOR: '0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9',

    VAUSDC_ADDRESS: '0xa8b607Aa09B6A2E306F93e74c282Fb13f6A80452',
  },
}

// =============================================================================
// PEGGED TOKEN (VUSD) CONFIGURATION
// =============================================================================

export const PeggedTokenConfig = {
  name: 'Vetro USD',
  symbol: 'VUSD',
}

// =============================================================================
// TREASURY CONFIGURATION
// =============================================================================

export const TreasuryConfig = {
  // Admin transfer delay is hardcoded in contract as 3 days
  // Initial roles granted to deployer: KEEPER_ROLE, MAINTAINER_ROLE
}

// =============================================================================
// GATEWAY CONFIGURATION
// =============================================================================

export const GatewayConfig = {
  // Maximum total mint limit for PeggedToken
  mintLimit: parseEther('100000000'), // 100M VUSD

  // Withdrawal delay period in seconds
  withdrawalDelay: 7 * 24 * 60 * 60, // 7 days

  // Default redeem fee (set in contract initialize): 0.3% (30 bps)
  // Default mint fee: 0% (can be updated via updateMintFee)
}

// =============================================================================
// STAKING VAULT (sVUSD) CONFIGURATION
// =============================================================================

export const StakingVaultConfig = {
  name: 'Staked Vetro USD',
  symbol: 'sVUSD',

  // Default cooldown duration is set in contract: 7 days
  // Min: 1 day, Max: 30 days
  // Cooldown is enabled by default
}

// =============================================================================
// YIELD DISTRIBUTOR CONFIGURATION
// =============================================================================

export const YieldDistributorConfig = {
  // Default yield duration is set in contract: 7 days
  // Min: 1 day
  // Admin transfer delay: 3 days (hardcoded in contract)
}

// =============================================================================
// CONTRACT ALIASES (for hardhat-deploy)
// =============================================================================

export const ContractAliases = {
  PeggedToken: 'PeggedToken',
  Treasury: 'Treasury',
  Gateway: 'Gateway',
  StakingVault: 'StakingVault',
  YieldDistributor: 'YieldDistributor',
} as const

// =============================================================================
// UPGRADEABLE CONTRACTS CONFIGURATION
// =============================================================================

interface ContractConfig {
  alias: string
  contract: string
}

export const UpgradableContracts: {[key: string]: ContractConfig} = {
  Gateway: {
    alias: 'Gateway',
    contract: 'Gateway',
  },
  StakingVault: {
    alias: 'StakingVault',
    contract: 'StakingVault',
  },
  YieldDistributor: {
    alias: 'YieldDistributor',
    contract: 'YieldDistributor',
  },
}

// =============================================================================
// HELPER FUNCTION TO GET ADDRESSES BY CHAIN ID
// =============================================================================

export const getNetworkAddresses = (chainId: number): NetworkAddresses => {
  const addresses = NetworkAddresses[chainId]
  if (!addresses) {
    // Default to mainnet addresses if chain not found
    return NetworkAddresses[1]
  }
  return addresses
}
