import {UpgradableContracts, ContractAliases} from '../../helpers'
import {GatewaySetup, gatewayDeployScript} from '../../helpers/gateway'
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
 *
 * The upgrade of a live Gateway rides in the Treasury migration batch (09_migrate_treasury.ts), see
 * deploy/helpers/gateway.ts.
 */
export const gatewaySetup: GatewaySetup = {
  peggedTokenAlias: PeggedToken,
  contractConfig: UpgradableContracts.Gateway,
  config: GatewayConfig,
}

const func = gatewayDeployScript(gatewaySetup)

func.tags = [Gateway]
func.dependencies = [PeggedToken]

export default func
