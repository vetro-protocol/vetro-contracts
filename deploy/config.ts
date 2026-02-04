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
    GOVERNOR: '0x0000000000000000000000000000000000000000',
    GNOSIS_SAFE_ADDRESS: '0x0000000000000000000000000000000000000000',
  },

  // Hardhat local network - mirrors mainnet for fork testing
  31337: {
    GOVERNOR: '0x0000000000000000000000000000000000000000',
    GNOSIS_SAFE_ADDRESS: '0x0000000000000000000000000000000000000000',
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
