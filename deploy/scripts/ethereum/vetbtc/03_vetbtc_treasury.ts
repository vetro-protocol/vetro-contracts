import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployUpgradable, UpgradableContracts, ContractAliases} from '../../../helpers'
import Address from '../../../helpers/address'

const {VetBTC, VetBTCTreasury} = ContractAliases

/**
 * Deploy Treasury for vetBTC (UPGRADEABLE)
 *
 * Initialize args:
 * - peggedToken_: vetBTC token address
 * - admin_:       GOVERNOR (multisig) or deployer on local networks
 *
 * An existing Treasury that is not behind a proxy is kept: vetbtc/10_vetbtc_migrate_treasury.ts replaces it, moving
 * the collateral in the same Safe batch as updateTreasury.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments, getNamedAccounts} = hre
  const {get, getOrNull} = deployments
  const {deployer} = await getNamedAccounts()

  const existing = await getOrNull(VetBTCTreasury)
  if (existing && !(await getOrNull(`${VetBTCTreasury}_Proxy`))) {
    console.log(`Keeping ${VetBTCTreasury} at ${existing.address}: not behind a proxy, replace it through a migration`)
    return
  }

  const {address: vetBTCAddress} = await get(VetBTC)
  const admin = ['hardhat', 'localhost'].includes(hre.network.name) ? deployer : Address.GOVERNOR || deployer

  await deployUpgradable({
    hre,
    contractConfig: UpgradableContracts.VetBTCTreasury,
    initializeArgs: [vetBTCAddress, admin],
  })
}

func.tags = [VetBTCTreasury]
func.dependencies = [VetBTC]

export default func
