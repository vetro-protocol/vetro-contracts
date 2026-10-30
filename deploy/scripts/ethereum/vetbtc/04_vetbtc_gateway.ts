import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployUpgradable, UpgradableContracts, ContractAliases} from '../../../helpers'
import {isTreasuryMigrated} from '../../../helpers/treasury-migration'
import {VetBTCGatewayConfig} from '../../../config'

const {VetBTC, VetBTCGateway} = ContractAliases

/**
 * Deploy Gateway for vetBTC — UPGRADEABLE
 *
 * Initialize args:
 * - asset_:           vetBTC token address
 * - mintLimit_:       maximum total mint cap
 * - withdrawalDelay_: withdrawal delay in seconds
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments} = hre
  const {get} = deployments

  const {address: vetBTCAddress} = await get(VetBTC)

  // The Gateway prices through the Treasury's peg band, which a Treasury from before the migration does not have
  if (!(await isTreasuryMigrated(hre, VetBTC))) {
    console.log(
      `${VetBTCGateway}: the live Treasury predates the migration, leaving the Gateway upgrade until it has run`
    )
    return
  }

  await deployUpgradable({
    hre,
    contractConfig: UpgradableContracts.VetBTCGateway,
    initializeArgs: [vetBTCAddress, VetBTCGatewayConfig.mintLimit, VetBTCGatewayConfig.withdrawalDelay],
  })
}

func.tags = [VetBTCGateway]
func.dependencies = [VetBTC]

export default func
