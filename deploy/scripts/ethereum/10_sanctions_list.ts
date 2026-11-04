import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {ContractAliases} from '../../helpers'
import {deploySanctionsList} from '../../helpers/sanctions-list'

const {PeggedToken, Treasury, Gateway, StakingVault, SanctionsList} = ContractAliases

/**
 * Deploy SanctionsList for VUSD (VUSD blacklist + RedStone sanctions oracle) and set it on the Treasury
 *
 * The Gateway and StakingVault check sanctions only through the Treasury's list, so the setter is queued in the same
 * Safe batch as their upgrade. A later list version is a new deployment plus this one setter.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  await deploySanctionsList(hre, {
    listAlias: SanctionsList,
    peggedTokenAlias: PeggedToken,
    treasuryAlias: Treasury,
  })
}

func.tags = [SanctionsList]
func.dependencies = [PeggedToken, Treasury, Gateway, StakingVault]

export default func
