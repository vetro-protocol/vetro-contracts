import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployUpgradable, UpgradableContracts, ContractAliases} from '../../../helpers'
import Address from '../../../helpers/address'

const {VetBTC, SVetBTC, VetBTCYieldDistributor} = ContractAliases

/**
 * Deploy YieldDistributor for svetBTC — UPGRADEABLE
 *
 * Initialize args:
 * - asset_:  vetBTC token address (the token being distributed as yield)
 * - vault_:  svetBTC staking vault address (recipient of dripped yield)
 * - admin_:  GOVERNOR (multisig) or deployer on local networks
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments, getNamedAccounts} = hre
  const {get} = deployments
  const {deployer} = await getNamedAccounts()

  const {address: vetBTCAddress} = await get(VetBTC)
  const {address: sVetBTCAddress} = await get(SVetBTC)
  const admin = ['hardhat', 'localhost'].includes(hre.network.name) ? deployer : Address.GOVERNOR || deployer

  await deployUpgradable({
    hre,
    contractConfig: UpgradableContracts.VetBTCYieldDistributor,
    initializeArgs: [vetBTCAddress, sVetBTCAddress, admin],
  })
}

func.tags = [VetBTCYieldDistributor]
func.dependencies = [VetBTC, SVetBTC]

export default func
