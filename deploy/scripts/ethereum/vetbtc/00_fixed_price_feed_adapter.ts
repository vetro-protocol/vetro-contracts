import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, ContractAliases} from '../../../helpers'

const {FixedPriceFeedAdapter} = ContractAliases

/**
 * Deploy FixedPriceFeedAdapter for WBTC/BTC = 1.0
 *
 * WBTC is a 1:1 wrapped representation of BTC, so its price in BTC is hardcoded to 1.0.
 * Constructor args:
 * - price_:       100000000 (1.0 at 8-decimal precision, matching Chainlink BTC feeds)
 * - decimals_:    8
 * - description_: "WBTC / BTC"
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  await deployNonUpgradeable(hre, FixedPriceFeedAdapter, [
    100_000_000, // price_: 1.0 at 8 decimals
    8, // decimals_
    'WBTC / BTC', // description_
  ])
}

func.tags = [FixedPriceFeedAdapter]

export default func
