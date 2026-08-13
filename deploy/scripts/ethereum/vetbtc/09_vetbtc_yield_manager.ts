import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, grantRoleIfNeeded, ContractAliases} from '../../../helpers'

const {VetBTC, VetBTCTreasury, VetBTCYieldDistributor, VetBTCYieldManager, YieldManager} = ContractAliases

/**
 * Deploy YieldManager for vetBTC: non-upgradeable keeper periphery
 *
 * Besides deploying, this queues the two grants that activate it (idempotent; Safe batch on
 * production): UMM_ROLE on the Treasury and DISTRIBUTOR_ROLE on the YieldDistributor.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments} = hre
  const {get, read} = deployments

  const {address: vetBTCAddress} = await get(VetBTC)
  const {address: yieldDistributorAddress} = await get(VetBTCYieldDistributor)

  // alias differs from the contract name, so pass the artifact explicitly
  const {address: yieldManagerAddress} = await deployNonUpgradeable(
    hre,
    VetBTCYieldManager,
    [vetBTCAddress, yieldDistributorAddress],
    YieldManager,
  )

  const ummRole = await read(VetBTCTreasury, 'UMM_ROLE')
  await grantRoleIfNeeded(hre, VetBTCTreasury, ummRole, yieldManagerAddress)

  const distributorRole = await read(VetBTCYieldDistributor, 'DISTRIBUTOR_ROLE')
  await grantRoleIfNeeded(hre, VetBTCYieldDistributor, distributorRole, yieldManagerAddress)
}

// No `dependencies`: this is an incremental script; running dependency scripts would redeploy
// drifted contracts. `get()` reads the existing artifacts instead.
func.tags = [VetBTCYieldManager]

export default func
