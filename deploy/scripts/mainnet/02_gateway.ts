import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployUpgradable, UpgradableContracts, ContractAliases} from '../../helpers'
import {GatewayConfig} from '../../config'

const {PeggedToken, Gateway} = ContractAliases

/**
 * Deploy Gateway (UPGRADEABLE)
 *
 * This is an UPGRADEABLE contract via OpenZeppelin v5 TransparentProxy pattern.
 * Uses the default OZ v5 ProxyAdmin (auto-created by the proxy, owned by GOVERNOR).
 *
 * Initialize args:
 * - peggedToken_: Address of the PeggedToken (VUSD) contract
 * - mintLimit_: Maximum total mint limit (e.g., 100M VUSD)
 * - initialWithdrawalDelay_: Withdrawal delay period (e.g., 7 days = 604800 seconds)
 *
 * The Gateway:
 * - Handles minting and redeeming of PeggedToken
 * - Uses Treasury for role management (reads roles from Treasury)
 * - Has withdrawal delay mechanism for security
 * - Supports AMO (Algorithmic Market Operations) minting
 *
 * After deployment:
 * 1. Call PeggedToken.updateGateway(gateway) - IMPORTANT: Must be done after Treasury is set
 * 2. Configure instant redeem whitelist if needed
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {deployments} = hre
  const {get} = deployments

  // Get the deployed PeggedToken address
  const {address: peggedTokenAddress} = await get(PeggedToken)

  await deployUpgradable({
    hre,
    contractConfig: UpgradableContracts.Gateway,
    initializeArgs: [
      peggedTokenAddress, // peggedToken_
      GatewayConfig.mintLimit, // mintLimit_
      GatewayConfig.withdrawalDelay, // initialWithdrawalDelay_
    ],
  })
}

func.tags = [Gateway]
func.dependencies = [PeggedToken]

export default func
