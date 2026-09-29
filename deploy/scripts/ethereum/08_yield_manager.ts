import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, grantRoleIfNeeded, revokeRoleIfNeeded, ContractAliases} from '../../helpers'
import {YieldManagerConfig} from '../../config'

const {PeggedToken, Treasury, YieldDistributor, YieldManager} = ContractAliases

/**
 * Deploy YieldManager for VUSD: non-upgradeable keeper periphery
 *
 * Keeps an existing deployment; to replace one, pass `redeploy = true` locally. Queues UMM_ROLE (Treasury)
 * and DISTRIBUTOR_ROLE (YieldDistributor) for it and revokes both from a replaced deployment.
 *
 * Requires a YieldDistributor whose `distribute` pulls accrued yield first (else it reverts
 * DripExceedsCap), so deploy with its tags: `--tags YieldDistributor,VetBTCYieldDistributor,
 * YieldManager,VetBTCYieldManager`, then `--tags MultisigTxs`.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments} = hre
  const {get, getOrNull, read} = deployments
  const {maxAprBps, absoluteCap} = YieldManagerConfig.vusd

  const {address: peggedTokenAddress} = await get(PeggedToken)
  const {address: yieldDistributorAddress} = await get(YieldDistributor)
  const previousAddress = (await getOrNull(YieldManager))?.address

  const {address: yieldManagerAddress} = await deployNonUpgradeable(hre, YieldManager, [
    peggedTokenAddress,
    yieldDistributorAddress,
    maxAprBps,
    absoluteCap,
  ])

  const ummRole = await read(Treasury, 'UMM_ROLE')
  const distributorRole = await read(YieldDistributor, 'DISTRIBUTOR_ROLE')
  await grantRoleIfNeeded(hre, Treasury, ummRole, yieldManagerAddress)
  await grantRoleIfNeeded(hre, YieldDistributor, distributorRole, yieldManagerAddress)

  if (previousAddress && previousAddress !== yieldManagerAddress) {
    await revokeRoleIfNeeded(hre, Treasury, ummRole, previousAddress)
    await revokeRoleIfNeeded(hre, YieldDistributor, distributorRole, previousAddress)
  }
}

// No `dependencies`: this is an incremental script; running dependency scripts would redeploy
// drifted contracts. `get()` reads the existing artifacts instead.
func.tags = [YieldManager]

export default func
