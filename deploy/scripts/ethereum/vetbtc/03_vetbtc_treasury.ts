import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, ContractAliases} from '../../../helpers'
import Address from '../../../helpers/address'

const {VetBTC, VetBTCTreasury} = ContractAliases

/**
 * Deploy Treasury for vetBTC
 *
 * Constructor args:
 * - peggedToken_: vetBTC token address
 * - admin_:       GOVERNOR (multisig) or deployer on local networks
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments, getNamedAccounts} = hre
  const {get} = deployments
  const {deployer} = await getNamedAccounts()

  const {address: vetBTCAddress} = await get(VetBTC)
  const admin = ['hardhat', 'localhost'].includes(hre.network.name) ? deployer : Address.GOVERNOR || deployer

  await deployNonUpgradeable(hre, VetBTCTreasury, [vetBTCAddress, admin], 'Treasury')
}

func.tags = [VetBTCTreasury]
func.dependencies = [VetBTC]

export default func
