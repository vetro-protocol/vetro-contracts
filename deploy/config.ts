import {parseEther} from 'ethers/lib/utils'

/**
 * Centralized deployment configuration
 * All deployment parameters should be defined here
 */

// =============================================================================
// NETWORK ADDRESSES
// =============================================================================

/**
 * Generic network addresses type - allows any string key for flexibility
 * Add new addresses as needed without modifying the interface
 */
type NetworkAddresses = Record<string, string>

export const NetworkAddresses: {[chainId: number]: NetworkAddresses} = {
  // Ethereum Mainnet
  1: {
    // Governance - UPDATE BEFORE MAINNET DEPLOYMENT
    GOVERNOR: '0xE173b056eF552c7322040703dDfC1e0638A575d3',
    GNOSIS_SAFE_ADDRESS: '0x0000000000000000000000000000000000000000',

    // Chainlink feeds
    CHAINLINK_BTC_USD_FEED: '0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c',
    CHAINLINK_CBBTC_USD_FEED: '0x2665701293fCbEB223D11A08D826563EDcCE423A',

    // Tokens
    WBTC: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599',
    CBBTC: '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf',

    VETRO_VAULT_WBTC: '0x30c410D92e54B2b492D725D6CEBed98891817C91',
    VETRO_VAULT_CBBTC: '0xD954d72D885f8409bCBe3f15ad2fc3EcA4a5Ba33',
    VETRO_VAULT_HemiBTC: '0x54b8a87c9f85Dd2515CaAE1fad2dd85199900076',
  },

  // Hardhat local network - mirrors mainnet for fork testing
  31337: {
    GOVERNOR: '0x0000000000000000000000000000000000000000',
    GNOSIS_SAFE_ADDRESS: '0x0000000000000000000000000000000000000000',

    // Chainlink feeds
    CHAINLINK_BTC_USD_FEED: '0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c',
    CHAINLINK_CBBTC_USD_FEED: '0x0000000000000000000000000000000000000000',

    // Tokens
    WBTC: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599',
    CBBTC: '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf',

    // vetBTC yield vaults
    VETRO_VAULT_WBTC: '0x30c410D92e54B2b492D725D6CEBed98891817C91',
    VETRO_VAULT_CBBTC: '0xD954d72D885f8409bCBe3f15ad2fc3EcA4a5Ba33',
    VETRO_VAULT_HemiBTC: '0x54b8a87c9f85Dd2515CaAE1fad2dd85199900076',
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
// vetBTC TOKEN CONFIGURATION
// =============================================================================

export const VetBTCConfig = {
  name: 'Vetro BTC',
  symbol: 'vetBTC',
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
  withdrawalDelay: 2 * 60,
}

export const VetBTCGatewayConfig = {
  // Maximum total mint limit for vetBTC
  mintLimit: parseEther('1320'), // 1320 vetBTC, approx 100M USD

  // Withdrawal delay period in seconds
  withdrawalDelay: 2 * 60,
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
// STAKING VAULT (svetBTC) CONFIGURATION
// =============================================================================

export const SVetBTCConfig = {
  name: 'Staked Vetro BTC',
  symbol: 'svetBTC',
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
  // VUSD ecosystem
  PeggedToken: 'PeggedToken',
  Treasury: 'Treasury',
  Gateway: 'Gateway',
  StakingVault: 'StakingVault',
  YieldDistributor: 'YieldDistributor',
  ChainlinkFeedAdapter: 'ChainlinkFeedAdapter',
  DerivedPriceFeedAdapter: 'DerivedPriceFeedAdapter',

  // vetBTC ecosystem
  VetBTC: 'VetBTC',
  VetBTCTreasury: 'VetBTCTreasury',
  VetBTCGateway: 'VetBTCGateway',
  SVetBTC: 'SVetBTC',
  VetBTCYieldDistributor: 'VetBTCYieldDistributor',
  FixedPriceFeedAdapter: 'FixedPriceFeedAdapter',
} as const

// =============================================================================
// UPGRADEABLE CONTRACTS CONFIGURATION
// =============================================================================

interface ContractConfig {
  alias: string
  contract: string
}

export const UpgradableContracts: {[key: string]: ContractConfig} = {
  // VUSD ecosystem
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

  // vetBTC ecosystem
  VetBTCGateway: {
    alias: ContractAliases.VetBTCGateway,
    contract: 'Gateway',
  },
  SVetBTC: {
    alias: ContractAliases.SVetBTC,
    contract: 'StakingVault',
  },
  VetBTCYieldDistributor: {
    alias: ContractAliases.VetBTCYieldDistributor,
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
