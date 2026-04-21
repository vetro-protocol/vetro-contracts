import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {updateParamIfNeeded, ContractAliases} from '../../../helpers'

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

  await updateParamIfNeeded(hre, {
    contractAlias: VetBTC,
    readMethod: 'treasury',
    writeMethod: 'updateTreasury',
    writeArgs: [treasuryAddress],
  })

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
