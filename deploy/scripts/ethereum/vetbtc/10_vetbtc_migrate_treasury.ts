import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {ContractAliases} from '../../../helpers'
import {migrateTreasuryIfRequested} from '../../../helpers/treasury-migration'

const {VetBTC, VetBTCTreasury} = ContractAliases

/**
 * Migrate vetBTC collateral to a new Treasury that mirrors the live one
 *
 * Opt-in with MIGRATE_TREASURY=true; see 09_migrate_treasury.ts and deploy/helpers/treasury-migration.ts.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  await migrateTreasuryIfRequested(hre, {peggedTokenAlias: VetBTC, treasuryAlias: VetBTCTreasury})
}

// No `dependencies`: running them would redeploy drifted contracts; it reads the artifacts.
func.tags = ['MigrateVetBTCTreasury']

export default func
