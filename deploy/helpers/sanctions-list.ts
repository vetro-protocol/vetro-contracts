import chalk from 'chalk'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable} from '.'
import {saveForMultiSigBatchExecution} from './gnosis-safe'
import {isTreasuryMigrated} from './treasury-migration'
import Address from './address'

const {log} = console

interface SanctionsListAliases {
  listAlias: string
  peggedTokenAlias: string
  treasuryAlias: string
}

/**
 * Deploys the SanctionsList for a PeggedToken (blacklist + RedStone oracle) and sets it on its Treasury, which the
 * Gateway and StakingVault check.
 *
 * They check the blacklist only through this list, so `updateSanctionsList` is queued in the same Safe batch as their
 * upgrade. A Treasury from before the migration has no list, and the Gateway and StakingVault upgrades wait for it too.
 */
export const deploySanctionsList = async (
  hre: HardhatRuntimeEnvironment,
  {listAlias, peggedTokenAlias, treasuryAlias}: SanctionsListAliases
): Promise<void> => {
  if (!(await isTreasuryMigrated(hre, peggedTokenAlias))) {
    log(chalk.yellow(`${listAlias}: the live Treasury predates the migration, leaving the list until it has run`))
    return
  }

  const {get, read, execute, catchUnknownSigner} = hre.deployments
  const {getAddress} = hre.ethers.utils

  const oracle = Address.REDSTONE_SANCTIONS_ORACLE
  if (!oracle) throw Error('REDSTONE_SANCTIONS_ORACLE is not configured for this network in deploy/config.ts')

  const {address: peggedToken} = await get(peggedTokenAlias)
  const {address: list} = await deployNonUpgradeable(hre, listAlias, [peggedToken, oracle], 'SanctionsList')

  let current: string | undefined
  try {
    current = await read(treasuryAlias, 'sanctionsList')
  } catch {
    // Live implementation predates the list: its upgrade is queued earlier in this batch
  }
  if (current && getAddress(current) === getAddress(list)) {
    log(chalk.blue(`${treasuryAlias}: sanctions list already ${list}`))
    return
  }

  // owner() is the DEFAULT_ADMIN_ROLE holder (AccessControlDefaultAdminRules)
  const admin: string = await read(treasuryAlias, 'owner')
  // `execute` estimates gas before it checks the signer, and the estimate reverts while the live implementation has no
  // setter yet. A fixed limit skips it so the setter is queued right after the upgrade.
  const options = current === undefined ? {from: admin, log: true, gasLimit: 100_000} : {from: admin, log: true}
  const multiSigTx = await catchUnknownSigner(execute(treasuryAlias, options, 'updateSanctionsList', list), {
    log: true,
  })
  if (multiSigTx) {
    await saveForMultiSigBatchExecution(multiSigTx)
    log(chalk.yellow(`  ⧗ ${treasuryAlias}.updateSanctionsList(${list}) queued for the Safe batch`))
  }
}
