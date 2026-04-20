import { DeployFunction } from 'hardhat-deploy/types'
import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { deployNonUpgradeable, ContractAliases } from '../../helpers'
import Address from '../../helpers/address'

const { DerivedPriceFeedAdapter } = ContractAliases

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  await deployNonUpgradeable(hre, DerivedPriceFeedAdapter, [
    Address.CHAINLINK_CBBTC_USD_FEED, // baseFeed  (cbBTC/USD)
    Address.CHAINLINK_BTC_USD_FEED,   // quoteFeed (BTC/USD)
  ])
}

func.tags = [DerivedPriceFeedAdapter]

export default func
