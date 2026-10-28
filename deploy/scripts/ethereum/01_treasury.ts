import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployUpgradable, UpgradableContracts, ContractAliases} from '../../helpers'
import Address from '../../helpers/address'

const {PeggedToken, Treasury} = ContractAliases

/**
 * Deploy Treasury (UPGRADEABLE)
 *
 * This is an UPGRADEABLE contract via OpenZeppelin v5 TransparentProxy pattern.
 * Uses the default OZ v5 ProxyAdmin (auto-created by the proxy, owned by GOVERNOR).
 *
 * Initialize args:
 * - peggedToken_: Address of the PeggedToken (VUSD) contract
 * - admin_: GOVERNOR (multisig) or deployer on local networks
 *
 * The Treasury:
 * - Uses AccessControlDefaultAdminRules with 3-day delay
 * - Holds collateral in ERC4626 yield vaults
 * - Has roles: DEFAULT_ADMIN_ROLE, KEEPER_ROLE, MAINTAINER_ROLE, UMM_ROLE
 *
 * After deployment:
 * 1. Call PeggedToken.updateTreasury(treasury)
 * 2. Add whitelisted tokens via Treasury.addToWhitelist()
 * 3. Grant KEEPER_ROLE, MAINTAINER_ROLE and UMM_ROLE: initialize grants none
 *
 * An existing Treasury that is not behind a proxy is kept: 09_migrate_treasury.ts replaces it, moving the collateral
 * in the same Safe batch as updateTreasury.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments, getNamedAccounts} = hre
  const {get, getOrNull} = deployments
  const {deployer} = await getNamedAccounts()

  const existing = await getOrNull(Treasury)
  if (existing && !(await getOrNull(`${Treasury}_Proxy`))) {
    console.log(`Keeping ${Treasury} at ${existing.address}: not behind a proxy, replace it through a migration`)
    return
  }

  // Get the deployed PeggedToken address
  const {address: peggedTokenAddress} = await get(PeggedToken)

  // Use deployer as admin on local networks, GOVERNOR on production
  const admin = ['hardhat', 'localhost'].includes(hre.network.name) ? deployer : Address.GOVERNOR || deployer

  await deployUpgradable({
    hre,
    contractConfig: UpgradableContracts.Treasury,
    initializeArgs: [
      peggedTokenAddress, // peggedToken_
      admin, // admin_
    ],
  })
}

func.tags = [Treasury]
func.dependencies = [PeggedToken]

export default func
