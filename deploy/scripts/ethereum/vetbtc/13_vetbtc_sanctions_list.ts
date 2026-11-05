import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {ContractAliases} from '../../../helpers'
import {deploySanctionsList} from '../../../helpers/sanctions-list'

const {VetBTC, VetBTCTreasury, VetBTCGateway, SVetBTC, VetBTCSanctionsList} = ContractAliases

/**
 * Deploy SanctionsList for vetBTC (vetBTC blacklist + RedStone sanctions oracle) and set it on the vetBTC Treasury
 *
 * Queued in the same Safe batch as the vetBTC Gateway and sVetBTC upgrades: they check sanctions only through it.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  await deploySanctionsList(hre, {
    listAlias: VetBTCSanctionsList,
    peggedTokenAlias: VetBTC,
    treasuryAlias: VetBTCTreasury,
  })
}

func.tags = [VetBTCSanctionsList]
func.dependencies = [VetBTC, VetBTCTreasury, VetBTCGateway, SVetBTC]

export default func
