import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, ContractAliases} from '../../helpers'
import {PeggedTokenConfig} from '../../config'
import Address from '../../helpers/address'

const {PeggedToken} = ContractAliases

/**
 * Deploy PeggedToken (VUSD)
 *
 * This is a NON-UPGRADEABLE contract that serves as the stablecoin.
 *
 * Constructor args:
 * - name_: "Vetro USD"
 * - symbol_: "VUSD"
 * - owner_: GOVERNOR (multisig) or deployer on local networks
 *
 * After deployment, need to:
 * 1. Deploy Treasury
 * 2. Call PeggedToken.updateTreasury(treasury)
 * 3. Deploy Gateway
 * 4. Call PeggedToken.updateGateway(gateway)
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {getNamedAccounts} = hre
  const {deployer} = await getNamedAccounts()

  // Use deployer as owner on local networks, GOVERNOR on production
  const owner = ['hardhat', 'localhost'].includes(hre.network.name)
    ? deployer
    : Address.GOVERNOR || deployer

  await deployNonUpgradeable(hre, PeggedToken, [
    PeggedTokenConfig.name, // name
    PeggedTokenConfig.symbol, // symbol
    owner, // owner
  ])
}

func.tags = [PeggedToken]

export default func
