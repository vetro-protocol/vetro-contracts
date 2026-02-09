import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, ContractAliases} from '../../helpers'
import Address from '../../helpers/address'

const {PeggedToken, Treasury} = ContractAliases

/**
 * Deploy Treasury
 *
 * This is a NON-UPGRADEABLE contract that manages collateral and yield vaults.
 *
 * Constructor args:
 * - peggedToken_: Address of the PeggedToken (VUSD) contract
 * - admin_: GOVERNOR (multisig) or deployer on local networks
 *
 * The Treasury:
 * - Uses AccessControlDefaultAdminRules with 3-day delay
 * - Holds collateral in ERC4626 yield vaults
 * - Has roles: DEFAULT_ADMIN_ROLE, KEEPER_ROLE, MAINTAINER_ROLE, UMM_ROLE
 * - Constructor grants KEEPER_ROLE and MAINTAINER_ROLE to deployer
 *
 * After deployment:
 * 1. Call PeggedToken.updateTreasury(treasury)
 * 2. Add whitelisted tokens via Treasury.addToWhitelist()
 * 3. Configure roles as needed
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments, getNamedAccounts} = hre
  const {get} = deployments
  const {deployer} = await getNamedAccounts()

  // Get the deployed PeggedToken address
  const {address: peggedTokenAddress} = await get(PeggedToken)

  // Use deployer as admin on local networks, GOVERNOR on production
  const admin = ['hardhat', 'localhost'].includes(hre.network.name)
    ? deployer
    : Address.GOVERNOR || deployer

  await deployNonUpgradeable(hre, Treasury, [
    peggedTokenAddress, // peggedToken_
    admin, // admin_
  ])
}

func.tags = [Treasury]
func.dependencies = [PeggedToken]

export default func
