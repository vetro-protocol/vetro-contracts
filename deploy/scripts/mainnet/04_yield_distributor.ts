import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployUpgradable, UpgradableContracts, ContractAliases} from '../../helpers'
import Address from '../../helpers/address'

const {PeggedToken, StakingVault, YieldDistributor} = ContractAliases

/**
 * Deploy YieldDistributor - UPGRADEABLE
 *
 * This is an UPGRADEABLE contract via OpenZeppelin v5 TransparentProxy pattern.
 * Uses the default OZ v5 ProxyAdmin (auto-created by the proxy, owned by GOVERNOR).
 *
 * Initialize args:
 * - asset_: Address of the asset token to distribute (PeggedToken/VUSD)
 * - vault_: Address of the StakingVault (sVUSD) that receives yield
 * - admin_: GOVERNOR (multisig) or deployer on local networks
 *
 * The YieldDistributor:
 * - Gradually drips yield to sVUSD vault over 7 days (default)
 * - Prevents sandwich attacks on yield distribution
 * - Uses AccessControlDefaultAdminRulesUpgradeable with 3-day delay
 * - Has DISTRIBUTOR_ROLE for calling distribute()
 *
 * After deployment:
 * 1. Call StakingVault.updateYieldDistributor(yieldDistributor)
 * 2. Grant DISTRIBUTOR_ROLE to keeper/yield source
 * 3. Configure yield duration if needed
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments, getNamedAccounts} = hre
  const {get} = deployments
  const {deployer} = await getNamedAccounts()

  // Get deployed contract addresses
  const {address: peggedTokenAddress} = await get(PeggedToken)
  const {address: stakingVaultAddress} = await get(StakingVault)

  // Use deployer as admin on local networks, GOVERNOR on production
  const admin = ['hardhat', 'localhost'].includes(hre.network.name)
    ? deployer
    : Address.GOVERNOR || deployer

  await deployUpgradable({
    hre,
    contractConfig: UpgradableContracts.YieldDistributor,
    initializeArgs: [
      peggedTokenAddress, // asset_
      stakingVaultAddress, // vault_
      admin, // admin_
    ],
  })
}

func.tags = [YieldDistributor]
func.dependencies = [PeggedToken, StakingVault]

export default func
