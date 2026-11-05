import {UpgradableContracts, ContractAliases} from '../../../helpers'
import {GatewaySetup, gatewayDeployScript} from '../../../helpers/gateway'
import {VetBTCGatewayConfig} from '../../../config'

const {VetBTC, VetBTCGateway} = ContractAliases

/**
 * Deploy Gateway for vetBTC — UPGRADEABLE
 *
 * Initialize args:
 * - asset_:           vetBTC token address
 * - mintLimit_:       maximum total mint cap
 * - withdrawalDelay_: withdrawal delay in seconds
 *
 * The upgrade of a live Gateway rides in the Treasury migration batch (10_vetbtc_migrate_treasury.ts), see
 * deploy/helpers/gateway.ts.
 */
export const vetBTCGatewaySetup: GatewaySetup = {
  peggedTokenAlias: VetBTC,
  contractConfig: UpgradableContracts.VetBTCGateway,
  config: VetBTCGatewayConfig,
}

const func = gatewayDeployScript(vetBTCGatewaySetup)

func.tags = [VetBTCGateway]
func.dependencies = [VetBTC]

export default func
