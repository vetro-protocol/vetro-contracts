import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, ContractAliases} from '../../../helpers'
import {VetBTCConfig} from '../../../config'
import Address from '../../../helpers/address'

const {VetBTC} = ContractAliases

/**
 * Deploy PeggedToken as vetBTC
 *
 * Constructor args:
 * - name_:   "Vetro BTC"
 * - symbol_: "vetBTC"
 * - owner_:  GOVERNOR (multisig) or deployer on local networks
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {getNamedAccounts} = hre
  const {deployer} = await getNamedAccounts()

  const owner = ['hardhat', 'localhost'].includes(hre.network.name) ? deployer : Address.GOVERNOR || deployer

  await deployNonUpgradeable(
    hre,
    VetBTC,
    [VetBTCConfig.name, VetBTCConfig.symbol, owner],
    'PeggedToken' // artifact name
  )
}

func.tags = [VetBTC]

export default func
