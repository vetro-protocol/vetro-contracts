import {ContractAliases} from '../../deploy/config'

export interface InstanceAliases {
  PeggedToken: string
  Treasury: string
  Gateway: string
  StakingVault: string
  YieldDistributor: string
  YieldManager: string
}

/**
 * Deployment alias of each role, per Vetro instance. The key is also the instance's `releases/<instance>` directory.
 * Vetro's aliases don't share a prefix (VUSD's are bare), so each role is mapped explicitly.
 */
export const INSTANCES: Record<string, InstanceAliases> = {
  vusd: {
    PeggedToken: ContractAliases.PeggedToken,
    Treasury: ContractAliases.Treasury,
    Gateway: ContractAliases.Gateway,
    StakingVault: ContractAliases.StakingVault,
    YieldDistributor: ContractAliases.YieldDistributor,
    YieldManager: ContractAliases.YieldManager,
  },
  vetbtc: {
    PeggedToken: ContractAliases.VetBTC,
    Treasury: ContractAliases.VetBTCTreasury,
    Gateway: ContractAliases.VetBTCGateway,
    StakingVault: ContractAliases.SVetBTC,
    YieldDistributor: ContractAliases.VetBTCYieldDistributor,
    YieldManager: ContractAliases.VetBTCYieldManager,
  },
}
