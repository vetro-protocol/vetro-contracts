import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployUpgradable, UpgradableContracts, ContractAliases} from '../../../helpers'
import {SVetBTCConfig} from '../../../config'
import Address from '../../../helpers/address'

const {VetBTC, SVetBTC} = ContractAliases

/**
 * Deploy StakingVault as svetBTC — UPGRADEABLE
 *
 * Initialize args:
 * - asset_:   vetBTC token address
 * - name_:    "Staked Vetro BTC"
 * - symbol_:  "svetBTC"
 * - owner_:   GOVERNOR (multisig) or deployer on local networks
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments, getNamedAccounts} = hre
  const {get} = deployments
  const {deployer} = await getNamedAccounts()

  const {address: vetBTCAddress} = await get(VetBTC)
  const owner = ['hardhat', 'localhost'].includes(hre.network.name) ? deployer : Address.GOVERNOR || deployer

  await deployUpgradable({
    hre,
    contractConfig: UpgradableContracts.SVetBTC,
    initializeArgs: [vetBTCAddress, SVetBTCConfig.name, SVetBTCConfig.symbol, owner],
  })
}

func.tags = [SVetBTC]
func.dependencies = [VetBTC]

export default func
