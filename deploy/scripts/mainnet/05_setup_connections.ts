import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {updateParamIfNeeded, ContractAliases} from '../../helpers'

const {PeggedToken, Treasury, Gateway, StakingVault, YieldDistributor} = ContractAliases

/**
 * Setup contract connections and cross-references
 *
 * This script connects all deployed contracts together:
 * 1. PeggedToken.updateTreasury(treasury) - Required before setting gateway
 * 2. PeggedToken.updateGateway(gateway) - Allows Gateway to mint/burn
 * 3. StakingVault.updateYieldDistributor(yieldDistributor) - Enables yield drip
 *
 * Note: These updates require owner/admin permissions.
 * On production networks, they will be batched for multisig execution.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments} = hre
  const {get} = deployments

  // Get all deployed contract addresses
  const {address: treasuryAddress} = await get(Treasury)
  const {address: gatewayAddress} = await get(Gateway)
  const {address: yieldDistributorAddress} = await get(YieldDistributor)

  // 1. Set Treasury on PeggedToken (must be done before setting Gateway)
  await updateParamIfNeeded(hre, {
    contractAlias: PeggedToken,
    readMethod: 'treasury',
    writeMethod: 'updateTreasury',
    writeArgs: [treasuryAddress],
  })

  // 2. Set Gateway on PeggedToken (requires Treasury to be set first)
  await updateParamIfNeeded(hre, {
    contractAlias: PeggedToken,
    readMethod: 'gateway',
    writeMethod: 'updateGateway',
    writeArgs: [gatewayAddress],
  })

  // 3. Set YieldDistributor on StakingVault
  await updateParamIfNeeded(hre, {
    contractAlias: StakingVault,
    readMethod: 'yieldDistributor',
    writeMethod: 'updateYieldDistributor',
    writeArgs: [yieldDistributorAddress],
  })
}

func.tags = ['SetupConnections']
func.dependencies = [PeggedToken, Treasury, Gateway, StakingVault, YieldDistributor]

export default func
