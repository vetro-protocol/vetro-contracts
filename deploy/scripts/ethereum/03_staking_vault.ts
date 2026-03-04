import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployUpgradable, UpgradableContracts, ContractAliases} from '../../helpers'
import {StakingVaultConfig} from '../../config'
import Address from '../../helpers/address'

const {PeggedToken, StakingVault} = ContractAliases

/**
 * Deploy StakingVault (sVUSD) - UPGRADEABLE
 *
 * This is an UPGRADEABLE contract via OpenZeppelin v5 TransparentProxy pattern.
 * Uses the default OZ v5 ProxyAdmin (auto-created by the proxy, owned by GOVERNOR).
 *
 * Initialize args:
 * - asset_: Address of the underlying asset (PeggedToken/VUSD)
 * - name_: "Staked Vetro USD"
 * - symbol_: "sVUSD"
 * - owner_: GOVERNOR (multisig) or deployer on local networks
 *
 * The StakingVault:
 * - ERC4626 yield-bearing vault
 * - Has cooldown mechanism for withdrawals (7 days default)
 * - Whitelisted addresses can withdraw instantly
 * - Integrates with YieldDistributor for drip yield
 *
 * After deployment:
 * 1. Deploy YieldDistributor
 * 2. Call StakingVault.updateYieldDistributor(yieldDistributor)
 * 3. Configure VaultRewards if needed
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments, getNamedAccounts} = hre
  const {get} = deployments
  const {deployer} = await getNamedAccounts()

  // Get the deployed PeggedToken (VUSD) address as underlying asset
  const {address: peggedTokenAddress} = await get(PeggedToken)

  // Use deployer as owner on local networks, GOVERNOR on production
  const owner = ['hardhat', 'localhost'].includes(hre.network.name)
    ? deployer
    : Address.GOVERNOR || deployer

  await deployUpgradable({
    hre,
    contractConfig: UpgradableContracts.StakingVault,
    initializeArgs: [
      peggedTokenAddress, // asset_
      StakingVaultConfig.name, // name_
      StakingVaultConfig.symbol, // symbol_
      owner, // owner_
    ],
  })
}

func.tags = [StakingVault]
func.dependencies = [PeggedToken]

export default func
