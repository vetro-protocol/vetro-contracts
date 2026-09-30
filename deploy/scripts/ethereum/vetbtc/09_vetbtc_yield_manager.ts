import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, grantRoleIfNeeded, revokeRoleIfNeeded, ContractAliases} from '../../../helpers'
import {YieldManagerConfig} from '../../../config'

const {VetBTC, VetBTCTreasury, VetBTCYieldDistributor, VetBTCYieldManager, YieldManager} = ContractAliases

/**
 * Deploy YieldManager for vetBTC: non-upgradeable keeper periphery
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
  const {maxAprBps, absoluteCap} = YieldManagerConfig.vetBTC

  const {address: vetBTCAddress} = await get(VetBTC)
  const {address: yieldDistributorAddress} = await get(VetBTCYieldDistributor)
  const previousAddress = (await getOrNull(VetBTCYieldManager))?.address

  // alias differs from the contract name, so pass the artifact explicitly
  const {address: yieldManagerAddress} = await deployNonUpgradeable(
    hre,
    VetBTCYieldManager,
    [vetBTCAddress, yieldDistributorAddress, maxAprBps, absoluteCap],
    YieldManager
  )

  const ummRole = await read(VetBTCTreasury, 'UMM_ROLE')
  const distributorRole = await read(VetBTCYieldDistributor, 'DISTRIBUTOR_ROLE')
  await grantRoleIfNeeded(hre, VetBTCTreasury, ummRole, yieldManagerAddress)
  await grantRoleIfNeeded(hre, VetBTCYieldDistributor, distributorRole, yieldManagerAddress)

  if (previousAddress && previousAddress !== yieldManagerAddress) {
    await revokeRoleIfNeeded(hre, VetBTCTreasury, ummRole, previousAddress)
    await revokeRoleIfNeeded(hre, VetBTCYieldDistributor, distributorRole, previousAddress)
  }
}

// No `dependencies`: this is an incremental script; running dependency scripts would redeploy
// drifted contracts. `get()` reads the existing artifacts instead.
func.tags = [VetBTCYieldManager]

export default func
