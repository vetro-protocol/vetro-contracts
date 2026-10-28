import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {updateParamIfNeeded, ContractAliases} from '../../../helpers'
import {isTreasuryMigrationPending} from '../../../helpers/treasury-migration'

const {VetBTC, VetBTCTreasury, VetBTCGateway, SVetBTC, VetBTCYieldDistributor} = ContractAliases

/**
 * Wire up vetBTC contract connections:
 * 1. VetBTC.updateTreasury(vetBTCTreasury)
 * 2. VetBTC.updateGateway(vetBTCGateway)
 * 3. SVetBTC.updateYieldDistributor(vetBTCYieldDistributor)
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments} = hre
  const {get} = deployments

  const {address: treasuryAddress} = await get(VetBTCTreasury)
  const {address: gatewayAddress} = await get(VetBTCGateway)
  const {address: yieldDistributorAddress} = await get(VetBTCYieldDistributor)

  // A pending migration owns this call: on its own it would point the token at a Treasury with no collateral yet
  if (await isTreasuryMigrationPending(hre, {peggedTokenAlias: VetBTC, treasuryAlias: VetBTCTreasury})) {
    console.log(`VetBTCTreasury migration to ${treasuryAddress} is pending: leaving updateTreasury to it`)
  } else {
    await updateParamIfNeeded(hre, {
      contractAlias: VetBTC,
      readMethod: 'treasury',
      writeMethod: 'updateTreasury',
      writeArgs: [treasuryAddress],
    })
  }

  await updateParamIfNeeded(hre, {
    contractAlias: VetBTC,
    readMethod: 'gateway',
    writeMethod: 'updateGateway',
    writeArgs: [gatewayAddress],
  })

  await updateParamIfNeeded(hre, {
    contractAlias: SVetBTC,
    readMethod: 'yieldDistributor',
    writeMethod: 'updateYieldDistributor',
    writeArgs: [yieldDistributorAddress],
  })
}

func.tags = ['VetBTCSetupConnections']
func.dependencies = [VetBTC, VetBTCTreasury, VetBTCGateway, SVetBTC, VetBTCYieldDistributor]

export default func
