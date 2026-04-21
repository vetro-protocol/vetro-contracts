import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, ContractAliases} from '../../../helpers'
import Address from '../../../helpers/address'

const {DerivedPriceFeedAdapter} = ContractAliases

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  // Deploy DerivedPriceFeedAdapter to derive cbBTC/BTC price from Chainlink feeds:
  // - baseFeed:  cbBTC/USD
  // - quoteFeed: BTC/USD
  await deployNonUpgradeable(hre, DerivedPriceFeedAdapter, [
    Address.CHAINLINK_CBBTC_USD_FEED,
    Address.CHAINLINK_BTC_USD_FEED,
    8, // decimals_  (output precision, min 8)
  ])
}

func.tags = [DerivedPriceFeedAdapter]

export default func
