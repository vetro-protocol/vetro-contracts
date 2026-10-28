import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {ContractAliases} from '../../helpers'
import {migrateTreasuryIfRequested} from '../../helpers/treasury-migration'

const {PeggedToken, Treasury} = ContractAliases

/**
 * Migrate VUSD collateral to a new Treasury that mirrors the live one
 *
 * Opt-in with MIGRATE_TREASURY=true: deploys the compiled Treasury and queues a Safe batch that copies the live
 * collateral config, settings and role holders onto it, then calls updateTreasury and migrate. Execute the batch as
 * one Safe transaction, then re-run the deploy to verify the copy. See deploy/helpers/treasury-migration.ts.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  await migrateTreasuryIfRequested(hre, {peggedTokenAlias: PeggedToken, treasuryAlias: Treasury})
}

// No `dependencies`: running them would redeploy drifted contracts; it reads the artifacts.
func.tags = ['MigrateTreasury']

export default func
