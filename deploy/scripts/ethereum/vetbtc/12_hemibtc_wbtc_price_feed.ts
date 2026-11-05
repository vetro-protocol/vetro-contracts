import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, ContractAliases} from '../../../helpers'
import Address from '../../../helpers/address'

const {FixedPriceFeedAdapter, HemiBtcWbtcChainlinkFeed, HemiBtcWbtcCurveEmaFeed, HemiBtcWbtcPriceFeed} = ContractAliases

/**
 * Deploy the hemiBTC/WBTC feed: min(Chainlink hemiBTC/WBTC, Curve EMA hemiBTC/WBTC)
 *
 * - Chainlink leg: Chainlink HEMIBTC/BTC exchange rate ÷ Chainlink WBTC/BTC. The exchange rate reads 1.0 while
 *                  the bridge holds, so this leg only lowers the price on a bridge rate cut or a WBTC premium.
 * - Curve leg:     EMA of hemiBTC (coin 2) in WBTC (coin 0), times the fixed 1.0 feed
 *
 * Deploy only. Wire it with `updateOracle(hemiBTC, HemiBtcWbtcPriceFeed, 90000)` from the Safe.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  if (['hardhat'].includes(hre.network.name)) {
    console.log('Skipping HemiBtcWbtcPriceFeed on local network (mainnet addresses not available)')
    return
  }

  const {address: wbtcUnitFeed} = await hre.deployments.get(FixedPriceFeedAdapter)

  const {address: chainlinkLeg} = await deployNonUpgradeable(
    hre,
    HemiBtcWbtcChainlinkFeed,
    [Address.HEMIBTC_BTC_ORACLE, Address.CHAINLINK_WBTC_BTC_FEED, 18],
    'DerivedPriceFeedAdapter'
  )

  const {address: curveLeg} = await deployNonUpgradeable(
    hre,
    HemiBtcWbtcCurveEmaFeed,
    [Address.CURVE_WBTC_CBBTC_HEMIBTC_POOL, Address.HEMIBTC, 2, Address.WBTC, 0, wbtcUnitFeed],
    'CurveStableSwapNGEmaFeedAdapter'
  )

  await deployNonUpgradeable(hre, HemiBtcWbtcPriceFeed, [chainlinkLeg, curveLeg, 18], 'MinPriceFeedAdapter')
}

func.tags = [HemiBtcWbtcPriceFeed]
func.dependencies = [FixedPriceFeedAdapter]

export default func
