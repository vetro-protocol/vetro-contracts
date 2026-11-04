import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, ContractAliases} from '../../../helpers'
import Address from '../../../helpers/address'

const {
  DerivedPriceFeedAdapter,
  FixedPriceFeedAdapter,
  CbBtcWbtcChainlinkFeed,
  CbBtcWbtcCurveEmaFeed,
  CbBtcWbtcPriceFeed,
} = ContractAliases

/**
 * Deploy the cbBTC/WBTC feed: min(Chainlink cbBTC/WBTC, Curve EMA cbBTC/WBTC)
 *
 * - Chainlink leg: the deployed cbBTC/BTC DerivedPriceFeedAdapter ÷ Chainlink WBTC/BTC
 * - Curve leg:     EMA of cbBTC (coin 1) in WBTC (coin 0), times the fixed 1.0 feed
 *
 * Deploy only. Wire it with `updateOracle(cbBTC, CbBtcWbtcPriceFeed, 90000)` from the Safe.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  if (['hardhat'].includes(hre.network.name)) {
    console.log('Skipping CbBtcWbtcPriceFeed on local network (mainnet addresses not available)')
    return
  }

  const {get} = hre.deployments
  const {address: cbBtcBtcFeed} = await get(DerivedPriceFeedAdapter)
  const {address: wbtcUnitFeed} = await get(FixedPriceFeedAdapter)

  const {address: chainlinkLeg} = await deployNonUpgradeable(
    hre,
    CbBtcWbtcChainlinkFeed,
    [cbBtcBtcFeed, Address.CHAINLINK_WBTC_BTC_FEED, 8],
    'DerivedPriceFeedAdapter'
  )

  const {address: curveLeg} = await deployNonUpgradeable(
    hre,
    CbBtcWbtcCurveEmaFeed,
    [Address.CURVE_WBTC_CBBTC_HEMIBTC_POOL, Address.CBBTC, 1, Address.WBTC, 0, wbtcUnitFeed],
    'CurveStableSwapNGEmaFeedAdapter'
  )

  await deployNonUpgradeable(hre, CbBtcWbtcPriceFeed, [chainlinkLeg, curveLeg, 18], 'MinPriceFeedAdapter')
}

func.tags = [CbBtcWbtcPriceFeed]
func.dependencies = [DerivedPriceFeedAdapter, FixedPriceFeedAdapter]

export default func
