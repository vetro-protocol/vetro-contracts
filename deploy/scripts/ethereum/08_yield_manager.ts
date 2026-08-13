import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, grantRoleIfNeeded, ContractAliases} from '../../helpers'

const {PeggedToken, Treasury, YieldDistributor, YieldManager} = ContractAliases

/**
 * Deploy YieldManager for VUSD: non-upgradeable keeper periphery
 *
 * Besides deploying, this queues the two grants that activate it (idempotent; Safe batch on
 * production): UMM_ROLE on the Treasury and DISTRIBUTOR_ROLE on the YieldDistributor.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments} = hre
  const {get, read} = deployments

  const {address: peggedTokenAddress} = await get(PeggedToken)
  const {address: yieldDistributorAddress} = await get(YieldDistributor)

  const {address: yieldManagerAddress} = await deployNonUpgradeable(hre, YieldManager, [
    peggedTokenAddress,
    yieldDistributorAddress,
  ])

  const ummRole = await read(Treasury, 'UMM_ROLE')
  await grantRoleIfNeeded(hre, Treasury, ummRole, yieldManagerAddress)

  const distributorRole = await read(YieldDistributor, 'DISTRIBUTOR_ROLE')
  await grantRoleIfNeeded(hre, YieldDistributor, distributorRole, yieldManagerAddress)
}

// No `dependencies`: this is an incremental script; running dependency scripts would redeploy
// drifted contracts. `get()` reads the existing artifacts instead.
func.tags = [YieldManager]

export default func
