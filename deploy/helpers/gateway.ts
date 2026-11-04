import chalk from 'chalk'
import {BigNumberish} from 'ethers'
import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployUpgradable} from '.'
import {getImplementation} from './eip1967'

const {log} = console

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

/** What a stack's Gateway script deploys, shared with the Treasury migration that carries the upgrade */
export interface GatewaySetup {
  peggedTokenAlias: string
  contractConfig: {alias: string; contract: string}
  config: {mintLimit: BigNumberish; withdrawalDelay: number}
}

/**
 * Whether the PeggedToken's live Treasury is behind a proxy, or not set yet. The Gateway prices through the Treasury's
 * peg band, which a Treasury from before the migration does not have, so the Gateway upgrades with the migration.
 */
export const isTreasuryMigrated = async (hre: HardhatRuntimeEnvironment, peggedTokenAlias: string) => {
  const treasury: string = await hre.deployments.read(peggedTokenAlias, 'treasury')
  if (treasury.toLowerCase() === ZERO_ADDRESS) return true
  return (await getImplementation(hre.ethers.provider, treasury)) !== ZERO_ADDRESS
}

/** Deploys the Gateway implementation after the storage check and queues the proxy upgrade for the Safe */
export const upgradeGateway = async (
  hre: HardhatRuntimeEnvironment,
  {peggedTokenAlias, contractConfig, config}: GatewaySetup
) => {
  const {address: peggedToken} = await hre.deployments.get(peggedTokenAlias)
  await deployUpgradable({
    hre,
    contractConfig,
    initializeArgs: [
      peggedToken, // peggedToken_
      config.mintLimit, // mintLimit_
      config.withdrawalDelay, // initialWithdrawalDelay_
    ],
  })
}

/**
 * The deploy script of a stack's Gateway. While the live Treasury predates the migration, the migration batch carries
 * the upgrade right after `migrate`, so skipping here keeps a routine run from queuing it a second time while that
 * batch is pending.
 */
export const gatewayDeployScript =
  (setup: GatewaySetup): DeployFunction =>
  async (hre: HardhatRuntimeEnvironment) => {
    if (!(await isTreasuryMigrated(hre, setup.peggedTokenAlias))) {
      log(
        chalk.blue(
          `${setup.contractConfig.alias}: the live Treasury predates the migration, its batch carries the Gateway upgrade`
        )
      )
      return
    }
    await upgradeGateway(hre, setup)
  }
